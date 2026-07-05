import Foundation

/// Incrementally parses the host->client OUTPUT byte stream and tracks the terminal
/// mode (`shellPrompt` vs `altScreen`) + emits OSC 133 command-boundary events.
///
/// ## Why a hand-rolled mini-parser (not a full VT parser)
/// libghostty's surface is opaque — there is no parsed grid or alt-screen action to read
/// (doc 14 §"Open questions libghostty"). So we sniff the byte stream ourselves for the
/// handful of markers we need (DECSET/DECRST 1049/47/1047 + OSC 133 A/B/C/D) and treat
/// everything else as opaque content. We deliberately do **not** model the full screen.
///
/// ## Robustness to split sequences (the #1 thing that silently breaks)
/// This is a true byte-at-a-time state machine. An escape sequence may be split across
/// arbitrary chunk boundaries (mid-`ESC`, mid-`CSI`, mid-`OSC`) — TCP gives us no
/// alignment. The machine holds its partial state between ``consume(_:)`` calls and only
/// fires a marker once the full sequence has arrived, so feeding the same stream one
/// byte at a time produces byte-for-byte identical events to feeding it in one chunk.
///
/// ## Tolerance
/// Unknown CSI / OSC sequences are consumed cleanly up to their terminator and ignored —
/// they never break mode tracking. Arbitrary content (including high-bit / UTF-8 bytes)
/// passes through. We never misclassify a partial sequence as content and we never get
/// "stuck" — an unterminated OSC is bounded by a sane cap so a malformed stream cannot
/// wedge the parser forever.
///
/// ## Fast path (the terminal-output ingest hot path)
/// Same discipline as `HostOutputSniffer`: in the two "skim" states the fast path
/// `memchr`s to the next byte that can change anything and routes ONLY that byte through
/// ``step(_:into:)`` — it decides WHICH bytes reach `step()`, it never replaces a
/// transition. In `.ground` the only interesting byte is `ESC` (this grammar ignores a
/// ground `BEL`, unlike the sniffer's bell detection — content is skipped wholesale); in
/// `.stringConsume` it is `ESC` or `BEL` (terminator), with the `BEL` scan bounded to the
/// prefix before the next `ESC` (the sniffer's measured O(n²) guard: total scanned bytes
/// stay ≤ 2× the input on escape-dense streams). All other states are buffering /
/// classification states where every byte matters — they step per-byte.
/// `TerminalModeTrackerFastPathTests` pins the fast path to the table with a chunking-
/// invariance oracle (chunk-size-1 bypasses memchr) + a differential oracle against the
/// frozen pre-fast-path copy in `Tests/.../Support/LegacyTerminalModeTracker.swift`.
public final class TerminalModeTracker {
    /// The current terminal mode.
    public private(set) var mode: TerminalMode = .shellPrompt

    /// TRUE while the foreground program has bracketed-paste mode (DECSET `?2004h`) enabled — set on
    /// `ESC[?2004h`, cleared on `ESC[?2004l`. Independent of ``mode`` (a shell prompt enables it; a TUI
    /// may too). It emits NO event (unlike alt-screen) so the frozen differential oracle stays byte-exact;
    /// it is a passive flag the E8 paste-protection pre-check reads to skip the sheet when the program
    /// frames the paste as an inert bracketed block (matching libghostty's own `clipboard-paste-bracketed-safe`).
    public private(set) var bracketedPasteActive = false

    public init() {}

    // MARK: Parser state

