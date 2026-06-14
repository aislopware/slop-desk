#if os(iOS)
import AislopdeskClient
import SwiftUI
import UIKit

/// The iOS input **host** that assembles the four inert table-stakes components (doc 17 §2.5)
/// into one working input surface, replacing the plain SwiftUI `TextField` on iOS.
///
/// The four components are deliberately UIKit-free or single-purpose and own no wiring; this is
/// the `UIView` that owns and connects them:
///
/// - **Hardware keyboard** — the key-encoding presses are intercepted **on the IME proxy** (the
///   only first responder, so the only view that receives `UIPress` events), classified by
///   ``InputRouting``, and surfaced to this host via the proxy's `onKeyPress`/`onKeyRelease`.
///   Key-path presses (Esc / Tab / arrows / Return / Delete and Ctrl/Alt+letter) are fed into a
///   ``KeyRepeater`` (manual auto-repeat, since UIKit fires each physical key once); each
///   ``KeyRepeater`` fire encodes the press to bytes and forwards them to `sendInput`. Plain
///   printable presses fall through to the proxy's text system so CJK composition is never broken.
/// - **Software keyboard accessory** — a ``KeyboardAccessoryBar`` is the view's
///   `inputAccessoryView`, shown/hidden by ``KeyboardAccessoryDecision`` driven from the
///   keyboard-frame notifications. Its `onKey` (Esc/Tab/arrows, Ctrl-folded) forwards to
///   `sendInput`.
/// - **IME / printable text** — the embedded ``IMEProxyTextView`` is the sole first responder;
///   its committed `onText` (post-IME-composition) is UTF-8 encoded and forwarded to `sendInput`.
/// - **Floating cursor** — the spacebar long-press floating cursor is delivered to the text-input
///   first responder; ``IMEProxyTextView`` forwards `begin/update/end` to a
///   ``FloatingCursorController``, whose `onArrows` (← / →) forward to `sendInput`.
///
/// Everything reaches `AislopdeskClient.sendInput` through ``InputBarModel``. Only committed
/// printable / IME text is recorded into the B1 echo-dedup ring (``InputBarModel/sendText(_:over:)``,
/// no implicit Enter), because the PTY echoes only that. Control sequences — special keys,
/// Ctrl/Alt codes, accessory taps, floating-cursor arrows — go through the **non-recording**
/// ``InputBarModel/sendRaw(_:over:record:)`` (`record: false`): the PTY never echoes them, so
/// recording them would leave stale bytes that could later swallow a real TUI redraw.
public struct TerminalInputHost: UIViewRepresentable {
    private let model: InputBarModel
    /// The pane this input surface backs (docs/22 §7). The key the ``PaneFocusCoordinator`` registers
    /// this host under so a focus change can resign-before-become the right surface.
    private let paneID: PaneID
    /// The single-focus arbiter for the multi-visible iPad-regular path (docs/22 §7). `nil` ⇒ compact
    /// (one mounted host): no race to coordinate, so the host claims first responder directly on
    /// appear, exactly as before.
    private let coordinator: PaneFocusCoordinator?

    public init(
        model: InputBarModel,
        paneID: PaneID,
        coordinator: PaneFocusCoordinator? = nil,
    ) {
        self.model = model
        self.paneID = paneID
        self.coordinator = coordinator
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(model: model, paneID: paneID, focusCoordinator: coordinator)
    }

    public func makeUIView(context: Context) -> TerminalInputResponderView {
        let view = TerminalInputResponderView()
        context.coordinator.attach(to: view)
        if let focus = context.coordinator.focusCoordinator {
            // iPad-regular (multi-visible): route first-responder through the coordinator so a stale
            // async becomeFirstResponder can never win the race (resign-before-become + generation
            // reject — docs/22 §7). The coordinator drives the actual `becomeFocus()`; we do NOT also
            // issue an un-tokened `becomeFirstResponder()` here (that would race the coordinator).
            let adapter = context.coordinator.makeFocusAdapter(for: view)
            focus.register(adapter, for: context.coordinator.paneID)
        } else {
            // Compact (single mounted host): no race — claim first responder directly so the
            // software/hardware keyboard targets this surface (the pre-WF6 behaviour, preserved).
            DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        }
        return view
    }

    public func updateUIView(_: TerminalInputResponderView, context _: Context) {
        // Nothing to refresh: sends funnel through InputBarModel.sendSink → the pane's
        // TerminalViewModel OUT FIFO, which always targets the LIVE client (the sink is
        // re-wired by ConnectionViewModel.connect across reconnects).
    }

