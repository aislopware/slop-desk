// MacGuiPaneControls — the remote-window pane's footer bar and its readouts, in AppKit
// (docs/56 wave R, batch R10, second of three files).
//
// The AppKit halves of `GuiStatsReadout`, `GuiStreamTunePopover`, `GuiDisplaySwitcherMenu`,
// `GuiPastePlateMenu` and `GuiPaneControlBar`. As with the decorations, every decision these draw is
// already answered elsewhere — `GuiPaneReadout` owns the strings, the stat rows and the choice lists,
// `ClipboardPasteMenu` owns the paste enablement and the masked previews, and `BindingRowPlatform`
// owns whether a verb exists on this platform at all. What crossed is the drawing.
//
// THE BAR IS BUILT ONCE AND UPDATED, NEVER REBUILT. Thirteen plates with conditional presence is the
// shape that tempts a wholesale rebuild on every model change, and it would be wrong here for a reason
// the upload stack does not share: these buttons own `NSTrackingArea`s and a hover state, so rebuilding
// under the pointer drops the hover of the plate the user is aiming at. `present(...)` therefore moves
// `isHidden`, `active`, `enabled`, `symbolName` and `toolTip` on standing views. It is more code than a
// rebuild and it is the difference between a bar that flickers under the cursor and one that does not.
//
// GROUPED BY KIND, and the grouping is the SwiftUI half's, preserved exactly: everything LEFT of the
// spacer is a COMMAND (momentary — press, something happens, nothing latches), everything RIGHT carries
// STATE (a toggle whose accent is a live status light). One rule for the eye — an accent-tinted plate
// can only ever appear on the right. Groups are `space1`-tight inside and `space3`-separated, so the
// rhythm does the grouping and no divider ornament is needed.

import AppKit
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The stats readout

/// The in-pane telemetry chip: five instrument-voice rows on the same dim material the stall caption
/// uses, hit-testing off.
///
/// The rows are `GuiPaneReadout.statRows(_:)`'s, including the "—until measured" rule inside each, so
/// this view never decides what a missing reading looks like.
@MainActor
final class MacGuiStatsReadout: NSView {
    private let column = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Slate.Metric.radiusSmall
        paint()

        column.orientation = .vertical
        column.spacing = Slate.Metric.space1
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space1),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space1),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// A readout over a surface that takes every event.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        layer?.backgroundColor = Slate.Native.Surface.ground
            .slateScalingAlpha(Slate.Opacity.scrim).cgColor
    }

    /// The row COUNT is fixed by `GuiPaneReadout`, so the labels are made once and only their strings
    /// move. That matters at this update rate — the stats mirror ticks about twice a second, and
    /// rebuilding five text fields at 2 Hz for the life of a stream is pure churn for no visible gain.
    private var labels: [NSTextField] = []

    func present(_ telemetry: GuiStreamTelemetry) {
        let rows = GuiPaneReadout.statRows(telemetry)
        while labels.count < rows.count {
            let label = NSTextField(labelWithString: "")
            labels.append(label)
            column.addArrangedSubview(label)
        }
        for (index, label) in labels.enumerated() {
            label.isHidden = index >= rows.count
            guard index < rows.count else { continue }
            label.attributedStringValue = macInstrumentString(
                rows[index], color: Slate.Native.Text.primary,
            )
        }
    }
}

// MARK: - The stream-quality popover

/// A live fps cap and bitrate ceiling for this session — `0` on either means auto, and the host's
/// governor and ABR run unclamped.
///
/// No Apply button, matching the SwiftUI half: the override is cheap and reversible, so every change
/// applies immediately. The model re-asserts a remembered override into each fresh session, which is
/// what makes a selection survive a detach, a remount and a relaunch alike.
@MainActor
final class MacGuiStreamTunePopover: NSViewController {
    private let fpsChoice = NSSegmentedControl()
    private let bitrateChoice = NSSegmentedControl()
    private let onFps: (Int) -> Void
    private let onBitrate: (Int) -> Void

