// MacOSIntegrationRows — registering SlopDesk with the Mac it is running on.
//
// The Default-Terminal status, the honestly-unavailable "Common Apps" case, and the two System-Settings
// deep-links. `DefaultTerminalIntegration` is where the behaviour lives; this is the four rows over it.
//
// THIS EXISTS ONCE BECAUSE IT IS ONE SURFACE. It is reached from two places — the guided first-launch
// step 2, and Settings → General → OS Integration — and until this file it was written twice, in two
// SwiftUI structs, with the four titles and the four subtitles typed out on both sides. They had already
// begun to be maintained separately (only one of them marked the first-launch step complete). One view,
// two call sites, and the only difference between them is whether anybody is listening for the
// registration to succeed.
//
// AppKit rather than a hosted SwiftUI view because it is macOS-only in the strongest sense: every row
// here calls into LaunchServices or opens a System Settings pane, neither of which exists on the phone.
// There is no second half to keep in step with, so there is nothing to gain from drawing it in the
// framework the phone would need.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

/// The four OS-integration rows.
///
/// `onDefaultTerminalSet` fires once the registration actually takes — the first-launch step marks
/// itself complete with it, and Settings passes nothing because a settings page has no checklist.
@MainActor
final class MacOSIntegrationRows: NSStackView {
    private let onDefaultTerminalSet: () -> Void
    /// The Default-Terminal row's trailing slot, swapped between the Set button and the ✓ — the one
    /// thing here that is a live fact about the machine rather than a static row.
    private let defaultTerminalSlot = NSStackView()

    init(onDefaultTerminalSet: @escaping () -> Void = {}) {
        self.onDefaultTerminalSet = onDefaultTerminalSet
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Slate.Metric.space3
        translatesAutoresizingMaskIntoConstraints = false

        defaultTerminalSlot.orientation = .horizontal
        defaultTerminalSlot.alignment = .centerY

        add(
            "Default Terminal",
            "Handle `ssh://` links and shell scripts opened from Finder or `open`.",
            defaultTerminalSlot,
        )
        // The remote case is UNAVAILABLE, and says so instead of offering a button that cannot work: an
        // editor on the remote host would need a host-side agent to have its config rewritten.
        add(
            "Default Terminal for Common Apps",
            "Editors and git GUIs hardcode Terminal.app. Rewriting their config only works for a LOCAL "
                + "editor — an editor on the remote host needs a host-side agent, so this is unavailable "
                + "in the remote model.",
            unavailable(),
        )
        add(
            "Finder Integration",
            "Add \u{201C}Open in SlopDesk\u{201D} to Finder's right-click Services menu for folders.",
            button("Open System Settings") { DefaultTerminalIntegration.openFinderServicesSettings() },
        )
        add(
            "Full Disk Access",
            "Needed when commands run inside SlopDesk must read or write protected files. The app works "
                + "without it.",
            button("Open System Settings") { DefaultTerminalIntegration.openFullDiskAccessSettings() },
        )
        refreshDefaultTerminal()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // MARK: The one live row

    /// Ask LaunchServices who handles a terminal script right now and draw that answer.
    private func refreshDefaultTerminal() {
        for view in defaultTerminalSlot.arrangedSubviews {
            defaultTerminalSlot.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !DefaultTerminalIntegration.isDefaultTerminal() else {
            let mark = NSImageView(
                image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) ?? NSImage(),
            )
            mark.contentTintColor = Slate.Native.StatusInk.ok
            let label = NSTextField(labelWithString: "Default")
            label.textColor = Slate.Native.StatusInk.ok
            defaultTerminalSlot.addArrangedSubview(mark)
            defaultTerminalSlot.addArrangedSubview(label)
            return
        }
        defaultTerminalSlot.addArrangedSubview(button("Set as Default Terminal") { [weak self] in
            Task { @MainActor in
                await DefaultTerminalIntegration.setAsDefaultTerminal()
                guard let self else { return }
                self.refreshDefaultTerminal()
                if DefaultTerminalIntegration.isDefaultTerminal() { self.onDefaultTerminalSet() }
            }
        })
    }

    // MARK: Row chrome

    /// A bold title over its wrapping gray subtitle, with the action trailing.
    private func add(_ title: String, _ subtitle: String, _ trailing: NSView) {
        let name = NSTextField(labelWithString: title)
        name.font = .preferredFont(forTextStyle: .body)
        let detail = NSTextField(wrappingLabelWithString: subtitle)
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.textColor = Slate.Native.Text.secondary
        detail.isSelectable = false

        let words = NSStackView(views: [name, detail])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = Slate.Metric.space1 / 2

        let row = NSStackView(views: [words, trailing])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Slate.Metric.space3
        words.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func unavailable() -> NSView {
        let label = NSTextField(labelWithString: "Unavailable")
        label.textColor = Slate.Native.Text.tertiary
        return label
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let control = MacActionButton(title: title, action)
        control.bezelStyle = .rounded
        return control
    }
}
