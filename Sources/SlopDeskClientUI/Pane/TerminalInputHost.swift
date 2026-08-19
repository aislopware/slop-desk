#if os(iOS)
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI
import UIKit

// The phone's terminal input surface — the UIKit half of `SlopDeskWorkspaceCore.PhoneKey`.
//
// Until this file existed the phone's terminal could not receive a keystroke at all: the rules were
// written, ported and tested, and nothing mounted a responder to ask them (docs/56 §Increment 15).
// This is that responder, and it is deliberately thin — it reads a `UIKey` into a `PhoneKey.Press`,
// asks which of the two paths the press takes, and writes the answer to the pane. It decides
// nothing: which keys are special, what bytes they send under the live cursor-key mode, which press
// is a chord and when the accessory row is worth its space are all `slopdesk_workspace::phone_key`.
//
// ## One view, two paths
//
// A touch device is forced to split physical input: some presses a terminal needs RAW (⌃C must be
// 0x03, not the letter c), and some are the visible half of a composition that has not finished yet
// (a Pinyin candidate is three keystrokes before it is one character). `PhoneKey.route` is that
// split, and the split is between PATHS, not between views — `pressesBegan` runs it before deciding
// whether to call `super`. A press routed to the proxy is one this view never touches, so UIKit's
// text system composes it and commits through `insertText`; a press routed to the encoder never
// reaches that system at all. Two first responders would have been the alternative, and it is the
// worse one: the order between them is UIKit's rather than ours, which is how a half-composed
// candidate ends up on the wire.
//
// ## What is NOT here yet
//
// `UITextInput` — marked text and the floating cursor. iOS shows CJK candidates in the keyboard's
// own bar and commits through `insertText`, so typing Chinese works without it; what it costs is
// INLINE composition display and space-bar-drag cursor movement. `PhoneKey`'s `FloatingCursor` is
// the prepared half of the second, and stays caller-less until that conformance lands.

/// Mounts the pane's key responder behind the terminal pixels.
///
/// Zero-sized on purpose: the surface is the renderer's, and this view exists only to hold first
/// responder, the accessory row and the press handlers. It sits UNDER the renderer in the leaf's
/// stack so it can never intercept a touch the terminal wanted.
struct TerminalInputHost: UIViewRepresentable {
    /// The pane this types into. Held weakly by the view so a leaf that outlives its session cannot
    /// keep the session alive through a responder.
    let live: LivePaneSession
    /// The coordinator that moves first responder between panes as the active pane changes.
    let focusCoordinator: PaneFocusCoordinator

    func makeUIView(context _: Context) -> TerminalInputHostView {
        let view = TerminalInputHostView()
        view.attach(to: live, focusCoordinator: focusCoordinator)
        return view
    }

    func updateUIView(_ view: TerminalInputHostView, context _: Context) {
        view.attach(to: live, focusCoordinator: focusCoordinator)
    }

    static func dismantleUIView(_ view: TerminalInputHostView, coordinator _: ()) {
        view.detach()
    }
}

/// The pane's first responder: hardware presses, software-keyboard commits, and the accessory row.
final class TerminalInputHostView: UIView, UIKeyInput {
    /// The pane's session. Weak — the leaf owns the mount, the store owns the session, and a
    /// responder that outlived its dismantle must go inert rather than write to a dead pane.
    private weak var live: LivePaneSession?
    private weak var focusCoordinator: PaneFocusCoordinator?
    private var paneID: PaneID?

    /// The accessory row's ⌃, which ARMS rather than toggles: the next commit folds to its control
    /// byte and the arming clears. A phone has no way to hold a modifier down while tapping a
    /// letter, so the modifier has to outlive the tap that set it and nothing else.
    private var controlArmed = false {
        didSet { accessoryBar?.setControlArmed(controlArmed) }
    }

