import Foundation

// MARK: - LineOverprintCollapser (replay hygiene: superseded line revisions contribute nothing)

/// Drops the SUPERSEDED revisions of a line that a progress reporter overprints in place with
/// `CR` (or `CSI 1 G`), from a scrollback REPLAY stream.
///
/// ## Why
/// `git push`, `swift build`/`swift test`, `npm`, `pip`, `cargo`, `docker pull` — every tool that
/// draws a percentage — repaints ONE line hundreds or thousands of times: `…: 1%\r…: 2%\r…`, or
/// `CSI 2K CR` then the new text. The final display is two or three lines; the recorded byte
/// stream is megabytes. On a COLD reattach every superseded revision is re-sent and re-parsed by
/// the client's terminal, which is seconds of wire + VT work whose entire visible result is the
/// LAST revision. ``AltScreenSegmentStripper`` and ``SyncUpdateFrameCollapser`` cannot see this
/// churn: it never enters the alt screen and is never wrapped in a synchronized-output frame, and
/// ``ScrollbackDistiller`` passes the command-OUTPUT span (`133;C`→`D`) verbatim by contract.
///
/// ## What survives
/// A line is split at each cursor-to-column-0 motion (`CR`, `CSI G`/`CSI 1 G`) into REVISIONS,
/// each painting from column 0. A revision is dropped only when LATER revisions of the same line
/// TOUCH every column it touched — are at least as wide, or erase across it (`CSI K`) — because
/// then the last writer of each of those columns is a later revision either way. Anything else is
/// kept:
/// - the LAST revision of the line, always (that is the visible state);
/// - a revision WIDER than everything after it — its tail survives on screen, exactly as a real
///   terminal leaves progress residue behind a shorter successor;
/// - a revision that ERASES more than its successors touch: its blanking is what put those columns
///   in their final state (so the final `CSI 2 K` of a repaint loop survives, at one revision's
///   cost, while the thousands before it do not);
/// - every revision of a line the pass cannot model exactly — any cursor motion other than the
///   column-0 reset, `BS`/`HT`, an OSC/DCS/`ESC`-pair, or malformed UTF-8 marks the whole line
///   UNSAFE and it is emitted byte-for-byte (the "never cleaner than raw" fallback the sibling
///   passes take).
///
/// Zero-width state a dropped revision established still applies to the survivor: `SGR` and the
/// position-neutral `?25`/`?7` (cursor visibility, autowrap) toggles are CARRIED FORWARD and
/// re-emitted ahead of the next kept revision, so a coloured bar keeps its colour. A revision that
/// OPENS with a zero-width scalar (combining mark, ZWJ, variation selector) marks the line UNSAFE:
/// the mark attaches to the last printed cell, which belongs to a predecessor a drop would take
/// away with it.
///
/// Known accepted gaps (the first mirrors ``SyncUpdateFrameCollapser``'s autowrap gap):
/// - A revision WIDER than the recording-time grid wrapped onto extra rows, and its `CR` then
///   returned to the start of the LAST visual row only — so its earlier rows survived on screen
///   and dropping the revision loses them. The pass has no grid width (the ring spans resizes, and
///   the client re-wraps at its own width anyway, so that layout was never faithfully replayable).
///   Width-aware progress reporters — which is what emits this churn — never exceed the grid.
/// - A LINE whose first scalar is a zero-width mark attaches it across the line boundary into the
///   PREVIOUS line, whose keep decisions are already emitted. The mark's target only moves if that
///   line's final revision painted nothing while earlier revisions were dropped — an erase-only
///   tail under a mark-led successor, which no real reporter produces.
///
/// ## Where it runs
/// ONLY on the replay-side transform (``ScrollbackReplayTransform``), after
/// ``SyncUpdateFrameCollapser`` and before ``ScrollbackDistiller`` (megabytes less for the
/// distiller to scan; lines carrying an OSC `133` mark are UNSAFE here, so every mark reaches it
/// verbatim). The live byte stream and the un-acked resume tail are untouched.
///
/// PURE + `nonisolated`, mirroring the sibling strippers ("mirror, don't share").
enum LineOverprintCollapser {
    private static let esc: UInt8 = 0x1B
    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A

    /// Cap on the carried-forward `SGR` bytes. A line with a hundred thousand dropped revisions
    /// would otherwise accumulate their every `SGR` byte; past the cap the OLDEST carried
    /// sequences are dropped whole (a later `SGR` overrides an earlier one for the same attribute,
    /// so the tail is the load-bearing end). The `?25`/`?7` toggles live OUTSIDE the cap as
    /// two-slot state — a one-shot `?25l` must survive any amount of colour churn.
    private static let carryCap = 4096

