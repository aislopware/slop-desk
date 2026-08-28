// PhoneDevicePanelParts — the drawing both device panels do AROUND the picture, plus the phone-only
// way of typing into one.
//
// Two things live here, and they are together for the reason the deleted `DevicePanelChrome.swift` and
// `DeviceSoftKeyboard.swift` were two files: they are the parts of the simulator and Android surfaces
// that are neither simulator nor Android. The Mac's counterpart is ``SlopDeskMacUI/MacDevicePanelParts``
// and it holds the same first half; it holds none of the second, because a Mac always has keys.
//
// ## The chrome
//
// The empty stage, the caption under it, the notice a list draws when it has no rows, and the delay
// before a veil admits that a stream is late. These are DESIGN decisions, not device ones, and each was
// made once and written down twice — `docs/DECISIONS.md` records the reasoning for all four in the
// singular ("a scrim says something is on top of the picture; there is no picture"), which is the tell.
// A panel that redraws its own empty state is how one console ends up on `Slate.Surface.field` and the
// other on `raised` after a design pass touches the file it happened to be looking at.
//
// What stays with each panel is the NUMBER that was measured on its own device —
// ``SimulatorPresentation/veilDelay`` against a 0.09 s first keyframe, ``AndroidPresentation/veilDelay``
// against 0.83 s — because those are facts about two different pieces of hardware and merging them
// would throw away the measurement. Both numbers are `rust/slopdesk-devicepanel`'s already
// (docs/62 §7 item 7); what is left on this side is the `Task.sleep`, which is an actuator.
//
// ## The soft keyboard
//
// Both mirrors already type: `pressesBegan` reads a `UIKey`, asks the shared rule what it means, and
// sends text or a keycode. That path needs a HARDWARE keyboard. On a Mac there is always one, so the
// capability was complete there and looked complete here — but the phone this ships on most often has
// no keys at all, and on that phone the mirrored device could be tapped, swiped, rotated and
// screenshotted while remaining impossible to type a single character into.
//
// So this is a PHONE-ONLY affordance closing a phone-only hole, which is the shape the split allows:
// the capability — put text into the device — is the Mac's too, and only the way it is reached differs.
// Nothing here is a second implementation of anything. The bytes go out through the very same two calls
// the hardware path uses, and even BACKSPACE is spelled as the HID usage a real key would have reported
// (``DeviceSoftKeyboard/softDeleteUsage``), so the keycode it becomes is still the shared rule's answer
// rather than a constant copied into Swift.
//
// ### Why a registry rather than a flag drilled down
//
// The plate that raises the keyboard sits on the STAGE's toolbar; the responder that receives the text
// is inside the mirror, several views below it. Threading a `Bool` through both stacks would put a
// typing flag in the signature of every view between them — including two that exist only to draw a
// bezel around a picture. The mirror on screen registers itself instead, exactly as the code panel's
// keyboard ownership is a registered fact rather than a passed one (`CodeSidebarKeyboardState`). It is
// sound BECAUSE of the phone's layout: the panel shows one surface, a surface shows one device, so "the
// mirror on screen" is never ambiguous — and a mirror leaving the screen clears the flag on its way
// out, so the plate cannot be lit for a stage that is gone.

#if os(iOS)
import Observation
import QuartzCore
import SFSafeSymbols
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit

// MARK: - The chrome

@MainActor
enum PhoneDevicePanelChrome {
    /// The stage with no picture on it: OPAQUE, on the stage's own tone rather than a dimming scrim.
    /// A scrim says "something is on top of the picture"; there is no picture, and the truthful drawing
    /// is the stage itself, empty.
    ///
    /// The caller fades it — ``Slate/Motion/smallFade`` on `alpha` — because a veil arriving and a veil
    /// leaving are the same beat as whatever else the stage is doing in that transaction.
    static func veil(_ views: [UIView]) -> UIView {
        let ground = UIView()
        ground.translatesAutoresizingMaskIntoConstraints = false
        ground.backgroundColor = Slate.Native.Surface.field

        let stack = PhonePanelCentredStack(views)
        ground.addSubview(stack)
        stack.pin(inside: ground)
        return ground
    }

