// MacSettingsBespokeSurfaces — the three small bespoke groups, in AppKit.
//
// docs/56 stage D, increment 49. `SettingsBespokeSurface` was the last thing `SlopDeskMacUI` imported
// `SlopDeskClientUI` for, and it was one `NSHostingView` standing in for eight surfaces at once. The three
// smallest are here — the Editor page's empty state, the Claude-hooks card and the notification-permission
// row — and the four larger ones are in the files beside this one. What each of them keeps in common is
// the rule increment 47 set: THE PAINTING CROSSED; NO ANSWER DID.
//
// Every word below, every state→control fold and every dot→meaning mapping is read from
// `SettingsBespokePresentation` in `SlopDeskClientCore`, one floor under both halves, so the phone's
// `SettingsBespokeSurface` reads the same answers and neither renderer can correct a sentence in one place
// and leave it stale in the other. What each half keeps is the HUE, and only because it must: Slate DEPENDS
// on ClientCore, so an ink cannot descend to an answer without becoming a cycle. The shared side therefore
// names a ROLE (``SettingsProseInk``) and this file resolves it once, in ``SettingsProseInk/nativeInk``.
//
// A REBUILD IS THE UPDATE — the rule the whole AppKit settings page runs on (`MacSettingsPage`) and the
// one `MacClaudeHooksCard` states for the checklist. `AgentHooksController` is `@Observable` and AppKit has
// no invalidation to hang on that, so the hooks rows redraw themselves whenever they drive the controller.

import AppKit
import SlopDeskClientCore // the answers both halves read
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore
import UserNotifications

// MARK: - The one place a shared role becomes a colour

extension SettingsProseInk {
    /// This renderer's spelling of a role the shared side named.
    ///
    /// The four status angles take ``Slate/Native/StatusInk`` rather than `Native.Status`: those are the
    /// SOLVED angles for MARKS AND WORDS, and everything a bespoke surface tints is one or the other. The
    /// group timing chip beside them keeps `Native.Status` because a chip is a FILL.
    ///
    /// `@MainActor` because the ladder it reads is: an `NSColor` resolved from the active appearance is
    /// main-actor state, and every caller here is already building views on it.
    @MainActor
    var nativeInk: NSColor {
        switch self {
        case .primary: Slate.Native.Text.primary
        case .secondary: Slate.Native.Text.secondary
        case .tertiary: Slate.Native.Text.tertiary
        case .ok: Slate.Native.StatusInk.ok
        case .warn: Slate.Native.StatusInk.warn
        case .err: Slate.Native.StatusInk.err
        case .info: Slate.Native.StatusInk.info
        }
    }
}

/// A wrapping caption in one of the shared roles — the shape four of these surfaces' prose takes.
///
/// `isSelectable = false` on purpose: a settings caption that takes a text cursor reads as a field the
/// reader failed to edit.
@MainActor
func macSettingsNote(
    _ words: String, _ ink: SettingsProseInk = .secondary, style: NSFont.TextStyle = .caption1,
) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: words)
    label.font = .preferredFont(forTextStyle: style)
    label.textColor = ink.nativeInk
    label.isSelectable = false
    return label
}

// MARK: - Editor (reserved)

/// The Editor page, which has no settings and says so.
///
/// An empty STATE rather than a "File editor — Not available" row: the latter read as a broken control, and
/// a page with no groups at all is indistinguishable from a page this build predates. Centred, because the
/// whole page is this one card.
@MainActor
final class MacEditorEmptyCard: NSStackView {
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = Slate.Metric.space2
        edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space4, left: 0, bottom: Slate.Metric.space4, right: 0,
        )
        translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView(
            image: NSImage(
                systemSymbolName: SettingsEditorEmpty.systemImage, accessibilityDescription: nil,
            ) ?? NSImage(),
        )
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .largeTitle)
        glyph.contentTintColor = Slate.Native.Text.tertiary
        addArrangedSubview(glyph)

        let title = NSTextField(labelWithString: SettingsEditorEmpty.title)
        title.font = .preferredFont(forTextStyle: .headline)
        addArrangedSubview(title)

        let blurb = macSettingsNote(SettingsEditorEmpty.blurb, .secondary, style: .subheadline)
        blurb.alignment = .center
        addArrangedSubview(blurb)
        blurb.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }
}

