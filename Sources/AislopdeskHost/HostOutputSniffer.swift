import Foundation
import AislopdeskProtocol

/// The FUSED host-side output sniffer: ONE pass over the outbound PTY byte stream replacing
/// the back-to-back pair ``HostTitleBellSniffer`` + ``HostCommandStatusSniffer``. It emits
/// all THREE inline host→client CONTROL messages:
///
/// - ``WireMessage/title(_:)`` — OSC 0 / OSC 2 (`ESC ] 0;… <terminator>` / `ESC ] 2;…`).
/// - ``WireMessage/bell`` — a standalone ground-state `BEL` (never an OSC/string terminator).
/// - ``WireMessage/commandStatus(_:)`` — OSC 133 `C` (running) / `D[;exit]` (idle, with the
///   host-measured C→D duration in milliseconds via the injectable ``clock``).
///
/// ## Provenance (exact-parity port)
/// The two old sniffers shared an IDENTICAL 8-state transition table; the title sniffer was
/// the strict superset (it additionally emits `.bell` in ground). ``step(_:into:)`` here is
/// that table VERBATIM. The only fusion point is ``finishOSC(into:)``, which dispatches on
/// the Ps prefix: `0`/`2` → the title path (incl. the `lastTitle` dedup), `133` → the old
/// command sniffer's C/D logic — guarded by an EXACT-PARITY 256-byte payload cap (see
/// ``cmdOscCap``) so payloads of 257..4096 bytes stay ignored exactly as the old command
/// sniffer (whose buffer cap was 256) ignored them.
///
/// Cross-type messages are emitted in BYTE order (the old pair emitted all title/bell before
/// all command messages per chunk); per-type subsequences are byte-identical to the old pair.
///
/// ## Non-destructive + streaming-safe (unchanged invariants)
/// ``observe(_:)`` only OBSERVES — the caller forwards the original bytes UNCHANGED. The
/// machine is a true byte-at-a-time state machine: state persists across chunks, so any
/// split (mid-ESC, mid-OSC, mid-terminator) yields identical messages to the whole stream.
/// The OSC payload buffer is capped (``oscCap``); over-cap / string-sequence bodies are
/// swallowed without buffering, so a hostile stream can never wedge the sniffer or make it
/// buffer unboundedly. Stray-ESC re-entry and DCS/SOS/PM/APC swallowing are carried over
/// verbatim (see the old sniffers' doc comments for the full rationale of each).
///
/// ## Fast path (hot read-loop thread)
/// In the three "skim" states — `.ground`, `.oscDiscard`, `.stringConsume` — the ONLY bytes
/// that can change anything are `ESC` (0x1B) and `BEL` (0x07); every other byte is a no-op
/// (verified against ``step(_:into:)``: ground ignores content, discard/string swallow it;
/// note that in THIS grammar `BEL` DOES terminate `.stringConsume` too). ``observe(_:)``
/// therefore `memchr`s for the next interesting byte and routes ONLY that byte through
/// ``step(_:into:)`` — the fast path decides WHICH bytes reach `step()`, it never replaces
/// a transition. All other states step per-byte.
///
/// `@unchecked Sendable`: the mutable parser/timing state is guarded by ``lock``. In
/// practice ``observe(_:)`` is only ever called from the single serial `PTYReadLoop` queue
/// (the `onChunk` sink), so calls are already serialized; the lock makes the type safe to
/// capture in the `@Sendable` `onChunk` closure regardless.
public final class HostOutputSniffer: @unchecked Sendable {

    /// - Parameter clock: the wall-clock source for the OSC 133 C→D duration. Injectable so
    ///   a test advances it deterministically; defaults to `Date.init` in production.
    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    private let lock = NSLock()
    private let clock: @Sendable () -> Date

    /// When the foreground command started (set on `133;C`, cleared on `133;D`); `nil` idle.
    private var runningSince: Date?

    // MARK: Parser state (verbatim from HostTitleBellSniffer)

    private enum State {
        /// Outside any escape sequence (opaque content). A `BEL` here is a real bell.
        case ground
        /// Saw `ESC` (`0x1B`); waiting for the next byte to classify (`]` → OSC, etc.).
        case escape
        /// Inside an OSC sequence (`ESC ]`). Collecting payload until `BEL` or `ST`.
        case osc
        /// Inside an OSC and the previous byte was `ESC` — waiting to see if it is the
        /// `\` that completes an `ST` terminator (`ESC \`), or a new sequence start.
        case oscEscape
        /// An over-cap OSC is being DISCARDED: still INSIDE the OSC (so its terminator must
        /// be consumed here, not re-parsed as ground), but no longer buffering. Bounded O(n).
        case oscDiscard
        /// Inside a discarded OSC and the previous byte was `ESC` (possible `ST`).
        case oscDiscardEscape
        /// Inside a DCS/SOS/PM/APC string sequence (R9 #4): swallow the body to its ST/BEL terminator,
        /// emitting NOTHING. UNLIKE an OSC, an embedded ESC that is NOT `\` is part of the opaque string
        /// (it does NOT start a new sequence), so this never re-classifies — that is the whole point.
        case stringConsume
        /// Inside a string sequence and the previous byte was `ESC` (possible `ST` = `ESC \`).
        case stringConsumeEscape
    }

