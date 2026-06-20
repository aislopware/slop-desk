import Foundation

// SPIKE — feasibility PoC, not wired into the live path.
//
// Question this answers: can the HOST segment the raw PTY OUTBOUND byte stream into
// per-command "Blocks" (Warp-style) using ONLY the OSC 133 A/B/C/D marks the live
// ``HostOutputSniffer`` already sniffs — without libghostty region-extract?
//
// This is a PURE, headless, ADDITIVE value-ish type. It does NOT touch the live sniffer,
// the wire, or the golden corpus; it is never instantiated on the byte pipeline. It exists
// to PROVE the segmentation, with tests, and nothing else.
//
// ## OSC 133 semantics (the shell-integration marks, FinalTerm/iTerm2)
//   - `A` = prompt start
//   - `B` = command start (= end of prompt; the user starts typing here)
//   - `C` = command OUTPUT start (the command was entered / began executing)
//   - `D[;exit[;k=v…]]` = command finished
//
// So within one A→D cycle:
//   - bytes between `B` and `C` = the typed command line (`commandText`)
//   - bytes between `C` and `D` = the command's OUTPUT (`output`)
//   - `D`'s payload carries the exit code; the host measures the C→D duration via a clock.
//
// ## 133 detection — MIRRORS ``HostOutputSniffer`` (it is NOT changed)
// We reuse the SAME byte-at-a-time OSC state machine the live sniffer runs: an `ESC ]`
// opens an OSC, a `BEL` or `ST` (`ESC \`) closes it, an over-cap OSC is discarded to its
// terminator, and DCS/SOS/PM/APC string sequences swallow their body so an embedded
// `ESC]133;…` inside such a string can NOT spoof a mark (the exact security property the
// live sniffer carries). The live machine is `private`, so the SPIKE mirrors the relevant
// subset verbatim rather than reaching into it — keeping the live path byte-identical. The
// shared 133-payload semantics (split on `;`, the 256-byte cmd cap, the exit parse) are
// duplicated here from the same source of truth.
//
// ## What it does with OUTPUT control sequences + the cap
//   - `output` is captured RAW (control sequences PRESERVED) — Blocks needs the literal VT
//     bytes to re-render or copy faithfully; stripping is a presentation concern left to the
//     consumer. (The `commandText` between B and C IS OSC-stripped: it is the typed line, and
//     any 133 marks inside it are detection bytes, not text.)
//   - A per-block output CAP (``outputCap``, default 256 KiB) bounds memory: once a block's
//     captured output hits the cap, further output bytes for that block are DROPPED (the block
//     is flagged ``outputTruncated``) — a runaway `yes` can never blow host memory. Capture
//     stops, but the A→D state machine keeps running so the block still closes cleanly on `D`.
public struct CommandBlockSegmenter {
    /// One segmented command block: a single A→D cycle (or a still-running B/C→… block).
    public struct CommandBlock: Equatable, Sendable {
        /// 0-based index in emission order within this segmenter's lifetime.
        public var index: Int
        /// The typed command line — bytes between `B` and `C`, OSC-stripped + trimmed of the
        /// trailing newline the shell echoes. Empty if the user entered a blank line.
        public var commandText: String
        /// The command's OUTPUT — raw bytes between `C` and `D` (control sequences PRESERVED),
        /// capped at ``outputCap``.
        public var output: [UInt8]
        /// The command's `$?` from the `D` payload, or `nil` if the shell did not report one.
        public var exitCode: Int32?
        /// The host-measured C→D wall-clock time in milliseconds, or `nil` while still running.
        public var durationMS: UInt32?
        /// `true` once the matching `D` arrived; `false` for a command still executing.
        public var complete: Bool
        /// `true` if ``output`` was clamped at ``outputCap`` (bytes beyond the cap dropped).
        public var outputTruncated: Bool

        public init(
            index: Int,
            commandText: String,
            output: [UInt8],
            exitCode: Int32?,
            durationMS: UInt32?,
            complete: Bool,
            outputTruncated: Bool,
        ) {
            self.index = index
            self.commandText = commandText
            self.output = output
            self.exitCode = exitCode
            self.durationMS = durationMS
            self.complete = complete
            self.outputTruncated = outputTruncated
        }
    }

