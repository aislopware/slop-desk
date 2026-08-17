import CSlopDeskFFI
import Foundation

/// hostd's END of the screend wire — the vocabulary, and the marshalling to the one encoder.
///
/// Every LAYOUT is `rust/slopdesk-screenwire`, linked in, and both ends of the protocol live there:
/// screend decodes what this encodes, so the round trip is a TEST rather than two files agreeing by
/// review. That was already the recorded decision (`docs/DECISIONS.md`, stage 17) — but only dropd's
/// Swift original was deleted when its client end moved. This file kept hand-writing the frame, and
/// the two copies had already diverged on an over-long detect label.
///
/// What stays here is the VOCABULARY — verb numbers, status numbers, flag bits, the banner — which
/// `check-supervisor.sh` pins across the two languages the way it pins the other five daemons'.
///
/// ```text
/// request  u32 len | u8 verb | u8 flags | u16 rows | u16 cols | u16 paneLen | pane… | raw…
/// reply    u32 len | u8 status | payload…
/// ```
/// `len` counts everything after itself. Big-endian, like every other length on the wire here.
public enum ScreenVerb: UInt8, Sendable {
    /// Liveness + version banner. Costs nothing and proves the peer is a screend rather than
    /// whatever else happens to be bound at that path.
    case hello = 0
    /// Stateless: parse `raw` into a fresh grid and answer the snapshot.
    case snapshot = 1
    /// Stateful: append `raw` to the pane's resident model and answer the snapshot.
    case feed = 2
    /// Drop the pane's resident model.
    case forget = 3
    /// Stateless: parse `raw` and render the minimal stream that reproduces the screen.
    /// ``ScreenWire/flagReassertInputModes`` appends the stream's net input-mode state after it.
    case compose = 4
    /// Stateless: parse `raw` and render it as a plain transcript.
    case transcript = 5
    /// The line-overprint churn pass. Geometry-free.
    case collapse = 6
    // 7 is RETIRED and stays unallocated. It was `sanitize`, the whole replay transform in one
    // round trip — and the round trip was the mistake: it is a pure function, so it is
    // `rust/slopdesk-sanitize` linked in now (``ReplayBuffer/sanitize(_:distill:reassertInputModes:)``)
    // rather than a verb. A future verb takes 10.
    /// The zsh `PROMPT_SP` pass alone, for the caller holding one captured command block rather
    /// than a replay stream. Geometry-free.
    case promptEolMarks = 8
    /// Stateful, and the one verb that answers a QUESTION rather than a screen: fold `raw` into
    /// the pane's grid, OSC tracker and synchronized-frame parser, then run the named agent's rule
    /// ladder over the result and answer the verdict.
    ///
    /// The payload is verb-local — `u16 agentLen | agent… | bytes…` — because the agent label is
    /// this verb's alone and the request header is shared by nine.
    ///
    /// An EMPTY label folds the bytes and skips the ladder, which is how a pane with no agent, a
    /// TUI still inside its startup grace and a quiescent idle pane all keep their grid warm for
    /// nothing (``ScreenDetection/state`` is then `unknown`, and the frame fields still answer).
    case detect = 9
}

/// The reply's first byte.
public enum ScreenStatus: UInt8, Sendable {
    case ok = 0
    /// The request was malformed or its geometry impossible — the payload is the reason, in UTF-8.
    case badRequest = 1
    /// screend failed internally; the payload is the reason.
    case internalError = 2
}

public enum ScreenWire {
    /// Rebuild the pane's model from scratch before feeding (a resize, an overflow, a first scan).
    public static let flagReset: UInt8 = 0x01

    /// ``ScreenVerb/compose``: append the stream's NET input-mode state,
    /// so a session still inside a TUI keeps that TUI's modes across a cold reattach.
    public static let flagReassertInputModes: UInt8 = 0x02

    /// ``ScreenVerb/detect``: these bytes are a scrollback REPLAY, not live output, so the
    /// synchronized-frame parser restarts with them. Its position is a position in a STREAM, and a
    /// rebuild hands over a different stream; without this a half-read `CSI ? 2026` from before the
    /// rebuild would swallow the `[` that opens the first real sequence after it.
    ///
    /// Distinct from ``flagReset``, which rebuilds the GRID: a resize resets the grid and must not
    /// reset the parser, because the stream did not restart.
    public static let flagRebuildReplay: UInt8 = 0x08

