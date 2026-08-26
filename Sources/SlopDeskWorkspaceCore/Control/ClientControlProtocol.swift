import CSlopDeskFFI
import SlopDeskWorkspaceModel

// MARK: - ClientControlProtocol (the socket's words, as `slopdesk_clientctl` spells them)

// The method names and the three token vocabularies of the CLIENT-side control socket — the
// runtime-control surface `slopdesk` drives the running GUI over (windows/tabs/panes, badges,
// jump/view/edit, font/keybind dumps, pane capture/send-keys, agent status).
//
// This file used to be the OTHER SPELLING of the CLI's own control module: fourteen method
// literals, a badge map, two raw-valued enums, a line codec and one `*Params` builder per verb,
// held against the CLI's copy by a `slopdesk-invariants` rule comparing regexes because no compiler
// crossed the boundary. The two ends ship on different clocks — the app from a `.app`, the CLI from
// `brew upgrade` — so a rename passed both suites green and then met last morning's peer.
//
// The vocabulary is `slopdesk-clientctl` now, linked by BOTH ends: the CLI takes it as a crate and
// this face reads it through `slopdesk_ws_ctl_*`. What went with it is everything that had no Swift
// caller at all — the request builders and the NDJSON codec, which only the CLI ever ran.
//
// There is no config verb here. Settings are the config FILE's, read by every process that wants
// them; a socket that wrote one would be a second authoring surface for a value the user is
// supposed to see in their own file.

/// The client control socket's vocabulary. A caseless namespace, so the dispatcher and the backend
/// name one source for the method strings and the token parsers.
public enum ClientControlProtocol {
    // MARK: - Method names

    /// The wire method strings, as `slopdesk_ws_ctl_methods` delivers them.
    ///
    /// Read ONCE into these `static let`s, in the crate's declaration order — the order IS the
    /// contract, the same way `TabBadge::ALL`'s is. A door that answers a shorter table than this
    /// build expects leaves the tail empty, which makes the affected verb undispatchable rather
    /// than dispatchable as its neighbour.
    public enum Method {
        /// Every recognised method, in the order the crate declares them.
        public static let all: [String] = {
            var out = [UInt8](repeating: 0, count: 256)
            var needed = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_ws_ctl_methods(buffer.baseAddress, buffer.count)
            }
            if needed > out.count {
                out = [UInt8](repeating: 0, count: needed)
                needed = out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_ws_ctl_methods(buffer.baseAddress, buffer.count)
                }
            }
            guard needed > 0, needed <= out.count else { return [] }
            var blob = DeviceControlBlob(Array(out.prefix(needed)))
            return (0..<blob.count16()).map { _ in blob.text() }
        }()

        /// The method at `slot`, or `""` when this build's door answered a shorter table.
        private static func at(_ slot: Int) -> String { slot < all.count ? all[slot] : "" }

        /// List all windows.
        public static let windows = at(0)
        /// List tabs (optionally scoped to a window).
        public static let tabs = at(1)
        /// List panes (optionally scoped to a tab).
        public static let panes = at(2)
        /// Set a tab status badge.
        public static let tabBadge = at(3)
        /// Resolve a frecency-ranked jump target and `cd` the focused pane (or just print it).
        public static let jump = at(4)
        /// Record a directory visit in the frecency database (no path → the focused pane's cwd).
        public static let learn = at(5)
        /// Remove a directory from the frecency database.
        public static let ignore = at(6)
        /// Open a read-only `view` shim (`less <path>` / `open <url>`) in a new split/tab/window.
        public static let view = at(7)
        /// Open an editable `edit` shim (`$EDITOR <path>`) in a new split/tab/window.
        public static let edit = at(8)
        /// Enumerate fonts.
        public static let fontList = at(9)
        /// Enumerate keybindings (optionally filtered by action substring).
        public static let keybindList = at(10)
        /// Capture the last N lines of a pane's scrollback.
        public static let paneCapture = at(11)
        /// Send literal text + named keys to a pane (VERBATIM; named keys via the keycode path).
        public static let paneSendKeys = at(12)
        /// Poll an agent session's rolled-up status (for `watch:claude`).
        public static let agentStatus = at(13)
    }

    // MARK: - Tab-badge tokens

    /// The ``TabBadgeKind`` a settable `tab badge --kind <token>` names, or `nil`.
    ///
    /// Validate-then-drop: an unknown token AND a listable-only one — `caffeinate`, `sudo` and the
    /// two command tiers, which a foreground process derives and no request may claim — both answer
    /// `nil`, which the dispatcher turns into an error response rather than a trap.
    public static func tabBadgeKind(forToken token: String) -> TabBadgeKind? {
        let index = controlLend(token) { bytes, len in
            slopdesk_ws_ctl_badge_for_token(bytes, len)
        }
        return TabBadgeKind(ffiByte: index)
    }

    /// The canonical token for a resolved ``TabBadgeKind`` — what LISTING a tab's badge prints.
    ///
    /// Total over the ladder, which is why the door is total: `unread ↦ finished` is many-to-one, so
    /// the reverse of ``TabBadgeKind/finished`` is the canonical `finished`.
    public static func badgeToken(for kind: TabBadgeKind) -> String {
        var out = [UInt8](repeating: 0, count: 32)
        let needed = out.withUnsafeMutableBufferPointer { buffer in
            slopdesk_ws_ctl_badge_token(kind.ffiByte, buffer.baseAddress, buffer.count)
        }
        guard needed > 0, needed <= out.count else { return "" }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: out.prefix(needed), as: UTF8.self)
    }

    // MARK: - Placement tokens (view/edit)

    /// Where a `view`/`edit` shim opens. The raw value is the token's POSITION in the crate's
    /// vocabulary, not its spelling — the token is parsed once, on the far side, and only the index
    /// crosses. `newTab` is 0 because it is the default.
    public enum Placement: UInt8, Sendable, Equatable, CaseIterable {
        case newTab = 0
        case newWindow = 1
        case left = 2
        case right = 3
        case top = 4
        case bottom = 5
    }

    /// Parse a placement token; `nil` for one the vocabulary does not carry (validate-then-drop).
    public static func placement(forToken token: String) -> Placement? {
        let index = controlLend(token) { bytes, len in
            slopdesk_ws_ctl_placement_for_token(bytes, len)
        }
        return index < 0 ? nil : Placement(rawValue: UInt8(index))
    }

    // MARK: - Font scope token

    /// `font list --system`/`--user` scope, by position in the crate's vocabulary.
    public enum FontScope: UInt8, Sendable, Equatable, CaseIterable {
        case system = 0
        case user = 1
    }

    /// Parse a font-scope token; `nil` for one the vocabulary does not carry.
    public static func fontScope(forToken token: String) -> FontScope? {
        let index = controlLend(token) { bytes, len in
            slopdesk_ws_ctl_font_scope_for_token(bytes, len)
        }
        return index < 0 ? nil : FontScope(rawValue: UInt8(index))
    }
}