    /// Per-block output cap (256 KiB). A runaway command can't blow host memory — output past
    /// the cap is dropped and the block is flagged ``CommandBlock/outputTruncated``.
    public static let defaultOutputCap = 256 * 1024

    // MARK: Construction

    private let clock: () -> Date
    private let outputCap: Int

    /// - Parameters:
    ///   - clock: wall-clock source for the C→D duration. Injectable so a test advances it
    ///     deterministically; defaults to `Date.init` in production.
    ///   - outputCap: per-block output byte ceiling (defaults to ``defaultOutputCap``).
    public init(clock: @escaping () -> Date = { Date() }, outputCap: Int = Self.defaultOutputCap) {
        self.clock = clock
        // Validate-then-clamp: a non-positive cap would mean "capture nothing"; treat <=0 as
        // the default so a caller can never accidentally disable capture or under/overflow.
        self.outputCap = outputCap > 0 ? outputCap : Self.defaultOutputCap
    }

    // MARK: One-shot convenience

    /// Segments a COMPLETE stream in one shot (a fresh segmenter). Convenience over ``ingest``
    /// + ``finish`` for a stream already fully in hand (tests, post-hoc replay-buffer scans).
    public static func segment(
        _ stream: [UInt8],
        clock: @escaping () -> Date = { Date() },
        outputCap: Int = Self.defaultOutputCap,
    ) -> [CommandBlock] {
        var seg = Self(clock: clock, outputCap: outputCap)
        var blocks = seg.ingest(stream)
        blocks.append(contentsOf: seg.finish())
        return blocks
    }

    // MARK: Incremental ingest

    /// Feeds a chunk of the OUTBOUND PTY byte stream. Returns the blocks that COMPLETED in
    /// this chunk (each closed by its `D` mark), in order. State persists across calls, so a
    /// sequence split at any byte boundary yields identical blocks to the whole stream.
    @discardableResult
    public mutating func ingest(_ bytes: [UInt8]) -> [CommandBlock] {
        var completed: [CommandBlock] = []
        for byte in bytes {
            step(byte, into: &completed)
        }
        return completed
    }

    /// Flushes any still-open block as an INCOMPLETE block (no `D` yet): the command is still
    /// running, so the caller can show its partial output. Returns `[]` if nothing is open.
    /// Call at end-of-stream; the segmenter is left ready to start a fresh block.
    public mutating func finish() -> [CommandBlock] {
        guard let open = takeOpenBlock(complete: false) else { return [] }
        return [open]
    }

    // MARK: Parser state — mirrors HostOutputSniffer's OSC machine (NOT shared, NOT changed)

    private enum State {
        case ground
        case escape
        case osc
        case oscEscape
        case oscDiscard
        case oscDiscardEscape
        case stringConsume
        case stringConsumeEscape
    }

    private var state: State = .ground
    private var oscBuffer: [UInt8] = []

    /// What span the current bytes belong to, between marks.
    private enum Phase {
        /// Outside any command: before `B`, or after a `D` and before the next `B`. Bytes
        /// here (prompts, banners) are NOT attributed to a block.
        case idle
        /// Between `B` and `C`: the user is typing the command line. Bytes → `commandText`.
        case command
        /// Between `C` and `D`: the command's output. Bytes → `output`.
        case output
    }

    private var phase: Phase = .idle

    // The block currently being assembled (opened at `B`, closed at `D`).
    private var nextIndex = 0
    private var openCommandBytes: [UInt8] = []
    private var openOutputBytes: [UInt8] = []
    private var openOutputTruncated = false
    private var hasOpenBlock = false
    private var runningSince: Date?

    // MARK: Byte constants (verbatim from HostOutputSniffer)

    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let rightBracket: UInt8 = 0x5D // ']'
    private static let backslash: UInt8 = 0x5C // '\'
    private static let dcs: UInt8 = 0x50 // 'P'
    private static let sos: UInt8 = 0x58 // 'X'
    private static let pm: UInt8 = 0x5E // '^'
    private static let apc: UInt8 = 0x5F // '_'
    private static let semicolon: UInt8 = 0x3B // ';'

