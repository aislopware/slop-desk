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
// a press in, and the marshalling. Nothing about BYTES decides anything: which keys are special at
// all, the C0 fold, the cursor block's introducer, the meta prefix, which presses are chords and
// what a floating-cursor drag is worth all live on the other side of the door, tested there.
//
// The ONE rule spelled on this side is `paneSwitcherKey(_:isOpen:)`, and it is here because it is
// not about bytes: it reads the WORKSPACE's live gesture, whose state is a Swift store's, and it
// invents no key identity — ⇥ comes back from `keyChord(for:)` and Esc/Return/←→ from
// `modalKey(_:)`, both of which are the Rust tables coming through. A door of its own would have to
// carry the store's flag across the boundary and back for a two-line composition of two doors that
// already exist.
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

        /// The flag word the doors read — `KeyChord.Modifiers`' own bits 0-3, plus the one thing that
        /// is not a modifier at all in bits 4-5: what ⌥ MEANS on this keyboard.
        ///
        /// `controls.optionAsAlt` is read LIVE off `Defaults` here, per press, exactly the way the
        /// libghostty surface reads `undoAtPrompt` in its `keyDown` — so a Settings change takes
        /// effect on the very next keystroke rather than on the next pane. What the value MEANS is
        /// the door's (`slopdesk_workspace::phone_key::OptionAsAlt`), including why a phone reads a
        /// LEFT/RIGHT choice the same as BOTH: a `UIKey` carries one `.alternate` bit and no side.
        var ffiFlags: UInt32 {
            var flags: UInt32 = 0
            if shift { flags |= UInt32(SLOPDESK_PHONE_KEY_SHIFT) }
            if control { flags |= UInt32(SLOPDESK_PHONE_KEY_CONTROL) }
            if option { flags |= UInt32(SLOPDESK_PHONE_KEY_OPTION) }
            if command { flags |= UInt32(SLOPDESK_PHONE_KEY_COMMAND) }
            return flags | Self.optionAsAltFlag(SettingsKey.optionAsAlt)
        }

        /// The bit-pair one ``OptionAsAlt`` crosses as. A `switch` rather than the raw value's index
        /// because the two vocabularies are independent: the raw values are slopdesk's persistence
        /// tokens and the pair is the door's ABI, whose zero has to stay BOTH.
        private static func optionAsAltFlag(_ mode: OptionAsAlt) -> UInt32 {
            switch mode {
            case .off: UInt32(SLOPDESK_PHONE_KEY_OPTION_AS_ALT_OFF)
            case .both: UInt32(SLOPDESK_PHONE_KEY_OPTION_AS_ALT_BOTH)
            case .left: UInt32(SLOPDESK_PHONE_KEY_OPTION_AS_ALT_LEFT)
            case .right: UInt32(SLOPDESK_PHONE_KEY_OPTION_AS_ALT_RIGHT)
            }
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

    /// A key a MODE reads as a command rather than as input.
    ///
    /// Copy Mode and Hint Mode are the two places a press is not typing: while either is armed the
    /// pane ANSWERS keys instead of forwarding them. These six are every press whose meaning is its
    /// KEY rather than its character; anything else — a letter, a digit, and equally a special key
    /// no mode binds — reaches the mode as its character, which is why there is no case for it.
    ///
    /// The rows are `slopdesk_workspace::phone_key::ModalKey`, projected off the SAME usage table
    /// the encoder resolves. Nothing here decides; this is the case index coming back.
    public enum ModalKey: Sendable, Equatable {
        /// Esc — peel one modal layer.
        case escape
        /// Return, and the keypad's Enter with it — confirm.
        case enter
        /// Backspace — undo the last typed label letter.
        case backspace
        case up
        case down
        case left
        case right
    }

    /// The modal key this press is, or `nil` for one a mode reads as its character.
    ///
    /// Keyed off the USAGE alone. The modifiers are deliberately not consulted: `⌃v` in copy mode is
    /// the visual-block key and `⌃d` is the half-page, so a mode takes the modifier state off the
    /// press itself and asks this only "which key is it".
    public static func modalKey(_ press: Press) -> ModalKey? {
        switch slopdesk_phone_modal_key(press.hidUsage) {
        case UInt8(SLOPDESK_PHONE_MODAL_ESCAPE): .escape
        case UInt8(SLOPDESK_PHONE_MODAL_ENTER): .enter
        case UInt8(SLOPDESK_PHONE_MODAL_BACKSPACE): .backspace
        case UInt8(SLOPDESK_PHONE_MODAL_UP): .up
        case UInt8(SLOPDESK_PHONE_MODAL_DOWN): .down
        case UInt8(SLOPDESK_PHONE_MODAL_LEFT): .left
        case UInt8(SLOPDESK_PHONE_MODAL_RIGHT): .right
        default: nil
        }
    }

    /// One of the pane switcher's three verbs, as a press asks for it.
    ///
    /// Three, not four: OPEN and STEP are one case because they are one store call
    /// (``WorkspaceStore/openOrStepPaneSwitcher(forward:armedByModifier:)``), which is where the
    /// difference between them lives — a walk that is already up steps, and only a closed one
    /// opens. Splitting them here would be this side holding an opinion the store already holds.
    public enum PaneSwitcherKey: Sendable, Equatable {
        /// Open the walk, or step an open one. `forward` is the ⇧-selected direction.
        case openOrStep(forward: Bool)
        /// Commit the highlighted pane and close the walk.
        case commit
        /// Abandon the walk, leaving the active pane where it was.
        case cancel
    }

    /// What one press means to the ⌃⇥ PANE SWITCHER — the walk over recently-visited panes.
    ///
    /// The Mac's twin is `WorkspaceKeyDispatcher.consumePaneSwitcher`, and this answers the same
    /// four questions off a ``Press`` rather than off an `NSEvent`. Like that one it must be asked
    /// BEFORE the binding table and before the encoder, for the reason it documents: the gesture is
    /// not expressible as a table row — one key means open, step or commit depending on whether the
    /// walk is already up — and its cancel key resolves to no chord at all, precisely so a bare Esc
    /// always reaches the TUI. Asked after the encoder instead, ⌃⇥ types `0x09` into the shell and
    /// Esc and Return reach the PTY through an overlay that is drawn over them.
    ///
    /// THE BOUNDARY THIS FUNCTION DEFENDS, which is the Mac's word for word: a bare ⇥ is shell
    /// completion and ⇧⇥ is how Claude Code cycles permission modes. Neither carries ⌃, and with the
    /// walk closed neither is claimed here — both fall straight through to the PTY. Only ⌃⇥ opens
    /// the gesture; only while it is open do Esc / Return / arrows / a bare ⇥ mean anything to us.
    ///
    /// COMPOSED OUT OF THE TWO DOORS THAT ALREADY EXIST rather than out of a third HID table: ⇥ is
    /// the named chord ``keyChord(for:)`` builds, and Esc, Return and ←→ are ``modalKey(_:)``'s.
    /// Nothing here names a usage, which is what keeps the HID page single.
    ///
    /// `isOpen` is the store's `paneSwitcher != nil`, THREADED rather than remembered — the walk can
    /// end between two presses (a tap on the card commits it), and a remembered copy would answer
    /// for a gesture that is over.
    public static func paneSwitcherKey(_ press: Press, isOpen: Bool) -> PaneSwitcherKey? {
        if let chord = keyChord(for: press), chord.key == .tab {
            // Ours only when ⌃ is held (the gesture) or the walk is already up (a palette-opened one
            // has no held modifier). Otherwise this is the terminal's Tab and must not be touched.
            guard press.control || isOpen else { return nil }
            // `unbind: ctrl+tab` gives the GESTURE back — the escape hatch a Neovim user needs once
            // the Kitty protocol delivers ⌃⇥ to the PTY as `CSI 9 ; 5 u`. The SAME override map the
            // Mac's dispatcher consults, so the unbind is made once and honoured on both. It gates
            // OPENING only, and reclaims each chord INDIVIDUALLY — unbinding ⌃⇥ is no statement
            // about ⌃⇧⇥ — because an open walk owns ⇥ regardless, or an unbind would strand a card
            // with no way to step it.
            if !isOpen, WorkspaceBindingRegistry.isUnbound(chord) { return nil }
            // ⇧ picks the direction: ⌃⇥ walks toward less-recent, ⌃⇧⇥ walks back. iOS reports Tab's
            // usage with and without ⇧ (`UIKey.modifierFlags` carries it), so the flag on the press
            // is the whole signal — there is no distinct back-tab press to wait for.
            return .openOrStep(forward: !press.shift)
        }
        // Everything below belongs to the terminal until the walk is up. Then, and only then, the
        // card's four keys are the card's.
        guard isOpen else { return nil }
        // Keyed by USAGE alone, modifiers included, exactly as the Mac keys these four by `keyCode`
        // alone: a stray ⌥ held over Escape is still the reader abandoning the walk.
        return switch modalKey(press) {
        case .escape: .cancel
        case .enter: .commit
        case .left: .openOrStep(forward: false)
        case .right: .openOrStep(forward: true)
        default: nil
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
        // The capacity is the door's, not a product of the arrow cap and the escape width spelled
        // here — the same number in two languages is the one this boundary exists to remove.
        var out = [UInt8](repeating: 0, count: slopdesk_phone_floating_cursor_run_capacity())
        // The remainder is lent to the door through a LOCAL rather than through `self.accumulated`:
        // the buffer closure already holds an exclusive access, and a second one to a property of
        // the same value would overlap it.
        let start = accumulated
        var carried = start
        var written = out.withUnsafeMutableBufferPointer { buffer in
            slopdesk_phone_floating_cursor_feed(
                &carried, threshold, deltaX, applicationCursorKeys, buffer.baseAddress, buffer.count,
            )
        }
        // A run longer than the advertised capacity: the door reported the size and wrote NOTHING,
        // so taking a prefix here would send that many NUL bytes to the PTY. Ask again with the
        // size it named, resuming from the remainder the FIRST call started at — the door consumes
        // `deltaX` on every call, so retrying from the answer would spend the delta twice.
        if written > out.count {
            out = [UInt8](repeating: 0, count: written)
            carried = start
            written = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_phone_floating_cursor_feed(
                    &carried, threshold, deltaX, applicationCursorKeys, buffer.baseAddress, buffer.count,
                )
            }
        }
        accumulated = carried
        guard written > 0, written <= out.count else { return [] }
        return Array(out.prefix(written))
    }

    /// Clears the carried remainder — the drag ended.
    public mutating func reset() {
        accumulated = 0
    }
}

