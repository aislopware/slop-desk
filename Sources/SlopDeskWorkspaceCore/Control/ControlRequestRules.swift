import CSlopDeskFFI

// MARK: - ControlRequestRules (validate-then-drop, and the words it refuses in)

/// The client control socket's request guards and its refusal vocabulary, as
/// `slopdesk-workspace::control_request` answers them.
///
/// Every line reaching ``ClientControlDispatcher`` was written by a process the app did not launch,
/// so the contract is the repo's untrusted-input one: validate before use, bound before allocate,
/// and answer `ok:false` rather than trap. The judgements are all here; what stays in Swift beside
/// them is the JSON — parsing a line into `(id, method, params)` and writing the response object —
/// and the METHOD `switch`, which dispatches against `ClientControlProtocol.Method` because that
/// vocabulary is pinned against `slopdesk-cli`'s end of the same socket.
///
/// The three bounds — the 64 KiB line cap, the default capture count and its ceiling — are spelled
/// on the far side alone. A constant repeated here would be the drift the doors exist to remove.
public enum ControlRequestRules {
    // MARK: The line guard

    /// The cap one request line is refused past, read from the door rather than typed.
    ///
    /// Both socket servers that keep this cap — the client's and the host's — read it from here, so
    /// the two ends of one socket cannot disagree about which line was too long.
    public static let maxRequestBytes = Int(slopdesk_ws_ctl_max_request_bytes())

    /// What one raw request line IS, before anything is parsed out of it.
    public enum LineVerdict: UInt8, Sendable, Equatable {
        /// Blank or whitespace-only. There is nothing to respond TO — which is not the same as an
        /// error response, and is why the socket answers no line at all.
        case blank = 0
        /// Past the size cap. Refused before it is parsed.
        case tooLarge = 1
        /// Worth parsing.
        case parse = 2
    }

    /// One scanned line: what to do with it, and the trimmed request it carries.
    public struct ScannedLine: Sendable, Equatable {
        /// What to do with the line.
        public let verdict: LineVerdict
        /// The trimmed request, empty for a blank line.
        public let request: String
    }

    /// What one raw request line is, and the request inside it.
    ///
    /// The trim happens once, on the far side, and comes back as a BYTE SPAN — nothing is allocated
    /// to slice at an offset, and a trim done on both sides of the boundary is a rule spelled twice.
    /// A trim boundary is a scalar boundary, so the span is always whole UTF-8.
    public static func scan(_ line: String) -> ScannedLine {
        let bytes = Array(line.utf8)
        var start = 0
        var end = 0
        let code = bytes.withUnsafeBufferPointer { buffer in
            slopdesk_ws_ctl_line_scan(buffer.baseAddress, buffer.count, &start, &end)
        }
        let verdict = LineVerdict(rawValue: code) ?? .parse
        guard start <= end, end <= bytes.count else {
            return ScannedLine(verdict: verdict, request: "")
        }
        return ScannedLine(
            verdict: verdict,
            // swiftlint:disable:next optional_data_string_conversion
            request: String(decoding: bytes[start..<end], as: UTF8.self),
        )
    }

    // MARK: The refusal vocabulary