    /// The line under a veil's mark — secondary, footnote-sized, one line of explanation.
    static func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: Slate.Typeface.footnote)
        label.textColor = Slate.Native.Text.secondary
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// What a device LIST draws in place of rows: centred, secondary, filling the space the rows would
    /// have had.
    ///
    /// A FAILED POLL DRAWS NOTHING HERE (user-directed 2026-08-04) — the last-known devices are still
    /// the best information available, the report goes to the window's notification card like every
    /// other report these panels make, and two bespoke alert shapes in one panel was the thing being
    /// fixed. This is for a list that is genuinely empty, which is a different sentence.
    static func notice(_ text: String) -> UIView {
        let host = UIView()
        host.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: Slate.Typeface.base)
        label.textColor = Slate.Native.Text.secondary
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: host.leadingAnchor, constant: Slate.Metric.space3,
            ),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: host.trailingAnchor, constant: -Slate.Metric.space3,
            ),
        ])
        return host
    }

    /// The trailing key that empties a filter field.
    ///
    /// `SlateSearchField`'s header hands the plate — and with it "the trailing clear affordance" — to
    /// its CALLER, and four callers took that four different distances: both device LISTS drew this key,
    /// and neither CONSOLE drew anything, so a typed filter over a log could only be undone by
    /// backspacing it. Same panel, same field, same act, two answers. Cut once here, drawn by all four.
    ///
    /// `ink` is a parameter because the two panels ARE two inks — the Android half reads in
    /// `AndroidInk`, which is the one thing about these surfaces that is deliberately not shared.
    ///
    /// The caller keeps the fade: this key appears on the FIRST keystroke and vanishes on the last,
    /// which at a field's trailing edge is a glyph blinking beside the caret, and the fade that keeps it
    /// from reading as part of the typing belongs to the row it blinks in, not to the key.
    static func clearKey(ink: UIColor, action: @escaping () -> Void) -> UIControl {
        let key = PhoneDeviceClearKey(ink: ink, action: action)
        key.accessibilityLabel = "Clear the filter"
        return key
    }

    /// Whether the loading veil should be showing, late on the way up and immediate on the way down;
    /// `nil` when the wait was cancelled and the caller must not write anything.
    ///
    /// The asymmetry is the whole point, and it is why the views keep a copy of the model's loading
    /// state at all: the caller's `Task` is cancelled the instant the model's state flips, so a pending
    /// veil for a stream that arrived in time never appears. Waiting on the way DOWN would leave grey
    /// over a picture that is already there.
    ///
    /// ⚠️ THE SIMULATOR HALF DOES NOT CALL THIS. ``SimulatorPresentation/loadingVeil(isAwaiting:)`` is
    /// the same three lines with that panel's own measured delay already inside, and calling the door
    /// beats passing it its own number. This form exists for the Android stage, whose delay
    /// (``AndroidPresentation/veilDelay``) crosses on its own and whose Mac twin inlines exactly this.
    static func loadingVeilState(isAwaiting: Bool, after delay: Duration) async -> Bool? {
        guard isAwaiting else { return false }
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return nil }
        return true
    }
}

/// The clear key itself — a `UIControl` rather than a `UIButton` so the glyph wears the panel's ink
/// instead of the platform's tint, and so a press has somewhere to land on a device with no pointer.
@MainActor
private final class PhoneDeviceClearKey: UIControl {
    private let action: () -> Void
    private let glyph = UIImageView()
    private let ink: UIColor

    init(ink: UIColor, action: @escaping () -> Void) {
        self.ink = ink
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The GLYPH is footnote-sized; the TOUCH TARGET is not. A caret-height key beside a text
            // field is a 11pt tap on a phone, which is half of what a finger can reliably hit.
            widthAnchor.constraint(equalToConstant: Slate.Metric.plate),
            heightAnchor.constraint(equalToConstant: Slate.Metric.plate),
        ])
        addTarget(self, action: #selector(fire), for: .touchUpInside)

        isAccessibilityElement = true
        accessibilityTraits = .button

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (key: Self, _: UITraitCollection) in
            key.refresh()
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            refresh()
        }
    }

    @objc
    private func fire() { action() }

    /// The press dims rather than plating: this key sits INSIDE a field's own fill, and a second plate
    /// there would read as a control standing on the text rather than at the end of it.
    private func refresh() {
        glyph.image = UIImage(
            systemName: SFSymbol.xmarkCircleFill.rawValue,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Slate.Typeface.footnote),
        )?.withTintColor(ink.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        alpha = isHighlighted ? Slate.Opacity.dim : 1
    }
}