    private enum State {
        /// Outside any escape sequence (passing through opaque content).
        case ground
        /// Saw `ESC` (`0x1B`); waiting for the next byte to classify.
        case escape
        /// Inside a CSI sequence (`ESC[`). Collecting parameter/intermediate bytes
        /// until a final byte in `0x40...0x7E`.
        case csi
        /// Inside an OSC sequence (`ESC]`). Collecting the payload until `BEL` (`0x07`)
        /// or `ST` (`ESC\`).
        case osc
        /// Inside an OSC and the previous byte was `ESC` — waiting to see if it is the
        /// `\` that completes an `ST` terminator (`ESC\`), or a new sequence start.
        case oscEscape
        /// Inside a DCS/SOS/PM/APC string sequence (R9 #4): swallow the body to ST/BEL, tracking nothing.
        /// An embedded `ESC[?1049h` (alt-screen) / `ESC]133;…` in a string body must NOT flip the mode —
        /// a conformant terminal treats the whole string as opaque. Unlike OSC, an embedded non-`\` ESC
        /// stays INSIDE the string (it does not start a new sequence), so this never re-classifies.
        case stringConsume
        /// Inside a string sequence and the previous byte was `ESC` (possible `ST` = `ESC\`).
        case stringConsumeEscape
    }

    private var state: State = .ground

    /// Accumulated bytes of the CSI parameter/intermediate run (without the leading
    /// `ESC[`). Bounded; an overlong CSI is abandoned.
    private var csiBuffer: [UInt8] = []

    /// Accumulated OSC payload bytes (without the leading `ESC]` or the terminator).
    /// Bounded; an overlong OSC is abandoned (we only care about the short `133;...`).
    private var oscBuffer: [UInt8] = []

    /// Hard caps so a malformed / hostile stream cannot make us buffer unboundedly. The
    /// markers we care about are tiny; anything longer is not one of ours.
    private static let csiCap = 64
    private static let oscCap = 256

    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let leftBracket: UInt8 = 0x5B // '['
    private static let rightBracket: UInt8 = 0x5D // ']'
    private static let backslash: UInt8 = 0x5C // '\'
    // String-sequence introducers (R9 #4): DCS `ESC P`, SOS `ESC X`, PM `ESC ^`, APC `ESC _`.
    private static let dcs: UInt8 = 0x50 // 'P'
    private static let sos: UInt8 = 0x58 // 'X'
    private static let pm: UInt8 = 0x5E // '^'
    private static let apc: UInt8 = 0x5F // '_'

    // MARK: Reset

    /// Returns the tracker to its initial state (`.shellPrompt`, ground, empty
    /// buffers), emitting no events. Call at a SESSION boundary: a reconnect always
    /// brings a fresh host shell, so a mode (or partial-sequence parse state) carried
    /// over from the dead session is a lie — a session that dropped inside vim leaves
    /// `.altScreen` latched (a fresh shell never emits DECRST 1049), and a drop
    /// mid-DCS leaves `.stringConsume` swallowing the new session's real markers.
    public func reset() {
        state = .ground
        mode = .shellPrompt
        bracketedPasteActive = false
        csiBuffer.removeAll(keepingCapacity: false)
        oscBuffer.removeAll(keepingCapacity: false)
    }

    // MARK: Consume

