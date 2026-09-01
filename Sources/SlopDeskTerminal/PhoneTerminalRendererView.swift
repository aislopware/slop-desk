// PhoneTerminalRendererView — the UIKit half of the terminal surface.
//
// The same file as `MacTerminalRendererView` in shape and NOT in content, which is `PlatformView.swift`'s
// rule honoured rather than worked around: AppKit and UIKit differ where it matters (`isFlipped`,
// who owns `layer`, presses vs. key events, gestures vs. tracking areas), and a shared superclass
// with `#if` around every method would be the cross-platform view layer this campaign deleted.
// What the two genuinely share is `TerminalSurfaceDriver`, and they share it as a type, not a base.
//
// ⚠️ THE LAYER IS BORROWED AT +0, and UIKit makes that harder rather than easier: a `UIView` owns its
// `layer` and will not take another, so the handle's layer is a SUBLAYER this view positions. It
// must be removed before `driver.close()` frees the handle beneath it.

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import CSlopDeskFFI
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import UIKit
import UniformTypeIdentifiers

/// The layer-hosting `UIView` the phone canvas mounts for a terminal pane.
@MainActor
final class PhoneTerminalRendererView: UIView {
    /// The framework-neutral half. Everything this view does to the terminal goes through it.
    private let driver: TerminalSurfaceDriver

    /// The pane, for the wiring a view owns rather than a driver.
    private weak var model: TerminalViewModel?

    /// The handle's layer, hosted as a sublayer — see this file's header.
    private var hostedLayer: CALayer?

    private var displayLink: CADisplayLink?
    private var needsPresent = false

    /// Whether a long-press selection drag is live.
    private var isSelecting = false
    private var isRectangularDrag = false
    private var lastPointerPoint: CGPoint = .zero

    /// The system edit menu, which renders the SAME ``TerminalContextMenu`` table the Mac's `NSMenu`
    /// renders, with the same order and the same enablement — so the two menus cannot come to offer
    /// different things.
    private var editMenu: UIEditMenuInteraction?

    /// The band under the grid, built on first ask of ``promptView``.
    private var band: PhoneTerminalPromptView?

    /// What an input method is composing over the EDITOR's line, or `nil` for a composition the grid
    /// is drawing instead — see ``setComposition(_:selection:)``. Never both.
    private var composition: (text: String, selection: NSRange)?

    /// The detected link the OPEN menu was offered on, resolved at the release point and stashed
    /// because a `UIAction` closure fires long after that point is gone. The Mac's `pendingMenuLink`,
    /// and one slot suffices for its reason: a menu is modal per view.
    private var pendingMenuLink: DetectedLink?

    /// The BLOCK the offered menu was pressed over, and the snapshot its rows were greyed by — the
    /// Mac's `pendingMenuBlock`, resolved at the same release point ``pendingMenuLink`` is.
    ///
    /// ⚠️ An ORDINAL, never the layout position: a menu outlives the layout it was built over, since
    /// output arriving meanwhile re-segments the list. The verbs resolve it again when they fire.
    private var pendingMenuBlock: (ordinal: UInt32, context: TerminalContextMenu.BlockContext)?

    init?(model: TerminalViewModel, isFocused: Bool) {
        guard let driver = TerminalSurfaceDriver(
            font: TerminalConfigBroadcaster.shared.font,
            scale: Double(UITraitCollection.current.displayScale),
            size: CGSize(width: 390, height: 600),
        ) else {
            return nil
        }
        self.driver = driver
        self.model = model
        super.init(frame: .zero)

        if let hosted = driver.layer {
            layer.addSublayer(hosted)
            hostedLayer = hosted
        }

        driver.onNeedsPresent = { [weak self] in self?.needsPresent = true }
        driver.onConfirmClipboardWrite = { text, decide in
            Self.confirm(.clipboardWrite, preview: text, dangers: [], decide)
        }
        driver.onConfirmPaste = { dangers, decide in
            Self.confirm(.unsafePaste, preview: "", dangers: dangers, decide)
        }
        driver.onPickFileToPaste = { [weak self] deliver in
            self?.pickFileToPaste(deliver)
        }
        // ⚠️ THE ARMING EDGE, which no keystroke announces. `TerminalInputHostView` refreshes the band
        // after edits IT made; this fires for the ones the ENGINE makes — the shell printing a prompt,
        // a fullscreen program taking the screen, a session re-attaching with a draft already in the
        // buffer. Without it the band appears only at the first keypress and stays up under `htop`.
        driver.onPromptEdited = { [weak self] in self?.band?.refresh() }
        driver.bind(to: model)
        driver.setFocus(isFocused, blinkVisible: true)
        installGestures()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("PhoneTerminalRendererView is built in code, never from a nib")
    }