    /// Every way the control socket says no. The five that name a token are the five a person reads
    /// to find their typo.
    public enum Refusal: UInt8, Sendable, Equatable {
        /// The line is past the size cap.
        case tooLarge = 1
        /// The line is not a JSON object with a string `id` and `method`.
        case malformed = 2
        /// A method this build does not dispatch. Names the method.
        case unknownMethod = 3
        /// `tab-badge` with no `kind`.
        case missingBadgeKind = 4
        /// `tab-badge` with a `kind` no badge answers to. Names the token.
        case invalidBadgeKind = 5
        /// `tab-badge` naming a tab that is not there.
        case tabNotFound = 6
        /// `jump` resolved to nothing.
        case noJumpTarget = 7
        /// `learn` with no path and no focused pane to take one from.
        case nothingToLearn = 8
        /// `ignore` with no `path`, or an empty one.
        case missingPath = 9
        /// `ignore` on a path the frecency store would not drop.
        case couldNotIgnore = 10
        /// `view` / `edit` with no `target`, or an empty one.
        case missingTarget = 11
        /// `view` / `edit` with a `placement` no surface answers to. Names the token.
        case invalidPlacement = 12
        /// `view` / `edit` on a target that would not open.
        case couldNotOpen = 13
        /// `font-list` with a `scope` no font surface answers to. Names the token.
        case invalidScope = 14
        /// `pane-capture` with a `lines` that is not a positive integer.
        case captureLines = 15
        /// A pane verb naming a pane that is not there.
        case paneNotFound = 16
        /// `pane-send-keys` with a `keys` that is not an array.
        case keysNotAnArray = 17
        /// `pane-send-keys` with neither text nor a named key to send.
        case nothingToSend = 18
        /// `pane-send-keys` naming a key the table does not carry. Names the key.
        case unknownKey = 19
        /// `agent-status` with no `id`, or an empty one.
        case missingID = 20
    }

    /// The sentence a refusal answers with, with `detail` filled in where one is named.
    ///
    /// A detail handed to a refusal that names none is IGNORED rather than appended, so a call site
    /// that always passes what it read stays a one-liner and no message grows a stray token.
    public static func message(_ refusal: Refusal, detail: String = "") -> String {
        let named = Array(detail.utf8)
        // Every sentence is a fixed prefix plus at most the caller's own token, so the first buffer
        // is the arithmetic bound rather than a guess and the size-then-retry below is a formality.
        var out = [UInt8](repeating: 0, count: named.count + 96)
        var needed = write(refusal, named, into: &out)
        if needed > out.count {
            out = [UInt8](repeating: 0, count: needed)
            needed = write(refusal, named, into: &out)
        }
        guard needed > 0, needed <= out.count else { return "" }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: out.prefix(needed), as: UTF8.self)
    }

    /// One attempt at the sentence: the bytes NEEDED, written only when they fit.
    private static func write(_ refusal: Refusal, _ detail: [UInt8], into out: inout [UInt8]) -> Int {
        detail.withUnsafeBufferPointer { named in
            out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_ws_ctl_refusal_message(
                    refusal.rawValue,
                    named.baseAddress,
                    named.count,
                    buffer.baseAddress,
                    buffer.count,
                )
            }
        }
    }

    // MARK: The two bounded payloads

    /// How many scrollback lines a `pane-capture` request asks for, or `nil` for
    /// ``Refusal/captureLines``.
    ///
    /// `present` is whether the request carried a `lines` field at all and `isInteger` whether it was
    /// one — a field carrying `"12"` is a refusal rather than a coercion, because a control socket
    /// that guesses at types is one that reads `true` as 1. An absent count answers the default; a
    /// present one is clamped to the ceiling rather than refused.
    public static func captureLines(present: Bool, isInteger: Bool, raw: Int) -> Int? {
        let answer = slopdesk_ws_ctl_capture_lines(present, isInteger, Int64(raw))
        return answer < 0 ? nil : Int(answer)
    }

    /// Why a `pane-send-keys` request cannot be served, or `nil` when it can.
    ///
    /// `hasKeys` is whether any key SURVIVED the read: non-string elements are dropped on the way in,
    /// so an array of numbers arrives as an array with nothing in it — and an otherwise empty request
    /// carrying one is ``Refusal/nothingToSend``, which is what it is.
    public static func sendKeysRefusal(
        keysPresent: Bool,
        keysIsArray: Bool,
        hasText: Bool,
        hasKeys: Bool,
    ) -> Refusal? {
        let code = slopdesk_ws_ctl_send_keys_refusal(SlopDeskWsSendKeys(
            keys_present: keysPresent,
            keys_is_array: keysIsArray,
            has_text: hasText,
            has_keys: hasKeys,
        ))
        return Refusal(rawValue: code)
    }
}
