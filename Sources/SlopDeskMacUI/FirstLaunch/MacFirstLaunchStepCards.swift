// MacFirstLaunchStepCards — the two CROSS-PLATFORM checklist steps, in AppKit.
//
// docs/56 stage D, increment 47. These two bodies — On-Launch and the Claude-hooks install — used to be
// one SwiftUI surface (`FirstLaunchStepSurface`) that ``MacFirstLaunchController`` hosted in an
// `NSHostingView`, and that host was the LAST thing any Mac file imported `SlopDeskClientUI` for. They
// are `NSView`s now, drawn by the same hand that already draws the sheet's shell, its header, its footer
// and its other two steps, so the checklist has one renderer instead of two stitched at a card boundary.
//
// ⚠️ THE PAINTING CROSSED; NO ANSWER DID. Every word here, the picker's options and their order, which
// install state earns a badge rather than a button, and whether an install ticks the step come from
// ``FirstLaunchStepPresentation`` in `SlopDeskClientCore` — below both halves, so the phone's
// `FirstLaunchView` reads the same answers and neither half can correct a word in one renderer and leave
// it stale in the other. What each half keeps is the HUE, and only because it must: `SlopDeskSlate`
// depends on `SlopDeskClientCore`, so an ink cannot descend to the answer without becoming a cycle. A
// badge names its silhouette (one SF-Symbol name both halves ask for) and this file spells the two
// status inks natively, the way every other Mac surface does.
//
// A REBUILD IS THE UPDATE, the same rule ``MacCLIInstallCard`` states: `AgentHooksController` is
// `@Observable` and AppKit has no invalidation to hang on that, so the hooks card redraws its own
// trailing slot whenever it drives the controller — on the appear-probe, and on either side of an
// install. The On-Launch card has nothing to observe: its only writer is the radio the reader clicked.

import AppKit
import Defaults
import SlopDeskClientCore // FirstLaunchStepPresentation — the answers both halves read
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore // AgentHooksController, OnLaunchBehavior

// MARK: - Step 1 · On Launch

/// The On-Launch choice, as a radio group over the live `Defaults[.onLaunch]` key — the SAME key
/// Settings → General binds, so the checklist is not a separate copy of the setting but the setting
/// itself, reached early.
///
/// A radio group rather than the pop-up the settings rows favour: there are two options, both are one
/// short phrase, and the whole point of the step is that a first-time reader SEES both answers without
/// opening anything. That is a radio group's one job on this platform.
@MainActor
final class MacOnLaunchCard: NSStackView {
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Slate.Metric.space3
        translatesAutoresizingMaskIntoConstraints = false

        let radios = MacOnLaunchRadios(selected: Defaults[.onLaunch]) { Defaults[.onLaunch] = $0 }
        addArrangedSubview(radios)

        let note = NSTextField(wrappingLabelWithString: FirstLaunchStepPresentation.onLaunchNote)
        note.font = .preferredFont(forTextStyle: .caption1)
        note.textColor = Slate.Native.Text.tertiary
        note.isSelectable = false
        addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }
}

/// The radio buttons themselves, one per ``FirstLaunchStepPresentation/onLaunchOptions`` entry.
///
/// ⚠️ THE GROUP IS EXPLICIT, not AppKit's implicit one. Radio buttons sharing a superview and an action
/// deselect each other automatically, but that arrangement resolves the reader's choice from whichever
/// button happens to be `.on` — so this owns one target, one selector, and sets all the states itself
/// from the OPTION it resolved. The reader's choice is then a value from the shared list, never a view's
/// index, which is what keeps a third option (should one ever land) from silently reading as the first.
@MainActor
private final class MacOnLaunchRadios: NSStackView {
    private let onPick: (OnLaunchBehavior) -> Void
    private var choices: [(option: OnLaunchBehavior, button: NSButton)] = []