    /// UIKit fires `pressesBegan`/`pressesEnded` exactly ONCE per physical key — there is no
    /// auto-repeat the way `keyDown` has one on macOS — so holding an arrow does nothing past the
    /// first event unless the embedder re-emits it. This is that re-emission.
    private lazy var repeater = KeyRepeater<PhoneKey.Press>(
        scheduler: DispatchRepeatScheduler(),
        onFire: { [weak self] press in
            // The scheduler fires on its own queue; every write below is main-actor state.
            Task { @MainActor [weak self] in self?.send(press) }
        },
    )

    private var accessoryBar: TerminalAccessoryBar?

    // MARK: Mounting

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false // the renderer above owns every touch
        backgroundColor = .clear
        // The row's producer. `willChangeFrame` rather than `willShow`: a hardware keyboard paired
        // mid-session never "shows", it changes the frame from hundreds of points to a shortcut
        // bar's few — and that transition is exactly the one that must take the row away again.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
        )
    }

    @objc
    private func keyboardFrameChanged(_ note: Notification) {
        let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        // An end frame parked below the screen is a keyboard on its way OUT, which is no keyboard at
        // all — its height is still hundreds of points at that moment, so the height alone would
        // keep the row up through the dismissal.
        guard let end, let screen = window?.screen, end.minY < screen.bounds.maxY else {
            reconcileAccessoryBar(keyboardHeight: 0)
            return
        }
        reconcileAccessoryBar(keyboardHeight: Double(end.height))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Points this responder at `session`, registering with the coordinator under its pane. Idempotent
    /// — `updateUIView` calls it on every SwiftUI pass, and a re-register under the same id is what
    /// re-claims first responder after a projection flip re-creates the view.
    func attach(to session: LivePaneSession, focusCoordinator: PaneFocusCoordinator) {
        let changed = live !== session || paneID != session.id
        live = session
        self.focusCoordinator = focusCoordinator
        guard changed else { return }
        if let previous = paneID, previous != session.id { focusCoordinator.unregister(previous) }
        paneID = session.id
        focusCoordinator.register(self, for: session.id)
    }

    /// Drops every registration and stops any key still repeating. Called on dismantle, which can
    /// happen mid-hold if the pane closes under a held key.
    func detach() {
        repeater.stop()
        if let paneID { focusCoordinator?.unregister(paneID) }
        focusCoordinator?.unregister(host: self)
        paneID = nil
        live = nil
        resignFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Physical keys

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, !handle(Self.read(key)) else { continue }
            unhandled.insert(press)
        }
        // Everything this view did not take goes on down the chain, which is what lets UIKit's own
        // text system compose the presses `PhoneKey` routed to it.
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            repeater.keyUp(Self.read(key))
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        repeater.stop()
        super.pressesCancelled(presses, with: event)
    }

    /// One `UIKey` as the rules' vocabulary — `PhoneKey.Press.init(_:)`, which the chord recorder
    /// reads its presses with too, so there is one answer to "which key is this".
    private static func read(_ key: UIKey) -> PhoneKey.Press { PhoneKey.Press(key) }

    /// Takes the press, or reports that the chain should have it. `true` means handled — either
    /// swallowed as a workspace chord or handed to the repeater, which writes it.
    ///
    /// The bytes are asked for TWICE on a press that is taken: once here, discarded, to learn
    /// whether the press writes anything at all, and once inside the repeater's immediate fire. That
    /// is one table lookup per human keystroke, and it buys the property that matters — a press that
    /// sends nothing never starts a 20 Hz repeat of nothing.
    @discardableResult
    private func handle(_ press: PhoneKey.Press) -> Bool {
        guard PhoneKey.routesToKeyEncoding(press) else { return false }
        // The SAME user-overridable table the Mac's dispatcher resolves against, so a rebind made
        // once fires on both. A bound chord is swallowed here — it never reaches the PTY, and it
        // does not repeat: a split that fired twenty times a second is not what holding ⌘D means.
        if let chord = PhoneKey.keyChord(for: press),
           let interceptor = live?.terminalModel?.keyInterceptor,
           case .swallow = interceptor.intercept(chord)
        {
            return true
        }
        guard encodedBytes(press) != nil else { return false }
        repeater.keyDown(press)
        return true
    }

    /// This press's bytes under the LIVE cursor-key mode, read per press off the model the far-side
    /// program is driving. A remembered copy would be one parse behind the screen the user is
    /// looking at, which is how arrows go dead in vim.
    private func encodedBytes(_ press: PhoneKey.Press) -> [UInt8]? {
        guard let live else { return nil }
        return PhoneKey.encode(
            press,
            applicationCursorKeys: live.terminalModel?.isCursorKeysApplication ?? false,
        )
    }

    /// Writes one press to the pane. A press that sends nothing is a no-op — a ⌘ combination that
    /// matched no binding is a shortcut that missed, not terminal input.
    private func send(_ press: PhoneKey.Press) {
        guard let live, let bytes = encodedBytes(press) else { return }
        live.sendBytes(bytes)
    }

    // MARK: The software keyboard's commits

    var hasText: Bool { true }

    /// A commit from the software keyboard — a tapped letter, or the string an input method settled
    /// on after however many keystrokes it needed.
    func insertText(_ text: String) {
        guard let live else { return }
        // An ARMED ⌃ folds the commit's first scalar to its control byte, which must go RAW because
        // a PTY never echoes one; the rest is ordinary text on the recorded path so the input bar
        // can dedupe the echo.
        if let folded = PhoneKey.foldArmedControl(text, armed: controlArmed) {
            controlArmed = false
            live.sendBytes([folded.controlByte])
            if !folded.rest.isEmpty { live.sendText(folded.rest) }
            return
        }
        live.sendText(text)
    }

    /// Backspace from the software keyboard. DEL, not BS — that is what a terminal's line editor
    /// reads as "erase the character behind the cursor".
    func deleteBackward() {
        send(PhoneKey.Press(hidUsage: PhoneKeyUsage.backspace))
    }

    // MARK: The accessory row

    override var inputAccessoryView: UIView? {
        guard let bar = accessoryBar else { return nil }
        return bar
    }

    /// Installs or removes the row for a keyboard of `height` points. Driven by the keyboard-frame
    /// notification rather than by a guess: `PhoneKey.showsAccessoryBar` is what separates a
    /// software keyboard — which has no ⌃, Esc or arrows and needs the row — from a hardware one,
    /// whose user already has all four.
    func reconcileAccessoryBar(keyboardHeight: Double) {
        let wanted = PhoneKey.showsAccessoryBar(keyboardHeight: keyboardHeight)
        guard wanted != (accessoryBar != nil) else { return }
        if wanted {
            let bar = TerminalAccessoryBar { [weak self] plate in self?.tap(plate) }
            bar.setControlArmed(controlArmed)
            accessoryBar = bar
        } else {
            accessoryBar = nil
            controlArmed = false
        }
        reloadInputViews()
    }

    /// One accessory plate. ⌃ arms; every other plate is a synthesized press through the same
    /// encoder a hardware key takes, so the bar cannot drift from the keyboard.
    private func tap(_ plate: TerminalAccessoryBar.Plate) {
        switch plate {
        case .control:
            controlArmed.toggle()
        case .dismiss:
            resignFirstResponder()
        case let .key(usage):
            handle(PhoneKey.Press(hidUsage: usage))
        }
    }
}

