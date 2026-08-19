import CSlopDeskFFI
import Foundation

// PhoneKey — the near side of the phone's key path.
//
// A touch device cannot have the Mac's single input path. Some presses a terminal needs raw — ⌃C is
// 0x03, not the letter c — and some are the visible half of a composition that has not finished yet.
// So every press is asked one question first, proxy or encoder, and the ones that answer "encoder"
// are turned into bytes and written straight to the pane; the rest are passed on down the responder
// chain for UIKit's own text input to compose. `SlopDeskClientUI.TerminalInputHost` is the caller.
//
// The rules are `slopdesk_workspace::phone_key`. What is here is the vocabulary the responder builds
// a press in, and the marshalling. Nothing decides anything: which keys are special at all, the C0
// fold, the cursor block's introducer, the meta prefix, which presses are chords and what a
// floating-cursor drag is worth all live on the other side of the door, tested there.
//
// A press is a HID usage plus one string, because `UIKey.keyCode` is the only signal that names the
// same key under every layout and input method. Keying a key's identity off what it COMMITTED — the
// deleted Swift original's approach — is what cost the phone its whole nav block (`docs/29` #7):
// Home, End, the page keys, Insert, forward Delete and F1-F12 commit nothing a table can match.
//
// DELIBERATELY NOT `#if os(iOS)`. Every one of these is a rule about bytes, and gating them behind
// the iOS triple would mean the macOS test runner never touches the marshalling — which is exactly
// the shape that let this whole path sit unbuilt: a green build over an empty file.

/// The phone's key path, as the responder asks it.
public enum PhoneKey {
    /// One physical key press, as the responder reads it off a `UIKey`.
    ///
    /// A usage and one string. ``hidUsage`` says WHICH key, under every layout and input method;
    /// ``charactersIgnoringModifiers`` says what that key produces under this one, which is what a
    /// ⌃ fold and a binding lookup are about. What the key COMMITTED (`UIKey.characters`) is
    /// deliberately absent — for a special key it is noise, and for a printable one UIKit's text input,
    /// not this, is what inserts it.
    public struct Press: Sendable, Equatable, Hashable {
        /// `UIKey.charactersIgnoringModifiers`.
        public var charactersIgnoringModifiers: String
        /// `UIKey.keyCode.rawValue` — a USB HID keyboard usage. `0` for a press with none, which is
        /// the HID keyboard page's own "no event".
        public var hidUsage: UInt16
        public var control: Bool
        public var option: Bool
        public var command: Bool
        /// ⇧. Not read by ``PhoneKey/route(_:)`` — a shifted letter is still typing — only by the
        /// encoder, where it is what tells a back-tab from a forward one.
        public var shift: Bool

        public init(
            charactersIgnoringModifiers: String = "",
            hidUsage: UInt16 = 0,
            control: Bool = false,
            option: Bool = false,
            command: Bool = false,
            shift: Bool = false,
        ) {
            self.charactersIgnoringModifiers = charactersIgnoringModifiers
            self.hidUsage = hidUsage
            self.control = control
            self.option = option
            self.command = command
            self.shift = shift
        }

        /// The flag word the doors read — `KeyChord.Modifiers`' own bits, and only those.
        var ffiFlags: UInt32 {
            var flags: UInt32 = 0
            if shift { flags |= UInt32(SLOPDESK_PHONE_KEY_SHIFT) }
            if control { flags |= UInt32(SLOPDESK_PHONE_KEY_CONTROL) }
            if option { flags |= UInt32(SLOPDESK_PHONE_KEY_OPTION) }
            if command { flags |= UInt32(SLOPDESK_PHONE_KEY_COMMAND) }
            return flags
        }
    }

    /// Which of the two input paths a press takes.
    public enum Route: Sendable, Equatable {
        /// Encode it here and write the bytes to the pane, bypassing the proxy.
        case keyEncoding
        /// Pass it on, so UIKit's own text input can compose it and commit through `insertText`.
        case imeProxy
    }

    /// Which path this press takes.
    public static func route(_ press: Press) -> Route {
        routesToKeyEncoding(press) ? .keyEncoding : .imeProxy
    }