// MARK: - Lending

/// Lends one token's UTF-8 to a door for the length of the call, and nothing longer.
///
/// The scope of `withUnsafeBufferPointer` is exactly the call, which is what discharges every
/// `slopdesk_ws_ctl_*_for_token` safety obligation. An empty token still lends a valid pair.
private func controlLend<T>(_ token: String, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
    let bytes = Array(token.utf8)
    return bytes.withUnsafeBufferPointer { buffer in body(buffer.baseAddress, buffer.count) }
}

// MARK: - Reading one delivery

/// A cursor over a `[u16 count]` + `[u32 length][UTF-8]` delivery.
///
/// The same framing `DevicePanelBlob` walks one target down; this is the reader for the targets that
/// cannot see it. Every read is bounds-checked and a short blob simply runs out of words, because a
/// delivery is bytes a door produced and the face's job is to refuse rather than trap.
private struct DeviceControlBlob {
    private let bytes: [UInt8]
    private var cursor = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// The next byte, or 0 past the end.
    private mutating func byte() -> UInt8 {
        guard cursor < bytes.count else { return 0 }
        defer { cursor += 1 }
        return bytes[cursor]
    }

    /// The next big-endian `u16` as a count.
    mutating func count16() -> Int {
        let high = Int(byte())
        return high << 8 | Int(byte())
    }

    /// The next `[u32 length][UTF-8]` field, or `""` when the blob is short of it.
    mutating func text() -> String {
        var length = 0
        for _ in 0..<4 { length = length << 8 | Int(byte()) }
        guard length > 0, cursor + length <= bytes.count else {
            cursor = Swift.min(cursor + length, bytes.count)
            return ""
        }
        defer { cursor += length }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes[cursor..<(cursor + length)], as: UTF8.self)
    }
}
