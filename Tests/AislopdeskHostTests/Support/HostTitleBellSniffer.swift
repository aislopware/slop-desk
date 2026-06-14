import AislopdeskProtocol
import Foundation

/// A **non-destructive** sniffer over the host's outbound PTY byte stream that observes
/// (never consumes) the bytes the host relays to the client and emits the two
/// host→client CONTROL messages the byte stream carries inline:
///
/// - ``WireMessage/title(_:)`` — from **OSC 0** (icon + window title) and **OSC 2**
///   (window title): `ESC ] 0 ; <text> <terminator>` / `ESC ] 2 ; <text> <terminator>`,
///   where `<terminator>` is `BEL` (`0x07`) **or** `ST` (`ESC \` = `0x1B 0x5C`).
/// - ``WireMessage/bell`` — from a **standalone** `BEL` (`0x07`) that is NOT serving as
///   an OSC string terminator.
///
/// ## Why a sniffer (and not the client / libghostty)
/// PATH 1 relays RAW VT bytes; libghostty on the client is the real terminal. But the
/// CONTROL channel surfaces `title`/`bell` as structured events (so the chrome view-model
/// can show a tab title / ring a bell without re-parsing the byte stream, and so they ride
/// the head-of-line-independent control connection). The host is the only place that sees
/// the byte stream *before* it is framed, so it sniffs OSC/BEL here and emits the control
/// messages alongside the unchanged `output` frames. This is the host-side analogue of
/// ``TerminalModeTracker`` (which sniffs the SAME stream client-side for alt-screen /
/// OSC 133); the two are deliberately separate — different consumers, different sequences.
///
/// ## Non-destructive (the load-bearing invariant)
/// ``observe(_:)`` returns ONLY the control messages it detected. The caller MUST forward
/// the original bytes to the client UNCHANGED — the sniffer never strips, rewrites, or
/// reorders a single byte of the relay. It is a pure observer of a copy of the stream.
///
/// ## Streaming-safe (split across read chunks)
/// This is a true byte-at-a-time state machine. An OSC sequence may be split across any
/// chunk boundary (mid-`ESC`, mid-`OSC`, mid-terminator) — TCP / `read()` give no
/// alignment. The machine holds its partial state between ``observe(_:)`` calls and only
/// emits a `.title` once the full sequence has arrived, so feeding a stream one byte at a
/// time produces identical control messages to feeding it whole.
///
/// ## BEL-vs-OSC-terminator disambiguation (the subtle correctness point)
/// A `BEL` inside / ending an OSC string is the OSC's **terminator**, NOT a bell. Only a
/// `BEL` seen in the **ground** state (outside any escape sequence) is a real bell. The
/// state machine guarantees this structurally: a `BEL` consumed while in `.osc` /
/// `.oscEscape` finishes the OSC (and may emit a `.title`) and **never** emits `.bell`; a
/// `BEL` consumed in `.ground` emits exactly one `.bell`.
///
/// ## Bounds + resync (defend against a hostile / unterminated OSC)
/// The OSC payload buffer is capped at ``oscCap``. An OSC that never terminates (or is
/// longer than any real title) is abandoned at the cap and the parser resyncs to ground —
/// a malformed stream can never make the host buffer unboundedly or wedge the sniffer.
///
/// ## Stray-ESC handling (the prior bug class — see ``TerminalModeTracker``)
/// If an `ESC` arrives inside an OSC and is NOT the `\` of an `ST` terminator, the OSC is
/// treated as ended by the stray `ESC`, and that `ESC` is re-fed as the introducer of a
/// NEW sequence (we re-enter `.escape`, we do NOT drop to `.ground`). Dropping to ground
/// would orphan the `ESC` and let the next sequence's `]` / `[` be misread as plain
/// content — losing a following title. (`TerminalModeTracker` carries the identical fix;
/// this sniffer reuses the approach rather than regressing it.)
///
/// `@unchecked Sendable`: the mutable parser state is guarded by ``lock``. In practice
/// ``observe(_:)`` is only ever called from the single serial `PTYReadLoop` queue (the
/// `onChunk` sink), so calls are already serialized; the lock makes the type safe to
/// capture in the `@Sendable` `onChunk` closure regardless.
public final class HostTitleBellSniffer: @unchecked Sendable {
    public init() {}

    // MARK: Parser state

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

    private let lock = NSLock()
    private var state: State = .ground

    /// Accumulated OSC payload bytes (without the leading `ESC ]` or the terminator),
    /// e.g. `0;my title`. Bounded by ``oscCap``.
    private var oscBuffer: [UInt8] = []

    /// The last title we emitted, for trivial coalescing (don't spam identical titles).
    private var lastTitle: String?