// MARK: - Agents → Claude Code

/// The Install-Hooks row, its Status row, and the two notes either can raise.
///
/// Distinct from ``MacClaudeHooksCard``, which is the first-launch checklist's step: that one offers a
/// badge with nothing to press once the write lands, and this one keeps Uninstall actionable so the
/// integration can be taken back off. The two folds are named separately in `SlopDeskClientCore` for
/// exactly that reason, over the ONE install state.
@MainActor
final class MacHooksSettingsRows: NSStackView {
    private let agentHooks: AgentHooksController?

    /// The trailing buttons for the Install-Hooks row: a spinner, an offer, or the installed pair.
    private let slot = NSStackView()
    /// The Status row's trailing readout.
    private let status = NSStackView()
    /// Built once and HIDDEN rather than added and removed, so the page's height does not shudder on a
    /// redraw that only changed which note applies.
    private let connectNote = macSettingsNote(SettingsHooksCard.connectNote, .tertiary)
    private let inactiveNote = macSettingsNote(SettingsHooksCard.inactiveNote, .warn)

    init(agentHooks: AgentHooksController?) {
        self.agentHooks = agentHooks
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Slate.Metric.space3
        translatesAutoresizingMaskIntoConstraints = false

        for row in [slot, status] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Slate.Metric.space2
        }

        let rows = [
            trailingRow(macRowLabel(SettingsHooksCard.rowTitle, SettingsHooksCard.rowBlurb), slot),
            trailingRow(NSTextField(labelWithString: SettingsHooksCard.statusRowTitle), status),
        ]
        for row in rows {
            addArrangedSubview(row)
            // AFTER the add, never inside the builder: a constraint between two views with no common
            // ancestor yet raises at activation time rather than waiting for one.
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        for note in [connectNote, inactiveNote] {
            addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        addArrangedSubview(macSettingsNote(SettingsHooksCard.restartCaption, .tertiary))

        redraw()
        // The appear-probe the SwiftUI half spells `.task { await agentHooks?.refresh() }`. Re-checked on
        // every open rather than trusting a cached answer: the pane behind the card can have come or gone
        // since, and a stale "not installed" is what makes a reader install twice.
        Task { @MainActor [weak self] in
            await agentHooks?.refresh()
            self?.redraw()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    // MARK: The live slots

    /// Draw both trailing slots and both notes from the controller's CURRENT state.
    private func redraw() {
        connectNote.isHidden = !SettingsHooksCard.showsConnectNote(agentHooks)
        inactiveNote.isHidden = !SettingsHooksCard.showsInactiveNote(agentHooks)

        clear(slot)
        switch SettingsHooksCard.buttons(agentHooks) {
        case .offerUninstall:
            // The entries are on disk either way, so Uninstall stays live beside the dead state pill.
            let installed = MacActionButton(title: SettingsHooksCard.installedTitle) {}
            installed.isEnabled = false
            slot.addArrangedSubview(installed)
            slot.addArrangedSubview(
                MacActionButton(title: SettingsHooksCard.uninstallTitle) { [weak self] in
                    self?.drive { await $0.uninstall() }
                },
            )
        case let .offerInstall(enabled):
            let install = MacActionButton(title: SettingsHooksCard.installTitle) { [weak self] in
                self?.drive { await $0.install() }
            }
            // DISABLED, never hidden: the row has to keep saying what it is for while nothing backs it,
            // and the note under it says why the button is dead.
            install.isEnabled = enabled
            slot.addArrangedSubview(install)
        case .working:
            slot.addArrangedSubview(spinner())
        }

        clear(status)
        let reading = SettingsHooksCard.status(agentHooks)
        if let symbol = reading.systemImage {
            let mark = NSImageView(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
            )
            mark.contentTintColor = reading.ink.nativeInk
            status.addArrangedSubview(mark)
        }
        let word = NSTextField(labelWithString: reading.label)
        word.textColor = reading.ink.nativeInk
        status.addArrangedSubview(word)
    }

    /// Run a write, showing the spinner for its whole duration.
    ///
    /// ⚠️ THE SPINNER IS PUT UP HERE, not read back out of the controller — the trap
    /// ``MacClaudeHooksCard`` records: `install()` claims `.working` as its first statement, but that
    /// statement runs on the hop the `Task` yields, so a redraw issued before the `await` still sees the
    /// OLD state and redraws the button that was just pressed.
    private func drive(_ work: @escaping (AgentHooksController) async -> Void) {
        guard let agentHooks else { return }
        clear(slot)
        slot.addArrangedSubview(spinner())
        Task { @MainActor [weak self] in
            await work(agentHooks)
            self?.redraw()
        }
    }

    /// Empty a slot. `removeArrangedSubview` alone only stops a view being LAID OUT — it stays a subview
    /// and keeps drawing, which is how a spinner ends up sitting behind the badge that replaced it.
    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
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

    private func trailingRow(_ label: NSView, _ control: NSView) -> NSView {
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Slate.Metric.space3
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }
}

// MARK: - Shell → Notification → System Permission

/// The OS-grant status row: a coloured dot, what the grant means in words, and the door to change it.
///
/// It edits no setting, which is why the layout table gives it a bespoke id rather than a key: what it
/// shows is the state of a permission, and no toggle in this window can move it.
///
/// ⚠️ NEVER INSTANTIATED IN A TEST. `UNUserNotificationCenter.current()` traps without a bundle — the same
/// hang/crash-safety boundary the video sessions keep — which is why the DECISION behind the dot is
/// `PermissionStatus.dot(forAuthorization:)`, pure and pinned headlessly, and this only asks and draws.
@MainActor
final class MacNotificationPermissionRow: NSStackView {
    /// The dot starts AMBER (unknown) and never a false green: the query is async, and the honest reading
    /// of "we have not asked yet" is the same one as "the OS will prompt".
    private var dot: PermissionStatus.Dot = .amber

    private let mark = MacPermissionDotView()
    private let subtitle = macSettingsNote(SettingsPermissionRow.subtitle(.amber), .secondary)

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = Slate.Metric.space3
        translatesAutoresizingMaskIntoConstraints = false

        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: MacPermissionDotView.size),
            mark.heightAnchor.constraint(equalToConstant: MacPermissionDotView.size),
        ])