    /// ``ScreenVerb/detect``: a different program is in the foreground, so drop the retained OSC
    /// title and progress BEFORE folding these bytes (herdr `clear_retained`) — otherwise the new
    /// agent inherits the old one's evidence. In-flight parse state is deliberately kept: a
    /// sequence spanning the change finalises normally, attributed to the new agent.
    public static let flagAgentChanged: UInt8 = 0x10

    /// What screend answers `hello` with. Pinned here so a version bump has to be a deliberate edit
    /// on both ends rather than a silent mismatch.
    public static let helloBanner = "slopdesk-screend 1"

    /// Refuses to frame more than screend will read (64 MiB) — a caller handing over a ring bigger
    /// than that gets an error here instead of a connection screend kills mid-stream.
    public static let maximumFrameBytes = 64 * 1024 * 1024

    public enum WireError: Error, Sendable {
        case frameTooLarge(bytes: Int)
        case truncatedReply
        case unknownStatus(UInt8)
        case rejected(status: ScreenStatus, message: String)
    }

    /// One framed request. `0` back from the door is a REFUSAL — an unserved verb, a pane id that
    /// is not UTF-8, or a body over ``maximumFrameBytes`` — which a real frame's length can never
    /// be, so it reads unambiguously as the error the caller used to compute here.
    public static func encodeRequest(
        verb: ScreenVerb,
        flags: UInt8 = 0,
        rows: Int = 0,
        cols: Int = 0,
        pane: String = "",
        raw: Data = Data(),
    ) throws -> Data {
        let paneBytes = Array(pane.utf8)
        let rawBytes = [UInt8](raw)
        let frame = paneBytes.withUnsafeBufferPointer { paneIn -> [UInt8]? in
            rawBytes.withUnsafeBufferPointer { rawIn -> [UInt8]? in
                let ask = { (out: UnsafeMutableBufferPointer<UInt8>?) -> Int in
                    slopdesk_screen_encode_request(
                        verb.rawValue, flags, UInt32(clamping: rows), UInt32(clamping: cols),
                        paneIn.baseAddress, paneIn.count, rawIn.baseAddress, rawIn.count,
                        out?.baseAddress, out?.count ?? 0,
                    )
                }
                let needed = ask(nil)
                guard needed > 0 else { return nil }
                var room = [UInt8](repeating: 0, count: needed)
                let written = room.withUnsafeMutableBufferPointer { ask($0) }
                return written == needed ? room : nil
            }
        }
        guard let frame else {
            throw WireError.frameTooLarge(bytes: 8 + paneBytes.count + rawBytes.count)
        }
        return Data(frame)
    }

    /// ``ScreenVerb/detect``'s verb-local payload: `u16 agentLen | agent… | bytes…`.
    ///
    /// The label is length-prefixed rather than delimited because a manifest label is a foreign
    /// string in the general case, and a delimiter is a rule about its contents. A label longer than
    /// the prefix can hold is TRUNCATED rather than refused — the one behaviour that changed when
    /// the two copies became one, and the surviving reading is argued where it now lives: a
    /// truncation is a wrong answer where a throw is no answer at all, and no manifest label is
    /// within three orders of magnitude of 64 KiB.
    public static func encodeDetectPayload(agent: String, raw: Data) throws -> Data {
        let agentBytes = Array(agent.utf8)
        let rawBytes = [UInt8](raw)
        let payload = agentBytes.withUnsafeBufferPointer { agentIn -> [UInt8]? in
            rawBytes.withUnsafeBufferPointer { rawIn -> [UInt8]? in
                let ask = { (out: UnsafeMutableBufferPointer<UInt8>?) -> Int in
                    slopdesk_screen_encode_detect_payload(
                        agentIn.baseAddress, agentIn.count, rawIn.baseAddress, rawIn.count,
                        out?.baseAddress, out?.count ?? 0,
                    )
                }
                let needed = ask(nil)
                guard needed > 0 else { return nil }
                var room = [UInt8](repeating: 0, count: needed)
                let written = room.withUnsafeMutableBufferPointer { ask($0) }
                return written == needed ? room : nil
            }
        }
        guard let payload else { throw WireError.frameTooLarge(bytes: agentBytes.count) }
        return Data(payload)
    }