// MARK: - The focus seam

extension TerminalInputHostView: PaneFocusCoordinator.FocusableInputHost {
    @discardableResult
    func resignFocus() -> Bool { resignFirstResponder() }

    @discardableResult
    func becomeFocus() -> Bool { becomeFirstResponder() }
}

// MARK: - The usages the bar synthesizes

/// The HID keyboard usages this file names, read off `UIKeyboardHIDUsage` so there is no second
/// table anywhere — the responder reports the same numbers for a real key, and
/// `slopdesk_workspace::phone_key` is the only thing that says what each one MEANS.
enum PhoneKeyUsage {
    static let escape = UInt16(UIKeyboardHIDUsage.keyboardEscape.rawValue)
    static let tab = UInt16(UIKeyboardHIDUsage.keyboardTab.rawValue)
    static let backspace = UInt16(UIKeyboardHIDUsage.keyboardDeleteOrBackspace.rawValue)
    static let left = UInt16(UIKeyboardHIDUsage.keyboardLeftArrow.rawValue)
    static let right = UInt16(UIKeyboardHIDUsage.keyboardRightArrow.rawValue)
    static let up = UInt16(UIKeyboardHIDUsage.keyboardUpArrow.rawValue)
    static let down = UInt16(UIKeyboardHIDUsage.keyboardDownArrow.rawValue)
}