    /// Revision count at which the line's buffered revisions are COMPACTED in place. The keep rule
    /// is a suffix-maximum, so applying it to the buffered prefix drops exactly what the final pass
    /// would drop — a pure memory backstop for a single line repainted millions of times. Never
    /// runs on an UNSAFE line: coverage is garbage once modelling has failed, and the verbatim
    /// guarantee needs every byte (an unsafe line stops splitting instead, so the per-revision
    /// memory the threshold bounds cannot accumulate there either).
    private static let compactionThreshold = 65536

    /// Coverage of a revision that erases through the line's end (`CSI K`) — covers any width.
    private static let fullCoverage = Int.max

    /// One column-0 repaint of the current line.
    ///
    /// Droppability rests on ONE quantity, ``covers``: the columns the revision TOUCHES — paints a
    /// glyph into or blanks with an erase. A revision is redundant exactly when later revisions
    /// touch every column it did, because then the last writer of each of those columns is a later
    /// revision either way. (Counting only what a revision still SHOWS would be wrong: a revision
    /// that merely erases shows nothing yet still decides those columns.)
    private struct Revision {
        /// The `CR` / `CSI G` that opened this revision (empty for the line's first revision).
        var prefix: [UInt8] = []
        /// Everything painted since that reset, verbatim.
        var bytes: [UInt8] = []
        /// Just the zero-width state changes within ``bytes`` (`SGR`, `?25`/`?7`), in order.
        var carry: [UInt8] = []
        /// Columns from 0 this revision paints or erases.
        var covers = 0
        /// Current column, so an erase knows which side of the cursor it clears.
        var cursor = 0
        /// Whether ``cursor`` is the TRUE column. A revision opened by `CR`/`CHA` starts at column 0
        /// and always knows; the FIRST revision of a line inherits the column the previous line left
        /// (bare `LF` moves down WITHOUT returning to column 0), which is unknown when the buffer
        /// starts mid-stream or the previous line was unmodelled. Unknown ⇒ ``keepMask(_:)`` never
        /// drops the revision: its painted span may reach past anything a successor covers.
        var startKnown = true
        /// Whether a width>0 glyph has landed yet. A zero-width scalar arriving BEFORE one attaches
        /// to a cell OUTSIDE this revision.
        var paintedGlyph = false
    }

    /// Byte-level parser phase. `CSI`/string bodies are tracked so a `CR` inside one is never
    /// mistaken for a revision boundary.
    private enum State {
        case ground
        case afterEsc
        case csi
        case stringBody // OSC/DCS/SOS/PM/APC — line is already UNSAFE; consume to the terminator
        case stringBodyEsc
    }