    /// Splits a reply body into its status and payload. The caller has already read `len` bytes.
    ///
    /// The status reading is the door's: an unknown byte is NOT degraded to `ok`, because a status
    /// is the answer to "did my request succeed" and guessing hands the caller a payload it has no
    /// reason to trust.
    public static func decodeReply(_ body: Data) throws -> (status: ScreenStatus, payload: Data) {
        let bytes = [UInt8](body)
        let verdict = bytes.withUnsafeBufferPointer { input in
            slopdesk_screen_reply_status(input.baseAddress, input.count)
        }
        switch verdict {
        case 0,
             1,
             2:
            guard let status = ScreenStatus(rawValue: UInt8(verdict)) else {
                throw WireError.unknownStatus(UInt8(verdict))
            }
            return (status, body.dropFirst().withUnsafeBytes { Data($0) })
        case -1:
            throw WireError.truncatedReply
        default:
            throw WireError.unknownStatus(bytes.first ?? 0)
        }
    }
}

/// One rendered grid, as screend serialises it (`camelCase`, by `serde` rename).
///
/// The DERIVED text — `detectionText`, the trimmed `text` the `screen` verb answers — is computed
/// from `lines` at the point of use rather than carried on the wire: it is a `join`, not a fact
/// about the terminal, and putting it in the payload would be a second place for it to be wrong.
public struct ScreenSnapshot: Decodable, Sendable, Equatable {
    public var rows: Int
    public var cols: Int
    public var cursorRow: Int
    public var cursorCol: Int
    public var cursorVisible: Bool
    public var altScreen: Bool
    public var lines: [String]

    public init(
        rows: Int,
        cols: Int,
        cursorRow: Int,
        cursorCol: Int,
        cursorVisible: Bool,
        altScreen: Bool,
        lines: [String],
    ) {
        self.rows = rows
        self.cols = cols
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.cursorVisible = cursorVisible
        self.altScreen = altScreen
        self.lines = lines
    }

    /// herdr's `detection_text`, exact: every visible row, trailing blank rows dropped, `\n`-joined
    /// with one trailing `\n` — or `""` for an all-blank screen.
    public var detectionText: String {
        let trimmed = linesWithoutTrailingBlanks
        guard !trimmed.isEmpty else { return "" }
        return trimmed.joined(separator: "\n") + "\n"
    }

    /// `lines` with the trailing empty rows dropped.
    public var linesWithoutTrailingBlanks: [String] {
        var trimmed = lines
        while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }
        return trimmed
    }
}

/// What ``ScreenVerb/detect`` answers: one agent-state verdict plus the two facts about the
/// synchronized-frame parser its caller needs.
///
/// This is the WIRE end — `state` is the raw label, decoded into the domain enum where the state
/// machine lives, because that module is linked by the client app and must not learn to talk to a
/// daemon. The screen tier's TEMPORAL layer (the startup grace, the working→idle hold, the cap on
/// how long an open frame may suppress a report) is not here either, and deliberately: screend owns
/// everything that reads the BYTES, hostd owns everything that reads the CLOCK. So `frameOpen` and
/// `frameGeneration` are reported as FACTS and the deadline is drawn on the other side of the
/// socket, where the scan timer is.
public struct ScreenDetection: Decodable, Sendable, Equatable {
    /// `idle` / `working` / `blocked` / `unknown`, as the manifest engine names them.
    public var state: String
    /// A freeze rule matched (a transcript viewer, a model picker): the caller holds its previous
    /// status rather than publishing this one.
    public var skipStateUpdate: Bool
    /// The screen LITERALLY shows a live prompt box / blocker form / spinner. Gates the temporal
    /// layer: a visible idle bypasses the working→idle hold, a visible blocker gets the re-publish
    /// heartbeat.
    public var visibleIdle: Bool
    public var visibleBlocker: Bool
    public var visibleWorking: Bool
    /// The winning rule's id, or `nil` on a fallback path.
    public var matchedRuleId: String?
    /// herdr's `fallback_reason` constant when no rule matched a known agent.
    public var fallbackReason: String?
    /// TRUE when the bytes folded so far end INSIDE an open synchronized update (DEC mode 2026) —
    /// the grid is then half a repaint, and a rule ladder reading it sees a dialog with its footer
    /// momentarily missing.
    public var frameOpen: Bool
    /// Bumped every time a frame OPENS. Two scans that both see a frame open are looking at the
    /// SAME frame only if this matches — a busy TUI opens one every few milliseconds, so a caller
    /// timing out an over-long frame must key its deadline on this or ordinary repainting retires
    /// the hold forever.
    public var frameGeneration: UInt64
}