    init(fpsCap: Int, bitrateCapMbps: Int, onFps: @escaping (Int) -> Void, onBitrate: @escaping (Int) -> Void) {
        self.onFps = onFps
        self.onBitrate = onBitrate
        super.init(nibName: nil, bundle: nil)
        configure(fpsChoice, labels: GuiPaneReadout.fpsChoices.map(GuiPaneReadout.fpsChoiceLabel))
        configure(bitrateChoice, labels: GuiPaneReadout.mbpsChoices.map(GuiPaneReadout.mbpsChoiceLabel))
        fpsChoice.selectedSegment = GuiPaneReadout.fpsChoices.firstIndex(of: fpsCap) ?? 0
        bitrateChoice.selectedSegment = GuiPaneReadout.mbpsChoices.firstIndex(of: bitrateCapMbps) ?? 0
        fpsChoice.target = self
        fpsChoice.action = #selector(fpsChanged)
        bitrateChoice.target = self
        bitrateChoice.action = #selector(bitrateChanged)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func configure(_ control: NSSegmentedControl, labels: [String]) {
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.segmentCount = labels.count
        for (index, label) in labels.enumerated() {
            control.setLabel(label, forSegment: index)
        }
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Stream quality")
        title.font = .systemFont(ofSize: Slate.Typeface.body, weight: .semibold)
        title.textColor = Slate.Native.Text.primary

        let note = NSTextField(
            wrappingLabelWithString: "Applies live. Auto restores the adaptive governor/ABR.",
        )
        note.font = .systemFont(ofSize: Slate.Typeface.footnote)
        note.textColor = Slate.Native.Text.secondary
        note.isSelectable = false

        let column = NSStackView(views: [
            title,
            field("FPS cap", fpsChoice),
            field("Bitrate ceiling", bitrateChoice),
            note,
        ])
        column.orientation = .vertical
        column.spacing = Slate.Metric.space3
        column.alignment = .leading
        column.edgeInsets = NSEdgeInsets(
            top: Slate.Metric.space4, left: Slate.Metric.space4,
            bottom: Slate.Metric.space4, right: Slate.Metric.space4,
        )
        // The SwiftUI half's `.frame(width: 300)`. A popover has no other width opinion, and the two
        // segmented controls are the widest things in it, so the number is what keeps the four
        // bitrate labels from compressing into unreadable stubs.
        column.widthAnchor.constraint(equalToConstant: Self.popoverWidth).isActive = true
        view = column
    }

    private static let popoverWidth: CGFloat = 300

    /// A captioned control — the SwiftUI half's `VStack { Text(caption); Picker }` with `labelsHidden`.
    private func field(_ caption: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: Slate.Typeface.footnote)
        label.textColor = Slate.Native.Text.secondary
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.spacing = Slate.Metric.space1
        stack.alignment = .leading
        return stack
    }

    @objc
    private func fpsChanged() {
        let index = fpsChoice.selectedSegment
        guard GuiPaneReadout.fpsChoices.indices.contains(index) else { return }
        onFps(GuiPaneReadout.fpsChoices[index])
    }

    @objc
    private func bitrateChanged() {
        let index = bitrateChoice.selectedSegment
        guard GuiPaneReadout.mbpsChoices.indices.contains(index) else { return }
        onBitrate(GuiPaneReadout.mbpsChoices[index])
    }
}

// MARK: - A plate that opens a menu