    public static func dismantleUIView(_ uiView: TerminalInputResponderView, coordinator: Coordinator) {
        // Unregister BEFORE teardown so the focus coordinator drops the (about-to-die) host and never
        // resurrects it from a scheduled become (docs/22 §7). By IDENTITY, not paneID, so a NEW host that
        // already re-registered under the same paneID (make-before-dismantle) is not clobbered (R13 #8).
        coordinator.unregisterFromCoordinator()
        uiView.teardown()
        coordinator.teardown()
    }

    /// Owns the per-instance send glue: turns the components' byte/text callbacks into
    /// SYNCHRONOUS `InputBarModel` sends on the main actor, recording for B1 dedup.
    ///
    /// NO local queue/drain (docs/29's documented dual-OUT-drain reorder fix): the model's
    /// `sendSink` enqueues straight into the pane's ONE ordered OUT FIFO (the
    /// `ConnectionViewModel` drain), so a tap/scroll byte and a keystroke can never race
    /// the reentrant client actor — the iOS keyboard path and the gesture/clipboard path
    /// now share a single FIFO. Record-then-enqueue is synchronous in call order, so the
    /// B1 echo-dedup ring matches wire order by construction.
    @preconcurrency
    @MainActor
    public final class Coordinator {
        let model: InputBarModel
        /// The pane this host backs (the coordinator registration key — docs/22 §7).
        let paneID: PaneID
        /// The single-focus arbiter, or `nil` on the compact single-host path.
        let focusCoordinator: PaneFocusCoordinator?
        /// The focus adapter over the responder view. RETAINED here because the coordinator's registry
        /// holds it weakly (so a dismantled host can't be resurrected); the Coordinator's lifetime is
        /// the host's, so this is the right owner.
        private var focusAdapter: FocusInputHostAdapter?

        init(
            model: InputBarModel,
            paneID: PaneID,
            focusCoordinator: PaneFocusCoordinator?,
        ) {
            self.model = model
            self.paneID = paneID
            self.focusCoordinator = focusCoordinator
        }

        /// Builds (and retains) the ``FocusInputHostAdapter`` over `view` for the focus coordinator.
        /// Called once from `makeUIView`; the coordinator holds the returned adapter weakly, so this
        /// Coordinator is its strong owner for the host's lifetime.
        func makeFocusAdapter(for view: TerminalInputResponderView) -> FocusInputHostAdapter {
            let adapter = FocusInputHostAdapter(view: view)
            focusAdapter = adapter
            return adapter
        }

        /// Identity-unregisters this host from the focus coordinator on dismantle. Removing by IDENTITY
        /// (this Coordinator's retained adapter) — not by paneID — means a make-before-dismantle flip,
        /// where a NEW host already re-registered under the same paneID, does not clobber the live new
        /// host or drop its focus (R13 #8). The compact path built no adapter (and has no coordinator),
        /// so it falls back to the paneID unregister.
        func unregisterFromCoordinator() {
            guard let focusCoordinator else { return }
            if let focusAdapter { focusCoordinator.unregister(host: focusAdapter) }
            else { focusCoordinator.unregister(paneID) }
        }

        func attach(to view: TerminalInputResponderView) {
            // Direct synchronous main-actor calls in true event order — the sink behind
            // sendRaw/sendText appends to the pane's single OUT FIFO.
            view.onKeyBytes = { [weak self] bytes in self?.model.sendRaw(bytes) }
            view.onText = { [weak self] text in self?.model.sendText(text) }
        }

        /// Called on SwiftUI dismantle. Nothing to stop — sends are synchronous enqueues;
        /// the pane's OUT drain is owned (and torn down) by `ConnectionViewModel`.
        func teardown() {}
    }
}

/// The custom `UIResponder` (a `UIView`) that physically hosts the four components and owns the
/// hardware-key / keyboard-frame plumbing. The SwiftUI ``TerminalInputHost`` is the thin
/// representable around it.
public final class TerminalInputResponderView: UIView {
    /// Forwarded raw bytes for the key path (hardware keys, accessory taps, floating-cursor arrows).
    var onKeyBytes: (([UInt8]) -> Void)?
    /// Forwarded committed text (IME / printable), already post-composition.
    var onText: ((String) -> Void)?

    private let proxy = IMEProxyTextView()
    private let accessoryDecision = KeyboardAccessoryDecision()
    private let floatingCursor = FloatingCursorController()
    private lazy var accessoryBar = KeyboardAccessoryBar()

