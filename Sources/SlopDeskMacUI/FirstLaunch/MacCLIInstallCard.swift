// MacCLIInstallCard — putting `slopdesk` on the PATH.
//
// The `/usr/local/bin/slopdesk` symlink (one admin escalation, through `CLIInstaller`), the Omit-Prefix
// shell-function toggle, and the Allow-Overwrite toggle that guards it. Reached from the guided
// first-launch step 3 and from Settings → Shell, which is the same reason `MacOSIntegrationRows` exists
// once: the card was written twice and the two copies had started to drift.
//
// A REBUILD IS THE UPDATE, for the same reason the settings page rebuilds: `CLIInstaller` is
// `@Observable`, which AppKit has no invalidation to hang on, and the states this card can be in are
// four (idle, working, installed, failed). It redraws its own install row when the installer's phase
// moves and leaves the toggles — which are `Defaults`-backed and change only when clicked — alone.
//
// macOS-only in the strongest sense: there is no `/usr/local/bin` and no `osascript` on the phone, so
// there is no second half of this to keep in step with.

import AppKit
import Defaults
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

/// The "SlopDesk CLI" card.
///
/// `onInstalled` fires when an install SUCCEEDS — the first-launch step marks itself complete with it;
/// Settings passes nothing, because a settings page has no checklist.
@MainActor
final class MacCLIInstallCard: NSStackView {
    private let installer = CLIInstaller()
    private let onInstalled: () -> Void

    /// The install row's trailing slot: the button, the ✓ + Uninstall pair, or a spinner.
    private let slot = NSStackView()
    /// The last failure's reason, hidden while there is none — a cancelled admin prompt is a normal
    /// outcome, not an error state the card should wear permanently.
    private let failure = NSTextField(wrappingLabelWithString: "")

    init(onInstalled: @escaping () -> Void = {}) {
        self.onInstalled = onInstalled
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Slate.Metric.space3
        translatesAutoresizingMaskIntoConstraints = false

        slot.orientation = .horizontal
        slot.alignment = .centerY
        slot.spacing = Slate.Metric.space2

        addRow(
            "Install CLI",
            "Adds `/usr/local/bin/slopdesk` (requests admin once).",
            slot,
        )
        addSeparator()
        addToggle(
            "Omit `slopdesk` Prefix",
            "Expose `edit`, `view`, `watch`, `jump`, and `learn` as bare commands in shells launched by "
                + "SlopDesk.",
            get: { Defaults[.omitCLIPrefix] },
            set: { [installer] on in
                Defaults[.omitCLIPrefix] = on
                installer.applyOmitPrefix(enabled: on, allowOverwrite: Defaults[.allowPrefixOverwrite])
            },
        )
        addToggle(
            "Allow Overwrite",
            "Leave OFF unless you already have your own `edit`/`view`/… functions you want SlopDesk to "
                + "replace.",
            get: { Defaults[.allowPrefixOverwrite] },
            set: { [installer] on in
                Defaults[.allowPrefixOverwrite] = on
                // Only re-writes the shim while the prefix functions are actually installed — flipping
                // the guard alone must not create a file the reader did not ask for.
                if Defaults[.omitCLIPrefix] { installer.applyOmitPrefix(enabled: true, allowOverwrite: on) }
            },
        )

        failure.font = .preferredFont(forTextStyle: .caption1)
        failure.textColor = Slate.Native.Text.tertiary
        failure.isSelectable = false
        failure.isHidden = true
        addArrangedSubview(failure)
        failure.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        installer.refreshInstalled()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // MARK: The live row

    private func refresh() {
        for view in slot.arrangedSubviews {
            slot.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        failure.stringValue = installer.errorMessage ?? ""
        failure.isHidden = installer.phase != .failed || installer.errorMessage == nil

        if installer.phase == .working {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            slot.addArrangedSubview(spinner)
            return
        }
        guard Defaults[.cliInstalled] else {
            slot.addArrangedSubview(MacActionButton(title: "Install") { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.refresh() // the phase is `.working` now — show the spinner while the prompt is up
                    let ok = await self.installer.install()
                    self.refresh()
                    if ok { self.onInstalled() }
                }
            })
            return
        }
        let mark = NSImageView(
            image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) ?? NSImage(),
        )
        mark.contentTintColor = Slate.Native.StatusInk.ok
        let label = NSTextField(labelWithString: "Installed")
        label.textColor = Slate.Native.StatusInk.ok
        slot.addArrangedSubview(mark)
        slot.addArrangedSubview(label)
        slot.addArrangedSubview(MacActionButton(title: "Uninstall") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                await self.installer.uninstall()
                self.refresh()
            }
        })
    }

    // MARK: Card chrome

    private func addRow(_ title: String, _ subtitle: String, _ trailing: NSView) {
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

    private func addToggle(
        _ title: String,
        _ note: String,
        get: () -> Bool,
        set: @escaping (Bool) -> Void,
    ) {
        let toggle = MacActionSwitch(set)
        toggle.state = get() ? .on : .off
        let label = NSTextField(labelWithString: title)
        label.font = .preferredFont(forTextStyle: .body)

        let row = NSStackView(views: [label, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space3
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        let caption = NSTextField(wrappingLabelWithString: note)
        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.textColor = Slate.Native.Text.tertiary
        caption.isSelectable = false
        addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func addSeparator() {
        let rule = NSBox()
        rule.boxType = .separator
        addArrangedSubview(rule)
        rule.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}