    // MARK: - Geometry

    override func layoutSubviews() {
        super.layoutSubviews()
        // The hosted layer follows the view exactly, and WITHOUT an implicit animation: a terminal
        // that eased into its new size would draw a frame of stretched glyphs on every rotation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer?.frame = bounds
        CATransaction.commit()
        driver.setGeometry(size: bounds.size, scale: renderScale)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else {
            startDisplayLink()
            driver.setGeometry(size: bounds.size, scale: renderScale)
        }
    }

    /// The backing-store scale to rasterise at.
    ///
    /// The WINDOW's screen first — an iPad on an external display is not the built-in one, and the
    /// glyphs have to be cut for the panel they land on. `traitCollection.displayScale` is the
    /// fallback rather than `UIScreen.main`, which is deprecated and, on a multi-scene app, names
    /// a screen this view may not be on at all.
    private var renderScale: CGFloat {
        window?.screen.scale ?? traitCollection.displayScale
    }

    // MARK: - The display link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc
    private func tick() {
        if isSelecting, driver.autoscrollDirection != .none {
            driver.autoscrollTick(at: lastPointerPoint, rectangle: isRectangularDrag)
        }
        guard needsPresent else { return }
        needsPresent = false
        driver.present()
    }

    // MARK: - Focus

    /// ⚠️ THE SURFACE IS NOT A RESPONDER, and the pane deliberately has exactly one.
    ///
    /// It used to claim first responder here, which made two of them: ``TerminalInputHostView`` is
    /// the pane's key path — a `UIKeyInput` holding the repeater, the accessory row, the ⌃⇥ walk and
    /// the four editing chords, registered with ``PaneFocusCoordinator`` and named by the phone
    /// parity ratchet — and it is a SIBLING of these pixels, not an ancestor, so whichever of the two
    /// won the race the loser's `pressesBegan` was never called at all. The coordinator claims on the
    /// next runloop hop (UIKit takes a synchronous claim back), so the claim made here from
    /// ``setPaneFocused(_:)`` won first and was overridden a hop later — a keyboard that flickered
    /// down and up on every pane focus, because this view conforms to no text-input protocol and
    /// UIKit raises the software keyboard only for one that does.
    ///
    /// What that claim was FOR is answered elsewhere and was already answered before it landed: the
    /// four ⌘ chords reach the surface as `UIKeyCommand`s on the input host, which hands each one to
    /// `onRequestMenuItem` — this view's own long-press menu route, selection and paste-protection
    /// included. So the collapse gives nothing up. What remains here is the DRIVER's focus, which is
    /// the caret's blink and the engine's own notion, pushed by the leaf.
    func setFocus(_ isFocused: Bool) {
        driver.setFocus(isFocused, blinkVisible: true)
    }

    // MARK: - Gestures

    /// Pan scrolls, long-press starts a selection, tap focuses. Three recognisers rather than raw
    /// touch handling because UIKit's arbitration between them is the thing a hand-rolled
    /// `touchesMoved` would have to reimplement badly.
    private func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        press.minimumPressDuration = TerminalTouchSelection.longPressDuration
        press.allowableMovement = CGFloat(TerminalTouchSelection.longPressAllowableMovement)
        addGestureRecognizer(press)

        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        editMenu = menu

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        // The tap must yield to the long press, or every selection would begin with a focus tap
        // that dismissed it.
        tap.require(toFail: press)
        addGestureRecognizer(tap)