        let title = NSTextField(labelWithString: SettingsPermissionRow.title)
        title.font = .preferredFont(forTextStyle: .body)
        let words = NSStackView(views: [title, subtitle])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = Slate.Metric.space1 / 2

        let button = MacActionButton(title: SettingsPermissionRow.buttonTitle) {
            // The custom `x-apple.systempreferences:` scheme routes through LaunchServices, which is what
            // `ExternalOpen` wraps — no `NSWorkspace` call site of its own.
            guard let url = URL(string: SettingsPermissionRow.macPreferencesURL) else { return }
            ExternalOpen.url(url)
        }
        button.controlSize = .small

        let leading = NSStackView(views: [mark, words])
        leading.orientation = .horizontal
        leading.alignment = .centerY
        leading.spacing = Slate.Metric.space2

        addArrangedSubview(leading)
        addArrangedSubview(button)
        leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        apply()
        // The `rawValue` Int is taken INSIDE the await so the non-`Sendable` `UNNotificationSettings`
        // never crosses the actor hop — only the `Int` does (Swift 6 region isolation).
        Task { @MainActor [weak self] in
            let raw = await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus.rawValue
            self?.dot = PermissionStatus.dot(forAuthorization: raw)
            self?.apply()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    private func apply() {
        mark.ink = SettingsPermissionRow.ink(dot)
        subtitle.stringValue = SettingsPermissionRow.subtitle(dot)
    }
}

/// The permission dot itself.
///
/// DRAWN rather than a tinted layer: every ink in the ladder is a DYNAMIC `NSColor`, and a `CGColor` set on
/// a layer is resolved once — the dot would keep its light-mode green after a switch to dark. `draw(_:)`
/// resolves against the view's own effective appearance every time, which is the whole reason AppKit still
/// has one.
@MainActor
private final class MacPermissionDotView: NSView {
    /// The smallest mark this window draws. Not `StatusDot.footprint`: that reading carries the rail's hit
    /// box with it, and this dot is a readout in a text row with nothing to press.
    static let size: CGFloat = 8

    var ink: SettingsProseInk = .warn {
        didSet { needsDisplay = true }
    }

    override func draw(_: NSRect) {
        ink.nativeInk.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