    /// Title sniffer's OSC payload cap (mirrors ``HostOutputSniffer/oscCap``).
    private static let oscCap = 4096
    /// 133-path payload cap (mirrors ``HostOutputSniffer/cmdOscCap``).
    private static let cmdOscCap = 256

    // MARK: State machine (mirrors HostOutputSniffer.step — the OSC subset)

    private mutating func step(_ byte: UInt8, into completed: inout [CommandBlock]) {
        switch state {
        case .ground:
            switch byte {
            case Self.esc:
                state = .escape
            default:
                // Opaque content byte — attribute it to the current span.
                appendContent(byte)
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
                // DCS/SOS/PM/APC string sequence — swallow the body so an embedded `ESC]133;…`
                // can never spoof a mark (the live sniffer's security property). The introducer
                // bytes are NOT content.
                state = .stringConsume
            case Self.esc:
                state = .escape
            default:
                // Some other escape (CSI `ESC[`, a 2-byte escape). Not an OSC. The two consumed
                // bytes (`ESC` + this) are part of the opaque VT stream — for OUTPUT we preserve
                // them so the captured bytes stay a faithful VT stream; for the COMMAND span they
                // are stripped (the typed line carries no raw escapes we surface).
                appendContent(Self.esc)
                appendContent(byte)
                state = .ground
            }

        case .osc:
            switch byte {
            case Self.bel:
                finishOSC(into: &completed)
                state = .ground
            case Self.esc:
                state = .oscEscape
            default:
                oscBuffer.append(byte)
                if oscBuffer.count > Self.oscCap {
                    oscBuffer.removeAll(keepingCapacity: true)
                    state = .oscDiscard
                }
            }

        case .oscEscape:
            if byte == Self.backslash {
                finishOSC(into: &completed)
                state = .ground
            } else {
                finishOSC(into: &completed)
                state = .escape
                step(byte, into: &completed)
            }

        case .oscDiscard:
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
                state = .ground
            } else {
                state = .escape
                step(byte, into: &completed)
            }

        case .stringConsume:
            switch byte {
            case Self.bel:
                state = .ground
            case Self.esc:
                state = .stringConsumeEscape
            default:
                break // opaque string-body byte — swallowed, never attributed.
            }

        case .stringConsumeEscape:
            switch byte {
            case Self.backslash:
                state = .ground
            case Self.esc:
                state = .stringConsumeEscape
            default:
                state = .stringConsume
            }
        }
    }

    /// Routes one opaque content byte to the current span's buffer (command / output / idle).
    private mutating func appendContent(_ byte: UInt8) {
        switch phase {
        case .idle:
            break // prompt / banner / between-command bytes — not part of any block.
        case .command:
            // Command line is small by nature; reuse the same 256-byte 133 cap as a sane
            // bound so a pathological no-`C` stream can't grow it unboundedly.
            if openCommandBytes.count < Self.cmdOscCap {
                openCommandBytes.append(byte)
            }
        case .output:
            if openOutputBytes.count < outputCap {
                openOutputBytes.append(byte)
            } else {
                openOutputTruncated = true
            }
        }
    }

    // MARK: OSC dispatch — the 133 A/B/C/D marks (mirrors HostOutputSniffer.finishOSC's 133 arm)

    private mutating func finishOSC(into completed: inout [CommandBlock]) {
        defer { oscBuffer.removeAll(keepingCapacity: true) }
        guard let sep = oscBuffer.firstIndex(of: Self.semicolon) else { return }
        let psBytes = oscBuffer[oscBuffer.startIndex..<sep]
        let ps = String(bytes: psBytes, encoding: .utf8) ?? ""
        guard ps == "133" else { return } // only 133 marks segment; ignore titles / OSC 9 / 777.

        // EXACT-PARITY guard: the live sniffer ignores a 133 payload over 256 bytes.
        guard oscBuffer.count <= Self.cmdOscCap else { return }
        let payload = String(bytes: oscBuffer, encoding: .utf8) ?? ""
        let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 2, fields[0] == "133" else { return }

        switch fields[1] {
        case "A":
            // Prompt start. If a block is somehow still open here (a malformed stream that
            // re-prompted without a `D`), close it as incomplete first so we never lose it.
            if hasOpenBlock, let open = takeOpenBlock(complete: false) {
                completed.append(open)
            }
            phase = .idle

        case "B":
            // Command start. Open a fresh block; subsequent ground bytes are the typed line.
            // (A `B` without a preceding `A` is tolerated — `A` only set phase to idle.)
            if hasOpenBlock, let open = takeOpenBlock(complete: false) {
                completed.append(open)
            }
            startOpenBlock()
            phase = .command

        case "C":
            // Output start. A `C` with no `B` (e.g. the very first prompt, or a stream that
            // joined mid-command) still opens a block so the OUTPUT is captured — with an empty
            // commandText. Start the duration clock here (matches the live sniffer's C→D timing).
            if !hasOpenBlock {
                startOpenBlock()
            }
            runningSince = clock()
            phase = .output

        case "D":
            // Command finished. A `D` with no open block is the first-prompt phantom `D;0`
            // (or a `D` with no matching `C`) — drop it, exactly like the live sniffer ignores
            // a `D` with no `runningSince`.
            guard hasOpenBlock else {
                phase = .idle
                return
            }
            let exit = Self.parseExit(fields)
            let duration: UInt32? = runningSince.map { Self.durationMS(from: $0, to: clock()) }
            runningSince = nil
            if let block = takeOpenBlock(complete: true, exitCode: exit, durationMS: duration) {
                completed.append(block)
            }
            phase = .idle

        default:
            break // unknown 133 subcommand — not a segmentation mark.
        }
    }

    // MARK: Open-block lifecycle

    private mutating func startOpenBlock() {
        openCommandBytes.removeAll(keepingCapacity: true)
        openOutputBytes.removeAll(keepingCapacity: true)
        openOutputTruncated = false
        hasOpenBlock = true
    }

    /// Materializes + clears the currently-open block, or `nil` if none is open.
    private mutating func takeOpenBlock(
        complete: Bool,
        exitCode: Int32? = nil,
        durationMS: UInt32? = nil,
    ) -> CommandBlock? {
        guard hasOpenBlock else { return nil }
        let index = nextIndex
        nextIndex += 1
        let block = CommandBlock(
            index: index,
            commandText: Self.decodeCommand(openCommandBytes),
            output: openOutputBytes,
            exitCode: exitCode,
            durationMS: durationMS,
            complete: complete,
            outputTruncated: openOutputTruncated,
        )
        hasOpenBlock = false
        runningSince = nil
        openCommandBytes.removeAll(keepingCapacity: true)
        openOutputBytes.removeAll(keepingCapacity: true)
        openOutputTruncated = false
        return block
    }

    // MARK: Decoding helpers

    /// Decodes the typed command line: strict UTF-8 (drops a hostile non-UTF-8 line to "",
    /// matching the live sniffer's `String(bytes:encoding:) ?? ""` idiom) with the
    /// shell-echoed trailing CR/LF stripped.
    private static func decodeCommand(_ bytes: [UInt8]) -> String {
        var trimmed = bytes[...]
        while let last = trimmed.last, last == 0x0A || last == 0x0D {
            trimmed = trimmed.dropLast()
        }
        return String(bytes: trimmed, encoding: .utf8) ?? ""
    }

    /// Parses the optional exit code from `133;D[;<exit>[;k=v…]]` (field[2], tolerating a
    /// trailing `=value`), clamped to `Int32`. (Mirrors ``HostOutputSniffer/parseExit``.)
    private static func parseExit(_ fields: [Substring]) -> Int32? {
        guard fields.count >= 3 else { return nil }
        let raw = fields[2].split(separator: "=").first.map(String.init) ?? String(fields[2])
        guard let value = Int(raw) else { return nil }
        return Int32(truncatingIfNeeded: value)
    }

    /// The non-negative C→D duration in ms (clamped at 0). (Mirrors ``HostOutputSniffer/durationMS``.)
    private static func durationMS(from start: Date, to end: Date) -> UInt32 {
        let seconds = end.timeIntervalSince(start)
        // Keep separate `*` then `.rounded()` — do NOT fuse (golden-math convention).
        let ms = (seconds * 1000).rounded()
        guard ms > 0 else { return 0 }
        return ms >= Double(UInt32.max) ? UInt32.max : UInt32(ms)
    }
}