    init(selected: OnLaunchBehavior, onPick: @escaping (OnLaunchBehavior) -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Slate.Metric.space1
        translatesAutoresizingMaskIntoConstraints = false
        for option in FirstLaunchStepPresentation.onLaunchOptions {
            let button = NSButton(radioButtonWithTitle: option.title, target: self, action: #selector(pick))
            button.state = option == selected ? .on : .off
            addArrangedSubview(button)
            choices.append((option, button))
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    @objc
    private func pick(_ sender: NSButton) {
        guard let choice = choices.first(where: { $0.button === sender })?.option else { return }
        for entry in choices { entry.button.state = entry.option == choice ? .on : .off }
        onPick(choice)
    }
}

// MARK: - Step 4 · Install Claude Code hooks

/// The Claude-Code hooks card: what installing does, and the one control that does it.
///
/// `onInstalled` fires when the write actually landed — the checklist step marks itself complete with
/// it, on the same terms ``MacCLIInstallCard`` and ``MacOSIntegrationRows`` use.
@MainActor
final class MacClaudeHooksCard: NSStackView {
    private let agentHooks: AgentHooksController?
    private let onInstalled: () -> Void

    /// The trailing slot: the Install button (live or dead), a finished badge, or a spinner.
    private let slot = NSStackView()
    /// The "connect a session first" note, hidden while there is a pane behind the card. Built once and
    /// hidden rather than added and removed, so the card's height does not shudder on every redraw.
    private let note = NSTextField(wrappingLabelWithString: FirstLaunchStepPresentation.hooksConnectNote)

    init(agentHooks: AgentHooksController?, onInstalled: @escaping () -> Void) {
        self.agentHooks = agentHooks
        self.onInstalled = onInstalled
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Slate.Metric.space3
        translatesAutoresizingMaskIntoConstraints = false

        slot.orientation = .horizontal
        slot.alignment = .centerY
        slot.spacing = Slate.Metric.space1

        let name = NSTextField(labelWithString: FirstLaunchStepPresentation.hooksAgentName)
        name.font = .preferredFont(forTextStyle: .body)
        let blurb = NSTextField(wrappingLabelWithString: FirstLaunchStepPresentation.hooksBlurb)
        blurb.font = .preferredFont(forTextStyle: .caption1)
        blurb.textColor = Slate.Native.Text.secondary
        blurb.isSelectable = false

        let words = NSStackView(views: [name, blurb])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = Slate.Metric.space1 / 2

        let row = NSStackView(views: [words, slot])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Slate.Metric.space3
        words.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slot.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        slot.setContentCompressionResistancePriority(.required, for: .horizontal)
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        note.font = .preferredFont(forTextStyle: .caption1)
        note.textColor = Slate.Native.Text.tertiary
        note.isSelectable = false
        addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        redraw()
        // The appear-probe the SwiftUI half spells `.task { await agentHooks?.refresh() }`. The card is
        // re-checked each time the sheet opens rather than trusting a cached answer: the pane that backs
        // it can have come or gone since, and a stale "not installed" is what makes a reader install
        // twice.
        Task { @MainActor [weak self] in
            await agentHooks?.refresh()
            self?.redraw()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // MARK: The live slot

    /// Draw the slot and the note from the controller's CURRENT state. Cheap enough to run on every
    /// transition — the card is three views and is only ever on screen while its own step is.
    private func redraw() {
        clearSlot()
        note.isHidden = !FirstLaunchStepPresentation.showsConnectNote(agentHooks)

        switch FirstLaunchStepPresentation.hooksControl(agentHooks) {
        case let .badge(badge):
            slot.addArrangedSubview(badgeView(badge))
        case let .offerInstall(enabled):
            let button = MacActionButton(title: FirstLaunchStepPresentation.hooksInstallTitle) { [weak self] in
                self?.install()
            }
            // DISABLED, never hidden: the step has to keep saying what it is for while nothing backs it,
            // and the note beside it says why the button is dead.
            button.isEnabled = enabled
            slot.addArrangedSubview(button)
        case .working:
            slot.addArrangedSubview(spinner())
        }
    }

    /// A finished state: the badge's own word and silhouette, in this renderer's spelling of the status
    /// ink. The hint rides as the tooltip — the AppKit register the SwiftUI half reaches with `.help`.
    private func badgeView(_ badge: FirstLaunchHooksBadge) -> NSView {
        let ink = badge == .installed ? Slate.Native.StatusInk.ok : Slate.Native.StatusInk.warn
        let mark = NSImageView(
            image: NSImage(systemSymbolName: badge.systemImage, accessibilityDescription: nil) ?? NSImage(),
        )
        mark.contentTintColor = ink
        let label = NSTextField(labelWithString: badge.label)
        label.textColor = ink

        let row = NSStackView(views: [mark, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space1
        row.toolTip = badge.hint
        return row
    }

    /// Empty the slot. `removeArrangedSubview` alone only stops a view being LAID OUT — it stays a
    /// subview and keeps drawing, which is how a spinner ends up sitting behind the badge that replaced it.
    private func clearSlot() {
        for view in slot.arrangedSubviews {
            slot.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func spinner() -> NSView {
        let wheel = NSProgressIndicator()
        wheel.style = .spinning
        wheel.controlSize = .small
        wheel.startAnimation(nil)
        return wheel
    }

    /// Run the install, showing the spinner for its whole duration.
    ///
    /// ⚠️ THE SPINNER IS PUT UP HERE, not read back out of the controller. `install()` claims
    /// ``AgentHooksController/InstallState/working`` as its first statement, but that statement runs on the
    /// hop the `Task` yields — so a ``redraw()`` issued before the `await` still sees the OLD state and
    /// draws the button that was just pressed. Owning the transition here is two lines and has no ordering
    /// to get wrong; ``FirstLaunchHooksControl/working`` still covers the other way in, which is a write
    /// started from Settings while this sheet is up.
    private func install() {
        guard let agentHooks else { return }
        clearSlot()
        slot.addArrangedSubview(spinner())
        Task { @MainActor [weak self] in
            await agentHooks.install()
            guard let self else { return }
            redraw()
            // The `settings.json` WRITE is what this step tracks, so an unbound listener still completes
            // it — see ``FirstLaunchStepPresentation/completesHooksStep(_:)``.
            if FirstLaunchStepPresentation.completesHooksStep(agentHooks) { onInstalled() }
        }
    }
}