    /// Returns `data` with fully-covered line revisions removed.
    static func collapse(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let input = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(input.count)

        var state = State.ground
        var seq: [UInt8] = [] // the in-progress escape sequence, decided at its final byte
        // The column the current line starts in. `nil` = unknown: the buffer opens mid-stream, so
        // where the previous (unseen) line left the cursor is anybody's guess.
        var startColumn: Int?

        // The line's opening revision, seeded with whatever the previous line left behind.
        func openingRevision() -> Revision {
            var rev = Revision()
            if let startColumn {
                rev.cursor = startColumn // it paints from HERE, not from column 0
            } else {
                rev.startKnown = false // keepMask never drops it — its true span is unknowable
            }
            return rev
        }

        var revisions: [Revision] = [openingRevision()]
        var lineUnsafe = false
        var utf8Pending: [UInt8] = [] // bytes of a partially-read multi-byte scalar
        var utf8Needed = 0

        func current() -> Int { revisions.count - 1 }

        // Emits the buffered line plus `terminator`, dropping every fully-covered revision. An
        // UNSAFE line is emitted byte-for-byte — also after a compaction, whose own drops happened
        // while the line was still modelled and are therefore screen-neutral.
        func flushLine(terminator: UInt8?) {
            if !utf8Pending.isEmpty { lineUnsafe = true } // truncated scalar — width unknowable
            if lineUnsafe {
                for rev in revisions {
                    out.append(contentsOf: rev.prefix)
                    out.append(contentsOf: rev.bytes)
                }
            } else {
                let keep = keepMask(revisions)
                var carried = Carry()
                for (index, rev) in revisions.enumerated() {
                    guard keep[index] else {
                        carried.absorb(rev.carry)
                        continue
                    }
                    out.append(contentsOf: rev.prefix)
                    carried.take(into: &out)
                    out.append(contentsOf: rev.bytes)
                }
            }
            if let terminator { out.append(terminator) }
            // `LF`/`VT`/`FF` move DOWN without returning to column 0, so the next line opens where
            // this one left the cursor — known only when the surviving last revision tracked it
            // (an unmodelled line's cursor is a guess, and a guess would drop visible content).
            let last = revisions[revisions.count - 1]
            startColumn = (lineUnsafe || !last.startKnown) ? nil : last.cursor
            revisions.removeAll(keepingCapacity: true)
            revisions.append(openingRevision())
            lineUnsafe = false
            utf8Pending.removeAll(keepingCapacity: true)
            utf8Needed = 0
        }

        // Rewrites the buffered revisions to the survivors of the keep rule (memory backstop).
        func compactRevisions() {
            let keep = keepMask(revisions)
            var survivors: [Revision] = []
            survivors.reserveCapacity(revisions.count / 2 + 1)
            var carried = Carry()
            for (index, rev) in revisions.enumerated() {
                guard keep[index] else {
                    carried.absorb(rev.carry)
                    continue
                }
                var survivor = rev
                if !carried.isEmpty {
                    // Fold the carry INTO the survivor: it is zero-width, so coverage is unchanged
                    // and both the emitted bytes and a later carry stay in the original order.
                    var folded: [UInt8] = []
                    carried.take(into: &folded)
                    survivor.bytes = folded + survivor.bytes
                    survivor.carry = folded + survivor.carry
                }
                survivors.append(survivor)
            }
            revisions = survivors
        }

        // Opens a new revision at column 0 (the `CR` / `CSI G` in `prefix`).
        func startRevision(prefix: [UInt8]) {
            if lineUnsafe {
                // The line is already verbatim; splitting buys nothing and each Revision costs
                // memory that the (safe-only) compaction backstop could no longer reclaim.
                revisions[current()].bytes.append(contentsOf: prefix)
                return
            }
            var rev = Revision()
            rev.prefix = prefix
            revisions.append(rev)
            if revisions.count >= compactionThreshold { compactRevisions() }
        }

        // Appends a completed escape sequence to the current revision, classifying its effect.
        func appendSequence(_ bytes: [UInt8], carriesState: Bool = false, erase: Int? = nil) {
            let index = current()
            revisions[index].bytes.append(contentsOf: bytes)
            if carriesState { revisions[index].carry.append(contentsOf: bytes) }
            switch erase {
            case 0: // cursor → end of line, on top of what it already painted: the whole line.
                revisions[index].covers = fullCoverage
            case 1: // start of line → cursor INCLUSIVE.
                revisions[index].covers = max(revisions[index].covers, revisions[index].cursor + 1)
            case 2: // the whole line.
                revisions[index].covers = fullCoverage
            default:
                break
            }
        }

        for byte in input {
            switch state {
            case .ground:
                switch byte {
                case esc:
                    if !utf8Pending.isEmpty { lineUnsafe = true }
                    utf8Pending.removeAll(keepingCapacity: true)
                    utf8Needed = 0
                    seq = [esc]
                    state = .afterEsc
                case cr:
                    if !utf8Pending.isEmpty { lineUnsafe = true }
                    utf8Pending.removeAll(keepingCapacity: true)
                    utf8Needed = 0
                    startRevision(prefix: [cr])
                case lf:
                    flushLine(terminator: lf)
                case 0x0B,
                     0x0C: // VT / FF — a vertical motion this pass does not model.
                    lineUnsafe = true
                    flushLine(terminator: byte)
                default:
                    let index = current()
                    consumeGroundByte(
                        byte,
                        into: &revisions[index],
                        utf8Pending: &utf8Pending,
                        utf8Needed: &utf8Needed,
                        lineUnsafe: &lineUnsafe,
                    )
                }

            case .afterEsc:
                seq.append(byte)
                switch byte {
                case UInt8(ascii: "["):
                    state = .csi
                case UInt8(ascii: "]"),
                     UInt8(ascii: "P"),
                     UInt8(ascii: "X"),
                     UInt8(ascii: "^"),
                     UInt8(ascii: "_"):
                    lineUnsafe = true
                    appendSequence(seq)
                    seq.removeAll(keepingCapacity: true)
                    state = .stringBody
                case esc: // consecutive ESC — the first was a lone one; keep this as the introducer.
                    lineUnsafe = true
                    seq.removeLast()
                    appendSequence(seq)
                    seq = [esc]
                default: // a two-byte escape (IND/RI/NEL/DECSC/…) — not modelled.
                    lineUnsafe = true
                    appendSequence(seq)
                    seq.removeAll(keepingCapacity: true)
                    state = .ground
                }

            case .csi:
                seq.append(byte)
                guard (0x40...0x7E).contains(byte) else {
                    // Parameter (0x30–0x3F) or intermediate (0x20–0x2F) byte — keep accumulating.
                    if !(0x20...0x3F).contains(byte) {
                        lineUnsafe = true // malformed CSI
                        appendSequence(seq)
                        seq.removeAll(keepingCapacity: true)
                        state = .ground
                    }
                    continue
                }
                switch classifyCSI(seq) {
                case .columnZero:
                    startRevision(prefix: seq)
                case let .eraseInLine(mode):
                    appendSequence(seq, erase: mode)
                case .stateOnly:
                    appendSequence(seq, carriesState: true)
                case .unmodelled:
                    lineUnsafe = true
                    appendSequence(seq)
                }
                seq.removeAll(keepingCapacity: true)
                state = .ground

            case .stringBody:
                revisions[current()].bytes.append(byte)
                switch byte {
                case 0x07: state = .ground // BEL terminates
                case esc: state = .stringBodyEsc
                default: break
                }

            case .stringBodyEsc:
                revisions[current()].bytes.append(byte)
                state = byte == UInt8(ascii: "\\") ? .ground : .stringBody
            }
        }

        // End of stream: a dangling escape and the unterminated final line are emitted as-is.
        if !seq.isEmpty {
            lineUnsafe = true
            revisions[current()].bytes.append(contentsOf: seq)
        }
        if state == .stringBody || state == .stringBodyEsc { lineUnsafe = true }
        flushLine(terminator: nil)
        return Data(out)
    }