    /// Whether the press bypasses the proxy.
    public static func routesToKeyEncoding(_ press: Press) -> Bool {
        withRecord(press) { record in
            var record = record
            return slopdesk_phone_key_routes_to_encoding(&record)
        }
    }

    /// The raw bytes this press sends, or `nil` for one that sends nothing — bare typing, which is
    /// the proxy's, or a ⌘ combination, which is an app shortcut rather than terminal input.
    ///
    /// `applicationCursorKeys` is the live DECCKM state, read off the pane's terminal model per
    /// press. A remembered copy would be one parse behind the screen the user is looking at, which
    /// is how arrows go dead in vim.
    public static func encode(_ press: Press, applicationCursorKeys: Bool = false) -> [UInt8]? {
        withRecord(press) { record in
            var record = record
            var out = [UInt8](repeating: 0, count: encodeCapacity)
            var written = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_phone_key_encode(&record, applicationCursorKeys, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else { return nil }
            // A key whose base is longer than the inline buffer — the door reported the size and
            // wrote nothing, so ask again with the size it named.
            if written > out.count {
                out = [UInt8](repeating: 0, count: written)
                written = out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_phone_key_encode(&record, applicationCursorKeys, buffer.baseAddress, buffer.count)
                }
                guard written > 0, written <= out.count else { return nil }
            }
            return Array(out.prefix(written))
        }
    }

    /// The ``KeyChord`` this press makes, or `nil` for one the binding table could not be keyed by —
    /// which the responder then routes normally rather than swallowing.
    ///
    /// The SAME table the Mac's dispatcher resolves against, user overrides included, so a rebind
    /// made once is a rebind both platforms honour.
    public static func keyChord(for press: Press) -> KeyChord? {
        withRecord(press) { record in
            var record = record
            var named: UInt8 = 0
            var character: UInt32 = 0
            var modifiers: UInt8 = 0
            guard slopdesk_phone_key_chord(&record, &named, &character, &modifiers) else { return nil }
            let mods = KeyChord.Modifiers(rawValue: Int(modifiers))
            if let key = KeyChord.Key(namedIndex: named) { return KeyChord(key, mods) }
            guard let scalar = UnicodeScalar(character) else { return nil }
            return KeyChord(character: Character(scalar), mods)
        }
    }

    /// What this press does to the binding being RECORDED in Settings ▸ Key Bindings.
    ///
    /// The same four answers the Mac's recorder gets from ``KeybindingCapture/outcome(keyCode:charactersIgnoringModifiers:command:shift:option:control:)``,
    /// numbered by the same table — the two write into ONE override map, so a press that reads as
    /// "clear" on one half cannot read as "rebind" on the other. Stricter than ``keyChord(for:)`` in
    /// the two ways a recorder is stricter than a dispatcher: the space bar is no key here, and a
    /// base the chord grammar cannot spell back is refused rather than stored.
    public static func captureOutcome(_ press: Press) -> KeybindingCaptureOutcome {
        withRecord(press) { record in
            var record = record
            var named: UInt8 = 0
            var character: UInt32 = 0
            var modifiers: UInt8 = 0
            let verdict = slopdesk_phone_key_capture(&record, &named, &character, &modifiers)
            switch verdict {
            case UInt8(SLOPDESK_PHONE_KEY_CAPTURE_CANCEL): return .cancel
            case UInt8(SLOPDESK_PHONE_KEY_CAPTURE_CLEAR): return .clear
            case UInt8(SLOPDESK_PHONE_KEY_CAPTURE_BIND):
                let mods = KeyChord.Modifiers(rawValue: Int(modifiers))
                if let key = KeyChord.Key(namedIndex: named) {
                    return .bind(KeyChord(key, mods).asPreferencesChord)
                }
                guard let scalar = UnicodeScalar(character) else { return .ignore }
                return .bind(KeyChord(character: Character(scalar), mods).asPreferencesChord)
            default: return .ignore
            }
        }
    }