    /// The repeater key: a modifier-INDEPENDENT PHYSICAL identity, carrying the modifier-laden press
    /// as the encode payload. Equality/hash key on the identity ONLY (not the payload).
    ///
    /// Why: holding Ctrl+L starts a repeat keyed by that press; if the user releases the MODIFIER
    /// BEFORE the letter, the letter's `pressesEnded` classifies as a PLAIN 'l' (control flag gone),
    /// which — keyed by the full press — would NOT match the held Ctrl+L and the repeat would run
    /// forever (a 20Hz control-code flood). `charactersIgnoringModifiers` ("l") is modifier-independent,
    /// so keyDown(Ctrl+L) and keyUp(L) produce the SAME identity and the release stops the repeat.
    private struct RepeatKey: Hashable {
        let identity: String
        let press: InputRouting.KeyPress
        init(_ press: InputRouting.KeyPress) {
            identity = (press.isSpecial ? "S:" : "C:") + press.charactersIgnoringModifiers
            self.press = press
        }

        static func == (a: Self, b: Self) -> Bool { a.identity == b.identity }
        func hash(into h: inout Hasher) { h.combine(identity) }
    }

    /// Manual key-repeat for the hardware path: each fire re-encodes the held press to bytes.
    /// Keyed by ``RepeatKey`` (modifier-independent physical id) so last-key-wins / release work even
    /// when a modifier is released before the letter (the runaway-repeat fix).
    private lazy var repeater = KeyRepeater<RepeatKey>(
        scheduler: DispatchRepeatScheduler(),
    ) { [weak self] key in
        guard let bytes = TerminalInputResponderView.encode(key.press) else { return }
        // The scheduler fires on a background queue; hop to main for the SwiftUI/UIKit send.
        // `[weak self]` on the inner hop too: a fire already in flight when the view is torn
        // down must NOT deliver a stale byte through a half-dismantled view.
        DispatchQueue.main.async { [weak self] in self?.onKeyBytes?(bytes) }
    }

    /// Whether the accessory bar should currently be attached (software keyboard on screen).
    private var accessoryVisible = false

    init() {
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) not supported") }