// MARK: - Spending a switcher key on the workspace

/// The other half of ``PhoneKey/paneSwitcherKey(_:isOpen:)``: turning its answer into the store's own
/// verbs.
///
/// Here rather than in `WorkspaceStore+PaneSwitcher.swift` because it is the phone key path, not the
/// gesture — it holds no opinion the switcher does not already hold, and every line of it is about a
/// `PhoneKey.Press`. Here rather than in the responder because a responder the iOS triple compiles is a
/// responder the macOS runner cannot drive, and that is precisely the blind spot this whole file is
/// un-gated to close: the defect it fixes shipped green for exactly that reason.
public extension WorkspaceStore {
    /// Offers one phone press to the ⌃⇥ walk, answering whether the walk took it.
    ///
    /// `false` means the press is the terminal's and must go on down the responder's own path — the
    /// press was not one of the walk's keys, or it was a ⌃⇥ the walk REFUSED (one pane leaves nothing to
    /// switch to, and swallowing the chord into a gesture that cannot happen would make ⌃⇥ dead rather
    /// than harmless).
    @discardableResult
    func takePaneSwitcherKey(_ press: PhoneKey.Press) -> Bool {
        guard let key = PhoneKey.paneSwitcherKey(press, isOpen: paneSwitcher != nil) else {
            return false
        }
        switch key {
        case let .openOrStep(forward):
            // `armedByModifier: false`, always. UIKit delivers no press for a bare modifier, so the ⌃
            // key-up that COMMITS the Mac's gesture never arrives on a phone — arming would leave the
            // walk waiting on a release that cannot come. This opens the same UNARMED switcher the
            // palette row opens, whose endings are Return, Esc and a tap on the card.
            openOrStepPaneSwitcher(forward: forward, armedByModifier: false)
            return paneSwitcher != nil
        case .commit:
            commitPaneSwitcher()
        case .cancel:
            cancelPaneSwitcher()
        }
        return true
    }
}