    /// Splits a soft-keyboard text commit when the accessory bar's ⌃ is ARMED: the first scalar
    /// folds to its control byte, to be written RAW because a PTY never echoes one, and the rest
    /// stays text. `nil` when not armed or the text is empty — send it as it came.
    public static func foldArmedControl(_ text: String, armed: Bool) -> (controlByte: UInt8, rest: String)? {
        guard armed else { return nil }
        var text = text
        var code: UInt8 = 0
        var restOffset = 0
        let folded = text.withUTF8 { bytes in
            slopdesk_phone_key_fold_control(bytes.baseAddress, bytes.count, &code, &restOffset)
        }
        guard folded else { return nil }
        // The door reports a BYTE offset, and it always lands on a scalar boundary — the fold
        // consumed exactly one. Sliced by that index rather than by character count, so a
        // multi-byte first scalar leaves the right remainder.
        let restIndex = text.utf8.index(text.utf8.startIndex, offsetBy: restOffset)
        return (code, String(text[restIndex...]))
    }

    /// The keyboard-frame height at or above which the on-screen keyboard is the SOFTWARE one, and
    /// the ⌃/Esc/Tab/arrow row is worth its space. A hardware keyboard leaves only a thin shortcut
    /// bar, and its user already has those keys.
    public static var softwareKeyboardThreshold: Double { slopdesk_phone_accessory_threshold() }

    /// Whether to show the accessory row for a keyboard of `keyboardHeight` points. A hidden
    /// keyboard reports zero, which is below every positive threshold.
    public static func showsAccessoryBar(
        keyboardHeight: Double,
        threshold: Double? = nil,
    ) -> Bool {
        slopdesk_phone_shows_accessory_bar(keyboardHeight, threshold ?? softwareKeyboardThreshold)
    }

    /// Long enough for every press the tables resolve; a longer base makes the door report its size
    /// and the encoder ask again.
    private static let encodeCapacity = 16

    /// Lends the press to `body` as the flat record the doors take. The span is alive for exactly
    /// the call, which is the obligation every door's `# Safety` names.
    private static func withRecord<T>(_ press: Press, _ body: (SlopDeskPhoneKeyPress) -> T) -> T {
        var base = press.charactersIgnoringModifiers
        let usage = press.hidUsage
        let flags = press.ffiFlags
        return base.withUTF8 { baseBytes in
            body(SlopDeskPhoneKeyPress(
                base: baseBytes.baseAddress,
                base_len: baseBytes.count,
                hid_usage: usage,
                flags: flags,
            ))
        }
    }
}

/// The floating cursor: long-pressing the space bar and dragging, which on a phone with no hardware
/// keyboard is the ONLY way to move the terminal cursor.
///
/// iOS reports the drag as a stream of positions; each delta is worth whole thresholds of travel,
/// and the sub-threshold remainder is CARRIED, so a slow drag of many small deltas still totals
/// correctly. That remainder is the entire state, which is why it crosses as one number rather than
/// as a handle the caller would have to remember to free when a gesture is cut short.
public struct FloatingCursor: Sendable, Equatable {
    /// Travel (points) per arrow emitted.
    public let threshold: Double
    /// Accumulated, not-yet-spent horizontal travel, signed.
    public private(set) var accumulated: Double = 0

    public init(threshold: Double? = nil) {
        self.threshold = threshold ?? slopdesk_phone_floating_cursor_threshold()
    }

    /// Feeds a horizontal delta (points, positive is rightward) and returns the arrow bytes the
    /// whole thresholds it completed are worth — one buffer, for one write to the pane.
    ///
    /// `applicationCursorKeys` is the live DECCKM state: reset gives the CSI form every line editor
    /// reads as a cursor move, set gives the SS3 form vim, less and htop ask for.
    public mutating func feed(deltaX: Double, applicationCursorKeys: Bool = false) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Self.runCapacity)
        // The remainder is lent to the door through a LOCAL rather than through `self.accumulated`:
        // the buffer closure already holds an exclusive access, and a second one to a property of
        // the same value would overlap it.
        var carried = accumulated
        let written = out.withUnsafeMutableBufferPointer { buffer in
            slopdesk_phone_floating_cursor_feed(
                &carried, threshold, deltaX, applicationCursorKeys, buffer.baseAddress, buffer.count,
            )
        }
        accumulated = carried
        return Array(out.prefix(min(written, out.count)))
    }

    /// Clears the carried remainder — the drag ended.
    public mutating func reset() {
        accumulated = 0
    }

    /// Three bytes per arrow, for the longest run one delta may earn.
    private static let runCapacity = 256 * 3
}
