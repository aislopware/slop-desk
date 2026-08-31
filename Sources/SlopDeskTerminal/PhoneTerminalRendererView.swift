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

    /// The detected link the OPEN menu was offered on, resolved at the release point and stashed
    /// because a `UIAction` closure fires long after that point is gone. The Mac's `pendingMenuLink`,
    /// and one slot suffices for its reason: a menu is modal per view.
    private var pendingMenuLink: DetectedLink?

    init?(model: TerminalViewModel, isFocused: Bool) {
        guard let driver = TerminalSurfaceDriver(
            family: TerminalConfigBroadcaster.shared.fontFamily,
            pointSize: TerminalConfigBroadcaster.shared.fontSize,
            scale: Double(UIScreen.main.scale),
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
        driver.setGeometry(size: bounds.size, scale: window?.screen.scale ?? UIScreen.main.scale)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else {
            startDisplayLink()
            driver.setGeometry(size: bounds.size, scale: window?.screen.scale ?? UIScreen.main.scale)
        }
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

    /// The surface takes the keyboard itself. On the phone the pane's first responder used to be a
    /// zero-sized sibling, which is what left ⌘C/⌘X/⌘V landing on a view that owned no surface;
    /// this view IS the surface, so the four chords reach it through the ordinary responder chain.
    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        driver.setFocus(true, blinkVisible: true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        driver.setFocus(false, blinkVisible: true)
        return super.resignFirstResponder()
    }

    // MARK: - Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard handle(presses, action: 0) else {
            super.pressesBegan(presses, with: event)
            return
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard handle(presses, action: 1) else {
            super.pressesEnded(presses, with: event)
            return
        }
    }

    /// Encodes every press in the set, answering whether any produced bytes.
    ///
    /// The keycode is always ``TerminalRendererSurface/noKey``: a `UIKey` carries CHARACTERS, not a
    /// hardware position, and inventing an AppKit keyCode for it would be a mapping table this side
    /// has no authority to write. The door documents the asymmetry.
    private func handle(_ presses: Set<UIPress>, action: UInt8) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            if model?.takesModalKeys == true {
                model?.handleCopyModeKey(TerminalViewModel.makeCopyModeKey(PhoneKey.Press(key)))
                handled = true
                continue
            }
            handled = driver.sendKey(
                keyCode: TerminalRendererSurface.noKey,
                action: action,
                mods: Self.mods(key.modifierFlags),
                consumedMods: 0,
                text: key.characters,
                composing: false,
            ) || handled
        }
        return handled
    }

    /// The engine's `mods` word for a UIKit flag set.
    ///
    /// ⚠️ Every bit is `slopdesk_term_mods`'s. UIKit reports no SIDE for a modifier — there is no
    /// `NX_DEVICER*` equivalent — so all four side flags are `false`, which is the honest answer
    /// rather than a guess: `macos-option-as-alt = right` is a Mac setting and the phone has no
    /// Option key to distinguish.
    static func mods(_ flags: UIKeyModifierFlags) -> UInt16 {
        slopdesk_term_mods(
            flags.contains(.shift),
            flags.contains(.alternate),
            flags.contains(.control),
            flags.contains(.command),
            flags.contains(.alphaShift),
            flags.contains(.numericPad),
            false, false, false, false,
        )
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
        model?.onRequestFocus?()
        becomeFirstResponder()
        let point = gesture.location(in: self)
        // A mouse-reporting TUI gets the tap as a click; otherwise it is just focus, and the tap
        // deliberately does NOT move a cursor — a terminal has no click-to-position.
        _ = driver.sendMouse(action: 0, button: 0, mods: 0, at: point)
        _ = driver.sendMouse(action: 1, button: 0, mods: 0, at: point)
    }

    @objc
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            gesture.setTranslation(.zero, in: self)
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
            driver.scrollPoints(travelled)
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
            editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }
    }

    // MARK: - The edit menu

    /// The detected link under a point, or `nil` when the touch landed on none.
    ///
    /// ``TerminalTouchSelection/linkHitSlop`` rather than the Mac's exact reading: a fingertip is a
    /// contact patch whose reported centre is a guess, and the phone gets ONE shot at the question with
    /// no hover to correct it. The detection and the hit-test are the same pair the Mac runs.
    private func detectedLink(at point: CGPoint) -> DetectedLink? {
        guard SettingsKey.linkDetectionEnabled, let metrics = driver.cellMetrics() else { return nil }
        let links = TerminalLinkDetector.detect(
            rows: driver.viewportTextRows(),
            cwd: model?.linkCwd,
            schemes: SettingsKey.linkSchemePolicy,
        )
        return TerminalLinkHitTest.link(
            in: links, metrics: metrics, pointX: point.x, pointY: point.y,
            slop: CGFloat(TerminalTouchSelection.linkHitSlop),
        )
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
        var groups: [[UIMenuElement]] = [linkActions(), []]
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

    func setPaneFocused(_ isFocused: Bool) {
        driver.setFocus(isFocused, blinkVisible: true)
        if isFocused, !isFirstResponder {
            becomeFirstResponder()
        }
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