    private var state: State = .ground

    /// Accumulated OSC payload bytes (without the leading `ESC ]` or the terminator),
    /// e.g. `0;my title` or `133;D;0`. Bounded by ``oscCap``.
    private var oscBuffer: [UInt8] = []

    /// The last title we emitted, for trivial coalescing (don't spam identical titles).
    private var lastTitle: String?

    /// Hard cap on the buffered OSC payload (the TITLE sniffer's cap — the larger of the
    /// two). A real title is tiny; anything longer is not a title we care about — abandon it
    /// and resync. (Generous enough for long window titles / paths, small enough to bound a
    /// hostile unterminated OSC.)
    private static let oscCap = 4096

    /// EXACT-PARITY guard for the 133 path: the old ``HostCommandStatusSniffer`` capped ITS
    /// buffer at 256, so a `133;…` payload of 257..4096 bytes never reached its finishOSC.
    /// The fused machine buffers up to 4096 (the title cap), so ``finishOSC(into:)`` must
    /// re-impose 256 on the 133 branch to keep those payloads ignored byte-for-byte.
    private static let cmdOscCap = 256

    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let rightBracket: UInt8 = 0x5D  // ']'
    private static let backslash: UInt8 = 0x5C     // '\'
    private static let semicolon: UInt8 = 0x3B     // ';'
    // String-sequence introducers (R9 #4): DCS `ESC P`, SOS `ESC X`, PM `ESC ^`, APC `ESC _`. A real
    // terminal swallows their body to the ST/BEL terminator without ringing a bell or changing the title.
    private static let dcs: UInt8 = 0x50           // 'P'
    private static let sos: UInt8 = 0x58           // 'X'
    private static let pm: UInt8 = 0x5E            // '^'
    private static let apc: UInt8 = 0x5F           // '_'

    // MARK: Observe

