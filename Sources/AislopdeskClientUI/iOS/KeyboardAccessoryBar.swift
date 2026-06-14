#if os(iOS)
import UIKit

/// The Ctrl / Esc / Tab / arrows accessory row shown above the software keyboard (doc 17 §2.5).
///
/// A terminal needs keys the iOS software keyboard lacks (Esc, Tab, arrows, and a Ctrl
/// modifier). This bar provides them as an `inputAccessoryView`. It is shown **only when the
/// software keyboard is visible** — with a hardware keyboard the user already has these keys
/// and iOS reports a short keyboard frame; the show/hide decision is the pure, unit-tested
/// ``KeyboardAccessoryDecision`` (~150pt threshold), which the owner consults on each
/// keyboard-frame notification.
///
/// Each button emits a raw terminal byte sequence via ``onKey``; Ctrl is a sticky modifier
/// that maps the next letter to its control code (e.g. Ctrl + C → 0x03), matching how a
/// hardware Ctrl behaves.
public final class KeyboardAccessoryBar: UIInputView {
    /// A labelled key the bar can send.
    public enum Key: Equatable {
        case escape
        case tab
        case control // sticky modifier
        case up
        case down
        case left
        case right

        /// The byte sequence for a non-modifier key. `control` returns `[]` (it is sticky).
        public var bytes: [UInt8] {
            switch self {
            case .escape: [0x1B]
            case .tab: [0x09]
            case .control: []
            case .up: [0x1B, 0x5B, 0x41] // ESC [ A
            case .down: [0x1B, 0x5B, 0x42] // ESC [ B
            case .right: [0x1B, 0x5B, 0x43] // ESC [ C
            case .left: [0x1B, 0x5B, 0x44] // ESC [ D
            }
        }
    }

    /// Fires with the raw bytes a tap produced (already Ctrl-folded if Ctrl was sticky).
    public var onKey: (([UInt8]) -> Void)?
    /// Whether the Ctrl modifier is currently armed.
    public private(set) var controlArmed = false

    private let stack = UIStackView()

    public init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44), inputViewStyle: .keyboard)
        buildButtons()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildButtons() {
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        for (title, key) in [
            ("esc", Key.escape),
            ("tab", .tab),
            ("ctrl", .control),
            ("←", .left),
            ("↓", .down),
            ("↑", .up),
            ("→", .right),
        ] {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
            button.tag = stack.arrangedSubviews.count
            button.addAction(UIAction { [weak self] _ in self?.tap(key, button: button) }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
    }

    private func tap(_ key: Key, button: UIButton) {
        if key == .control {
            controlArmed.toggle()
            button.backgroundColor = controlArmed ? .systemBlue.withAlphaComponent(0.3) : .clear
            return
        }
        onKey?(key.bytes)
        // Ctrl is one-shot after a key (matches hardware behaviour for a single combo).
        if controlArmed { controlArmed = false
            updateControlVisual()
        }
    }

    private func updateControlVisual() {
        // The ctrl button is the 3rd arranged view (esc, tab, ctrl, …).
        if let ctrl = stack.arrangedSubviews[safe: 2] as? UIButton {
            ctrl.backgroundColor = .clear
        }
    }

    /// Folds a printable letter under an armed Ctrl into its control code (Ctrl-A → 0x01 …).
    /// Returns the bytes to send and consumes the Ctrl arm. Used by the owner when a letter
    /// key arrives while ``controlArmed``.
    public func controlFold(_ scalar: UnicodeScalar) -> [UInt8] {
        defer { consumeControlArm() }
        return Self.controlCode(for: scalar)
    }

    /// Consumes the one-shot Ctrl arm (after an armed letter has been folded) and clears its visual.
    /// Used by the soft-keyboard text path, which folds the first scalar via the pure
    /// ``KeyEncoding/foldArmedControl(_:armed:)`` and then consumes the arm here (R13 #6).
    public func consumeControlArm() {
        if controlArmed { controlArmed = false
            updateControlVisual()
        }
    }

    /// Pure mapping of a key to its ASCII control code (delegates to the platform-agnostic, headless-
    /// testable ``KeyEncoding/controlCode(for:)``). `nonisolated` because it touches no UIKit state —
    /// the hardware-key encoder calls it from the key-repeat scheduler's background queue.
    public nonisolated static func controlCode(for scalar: UnicodeScalar) -> [UInt8] {
        KeyEncoding.controlCode(for: scalar)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