    /// Hard cap on the buffered OSC payload. A real title is tiny; anything longer is not
    /// a title we care about — abandon it and resync. (Generous enough for long window
    /// titles / paths, small enough to bound a hostile unterminated OSC.)
    private static let oscCap = 4096

    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let rightBracket: UInt8 = 0x5D // ']'
    private static let backslash: UInt8 = 0x5C // '\'
    private static let semicolon: UInt8 = 0x3B // ';'
    // String-sequence introducers (R9 #4): DCS `ESC P`, SOS `ESC X`, PM `ESC ^`, APC `ESC _`. A real
    // terminal swallows their body to the ST/BEL terminator without ringing a bell or changing the title.
    private static let dcs: UInt8 = 0x50 // 'P'
    private static let sos: UInt8 = 0x58 // 'X'
    private static let pm: UInt8 = 0x5E // '^'
    private static let apc: UInt8 = 0x5F // '_'

    // MARK: Observe

    /// Observes a chunk of the OUTBOUND byte stream and returns the CONTROL messages
    /// (`.title` / `.bell`) detected in it, in order. **Does not modify or consume the
    /// bytes** — the caller forwards the original chunk to the client unchanged.
    @discardableResult
    public func observe(_ bytes: Data) -> [WireMessage] {
        lock.lock()
        defer { lock.unlock() }
        var messages: [WireMessage] = []
        for byte in bytes {
            step(byte, into: &messages)
        }
        return messages
    }

    /// Convenience overload for raw byte arrays (used by tests).
    @discardableResult
    public func observe(_ bytes: [UInt8]) -> [WireMessage] {
        observe(Data(bytes))
    }

    // MARK: State machine

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
            case Self.dcs,
                 Self.sos,
                 Self.pm,
                 Self.apc:
                // R9 #4 (security): DCS/SOS/PM/APC introduce a STRING sequence whose body a conformant
                // terminal swallows to its ST/BEL terminator WITHOUT ringing a bell or changing the title.
                // Consume the whole string + terminator, emitting NOTHING — else a malicious remote program
                // could embed a BEL (phantom bell) or an `ESC]2;…` (title spoof) inside the string body and
                // we'd fabricate control events the client never honors.
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
                // BEL terminates the OSC string — emit a title if it is OSC 0/2, and
                // CRUCIALLY do NOT emit a .bell (this BEL is a terminator, not a bell).
                finishOSC(into: &messages)
                state = .ground
            case Self.esc:
                // Possible start of an `ST` terminator (`ESC \`).
                state = .oscEscape
            default:
                oscBuffer.append(byte)
                if oscBuffer.count > Self.oscCap {
                    // Overlong — not a title we care about; abandon WITHOUT emitting a title.
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
                // there is no title to finish since the OSC was discarded).
                state = .escape
                step(byte, into: &messages)
            }

        case .stringConsume:
            // R9 #4: swallow a DCS/SOS/PM/APC string body, emitting nothing. The ONLY terminators are
            // ST (`ESC \`) and BEL. CRUCIALLY, unlike the OSC-discard path, an embedded ESC that is not
            // `\` stays INSIDE the string (it does NOT introduce a new sequence), so an `ESC]2;…` in the
            // body can never spoof a title and an embedded BEL never rings.
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
                // the ESC and let a following title's `]` be parsed as plain content,
                // losing the whole sequence (the prior stray-ESC bug — see the type doc).
                finishOSC(into: &messages)
                state = .escape
                step(byte, into: &messages)
            }
        }
    }

    // MARK: OSC handling — OSC 0 (icon+title) / OSC 2 (window title)

    private func finishOSC(into messages: inout [WireMessage]) {
        defer { oscBuffer.removeAll(keepingCapacity: true) }
        // Split only on the FIRST ';': `Ps ; Pt` — the title text itself may contain ';'.
        guard let sep = oscBuffer.firstIndex(of: Self.semicolon) else { return }
        let psBytes = oscBuffer[oscBuffer.startIndex..<sep]
        let ps = String(bytes: psBytes, encoding: .utf8) ?? ""
        // We surface a title for OSC 0 (icon name + window title) and OSC 2 (window title
        // only). OSC 1 is icon-name-ONLY and is deliberately ignored — it never sets the
        // window title, so it should not change the client's displayed title. Any other Ps
        // (e.g. OSC 8 hyperlink, OSC 52 clipboard, OSC 133 prompt marks, OSC 4 palette) is
        // not a title and is skipped.
        guard ps == "0" || ps == "2" else { return }
        let titleBytes = oscBuffer[oscBuffer.index(after: sep)...]
        let title = String(bytes: titleBytes, encoding: .utf8) ?? ""
        // Trivial dedup: don't spam an identical title back-to-back.
        if title == lastTitle { return }
        lastTitle = title
        messages.append(.title(title))
    }
}