/// The AppKit half of `SlatePlateMenu`: a plate button whose click drops an `NSMenu` beneath it.
///
/// COMPOSED, NOT SUBCLASSED — `MacPlateIconButton` is `final`, and it should stay that way. It carries
/// two user-directed rules about how a plate reads (latched is ink and weight, never accent; a press
/// moves the plate one rung toward what the click will do), and a subclass is exactly how a third
/// spelling of those rules appears. A menu is a different ACTION on the same button, not a different
/// button, so it belongs in the click closure.
///
/// The menu is rebuilt at OPEN rather than held. Both callers list live state — the host's current
/// displays, the clipboard ring as it stands right now — so a menu built at mount would show whatever
/// was true when the pane appeared.
@MainActor
func macPlateMenuButton(
    symbolName: String, help: String, itemsAtOpen: @escaping () -> [NSMenuItem],
) -> MacPlateIconButton {
    let button = MacPlateIconButton(symbolName: symbolName)
    button.toolTip = help
    button.onClick = { [weak button] in
        guard let button else { return }
        let menu = NSMenu()
        for item in itemsAtOpen() { menu.addItem(item) }
        // Anchored to the plate's bottom-left so the menu hangs UNDER the button. This bar sits at the
        // pane's bottom edge, so a menu opening upward would cover the content the verb acts on.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }
    return button
}

/// A menu row, spelled once so the two menus below cannot disagree about what "disabled" looks like.
@MainActor
func macMenuItem(
    _ title: String, enabled: Bool = true, checked: Bool = false, action: (() -> Void)? = nil,
) -> NSMenuItem {
    let item = MacClosureMenuItem(title: title, run: action)
    item.isEnabled = enabled
    item.state = checked ? .on : .off
    return item
}

/// An `NSMenuItem` that owns its action as a closure.
///
/// `NSMenuItem`'s target/action predates closures and wants a selector on some other object, which for
/// a menu built fresh at every open means either a retained delegate per menu or a tag-to-verb table
/// that has to stay in step with the item order. Carrying the closure on the item is the version with
/// no bookkeeping to get wrong.
@MainActor
final class MacClosureMenuItem: NSMenuItem {
    private let run: (() -> Void)?

    init(title: String, run: (() -> Void)?) {
        self.run = run
        super.init(title: title, action: run == nil ? nil : #selector(fire), keyEquivalent: "")
        if run != nil { target = self }
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError("not from a nib") }

    @objc
    private func fire() { run?() }
}

// MARK: - The footer control bar

/// The bottom control strip for a live remote-window pane: window verbs, viewport verbs, stream state
/// and the two latched modes, kept OUT of the pane content.
///
/// The plates are made once in `build()` and only ever updated afterwards — see the file header for why
/// a rebuild would be wrong on a bar whose buttons own tracking areas. `present(...)` is the single
/// entry point; it decides visibility and state for every plate from one snapshot of the model, so the
/// bar can never show half of one update and half of the next.
@MainActor
final class MacGuiPaneControlBar: NSView {
    /// Fold the bar back into the leaf's corner chip. The leaf owns that state, so this is a callback
    /// rather than something the bar decides.
    var onCollapse: () -> Void = {}
    /// Toggle the in-pane telemetry chip — also the leaf's state, for the same reason.
    var onToggleStats: () -> Void = {}
    /// Toggle immersive system-key capture. The capture object lives above this view.
    var onToggleImmersive: () -> Void = {}

    private let pasteMenu: MacPlateIconButton
    private let displayMenu: MacPlateIconButton
    private let detach = MacPlateIconButton(symbolName: SFSymbol.macwindowOnRectangle.rawValue)
    private let fit = MacPlateIconButton(symbolName: SFSymbol.rectangleArrowtriangle2Inward.rawValue)
    private let zoomOut = MacPlateIconButton(symbolName: SFSymbol.minusMagnifyingglass.rawValue)
    private let actualSize = MacPlateIconButton(symbolName: SFSymbol._1Magnifyingglass.rawValue)
    private let zoomIn = MacPlateIconButton(symbolName: SFSymbol.plusMagnifyingglass.rawValue)
    private let stats = MacPlateIconButton(symbolName: SFSymbol.chartBarXaxis.rawValue)
    private let quality = MacPlateIconButton(symbolName: SFSymbol.gaugeWithDotsNeedle67percent.rawValue)
    private let audio = MacPlateIconButton(symbolName: SFSymbol.speakerSlash.rawValue)
    private let privacy = MacPlateIconButton(symbolName: SFSymbol.eye.rawValue)
    private let immersive = MacPlateIconButton(symbolName: SFSymbol.command.rawValue)
    private let viewportLock = MacPlateIconButton(symbolName: SFSymbol.lockOpen.rawValue)
    private let collapse = MacPlateIconButton(symbolName: SFSymbol.chevronDown.rawValue)

    private let commands = NSStackView()
    private let viewport = NSStackView()
    private let streamState = NSStackView()
    private let modeState = NSStackView()
    private let hairline = NSView()

    /// The live snapshot the menus and the popover read at OPEN. Held rather than passed because a menu
    /// is built when the user clicks it, which is always later than the `present(...)` that armed it.
    private var model: RemoteWindowModel?
    private var store: WorkspaceStore?
    private var paneID: PaneID?

    private typealias Tip = GuiPaneReadout.Tooltip

    override init(frame frameRect: NSRect) {
        pasteMenu = macPlateMenuButton(
            symbolName: SFSymbol.documentOnClipboard.rawValue, help: Tip.paste, itemsAtOpen: { [] },
        )
        displayMenu = macPlateMenuButton(
            symbolName: SFSymbol.display.rawValue, help: Tip.displaySwitcher, itemsAtOpen: { [] },
        )
        super.init(frame: frameRect)
        wantsLayer = true
        build()
        wire()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        // FLAT: the bar's background IS the pane's, so the strip reads as part of the pane rather than
        // as a floating card. The single top hairline is the only thing separating them.
        layer?.backgroundColor = Slate.Native.Surface.face.cgColor
        hairline.layer?.backgroundColor = Slate.Native.Line.divider.cgColor
    }

    private func build() {
        for (group, members) in [
            (commands, [pasteMenu, displayMenu, detach]),
            (viewport, [fit, zoomOut, actualSize, zoomIn]),
            (streamState, [stats, quality, audio, privacy]),
            (modeState, [immersive, viewportLock]),
        ] {
            group.orientation = .horizontal
            group.spacing = Slate.Metric.space1
            group.alignment = .centerY
            for member in members { group.addArrangedSubview(member) }
        }

        // `space3` BETWEEN groups against `space1` inside them: the rhythm is what says these are four
        // kinds of thing, which is why there is no divider ornament anywhere in this bar.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [commands, viewport, spacer, streamState, modeState, collapse])
        row.orientation = .horizontal
        row.spacing = Slate.Metric.space3
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        hairline.wantsLayer = true
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)
        paint()

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Slate.Metric.paneHeaderHeight),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: Slate.Metric.hairline),
        ])
    }

    private func wire() {
        detach.onClick = { [weak self] in
            guard let self, let store, let paneID else { return }
            if store.tree.isDetached(paneID) {
                store.reattachPane(paneID)
            } else {
                store.detachPaneToWindow(paneID)
            }
        }
        fit.onClick = { [weak self] in self?.model?.sendViewport(.fitToPane) }
        zoomOut.onClick = { [weak self] in self?.model?.sendViewport(.zoomOut) }
        actualSize.onClick = { [weak self] in self?.model?.sendViewport(.reset) }
        zoomIn.onClick = { [weak self] in self?.model?.sendViewport(.zoomIn) }
        stats.onClick = { [weak self] in self?.onToggleStats() }
        quality.onClick = { [weak self] in self?.dropTunePopover() }
        audio.onClick = { [weak self] in
            guard let model = self?.model else { return }
            model.applyAudioEnabled(!model.audioStreamEnabled)
        }
        privacy.onClick = { [weak self] in
            guard let model = self?.model else { return }
            model.applyPrivacyEnabled(!model.privacyEnabled)
        }
        immersive.onClick = { [weak self] in self?.onToggleImmersive() }
        viewportLock.onClick = { [weak self] in self?.model?.toggleViewportLock() }
        collapse.onClick = { [weak self] in self?.onCollapse() }
        collapse.toolTip = Tip.collapseControls
        fit.toolTip = Tip.fitToPane
        zoomOut.toolTip = Tip.zoomOut
        actualSize.toolTip = Tip.actualSize
        zoomIn.toolTip = Tip.zoomIn

        pasteMenuItems()
        displayMenuItems()
    }

    /// The paste menu, rebuilt at open so the clipboard it offers is the one on the pasteboard NOW.
    ///
    /// Enablement and the masked previews are `ClipboardPasteMenu`'s, not this view's — a preview that
    /// unmasked a secret would be a leak decided in a renderer, which is precisely why that judgement
    /// lives in the headless model.
    private func pasteMenuItems() {
        pasteMenu.onClick = { [weak self] in
            guard let self, let model, let store else { return }
            let clipboard = store.currentLocalClipboard()
            let menu = NSMenu()
            menu.addItem(macMenuItem(
                "Paste as Keystrokes",
                // Content in hand, so the enablement's `Bool` comes from the content itself — the
                // phone's twin has to ask a probe instead, because it decides at RENDER time and a
                // content read there raises iOS's "Allow Paste?" alert (increment 78).
                enabled: ClipboardPasteMenu.canPaste(
                    canPasteKeystrokes: model.canPasteKeystrokes,
                    clipboardHasText: ClipboardPasteMenu.isPastable(clipboard),
                ),
            ) { if let clipboard { model.pasteAsKeystrokes(clipboard) } })

            let rows = ClipboardPasteMenu.rows(store.clipboardRing)
            if rows.isEmpty {
                menu.addItem(macMenuItem("No recent clips", enabled: false))
            } else {
                let ring = NSMenu()
                for row in rows {
                    // The LABEL is the masked preview; the full clip is what gets typed and is never
                    // shown anywhere.
                    ring.addItem(macMenuItem(row.label, enabled: model.canPasteKeystrokes) {
                        model.pasteAsKeystrokes(row.text)
                    })
                }
                let parent = NSMenuItem(title: "Clipboard Ring", action: nil, keyEquivalent: "")
                parent.submenu = ring
                menu.addItem(parent)
            }
            menu.popUp(
                positioning: nil, at: NSPoint(x: 0, y: pasteMenu.bounds.height), in: pasteMenu,
            )
        }
    }

    /// The display switcher, likewise rebuilt at open — a monitor hot-plugged since the pane mounted
    /// has to appear without anything having invalidated a cached menu.
    private func displayMenuItems() {
        displayMenu.onClick = { [weak self] in
            guard let self, let model else { return }
            let menu = NSMenu()
            if model.availableDisplays.isEmpty {
                menu.addItem(macMenuItem("No display list from host", enabled: false))
            } else {
                for (index, display) in model.availableDisplays.enumerated() {
                    menu.addItem(macMenuItem(
                        display.displayLabel(ordinal: index + 1),
                        checked: display.displayID == model.desktopDisplayID,
                    ) { model.switchDisplay(to: display.displayID) })
                }
            }
            menu.addItem(.separator())
            menu.addItem(macMenuItem("Refresh Displays") {
                Task { await model.refreshDisplays() }
            })
            menu.popUp(
                positioning: nil, at: NSPoint(x: 0, y: displayMenu.bounds.height), in: displayMenu,
            )
        }
    }

    private func dropTunePopover() {
        guard let model else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = MacGuiStreamTunePopover(
            fpsCap: model.streamFpsCap,
            bitrateCapMbps: GuiPaneReadout.mbps(fromBps: model.streamBitrateCeilingBps),
            onFps: { model.applyStreamSettings(fpsCap: $0, bitrateCeilingBps: model.streamBitrateCeilingBps) },
            onBitrate: {
                model.applyStreamSettings(
                    fpsCap: model.streamFpsCap, bitrateCeilingBps: GuiPaneReadout.bps(fromMbps: $0),
                )
            },
        )
        // `.maxY` — the bar is at the pane's BOTTOM, so the popover opens upward into the content and
        // not off the window edge.
        popover.show(relativeTo: quality.bounds, of: quality, preferredEdge: .maxY)
    }

    // MARK: The one update path

    /// Point the bar at a pane and settle every plate from one snapshot.
    func present(
        model: RemoteWindowModel?, store: WorkspaceStore, paneID: PaneID,
        showStats: Bool, immersiveOn: Bool,
    ) {
        self.model = model
        self.store = store
        self.paneID = paneID

        // ── WINDOW COMMANDS
        pasteMenu.isHidden = model == nil
        displayMenu.isHidden = model?.desktopDisplayID == nil
        // The detach verb's PRESENCE is data, read from the same `binding_rows` declaration that decides
        // whether ⌥⌘P is bound and whether the palette lists it. A platform gate here would be a fourth
        // place for that answer to drift — and this target forbids one anyway.
        detach.isHidden = !BindingRowPlatform.lists("pane.detach")
        let detached = store.tree.isDetached(paneID)
        detach.symbolName = detached
            ? SFSymbol.macwindowAndPointerArrow.rawValue : SFSymbol.macwindowOnRectangle.rawValue
        detach.toolTip = detached ? Tip.reattach : Tip.detach
        commands.isHidden = pasteMenu.isHidden && displayMenu.isHidden && detach.isHidden

        // ── VIEWPORT COMMANDS. Withheld while the viewport is locked: they would re-anchor the pan or
        // read as live controls the lock does not actually hold, so dimming them sends the eye to the
        // lock button — which stays live, and stays OUTSIDE this cluster.
        let canViewport = model?.canControlViewport == true
        viewport.isHidden = !canViewport
        let locked = model?.viewportLocked == true
        for plate in [fit, zoomOut, actualSize, zoomIn] { plate.enabled = !locked }

        // ── STREAM STATE
        stats.isHidden = model == nil
        stats.active = showStats
        stats.toolTip = showStats ? Tip.hideStats : Tip.showStats

        quality.isHidden = model?.canAdjustStreamSettings != true
        quality.active = (model?.streamFpsCap ?? 0) != 0 || (model?.streamBitrateCeilingBps ?? 0) != 0
        quality.toolTip = Tip.streamQuality

        // The speaker stays VISIBLE while on even when the sink is withheld, so the status light never
        // vanishes mid-stream; the verb is what gets refused. The privacy shield below follows the same
        // rule, and so does immersive.
        let audioOn = model?.audioStreamEnabled == true
        audio.isHidden = !(model?.canToggleAudio == true || audioOn)
        audio.symbolName = audioOn ? SFSymbol.speakerWave2.rawValue : SFSymbol.speakerSlash.rawValue
        audio.active = audioOn
        audio.enabled = model?.canToggleAudio == true
        audio.toolTip = audioOn ? Tip.muteAudio : Tip.playAudio

        let privacyOn = model?.privacyEnabled == true
        let isDesktop = store.tree.spec(for: paneID)?.kind == .desktop
        privacy.isHidden = !(isDesktop && (model?.canTogglePrivacy == true || privacyOn))
        privacy.symbolName = privacyOn ? SFSymbol.eyeSlashFill.rawValue : SFSymbol.eye.rawValue
        privacy.active = privacyOn
        privacy.enabled = model?.canTogglePrivacy == true
        privacy.toolTip = privacyOn ? Tip.privacyOff : Tip.privacyOn

        streamState.isHidden = stats.isHidden && quality.isHidden && audio.isHidden && privacy.isHidden

        // ── MODE STATE. The immersive chip exists only where there is a CGEventTap to arm — capability
        // as DATA, never a compile-time gate, so a chip is never drawn over a no-op.
        let immersiveListed = PaneImmersiveCapture.isSupported
            && (model?.canInjectSystemKeys == true || immersiveOn)
        immersive.isHidden = !immersiveListed
        immersive.active = immersiveOn
        immersive.toolTip = immersiveOn ? Tip.immersiveOn : Tip.immersiveOff

        viewportLock.isHidden = !canViewport
        viewportLock.symbolName = locked ? SFSymbol.lockFill.rawValue : SFSymbol.lockOpen.rawValue
        viewportLock.active = locked
        viewportLock.toolTip = locked ? Tip.unlockViewport : Tip.lockViewport

        // Gated as a WHOLE so an all-absent mode row leaves no stray double gap in the bar's rhythm.
        modeState.isHidden = immersive.isHidden && viewportLock.isHidden
    }
}