    // MARK: - Ground bytes

    /// Folds one non-control ground byte into `revision`, tracking display width across UTF-8
    /// scalars. A malformed sequence marks the line UNSAFE (its width — and so its coverage —
    /// would be a guess).
    private static func consumeGroundByte(
        _ byte: UInt8,
        into revision: inout Revision,
        utf8Pending: inout [UInt8],
        utf8Needed: inout Int,
        lineUnsafe: inout Bool,
    ) {
        func addWidth(_ width: Int) {
            if width > 0 { revision.paintedGlyph = true }
            revision.cursor += width
            revision.covers = max(revision.covers, revision.cursor)
        }
        revision.bytes.append(byte)
        if utf8Needed > 0 {
            guard (0x80...0xBF).contains(byte) else {
                lineUnsafe = true
                utf8Pending.removeAll(keepingCapacity: true)
                utf8Needed = 0
                return
            }
            utf8Pending.append(byte)
            utf8Needed -= 1
            guard utf8Needed == 0 else { return }
            if let scalar = decodeScalar(utf8Pending) {
                let width = TerminalScreenModel.scalarWidth(scalar)
                // A zero-width scalar attaches to the LAST printed cell; before this revision
                // has painted one, that cell belongs to a PREDECESSOR a drop would take with it.
                if width == 0, !revision.paintedGlyph { lineUnsafe = true }
                addWidth(width)
            } else {
                lineUnsafe = true
            }
            utf8Pending.removeAll(keepingCapacity: true)
            return
        }
        switch byte {
        case 0x20...0x7E:
            addWidth(1)
        case 0x7F: // DEL — ignored by a terminal, zero width.
            break
        case 0x00...0x1F: // BS/HT/BEL/… — a motion or effect this pass does not model.
            lineUnsafe = true
        case 0xC2...0xDF:
            utf8Pending = [byte]
            utf8Needed = 1
        case 0xE0...0xEF:
            utf8Pending = [byte]
            utf8Needed = 2
        case 0xF0...0xF4:
            utf8Pending = [byte]
            utf8Needed = 3
        default: // 0x80–0xC1, 0xF5–0xFF — never a valid UTF-8 lead.
            lineUnsafe = true
        }
    }