    /// Observes a chunk of the OUTBOUND byte stream and returns the CONTROL messages
    /// (`.title` / `.bell` / `.commandStatus`) detected in it, in byte order. **Does not
    /// modify or consume the bytes** — the caller forwards the original chunk unchanged.
    @discardableResult
    public func observe(_ bytes: Data) -> [WireMessage] {
        lock.lock()
        defer { lock.unlock() }
        var messages: [WireMessage] = []
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var i = 0
            while i < count {
                switch state {
                case .ground:
                    // FAST PATH: in ground, only ESC (state change) and BEL (.bell) matter.
                    // Find the next ESC in the remainder…
                    let escPointer = memchr(base + i, Int32(Self.esc), count - i)
                    let escOffset = escPointer.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                    // …then scan for BELs ONLY in the prefix BEFORE that ESC. CRITICAL
                    // bound: an UNBOUNDED BEL memchr over the whole remainder, re-run on
                    // every ground re-entry, degrades to O(n^2) on escape-dense streams and
                    // was MEASURED at 29 MiB/s — SLOWER than the per-byte loop it replaces.
                    // Bounding the BEL scan to [i, escOffset) keeps total scanned bytes
                    // <= 2x the input (each byte is seen by at most one ESC scan and one
                    // BEL scan).
                    var j = i
                    while j < escOffset {
                        guard let belPointer = memchr(base + j, Int32(Self.bel), escOffset - j) else { break }
                        let belOffset = base.distance(to: UnsafeRawPointer(belPointer))
                        step(Self.bel, into: &messages) // ground BEL → .bell (state stays ground)
                        j = belOffset + 1
                    }
                    if escOffset < count {
                        step(Self.esc, into: &messages) // ground ESC → .escape
                        i = escOffset + 1
                    } else {
                        i = count
                    }

                case .oscDiscard, .stringConsume:
                    // FAST PATH: in both skim states the ONLY interesting bytes are ESC and
                    // BEL — every other byte is swallowed with no transition. (Verified
                    // against step(): BEL DOES terminate `.stringConsume` in this grammar,
                    // same as `.oscDiscard` — both drop to ground on BEL.) Route only the
                    // FIRST interesting byte through step(); never substitute a transition.
                    let escPointer = memchr(base + i, Int32(Self.esc), count - i)
                    let escOffset = escPointer.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                    // BEL scan bounded to the prefix BEFORE the ESC — same O(n^2) guard
                    // (and 29 MiB/s measurement) as the ground fast path above.
                    if let belPointer = memchr(base + i, Int32(Self.bel), escOffset - i) {
                        let belOffset = base.distance(to: UnsafeRawPointer(belPointer))
                        step(Self.bel, into: &messages) // terminator → ground
                        i = belOffset + 1
                    } else if escOffset < count {
                        step(Self.esc, into: &messages) // → .oscDiscardEscape / .stringConsumeEscape
                        i = escOffset + 1
                    } else {
                        i = count
                    }

                case .escape, .osc, .oscEscape, .oscDiscardEscape, .stringConsumeEscape:
                    // Buffering / classification states: every byte matters — step per-byte.
                    step(base.load(fromByteOffset: i, as: UInt8.self), into: &messages)
                    i += 1
                }
            }
        }
        return messages
    }

    /// Convenience overload for raw byte arrays (used by tests).
    @discardableResult
    public func observe(_ bytes: [UInt8]) -> [WireMessage] {
        observe(Data(bytes))
    }

    // MARK: State machine (verbatim from HostTitleBellSniffer — the strict superset)

    private func step(_ byte: UInt8, into messages: inout [WireMessage]) {
        switch state {
        case .ground:
            switch byte {
            case Self.esc:
                state = .escape
            case Self.bel:
                // A BEL in ground state is a real terminal bell (NOT an OSC terminator).
                messages.append(.bell)
            default:
                break // opaque content byte — ignore.
            }

        case .escape:
            switch byte {
            case Self.rightBracket:
                state = .osc
                oscBuffer.removeAll(keepingCapacity: true)
            case Self.dcs, Self.sos, Self.pm, Self.apc:
                // R9 #4 (security): DCS/SOS/PM/APC introduce a STRING sequence whose body a conformant
                // terminal swallows to its ST/BEL terminator WITHOUT ringing a bell or changing the title.
                // Consume the whole string + terminator, emitting NOTHING — else a malicious remote program
                // could embed a BEL (phantom bell), an `ESC]2;…` (title spoof), or an `ESC]133;C/D`
                // (phantom command status) inside the string body and we'd fabricate control events.
                state = .stringConsume
            case Self.esc:
                // `ESC ESC` — stay in escape, waiting to classify the second ESC.
                state = .escape
            default:
                // Some other escape (CSI `ESC[`, a 2-byte / nF escape like `ESC c`). Not
                // an OSC; we do not track it. Return to ground. NOTE: a BEL here would be
                // an `ESC BEL` which is not a real sequence we care about and not a
                // standalone bell — treating it as ground content is fine.
                state = .ground
            }

        case .osc:
            switch byte {
            case Self.bel:
                // BEL terminates the OSC string — emit a title / command status if it is an
                // OSC 0/2/133, and CRUCIALLY do NOT emit a .bell (this BEL is a terminator).
                finishOSC(into: &messages)
                state = .ground
            case Self.esc:
                // Possible start of an `ST` terminator (`ESC \`).
                state = .oscEscape
            default:
                oscBuffer.append(byte)
                if oscBuffer.count > Self.oscCap {
                    // Overlong — not a sequence we care about; abandon WITHOUT emitting.
                    // Do NOT drop to `.ground` here: we are still INSIDE the OSC, so its real
                    // terminator (BEL / ST) has not arrived yet. Dropping to ground would make
                    // that terminator BEL be re-parsed as a spurious `.bell` (and any following
                    // bytes misread). Switch to `.oscDiscard` to swallow the rest of the OSC —
                    // including its terminator — byte-at-a-time (bounded, no buffering).
                    oscBuffer.removeAll(keepingCapacity: true)
                    state = .oscDiscard
                }
            }

        case .oscDiscard:
            // Discarding an over-cap OSC: consume bytes until its genuine terminator so the
            // terminator can never leak into ground parsing. No buffering → still O(n)/bounded.
            switch byte {
            case Self.bel:
                state = .ground
            case Self.esc:
                state = .oscDiscardEscape
            default:
                break // discarded payload byte
            }

        case .oscDiscardEscape:
            if byte == Self.backslash {
                state = .ground // `ESC \` = ST terminator of the discarded OSC.
            } else {
                // The `ESC` was not an ST terminator — it may introduce a NEW sequence. Re-enter
                // `.escape` and re-classify this byte (mirror the `.oscEscape` stray-ESC fix;
                // there is no payload to finish since the OSC was discarded).
                state = .escape
                step(byte, into: &messages)
            }

        case .stringConsume:
            // R9 #4: swallow a DCS/SOS/PM/APC string body, emitting nothing. The ONLY terminators are
            // ST (`ESC \`) and BEL. CRUCIALLY, unlike the OSC-discard path, an embedded ESC that is not
            // `\` stays INSIDE the string (it does NOT introduce a new sequence), so an `ESC]2;…` or
            // `ESC]133;…` in the body can never spoof a title / command status and an embedded BEL
            // never rings.
            switch byte {
            case Self.bel:
                state = .ground
            case Self.esc:
                state = .stringConsumeEscape
            default:
                break // opaque string-body byte — swallow.
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

        case .oscEscape:
            if byte == Self.backslash {
                // `ESC \` = ST: the OSC is complete.
                finishOSC(into: &messages)
                state = .ground
            } else {
                // The `ESC` was not an ST terminator. Treat the OSC as terminated by the
                // stray ESC, but the ESC we already consumed may itself introduce a NEW
                // sequence — so re-enter `.escape` (NOT `.ground`) and re-classify this
                // byte as that sequence's introducer. Dropping to ground here would orphan
                // the ESC and let a following sequence's `]` be parsed as plain content,
                // losing the whole sequence (the prior stray-ESC bug — see the old sniffers).
                finishOSC(into: &messages)
                state = .escape
                step(byte, into: &messages)
            }
        }
    }

    // MARK: OSC handling — fused dispatch: OSC 0/2 (title) + OSC 133 C/D (command status)

    private func finishOSC(into messages: inout [WireMessage]) {
        defer { oscBuffer.removeAll(keepingCapacity: true) }
        // Split the Ps prefix at the FIRST ';' — the payload after it may itself contain ';'
        // (a title keeps them; the 133 path re-splits the FULL payload below, exactly like
        // the old command sniffer).
        guard let sep = oscBuffer.firstIndex(of: Self.semicolon) else { return }
        let psBytes = oscBuffer[oscBuffer.startIndex..<sep]
        let ps = String(decoding: psBytes, as: UTF8.self)

        switch ps {
        case "0", "2":
            // Title path — verbatim from HostTitleBellSniffer. We surface a title for OSC 0
            // (icon name + window title) and OSC 2 (window title only). OSC 1 is
            // icon-name-ONLY and is deliberately ignored — it never sets the window title.
            let titleBytes = oscBuffer[oscBuffer.index(after: sep)...]
            let title = String(decoding: titleBytes, as: UTF8.self)
            // Trivial dedup: don't spam an identical title back-to-back.
            if title == lastTitle { return }
            lastTitle = title
            messages.append(.title(title))

        case "133":
            // EXACT-PARITY guard: the old command sniffer's 256-byte buffer cap means a
            // `133;…` payload of 257..4096 bytes was discarded before ever reaching its
            // finishOSC — reproduce that here so those payloads stay ignored.
            guard oscBuffer.count <= Self.cmdOscCap else { return }
            // C/D logic — verbatim from HostCommandStatusSniffer: full split on ';' with
            // empty fields KEPT. Expected: "133;A" | "133;B" | "133;C" | "133;D" |
            // "133;D;<exit>" (+ extra ;k=v).
            let payload = String(decoding: oscBuffer, as: UTF8.self)
            let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count >= 2, fields[0] == "133" else { return }

            switch fields[1] {
            case "C":
                // A command began executing — mark RUNNING and start the duration clock.
                runningSince = clock()
                messages.append(.commandStatus(.running))
            case "D":
                // A command finished. Ignore a `D` with no matching `C` (the first-prompt
                // phantom `D;0`) — never emit a 0-duration `.idle` for a command that never ran.
                guard let started = runningSince else { return }
                runningSince = nil
                let exit = Self.parseExit(fields)
                let durationMS = Self.durationMS(from: started, to: clock())
                messages.append(.commandStatus(.idle(exitCode: exit, durationMS: durationMS)))
            default:
                break // A / B / unknown 133 subcommand — not surfaced.
            }

        default:
            // Any other Ps (OSC 1 icon, OSC 8 hyperlink, OSC 52 clipboard, OSC 4 palette …)
            // is neither a title nor a command mark — skip.
            return
        }
    }

    /// Parses the optional exit code from a `133;D[;<exit>[;k=v…]]` field list (field[2],
    /// tolerating a trailing `=value`), clamped to `Int32`. Returns `nil` when absent/unparsable.
    private static func parseExit(_ fields: [Substring]) -> Int32? {
        guard fields.count >= 3 else { return nil }
        let raw = fields[2].split(separator: "=").first.map(String.init) ?? String(fields[2])
        guard let value = Int(raw) else { return nil }
        return Int32(truncatingIfNeeded: value)
    }

    /// The non-negative C→D wall-clock duration in milliseconds (clamped at 0; a non-monotonic
    /// clock or a same-instant C/D can never produce a negative).
    private static func durationMS(from start: Date, to end: Date) -> UInt32 {
        let seconds = end.timeIntervalSince(start)
        let ms = (seconds * 1000).rounded()
        guard ms > 0 else { return 0 }
        return ms >= Double(UInt32.max) ? UInt32.max : UInt32(ms)
    }
}