    /// Feeds a chunk of output bytes and returns the marker events produced by this
    /// chunk (in order). Safe to call with chunks split at any byte boundary.
    @discardableResult
    public func consume(_ bytes: Data) -> [TerminalModeEvent] {
        var events: [TerminalModeEvent] = []
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var i = 0
            while i < count {
                switch state {
                case .ground:
                    // FAST PATH: in ground only ESC can change anything — content
                    // (including BEL) is ignored for mode tracking. Skip to the next ESC.
                    guard let escPointer = memchr(base + i, Int32(Self.esc), count - i) else {
                        i = count
                        break
                    }
                    let escOffset = base.distance(to: UnsafeRawPointer(escPointer))
                    step(Self.esc, into: &events) // ground ESC → .escape
                    i = escOffset + 1

                case .stringConsume:
                    // FAST PATH: only ESC (possible ST start) and BEL (terminator) matter;
                    // every other byte is opaque string body. Route only the FIRST
                    // interesting byte through step(). The BEL scan is bounded to the
                    // prefix BEFORE the next ESC — an unbounded scan re-run on every
                    // re-entry degrades to O(n²) on escape-dense streams (measured at
                    // 29 MiB/s in the sniffer; see HostOutputSniffer.observe).
                    let escPointer = memchr(base + i, Int32(Self.esc), count - i)
                    let escOffset = escPointer.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                    if let belPointer = memchr(base + i, Int32(Self.bel), escOffset - i) {
                        let belOffset = base.distance(to: UnsafeRawPointer(belPointer))
                        step(Self.bel, into: &events) // terminator → ground
                        i = belOffset + 1
                    } else if escOffset < count {
                        step(Self.esc, into: &events) // → .stringConsumeEscape
                        i = escOffset + 1
                    } else {
                        i = count
                    }

                case .escape,
                     .csi,
                     .osc,
                     .oscEscape,
                     .stringConsumeEscape:
                    // Buffering / classification states: every byte matters — step per-byte.
                    step(base.load(fromByteOffset: i, as: UInt8.self), into: &events)
                    i += 1
                }
            }
        }
        return events
    }

    /// Convenience overload for raw byte arrays.
    @discardableResult
    public func consume(_ bytes: [UInt8]) -> [TerminalModeEvent] {
        consume(Data(bytes))
    }

    // MARK: State machine

    private func step(_ byte: UInt8, into events: inout [TerminalModeEvent]) {
        switch state {
        case .ground:
            if byte == Self.esc { state = .escape }
            // else: opaque content byte — ignore for mode tracking.

        case .escape:
            switch byte {
            case Self.leftBracket:
                state = .csi
                csiBuffer.removeAll(keepingCapacity: true)
            case Self.rightBracket:
                state = .osc
                oscBuffer.removeAll(keepingCapacity: true)
            case Self.dcs,
                 Self.sos,
                 Self.pm,
                 Self.apc:
                // R9 #4: a DCS/SOS/PM/APC string body is opaque to a conformant terminal — swallow it to
                // ST/BEL so an embedded `ESC[?1049h` / `ESC]133;…` can't flip the tracked mode.
                state = .stringConsume
            case Self.esc:
                // `ESC ESC` — stay in escape, waiting to classify the second ESC.
                state = .escape
            default:
                // Some other 2-byte / nF escape (e.g. `ESC c`, `ESC (B`). Not a marker
                // we track; return to ground. (Single-byte intermediates are rare and
                // not load-bearing for our markers.)
                state = .ground
            }

        case .csi:
            // Final byte of a CSI is in 0x40...0x7E ('@'...'~'); everything before is a
            // parameter (0x30...0x3F) or intermediate (0x20...0x2F) byte.
            if (0x40...0x7E).contains(byte) {
                csiBuffer.append(byte)
                handleCSI(csiBuffer, into: &events)
                state = .ground
            } else {
                csiBuffer.append(byte)
                if csiBuffer.count > Self.csiCap {
                    // Overlong — not one of ours; abandon and resync at ground. (We do
                    // not re-interpret the overflow byte; a real terminator will reset us
                    // and worst case we drop one bogus CSI, never a tracked marker.)
                    state = .ground
                }
            }

        case .osc:
            switch byte {
            case Self.bel:
                handleOSC(oscBuffer, into: &events)
                state = .ground
            case Self.esc:
                // Possible start of an `ST` terminator (`ESC\`).
                state = .oscEscape
            default:
                oscBuffer.append(byte)
                if oscBuffer.count > Self.oscCap {
                    state = .ground
                }
            }

        case .oscEscape:
            if byte == Self.backslash {
                // `ESC\` = ST: the OSC is complete.
                handleOSC(oscBuffer, into: &events)
                state = .ground
            } else {
                // The `ESC` was not an ST terminator. Treat the OSC as terminated by the
                // stray ESC, but the ESC we already consumed may itself introduce a NEW
                // escape sequence — so re-enter `.escape` (not `.ground`) and classify
                // this byte as that sequence's introducer. Returning to `.ground` here
                // would orphan the ESC and let the next marker's introducer (`[`/`]`) be
                // parsed as plain content, losing the whole following sequence.
                handleOSC(oscBuffer, into: &events)
                state = .escape
                step(byte, into: &events)
            }

        case .stringConsume:
            // R9 #4: swallow a DCS/SOS/PM/APC string body. Terminators are ST/BEL; an embedded ESC that
            // is not `\` stays INSIDE the opaque string (it never starts a new tracked sequence).
            switch byte {
            case Self.bel:
                state = .ground
            case Self.esc:
                state = .stringConsumeEscape
            default:
                break // opaque string-body byte.
            }

        case .stringConsumeEscape:
            switch byte {
            case Self.backslash:
                state = .ground // `ESC \` = ST terminator.
            case Self.esc:
                state = .stringConsumeEscape // another ESC — could still begin ST; keep waiting.
            default:
                state = .stringConsume // a lone ESC inside the body — swallow it + keep consuming.
            }
        }
    }

    // MARK: CSI handling — DECSET/DECRST private modes 1049 / 47 / 1047

    private func handleCSI(_ buffer: [UInt8], into events: inout [TerminalModeEvent]) {
        // We only care about `?<n>h` / `?<n>l` (DEC private set/reset). Shape:
        //   '?' params... final  where final is 'h' (set) or 'l' (reset).
        guard let final = buffer.last, final == 0x68 || final == 0x6C else { return } // 'h'/'l'
        guard buffer.first == 0x3F else { return } // '?'

        // Parameters between '?' and the final byte, split on ';'.
        let paramBytes = buffer.dropFirst().dropLast()
        // Lossy UTF-8 decode is required: the state machine can append arbitrary (incl. non-UTF-8)
        // bytes to `csiBuffer`, and the frozen differential oracle (`LegacyTerminalModeTracker`) decodes
        // the same lossy way. The failable `String(bytes:encoding:)` would return nil on such bytes,
        // dropping params that lossy decode still yields — diverging from the oracle. So we keep the
        // lossy initializer here on purpose.
        // swiftlint:disable:next optional_data_string_conversion
        let params = String(decoding: paramBytes, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: true)
            .compactMap { Int($0) }

        let isSet = (final == 0x68) // 'h'
        // DECSET/DECRST 2004 — bracketed-paste mode. Passive flag only (no event), so the frozen
        // differential oracle (`LegacyTerminalModeTracker`, which compares events + `.mode`) stays exact.
        // Handled independently of alt-screen: a single CSI can carry both (e.g. `?1049;2004h`).
        if params.contains(2004) { bracketedPasteActive = isSet }
        for param in params where param == 1049 || param == 47 || param == 1047 {
            if isSet {
                if mode != .altScreen {
                    mode = .altScreen
                    events.append(.enteredAltScreen)
                }
            } else {
                if mode != .shellPrompt {
                    mode = .shellPrompt
                    events.append(.exitedAltScreen)
                }
            }
            // One alt-screen marker per CSI is enough; the modes are equivalent.
            return
        }
    }

    // MARK: OSC handling — OSC 133 prompt marks

    private func handleOSC(_ buffer: [UInt8], into events: inout [TerminalModeEvent]) {
        // Lossy UTF-8 decode is required: `oscBuffer` can hold arbitrary (incl. non-UTF-8) bytes and the
        // frozen differential oracle (`LegacyTerminalModeTracker`) decodes the same lossy way. The failable
        // `String(bytes:encoding:)` would return nil on such bytes, changing which OSC 133 events fire and
        // diverging from the oracle. So we keep the lossy initializer here on purpose.
        // swiftlint:disable:next optional_data_string_conversion
        let payload = String(decoding: buffer, as: UTF8.self)
        // Expected: "133;A" | "133;B" | "133;C" | "133;D" | "133;D;<exit>" (+ extra ;k=v).
        let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 2, fields[0] == "133" else { return }

        switch fields[1] {
        case "A": events.append(.promptStart)
        case "B": events.append(.commandStart)
        case "C": events.append(.commandStarted)
        case "D":
            // `;D` or `;D;<exit>[;...]`. The exit code, if present, is field[2].
            var exit: Int?
            if fields.count >= 3 {
                let raw = fields[2].split(separator: "=").first.map(String.init) ?? String(fields[2])
                exit = Int(raw)
            }
            events.append(.commandFinished(exitCode: exit))
        default:
            break // Unknown OSC 133 subcommand — ignore cleanly.
        }
    }
}