    private static func decodeScalar(_ bytes: [UInt8]) -> Unicode.Scalar? {
        var value: UInt32
        let minimum: UInt32
        switch bytes.count {
        case 2: value = UInt32(bytes[0] & 0x1F)
            minimum = 0x80
        case 3: value = UInt32(bytes[0] & 0x0F)
            minimum = 0x800
        case 4: value = UInt32(bytes[0] & 0x07)
            minimum = 0x10000
        default: return nil
        }
        for byte in bytes.dropFirst() { value = (value << 6) | UInt32(byte & 0x3F) }
        // An OVERLONG encoding is structurally complete but a terminal rejects it and paints
        // nothing — crediting it width would let a successor bury visible residue. (Surrogates and
        // out-of-range values are rejected by the `Unicode.Scalar` initializer itself.)
        guard value >= minimum else { return nil }
        return Unicode.Scalar(value)
    }

    // MARK: - CSI classification

    private enum CSIEffect {
        /// `CSI G` / `CSI 1 G` (CHA to column 1) — a revision boundary, like `CR`.
        case columnZero
        /// `CSI Ps K` (EL) — 0 = cursor→end, 1 = start→cursor, 2 = the whole line.
        case eraseInLine(mode: Int)
        /// Zero-width, position-neutral state: `SGR`, and the `?25` / `?7` toggles.
        case stateOnly
        /// Anything else — the pass cannot place the cursor afterwards.
        case unmodelled
    }

    /// Position-neutral DEC private modes: cursor visibility (DECTCEM) and autowrap (DECAWM). Every
    /// other private mode (alt screen, mouse, sync, bracketed paste) belongs to a sibling pass and
    /// is deliberately NOT modelled here.
    private static let neutralPrivateModes: Set<Int> = [7, 25]

    private static func classifyCSI(_ seq: [UInt8]) -> CSIEffect {
        guard let final = seq.last, seq.count >= 3 else { return .unmodelled }
        let params = seq[2..<(seq.count - 1)]
        let isPrivate = params.first == UInt8(ascii: "?")
        // An intermediate byte (0x20–0x2F) means a sequence outside the small set modelled here.
        guard !params.contains(where: { (0x20...0x2F).contains($0) }) else { return .unmodelled }
        let digits = isPrivate ? params.dropFirst() : params
        guard digits.allSatisfy({ (0x30...0x39).contains($0) || $0 == UInt8(ascii: ";") }) else {
            return .unmodelled
        }
        if isPrivate {
            guard final == UInt8(ascii: "h") || final == UInt8(ascii: "l") else { return .unmodelled }
            let values = splitParams(digits)
            guard !values.isEmpty, values.allSatisfy({ neutralPrivateModes.contains($0) }) else {
                return .unmodelled
            }
            return .stateOnly
        }
        switch final {
        case UInt8(ascii: "m"):
            return .stateOnly
        case UInt8(ascii: "K"):
            let values = splitParams(digits)
            let mode = values.isEmpty ? 0 : values[0]
            // EL takes ONE parameter and only modes 0–2 exist; anything else is a sequence this
            // pass has no model for.
            guard values.count <= 1, (0...2).contains(mode) else { return .unmodelled }
            return .eraseInLine(mode: mode)
        case UInt8(ascii: "G"):
            let values = splitParams(digits)
            // CHA is 1-based: an omitted or explicit 1 lands on column 0.
            return values.isEmpty || values == [1] ? .columnZero : .unmodelled
        default:
            return .unmodelled
        }
    }

    /// Splits a numeric CSI parameter run into its values. An omitted value reads as 0 (the VT
    /// default), and an over-long run yields the `[-1]` sentinel — never a modelled mode or
    /// parameter, so every caller's range check rejects it.
    private static func splitParams(_ digits: some Collection<UInt8>) -> [Int] {
        guard !digits.isEmpty else { return [] }
        var values: [Int] = []
        var accumulator = 0
        var sawDigit = false
        for byte in digits {
            if byte == UInt8(ascii: ";") {
                values.append(sawDigit ? accumulator : 0)
                accumulator = 0
                sawDigit = false
            } else {
                accumulator = accumulator * 10 + Int(byte - 0x30)
                if accumulator > 65535 { return [-1] } // absurd parameter — never a modelled mode
                sawDigit = true
            }
        }
        values.append(sawDigit ? accumulator : 0)
        return values
    }

    // MARK: - Keep rule