// MARK: - The row itself

/// The ⌃ / Esc / Tab / arrows row above the software keyboard.
///
/// Every plate but ⌃ and the dismiss chevron is a KEY, and each one goes through the same
/// `PhoneKey.encode` a hardware press takes — the bar has no byte table of its own, so it cannot
/// send an arrow the hardware path would have sent differently.
final class TerminalAccessoryBar: UIInputView {
    /// What a plate does when tapped.
    enum Plate: Equatable {
        /// Arm ⌃ for the next commit.
        case control
        /// Send a key.
        case key(UInt16)
        /// Put the keyboard away.
        case dismiss
    }

    private let onTap: (Plate) -> Void
    private var controlButton: UIButton?

    init(onTap: @escaping (Plate) -> Void) {
        self.onTap = onTap
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: Slate.Metric.plate + Slate.Metric.space2 * 2),
            inputViewStyle: .keyboard,
        )
        buildPlates()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// Lights ⌃ while it is armed. The arming has to be VISIBLE — a modifier that outlives the tap
    /// that set it and shows nothing is a keystroke the user cannot predict.
    func setControlArmed(_ armed: Bool) {
        controlButton?.backgroundColor = armed ? Slate.Native.accent : Slate.Native.Surface.raised
        controlButton?.tintColor = armed ? Slate.Native.Surface.face : Slate.Native.Text.primary
        controlButton?.setTitleColor(armed ? Slate.Native.Surface.face : Slate.Native.Text.primary, for: .normal)
    }

    private func buildPlates() {
        let plates: [(String, Plate)] = [
            ("⌃", .control),
            ("esc", .key(PhoneKeyUsage.escape)),
            ("⇥", .key(PhoneKeyUsage.tab)),
            ("←", .key(PhoneKeyUsage.left)),
            ("↓", .key(PhoneKeyUsage.down)),
            ("↑", .key(PhoneKeyUsage.up)),
            ("→", .key(PhoneKeyUsage.right)),
        ]
        let row = UIStackView(arrangedSubviews: plates.map { button(title: $0.0, plate: $0.1) })
        row.axis = .horizontal
        row.spacing = Slate.Metric.space1
        row.distribution = .fillEqually

        let dismiss = button(title: "⌄", plate: .dismiss)
        let outer = UIStackView(arrangedSubviews: [row, dismiss])
        outer.axis = .horizontal
        outer.spacing = Slate.Metric.space2
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space2),
            dismiss.widthAnchor.constraint(equalToConstant: Slate.Metric.plate),
        ])
    }

    private func button(title: String, plate: Plate) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = SlateNativeFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        button.setTitleColor(Slate.Native.Text.primary, for: .normal)
        button.backgroundColor = Slate.Native.Surface.raised
        button.layer.cornerRadius = Slate.Metric.radiusSmall
        button.addAction(UIAction { [weak self] _ in self?.onTap(plate) }, for: .touchUpInside)
        if plate == .control { controlButton = button }
        return button
    }
}
#endif