        // A fourth, because "phone" is also iPad-with-a-trackpad and that one HAS a pointer. On a
        // device with no indirect input the recogniser simply never fires, so this is not a
        // platform check — it is the same block wash the Mac draws, reaching the only iOS input
        // that can ask for it.
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover)))
    }

    /// Feeds the pointer to the block chrome. `.ended`/`.cancelled` is the pointer LEAVING, which is
    /// a different state from hovering at the origin — see the door.
    @objc
    private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began,
             .changed: driver.setHover(gesture.location(in: self))
        default: driver.setHover(nil)
        }
    }

    @objc
    private func handleTap(_ gesture: UITapGestureRecognizer) {
        // The REQUEST only. Which view holds first responder is ``PaneFocusCoordinator``'s, driven
        // off the store's active pane, and claiming it from a gesture is the second mover the leaf's
        // own `setFocused(_:)` comment forbids.
        model?.onRequestFocus?()
        let point = gesture.location(in: self)
        // A mouse-reporting TUI gets the tap as a click. Otherwise the tap is focus and, at an
        // editable prompt with `controls.click-to-move` on, the shell's cursor: the same door the
        // Mac's `mouseUp` reaches, so a tap and a click move the caret by the same rule rather than
        // by two guesses at one. A tap ends where it began, so there is no selection to prefer.
        let forwarded = driver.sendMouse(action: 0, button: 0, mods: 0, at: point)
        _ = driver.sendMouse(action: 1, button: 0, mods: 0, at: point)
        if !forwarded { driver.clickToMove(at: point) }
    }

    @objc
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            gesture.setTranslation(.zero, in: self)
        case .ended,
             .cancelled,
             .failed:
            // A zero delta, on purpose: the lift is what owes the row snap under
            // `controls.smooth-scroll`, and there is no travel left to carry it.
            driver.scrollPoints(0, phase: TerminalScrollPhase(state: gesture.state))
        case .changed:
            // POINTS, not rows: the block list's chrome is spent before the scrollback, and a
            // finger dragging through a header should move by what it travelled rather than
            // quantise to the cell. The remainder the old row arithmetic carried is gone with it —
            // there is nothing left to round.
            //
            // Dragging DOWN reveals older output, which is the direction this door reads positive.
            let travelled = gesture.translation(in: self).y
            gesture.setTranslation(.zero, in: self)
            guard travelled != 0 else { return }
            driver.scrollPoints(travelled, phase: TerminalScrollPhase(state: gesture.state))
        default:
            break
        }
    }

    @objc
    private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        lastPointerPoint = point
        switch gesture.state {
        case .began:
            // A second press replaces the first menu rather than stacking one on it, and the link the
            // old menu was offered on dies with it.
            editMenu?.dismissMenu()
            pendingMenuLink = nil
            pendingMenuBlock = nil
            isSelecting = true
            isRectangularDrag = false
            driver.selectPress(
                at: point,
                timeMs: CACurrentMediaTime() * 1000,
                // The phone has no double-click interval and no mouse slop; a long press is one
                // gesture, so the ladder never advances and the two numbers only have to be
                // non-degenerate. A finger's slop, in points.
                repeatIntervalMs: 0,
                repeatDistance: 10,
            )
        case .changed:
            driver.selectDrag(to: point, rectangle: false)
        default:
            guard isSelecting else { return }
            isSelecting = false
            driver.selectRelease(at: point)
            // A CANCELLED gesture (a system gesture took the touch) is not a request for a menu, and a
            // program tracking the mouse owns the press outright — ``TerminalTouchSelection`` owns that
            // second rule, so the two shells cannot disagree about when a menu appears.
            guard gesture.state == .ended,
                  TerminalTouchSelection.presentsMenuOnRelease(mouseCaptured: driver.modes().isMouseTracking)
            else { return }
            // Resolved at the RELEASE point, which is the point the menu anchors to — the same reading
            // the Mac's `menu(for:)` takes at the location its menu opens at.
            pendingMenuLink = detectedLink(at: point)
            pendingMenuBlock = driver.blockMenu(at: point)
            editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }
    }

    // MARK: - The edit menu

    /// The detected link under a point, or `nil` when the touch landed on none.
    ///
    /// ``TerminalTouchSelection/linkHitSlop`` rather than the Mac's exact reading: a fingertip is a
    /// contact patch whose reported centre is a guess, and the phone gets ONE shot at the question with
    /// no hover to correct it. The door is ``TerminalSurfaceDriver/link(at:cwd:slop:)``, the same one
    /// the Mac runs, so an `OSC 8` hyperlink outranks a detected path here too.
    private func detectedLink(at point: CGPoint) -> DetectedLink? {
        driver.link(at: point, cwd: model?.linkCwd, slop: CGFloat(TerminalTouchSelection.linkHitSlop))
    }

    /// The menu, built from the PURE ``TerminalContextMenu``: same items, same order, same enablement,
    /// same glyphs. The Mac renders that table as an `NSMenu`; this renders it as a `UIMenu`.
    ///
    /// `Item.separatorBefore` opens a new GROUP, and UIKit draws an inline submenu with the rule an
    /// `NSMenuItem.separator()` draws on the Mac — same table, each framework's own spelling. The link
    /// group is first and EMPTY for a press over no link, which is most presses; the `filter` drops it,
    /// so there is never a rule over nothing.
    private func menuElements() -> [UIMenuElement] {
        let context = TerminalContextMenu.Context(
            hasSelection: driver.hasSelection(),
            clipboardHasText: !(ClientPasteboard.text()?.isEmpty ?? true),
            paneConnected: model?.connectionStatus.isLive ?? false,
            hasCommandOutput: model?.blocks.latest?.complete ?? false,
        )
        var groups: [[UIMenuElement]] = [linkActions()]
        groups.append(contentsOf: blockActions())
        groups.append([])
        for item in TerminalContextMenu.items {
            if item.separatorBefore { groups.append([]) }
            groups[groups.count - 1].append(action(for: item, context: context))
            if item == .paste {
                groups[groups.count - 1].append(UIMenu(
                    title: TerminalContextMenu.pasteAsSubmenuTitle,
                    image: UIImage(systemName: TerminalContextMenu.Item.paste.symbol),
                    children: TerminalContextMenu.pasteAsItems.map { action(for: $0, context: context) },
                ))
            }
        }
        return groups.filter { !$0.isEmpty }.map { UIMenu(title: "", options: .displayInline, children: $0) }
    }

    /// One item, greyed by the same unit-tested rule the Mac greys by.
    ///
    /// The two verbs that are the WORKSPACE's rather than the surface's go to the pane's own callbacks,
    /// exactly as they do on the Mac; everything else is one call into the driver.
    private func action(
        for item: TerminalContextMenu.Item, context: TerminalContextMenu.Context,
    ) -> UIAction {
        let enabled = TerminalContextMenu.isEnabled(item, context: context)
        return UIAction(
            title: item.title,
            image: UIImage(systemName: item.symbol),
            attributes: enabled ? [] : .disabled,
        ) { [weak self] _ in
            guard let self else { return }
            switch item {
            case .splitRight: model?.onContextMenuSplit?(true)
            case .splitDown: model?.onContextMenuSplit?(false)
            case .find: model?.onRequestFind?()
            default: driver.run(item)
            }
        }
    }

    /// The block items for ``pendingMenuBlock``, already split into groups at
    /// ``TerminalContextMenu/BlockItem/separatorBefore`` — the Mac draws that rule as an
    /// `NSMenuItem.separator()`, UIKit as a new inline group. Empty when the press landed on no block.
    ///
    /// Which verbs exist, what they say, which are live and what each DOES are all shared with the Mac
    /// (``TerminalContextMenu/blockItems`` and ``TerminalSurfaceDriver/run(_:ordinal:)``), so the whole
    /// of this half is the labels — ``linkActions()``'s shape, for its reason.
    private func blockActions() -> [[UIMenuElement]] {
        guard let block = pendingMenuBlock else { return [] }
        var groups: [[UIMenuElement]] = [[]]
        for item in TerminalContextMenu.blockItems {
            if item.separatorBefore { groups.append([]) }
            let enabled = TerminalContextMenu.isEnabled(item, context: block.context)
            groups[groups.count - 1].append(UIAction(
                title: item.title(for: block.context),
                image: UIImage(systemName: item.symbol(for: block.context)),
                attributes: enabled ? [] : .disabled,
            ) { [weak self] _ in
                self?.driver.run(item, ordinal: block.ordinal)
            })
        }
        return groups.filter { !$0.isEmpty }
    }

    /// The link items for ``pendingMenuLink``, or nothing when the press landed on no link.
    ///
    /// Which items a kind offers is ``TerminalContextMenu/linkItems(for:)``'s and what each DOES is
    /// ``LinkActionPolicy``'s — both pure, both already shared with the Mac — so the whole of this
    /// half is the labels.
    private func linkActions() -> [UIMenuElement] {
        guard let link = pendingMenuLink else { return [] }
        return TerminalContextMenu.linkItems(for: link.kind).map { item in
            let action = LinkActionPolicy.action(for: item, link: link)
            return UIAction(
                title: item.title(for: link.kind), image: UIImage(systemName: item.symbol),
            ) { [weak self] _ in
                LinkActionActuator.actuate(action, model: self?.model)
            }
        }
    }

    // MARK: - The clipboard-write sheet

    /// Files one of the three terminal confirmations with the phone's mailbox.
    ///
    /// ⚠️ **Filed, not presented, and that asymmetry with the Mac is UIKit's rather than a
    /// decision.** `NSAlert.beginSheetModal(for:)` can be called from inside a drain because the
    /// presenter is a function; a UIKit surface exists only because something in a mounted tree says
    /// it does. So this asks, and `ClipboardConfirmCard` — which is already mounted in the phone's
    /// overlay layer — draws it. The mailbox is what guarantees the completion runs exactly once.
    ///
    /// `static` because it must survive this view: a request filed as a pane tears down is still a
    /// question the user is owed, and the completion holds only what it needs.
    private static func confirm(
        _ ask: PasteSafetyAnalyzer.Ask,
        preview: String,
        dangers: PasteSafetyAnalyzer.PasteDangers,
        _ decide: @escaping (Bool) -> Void,
    ) {
        ClipboardConfirmRequests.shared.ask(
            ClipboardConfirmPresentation.reading(ask: ask, preview: preview, dangers: dangers),
            answer: decide,
        )
    }

    /// Chooses a file for **Paste File Base64-Encoded…** and hands back its bytes.
    ///
    /// A view with no view controller to present from delivers `nil`, which pastes nothing — the
    /// same direction an unanswerable confirmation takes.
    private func pickFileToPaste(_ deliver: @escaping (Data?) -> Void) {
        guard let presenter = window?.rootViewController else {
            deliver(nil)
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        let delegate = FilePasteDelegate(deliver: deliver)
        picker.delegate = delegate
        // The picker holds the only strong reference UIKit keeps; the delegate must outlive this
        // call, so it rides on the picker itself rather than on a field this view would have to
        // clear.
        objc_setAssociatedObject(picker, &FilePasteDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        presenter.present(picker, animated: true)
    }
}

// MARK: - The edit menu's delegate

extension PhoneTerminalRendererView: @MainActor UIEditMenuInteractionDelegate {
    /// ⚠️ The system's `suggestedActions` are deliberately DROPPED. They are the responder chain's
    /// Copy/Paste over a `UITextInput` this view is not, and offering both would put two Copies with
    /// different meanings in one menu.
    func editMenuInteraction(
        _: UIEditMenuInteraction,
        menuFor _: UIEditMenuConfiguration,
        suggestedActions _: [UIMenuElement],
    ) -> UIMenu? {
        UIMenu(children: menuElements())
    }
}

// MARK: - TerminalSurfaceHosting

extension PhoneTerminalRendererView: @MainActor TerminalMenuItemRunning {
    @discardableResult
    func run(_ item: TerminalContextMenu.Item) -> Bool {
        driver.run(item)
    }

    /// Re-arms the present keep-alive after a resize settles — see ``TerminalViewModel/onResizeSettled``.
    /// One frame is enough here where the fork needed a burst: the drain is synchronous, so the
    /// reflow bytes are on the grid before this view is asked to draw them.
    func requestPresentBurst() {
        needsPresent = true
    }
}

extension PhoneTerminalRendererView: @MainActor TerminalSurfaceHosting {
    var surfaceView: PlatformView { self }

    /// The DRIVER's focus and nothing else — see ``setFocus(_:)``. The responder is
    /// ``PaneFocusCoordinator``'s, and this view is not a candidate for it.
    func setPaneFocused(_ isFocused: Bool) {
        setFocus(isFocused)
    }

    /// The band, built on first ask and kept for the life of the surface.
    var promptView: PlatformView? {
        guard let model else { return nil }
        if let band { return band }
        let made = PhoneTerminalPromptView(
            prompt: model.commandPrompt,
            armed: { [weak self] in self?.model?.commandPromptArmed ?? false },
            composition: { [weak self] in self?.composition },
            // The same REQUEST ``handleTap(_:)`` makes, for the same reason: claiming first responder
            // from a gesture is the second mover the leaf's `setFocused(_:)` forbids.
            focusPane: { [weak self] in self?.model?.onRequestFocus?() },
            promptEdited: { [weak self] in self?.promptDidChange() },
        )
        band = made
        return made
    }

    /// The input method's preedit, and the one decision the reporting host does not make: WHICH of
    /// the two surfaces draws it.
    ///
    /// `MacTerminalRendererView.setMarkedText(_:selectedRange:replacementRange:)`'s fork exactly, and
    /// for its reason: a composition over the EDITOR's line belongs to the band, so the grid — which
    /// is not where that line is — must not also draw it. Two underlined runs on screen at once is
    /// what pushing every composition to both would look like.
    ///
    /// An empty `text` withdraws it from BOTH, unconditionally: the arming can change between the
    /// composition starting and its cancellation, and clearing only the side that happens to be armed
    /// now is how an underlined run gets stranded on the other one with nothing left to repaint it.
    func setComposition(_ text: String, selection: NSRange) {
        guard !text.isEmpty else {
            composition = nil
            driver.setMarkedText("", cursorBytes: 0)
            band?.refresh()
            return
        }
        if model?.commandPromptArmed == true {
            composition = (text, selection)
            band?.refresh()
            return
        }
        composition = nil
        // UIKit counts in UTF-16 and the door takes UTF-8. `String.Index(utf16Offset:in:)` lands on
        // `endIndex` for an offset past the end, which is the same "caret after everything" the door
        // falls back to — so an out-of-range report is handled once, here, rather than twice.
        let caret = String.Index(utf16Offset: selection.location, in: text)
        driver.setMarkedText(text, cursorBytes: text[..<caret].utf8.count)
    }

    /// The band's caret while the editor owns the line, else the grid's cell — see the seam.
    ///
    /// The band answers `nil` for its own caret whenever it is not armed, so the fork is ITS reading
    /// of the arming rather than a second one spelled here.
    var caretAnchor: (view: PlatformView, rect: CGRect)? {
        if let band, let caret = band.caretRect { return (band, caret) }
        guard let cell = driver.caretRect() else { return nil }
        return (self, cell)
    }

    /// The responder edited the prompt — see the seam.
    ///
    /// Repaint, then ask the host's shell about any command word it has not ruled on yet. The ask is
    /// free when there is nothing to ask — ``CommandPrompt/whenceRequest`` is nil once every word has
    /// a verdict — so this costs a cursor move nothing.
    func promptDidChange() {
        band?.refresh()
        model?.askShellAboutTypedCommands { [weak self] in self?.band?.refresh() }
    }

    func scrollPages(_ pages: Int) {
        // Saturating rather than trapping: the seam speaks `Int` because every caller does, the driver
        // speaks `Int32` because the engine does, and a page count that overflows `Int32` is a scroll
        // past the end of a scrollback no machine holds — clamping it lands where the trap would have
        // gone anyway, without taking the app down to get there.
        driver.scroll(.pages(Int32(clamping: pages)))
    }

    /// ⚠️ The ORDER is the whole point — see this file's header.
    func detachSurface() {
        stopDisplayLink()
        hostedLayer?.removeFromSuperlayer()
        hostedLayer = nil
        driver.close()
    }
}

/// Bridges `UIDocumentPickerViewController`'s delegate back to one closure.
///
/// A separate object because `UIDocumentPickerDelegate` is `NSObjectProtocol` and the renderer view
/// is not an `NSObject` subclass by accident — it is a `UIView`, and conforming it here would put a
/// file-picking protocol on the terminal surface.
@MainActor
private final class FilePasteDelegate: NSObject, UIDocumentPickerDelegate {
    /// The associated-object key. One per process; its ADDRESS is the key, never its value.
    nonisolated(unsafe) static var key = 0

    private let deliver: (Data?) -> Void

    init(deliver: @escaping (Data?) -> Void) {
        self.deliver = deliver
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            deliver(nil)
            return
        }
        // A picked file is outside the app's container, so the read needs the security scope the
        // picker granted. Without this the read fails and a user who chose a file sees nothing
        // happen.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        deliver(try? Data(contentsOf: url))
    }

    func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
        deliver(nil)
    }
}
#endif