    /// The keep rule, as ONE function for both the final flush and mid-line compaction (the two
    /// must never drift — compaction's whole claim is that it drops exactly what the flush would).
    /// A revision survives when it is the last (the visible state), when its coverage exceeds
    /// every later revision's (suffix maximum — its tail is still on screen), or when its start
    /// column is UNKNOWN (its true span is unknowable, so no successor can be proven to bury it —
    /// not even one that erases the whole line, since the unknown paint may have wrapped rows).
    private static func keepMask(_ revisions: [Revision]) -> [Bool] {
        var keep = [Bool](repeating: false, count: revisions.count)
        keep[revisions.count - 1] = true
        var maxCoverage = revisions[revisions.count - 1].covers
        var i = revisions.count - 2
        while i >= 0 {
            if revisions[i].covers > maxCoverage || !revisions[i].startKnown { keep[i] = true }
            maxCoverage = max(maxCoverage, revisions[i].covers)
            i -= 1
        }
        return keep
    }

    // MARK: - Carry

    /// The zero-width state of DROPPED revisions, replayed ahead of the next kept one. Held as
    /// STATE rather than a byte stream so the cap cannot eat a one-shot toggle:
    /// - the `?25`/`?7` modes keep only the LAST sequence that set each (exactly the state that
    ///   replaying every toggle would end in);
    /// - `SGR` sequences accumulate in order, cleared whole by a full reset (`CSI m`, or a leading
    ///   `0` parameter), with the OLDEST discarded past ``carryCap`` — a later `SGR` overrides an
    ///   earlier one for the same attribute, so the tail is the load-bearing end. Only original
    ///   sequences are re-emitted, whole, so the carry can never exceed the bytes it absorbed.
    private struct Carry {
        /// Complete `SGR` sequences, oldest first, and their total byte count.
        private var sgr: [[UInt8]] = []
        private var sgrBytes = 0
        /// Last sequence that set mode 7 / mode 25, stamped with an arrival clock so emission
        /// preserves their relative order (one sequence may set both).
        private var toggle7: (order: Int, seq: [UInt8])?
        private var toggle25: (order: Int, seq: [UInt8])?
        private var toggleClock = 0

        var isEmpty: Bool { sgr.isEmpty && toggle7 == nil && toggle25 == nil }

        /// Splits a dropped revision's carry into its sequences and folds each into the state.
        mutating func absorb(_ carry: [UInt8]) {
            guard !carry.isEmpty else { return }
            var start = carry.startIndex
            for i in carry.indices.dropFirst() where carry[i] == LineOverprintCollapser.esc {
                fold(Array(carry[start..<i]))
                start = i
            }
            fold(Array(carry[start...]))
        }

        private mutating func fold(_ seq: [UInt8]) {
            guard let final = seq.last else { return }
            if final == UInt8(ascii: "m") {
                // `CSI params m` — a reset as the FIRST parameter (0, or none at all) kills every
                // attribute before it. A 0 deeper in the list may be a colour component
                // (`38;5;0`), so only the leading position is trusted to reset.
                let values = LineOverprintCollapser.splitParams(seq.dropFirst(2).dropLast())
                if values.isEmpty || values[0] == 0 {
                    sgr.removeAll(keepingCapacity: true)
                    sgrBytes = 0
                }
                sgr.append(seq)
                sgrBytes += seq.count
                while sgrBytes > LineOverprintCollapser.carryCap, sgr.count > 1 {
                    sgrBytes -= sgr.removeFirst().count
                }
            } else {
                // `CSI ? modes h/l` — only the final setting of each toggle is the truth.
                toggleClock += 1
                for mode in LineOverprintCollapser.splitParams(seq.dropFirst(3).dropLast()) {
                    if mode == 7 { toggle7 = (toggleClock, seq) }
                    if mode == 25 { toggle25 = (toggleClock, seq) }
                }
            }
        }

        /// Appends the carried state (`SGR` oldest-first, then the toggles) and resets.
        mutating func take(into out: inout [UInt8]) {
            for seq in sgr { out.append(contentsOf: seq) }
            switch (toggle7, toggle25) {
            case (nil, nil):
                break
            case (let only?, nil),
                 (nil, let only?):
                out.append(contentsOf: only.seq)
            case let (a?, b?) where a.order == b.order: // one sequence set both modes
                out.append(contentsOf: a.seq)
            case let (a?, b?):
                out.append(contentsOf: a.order < b.order ? a.seq : b.seq)
                out.append(contentsOf: a.order < b.order ? b.seq : a.seq)
            }
            self = Self()
        }
    }
}