    private func configure() {
        backgroundColor = .clear
        // The IME proxy is the text first responder; embed it so iOS routes composed text to it.
        // It is also the only view that receives `UIPress` events, so the key-encoding presses
        // it intercepts are fed into the repeater here (special keys + Ctrl/Alt combos).
        addSubview(proxy)
        proxy.onText = { [weak self] text in self?.handleProxyText(text) }
        proxy.onKeyPress = { [weak self] press in self?.repeater.keyDown(RepeatKey(press)) }
        proxy.onKeyRelease = { [weak self] press in self?.repeater.keyUp(RepeatKey(press)) }
        proxy.onFloatingCursorBegin = { [weak self] point in self?.floatingCursor.begin(at: point) }
        proxy.onFloatingCursorUpdate = { [weak self] point in self?.floatingCursor.update(at: point) }
        proxy.onFloatingCursorEnd = { [weak self] in self?.floatingCursor.end() }

        // Floating-cursor arrow runs go straight to the key path.
        floatingCursor.onArrows = { [weak self] bytes in self?.onKeyBytes?(bytes) }

        // Accessory bar: Esc/Tab/arrows (and Ctrl-folded letters) forward to the key path.
        accessoryBar.onKey = { [weak self] bytes in self?.onKeyBytes?(bytes) }

        // Keyboard-frame notifications drive the accessory show/hide decision.
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil,
        )
        center.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
        )
        center.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil,
        )
    }

    /// Soft-keyboard committed text (post-IME). If the accessory bar is visible and its Ctrl is ARMED,
    /// fold the FIRST scalar into its control code and send it RAW (non-recorded — the PTY never echoes a
    /// control byte), consuming the one-shot arm; any remaining text flows as normal recorded text.
    /// Without this the accessory Ctrl button was a dead no-op for soft-keyboard letters — Ctrl-C from a
    /// pure soft keyboard was impossible, the exact case the bar exists to solve (R13 #6). Gating on
    /// `accessoryVisible` first avoids touching (and lazily building) the bar on the hardware-keyboard
    /// path, where Ctrl+letter is handled by the key encoder instead.
    private func handleProxyText(_ text: String) {
        if accessoryVisible, let folded = KeyEncoding.foldArmedControl(text, armed: accessoryBar.controlArmed) {
            accessoryBar.consumeControlArm()
            onKeyBytes?(folded.controlBytes)
            if !folded.rest.isEmpty { onText?(folded.rest) }
            return
        }
        onText?(text)
    }

    /// Tears down notifications + repeater (called on SwiftUI dismantle). The repeater's `stop()`
    /// is thread-safe (its own lock), and `removeObserver` is safe from any thread, so `deinit`
    /// performs the same cleanup directly without hopping the main actor.
    func teardown() {
        repeater.stop()
        // Remove exactly the observers registered in `configure` (rather than the blanket
        // `removeObserver(self)`, which is reserved for `deinit`); equivalent here since these
        // are the only notifications this object observes.
        let center = NotificationCenter.default
        center.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        center.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit {
        // `repeater`'s own `deinit` cancels its in-flight timer; here we only drop the
        // notification observers (safe from any thread, no main-actor hop).
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: First responder + IME embedding

    override public var canBecomeFirstResponder: Bool { true }

    /// We are a transparent lifecycle host; the embedded IME proxy is the **sole** first responder
    /// (it owns both text composition and the `pressesBegan` key interception). Becoming first
    /// responder here forwards straight to the proxy so there is never an ambiguous responder
    /// order between text input and key handling.
    @discardableResult
    override public func becomeFirstResponder() -> Bool {
        proxy.becomeFirstResponder()
    }

    override public func resignFirstResponder() -> Bool {
        repeater.stop()
        return proxy.resignFirstResponder()
    }

    // MARK: inputAccessoryView (the accessory bar, gated by the decision)

    override public var inputAccessoryView: UIView? {
        accessoryVisible ? accessoryBar : nil
    }

    @objc
    private func keyboardFrameChanged(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
            return
        }
        setAccessory(visible: accessoryDecision.shouldShowAccessoryBar(keyboardHeight: Double(frame.height)))
    }

    @objc
    private func keyboardWillHide(_: Notification) {
        setAccessory(visible: false)
    }

    private func setAccessory(visible: Bool) {
        guard visible != accessoryVisible else { return }
        accessoryVisible = visible
        // Clear a stale Ctrl arm on hide: a one-shot arm set but never spent (keyboard dismissed before
        // the letter) would otherwise persist on this lazy instance and silently Ctrl-fold the FIRST
        // letter of the next soft-keyboard session (UI/UX pass-3 #4). The bar is already instantiated
        // here (it was visible to be hidden).
        if !visible { accessoryBar.consumeControlArm() }
        // Reloading input views re-queries `inputAccessoryView` so the bar attaches/detaches.
        proxy.reloadInputViews()
        reloadInputViews()
    }

    // MARK: Key encoding (the proxy classifies; this host encodes each repeater fire)

    /// Encodes a classified key-path press into the raw terminal bytes for `sendInput`. Returns
    /// `nil` for a press that carries nothing to send (e.g. a bare modifier). The platform-agnostic,
    /// headless-testable ``KeyEncoding`` does the work (control codes, the `characters`-keyed specials
    /// Esc/Tab/Shift+Tab/CR/DEL, and the Option/meta prefix); the arrow keys — whose identity is the
    /// opaque UIKit `UIKeyCommand.input*Arrow` constants — are resolved here and injected.
    nonisolated static func encode(_ press: InputRouting.KeyPress) -> [UInt8]? {
        KeyEncoding.encode(press, arrowFallback: arrowBytes)
    }

    /// Resolves the arrow keys — the one special-key class whose identity is a UIKit constant, so it
    /// cannot live in the platform-agnostic ``KeyEncoding``. Reuses the accessory bar's verified
    /// cursor byte table.
    private nonisolated static func arrowBytes(_ press: InputRouting.KeyPress) -> [UInt8]? {
        switch press.charactersIgnoringModifiers {
        case UIKeyCommand.inputUpArrow: KeyboardAccessoryBar.Key.up.bytes
        case UIKeyCommand.inputDownArrow: KeyboardAccessoryBar.Key.down.bytes
        case UIKeyCommand.inputLeftArrow: KeyboardAccessoryBar.Key.left.bytes
        case UIKeyCommand.inputRightArrow: KeyboardAccessoryBar.Key.right.bytes
        default: nil
        }
    }
}

// MARK: - Focus adapter (the PaneFocusCoordinator seam)

/// A thin adapter that lets the ``PaneFocusCoordinator`` drive a ``TerminalInputResponderView``'s
/// first-responder status WITHOUT importing the coordinator into the byte pipeline (docs/22 §7 — the
/// adapter approach). It forwards `resignFocus()`/`becomeFocus()` to the view's
/// `resignFirstResponder()`/`becomeFirstResponder()` (both already overridden to forward to the IME
/// proxy). The view is held **weakly** so a dismantled host is never resurrected or leaked — the
/// coordinator's registry also boxes the adapter weakly, and the `TerminalInputHost.Coordinator`
/// retains it for the host's lifetime.
@preconcurrency
@MainActor
public final class FocusInputHostAdapter: PaneFocusCoordinator.FocusableInputHost {
    private weak var view: TerminalInputResponderView?

    init(view: TerminalInputResponderView) {
        self.view = view
    }

    @discardableResult
    public func resignFocus() -> Bool {
        view?.resignFirstResponder() ?? false
    }

    @discardableResult
    public func becomeFocus() -> Bool {
        view?.becomeFirstResponder() ?? false
    }
}
#endif
