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

    /// Where a pan started, so scroll can be reported in whole ROWS rather than in the pixels UIKit
    /// hands over — a terminal scrolls by lines, and rounding per-callback would lose the remainder.
    private var panRowRemainder: CGFloat = 0

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
        addGestureRecognizer(press)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        // The tap must yield to the long press, or every selection would begin with a focus tap
        // that dismissed it.
        tap.require(toFail: press)
        addGestureRecognizer(tap)
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
        guard let metrics = driver.cellMetrics(), metrics.cellHeight > 0 else { return }
        switch gesture.state {
        case .began:
            panRowRemainder = 0
        case .changed:
            // Whole rows, remainder carried: a terminal scrolls by lines, and rounding each
            // callback independently would drop a fraction of a row per frame and drift.
            let travelled = gesture.translation(in: self).y + panRowRemainder
            let rows = (travelled / metrics.cellHeight).rounded(.towardZero)
            panRowRemainder = travelled - rows * metrics.cellHeight
            gesture.setTranslation(.zero, in: self)
            guard rows != 0 else { return }
            // Dragging DOWN reveals older output, which is the opposite sign to the door's.
            driver.scroll(.rows(Int32(rows)))
        default:
            panRowRemainder = 0
        }
    }

    @objc
    private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        lastPointerPoint = point
        switch gesture.state {
        case .began:
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