// MARK: - The soft keyboard

/// The mirror's half of the deal: raise or drop the keyboard, and take what is typed.
@MainActor
protocol DeviceSoftKeyboardHost: AnyObject {
    func setSoftKeyboard(_ armed: Bool)
}

/// Which mirror is on screen, and whether it is currently taking typed text.
@MainActor
@Observable
final class DeviceSoftKeyboard {
    static let shared = DeviceSoftKeyboard()
    private init() {}

    /// Whether the keyboard is up over the mirror. Observed by the stage's plate, so the key is lit
    /// while it is — and, because the mirror writes it back on `resignFirstResponder`, the plate also
    /// goes dark when the keyboard is dismissed by the system's own gesture rather than by the plate.
    private(set) var isTyping = false

    /// The mirror currently mounted. Weak — a stage that has gone away must not be kept alive by a
    /// registry, and a stale entry would send text into a socket that is already closed.
    ///
    /// ⚠️ NOT `@ObservationIgnored`, and not observed either: it is `private`, so no tracked read of it
    /// can exist outside this file. The deleted original carried a `hasHost` reader for the plate to
    /// gate on; docs/62's member-deletion ledger struck it, and the plate now gates on the stage having
    /// mounted a mirror at all — which is a fact the stage already knows without asking a registry.
    private weak var host: (any DeviceSoftKeyboardHost)?

    func register(_ host: any DeviceSoftKeyboardHost) {
        self.host = host
    }

    /// A mirror leaving the screen. Guarded on identity: views come and go in either order across a
    /// device switch, and a departing OLD mirror must not unregister the new one that just arrived.
    func unregister(_ host: any DeviceSoftKeyboardHost) {
        guard self.host === host else { return }
        self.host = nil
        isTyping = false
    }

    /// The plate. Idempotent in both directions.
    func toggle() {
        guard let host else { return }
        isTyping.toggle()
        host.setSoftKeyboard(isTyping)
    }

    /// The mirror reporting what actually happened — the keyboard can go down without the plate being
    /// touched (the system's dismiss gesture, a responder change), and a plate lit against a keyboard
    /// that is not there is worse than no plate.
    func report(isTyping: Bool) {
        self.isTyping = isTyping
    }

    /// The USB HID usage a real Backspace key reports. Sent through the same resolve door the hardware
    /// path uses rather than named as a keycode here, so the two spellings of "backspace" stay one —
    /// this file knows a KEY, not a device's table.
    static let softDeleteUsage: UInt16 = 42

    /// The plate's word. Phone-only, so it lives with the phone-only affordance rather than in a shared
    /// presentation both shells read.
    static let plateHelp = "Type into the device"
}

/// The zero-sized responder the soft keyboard actually belongs to.
///
/// A separate view rather than the mirror itself, and that is the whole trick: `UIKeyInput` is what
/// raises the keyboard, and a mirror that adopted it would raise one on every TAP, because the mirror
/// takes first responder on touch so that a hardware keyboard follows the last device touched. Kept as
/// a CHILD of the mirror so the two answers stay ordered without a second rule — while this view holds
/// first responder a hardware press still walks up to the mirror's own `pressesBegan`, so an iPad with
/// a keyboard attached loses nothing by the plate having been pressed.
@MainActor
final class DeviceSoftKeyInput: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    /// Told when the keyboard actually goes down, however it went down.
    var onResign: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }

    // MARK: UIKeyInput

    /// Always `true`, so the keyboard draws its delete key as live. The mirror holds no text to report
    /// on — the device does, and what it holds is not knowable from here — and answering `false` would
    /// grey out the one key most needed to fix a typo on the device.
    var hasText: Bool { true }

    func insertText(_ text: String) { onText?(text) }

    func deleteBackward() { onDeleteBackward?() }
}
#endif
