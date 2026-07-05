import Foundation
import SlopDeskProtocol

// The HOST-side per-command "Blocks" segmenter (Warp-style). Segments the raw PTY OUTBOUND
// byte stream into per-command blocks using ONLY the OSC 133 A/B/C/D marks the live
// ``HostOutputSniffer`` already sniffs — no libghostty region-extract.
//
// This is a PURE value type. It runs as an ADDITIVE PARALLEL tap alongside the live
// ``HostOutputSniffer`` (which is unchanged): the segmenter only OBSERVES the same outbound
// chunks the sniffer sees; the byte pipeline forwards the original bytes unchanged. It is
// env-gated (`SLOPDESK_BLOCKS`, default-ON) at its call site so the byte pipeline + sniffer
// stay byte-identical when off.
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
        /// The 1-based count of `133;A` PROMPT CYCLES seen when this block's cycle began — the block's
        /// prompt-row ordinal in the terminal. Counts EVERY primary prompt start (including empty-Enter /
        /// Ctrl-C cycles that never become a block, and redraw-immune: `A` is emitted once per cycle from
        /// precmd while only the in-`$PROMPT` `B` re-fires on redraws), exactly as libghostty counts
        /// `.prompt` rows for `jump_to_prompt`. `0` = unknown (no `A` seen before the block opened).
        public var promptOrdinal: Int

        public init(
            index: Int,
            commandText: String,
            output: [UInt8],
            exitCode: Int32?,
            durationMS: UInt32?,
            complete: Bool,
            outputTruncated: Bool,
            promptOrdinal: Int = 0,
        ) {
            self.index = index
            self.commandText = commandText
            self.output = output
            self.exitCode = exitCode
            self.durationMS = durationMS
            self.complete = complete
            self.outputTruncated = outputTruncated
            self.promptOrdinal = promptOrdinal
        }
    }

    /// Per-block output cap (256 KiB). A runaway command can't blow host memory — output past
    /// the cap is dropped and the block is flagged ``CommandBlock/outputTruncated``.
    public static let defaultOutputCap = 256 * 1024

    // MARK: Construction

    private let clock: () -> Date
    private let outputCap: Int

    /// K2 auto-progress (E14/WI-3): the configured slow-command PREFIX list ("Auto Progress-Bar
    /// Commands"). EMPTY disables auto-progress entirely — no synthetic spinner is ever emitted, so the
    /// segmenter is byte-identical to the pre-E14 tap. Resolved by the owner from
    /// `SLOPDESK_AUTO_PROGRESS_COMMANDS` (host) → ``AutoProgressMatcher/builtInPrefixes`` fallback.
    private let autoProgressPrefixes: [String]

    /// - Parameters:
    ///   - clock: wall-clock source for the C→D duration. Injectable so a test advances it
    ///     deterministically; defaults to `Date.init` in production.
    ///   - outputCap: per-block output byte ceiling (defaults to ``defaultOutputCap``).
    ///   - autoProgressPrefixes: the slow-command prefix list for the synthetic OSC-9;4 spinner
    ///     (E14/K2). Defaults to `[]` (auto-progress OFF — byte-identical to the pre-E14 segmenter).
    public init(
        clock: @escaping () -> Date = { Date() },
        outputCap: Int = Self.defaultOutputCap,
        autoProgressPrefixes: [String] = [],
    ) {
        self.clock = clock
        // Validate-then-clamp: a non-positive cap would mean "capture nothing"; treat <=0 as
        // the default so a caller can never accidentally disable capture or under/overflow.
        self.outputCap = outputCap > 0 ? outputCap : Self.defaultOutputCap
        self.autoProgressPrefixes = autoProgressPrefixes
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

    /// A NON-DESTRUCTIVE snapshot of the currently-OPEN (still-running) block, or `nil` if none is
    /// open. Unlike ``finish()`` this does NOT materialize/clear the block, so the segmenter keeps
    /// accumulating its output — it lets the live tap emit a `commandBlock` METADATA update for a
    /// running command (RUNNING indicator, partial output length) without disturbing segmentation.
    /// The snapshot carries the index the block WILL receive when it closes (the next free index),
    /// `complete == false`, and a `nil` duration (it has not finished).
    public func peekOpenBlock() -> CommandBlock? {
        // Only surface a block that has actually STARTED EXECUTING — one that saw its `C` (preexec)
        // mark and is in the `.output` phase. A block still in the `.command` phase is the CURRENT
        // PROMPT waiting for input (the user is typing, or idling at the prompt), NOT a running
        // command; surfacing it would show a spurious "(no command) running…" entry that sits forever
        // at the top of the Commands / Outline panel — and, because the `B` mark re-fires on every
        // prompt redraw (see the `B` arm), one such entry per resize. A real command's block is
        // surfaced from its `C` onward, with its full `commandText` already captured.
        guard hasOpenBlock, phase == .output else { return nil }
        return CommandBlock(
            index: nextIndex,
            commandText: Self.decodeCommand(currentCommandBytes()),
            output: openOutputBytes,
            exitCode: nil,
            durationMS: nil,
            complete: false,
            outputTruncated: openOutputTruncated,
            promptOrdinal: openPromptOrdinal,
        )
    }

    /// Drains + clears the SYNTHETIC OSC-9;4 progress frames queued at the `C` / `D` marks (E14/WI-3,
    /// K2). The owner (``CommandBlockTracker``) calls this after each ``ingest`` and enqueues the
    /// frames on the CONTROL channel alongside the type-28 block metadata. Returns `[]` when
    /// auto-progress is disabled (empty prefix list) or nothing matched in this batch.
    public mutating func drainAutoProgress() -> [WireMessage] {
        defer { pendingProgress.removeAll(keepingCapacity: true) }
        return pendingProgress
    }

    // MARK: Parser state — mirrors HostOutputSniffer's OSC machine (NOT shared, NOT changed)

    private enum State {
        case ground
        case escape
        case csi
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
    /// The EXPLICIT command line reported by the `133;E` preexec mark (unescaped raw bytes), or `nil`
    /// when no explicit mark was seen for the open block — then `commandText` falls back to the echoed
    /// ``openCommandBytes``. The explicit line is immune to the line-editor redraw pollution
    /// (zsh-autosuggestions ghost text, zsh-syntax-highlighting re-colors, starship transient redraws)
    /// that made the echo-reconstructed command a soup of every glyph ever painted in the prompt region.
    /// See the `E` arm in ``finishOSC``.
    private var openCommandExplicit: [UInt8]?
    private var openOutputBytes: [UInt8] = []
    private var openOutputTruncated = false
    private var hasOpenBlock = false
    private var runningSince: Date?
    /// Running count of PRIMARY `133;A` prompt starts (kind `initial` — a `k=c`/`k=s`/`k=r` mark is a
    /// continuation / secondary / right-prompt, which libghostty does NOT count as a new prompt row).
    /// Increments once per prompt CYCLE (the shim emits `A` from precmd, so a `zle reset-prompt` redraw
    /// storm — which re-fires only the in-`$PROMPT` `B` — never inflates it), including cycles that are
    /// later discarded (empty Enter / Ctrl-C), so it stays 1:1 with the terminal's `.prompt` rows.
    private var promptCycleCount = 0
    /// ``promptCycleCount`` captured when the open block's cycle began — stamped onto the block.
    private var openPromptOrdinal = 0

    // MARK: K2 auto-progress state (E14/WI-3) — synthetic OSC-9;4 spinner for configured slow commands

    /// Whether a SYNTHETIC indeterminate spinner is currently active for the open block — so its
    /// matching clear is emitted exactly once when the block closes (and never twice).
    private var syntheticSpinnerActive = false
    /// Whether the PROGRAM drove its OWN OSC 9;4 in the open block. A real `9;4` (which the live
    /// ``HostOutputSniffer`` parses into the real type-32 `.progress`) SUPPRESSES the synthetic
    /// spinner/clear so the two never fight — the program owns the indicator then.
    private var sawRealProgressThisBlock = false
    /// The SYNTHETIC ``WireMessage/progress`` frames queued at the `C` / `D` marks, drained by
    /// ``drainAutoProgress()`` and enqueued on the CONTROL channel beside the type-28 block metadata.
    private var pendingProgress: [WireMessage] = []

    // MARK: Byte constants (verbatim from HostOutputSniffer)

    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let leftBracket: UInt8 = 0x5B // '['
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
            case Self.leftBracket:
                // CSI `ESC [ … <final 0x40–0x7E>` (SGR colour runs, cursor ops, erases). A colorized
                // command line (zsh-syntax-highlighting / fish / oh-my-zsh wrap the typed line in SGR
                // runs as you type) emits CSI in the B→C region, so the WHOLE sequence — introducer,
                // parameters, AND final byte — must be tracked and stripped from `commandText`. The old
                // code returned to ground after the introducer, leaking the `32m`/`0m` parameter+final
                // bytes as ground text. For OUTPUT the sequence is preserved verbatim (see `.csi`).
                if phase == .output {
                    appendContent(Self.esc)
                    appendContent(byte)
                }
                state = .csi
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
                // Some OTHER (non-CSI, non-OSC) escape: a 2-byte / nF escape (`ESC c`, `ESC ( B`). The two
                // consumed bytes (`ESC` + this) are part of the opaque VT stream — for OUTPUT we preserve
                // them so the captured bytes stay a faithful VT stream; for the COMMAND span they are
                // STRIPPED (the typed line carries no raw escapes we surface — `commandText` is doc-pinned
                // as OSC/escape-stripped). `appendContent` no-ops for `.idle`, so only the `.output` phase
                // preserves the ESC+byte; the guard makes the `.command` strip explicit.
                if phase == .output {
                    appendContent(Self.esc)
                    appendContent(byte)
                }
                state = .ground
            }

        case .csi:
            // CSI body: parameter / intermediate bytes (0x20–0x3F) until a FINAL byte (0x40–0x7E) ends
            // the sequence. Preserve every byte for OUTPUT (so the captured stream stays a faithful VT
            // stream — `testControlSequencesPreservedInOutput` pins this); strip ALL of it for the COMMAND
            // span. A final byte returns to ground; anything else (incl. an unexpected `ESC`, which a
            // conformant terminal treats as aborting the CSI) is handled defensively.
            if phase == .output { appendContent(byte) }
            switch byte {
            case 0x40...0x7E:
                state = .ground // final byte — CSI complete.
            case Self.esc:
                // A stray ESC inside a CSI aborts it and starts a new escape (the ESC byte we just
                // appended for OUTPUT is the abort marker — faithful to the raw stream).
                state = .escape
            default:
                break // parameter / intermediate byte — stay in the CSI body.
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
        // K2 auto-progress (E14/WI-3): NOTICE a program-emitted OSC 9;4 so the SYNTHETIC spinner stands
        // down (the program drives the badge itself; the live ``HostOutputSniffer`` emits the REAL
        // type-32 `.progress` — the segmenter only OBSERVES, it never emits the real one). Allocation-free
        // byte probe for a body of `"4"` or `"4;…"`, mirroring HostOutputSniffer's `9;4` intercept.
        if ps == "9" {
            let bodyStart = oscBuffer.index(after: sep)
            if bodyStart < oscBuffer.endIndex, oscBuffer[bodyStart] == 0x34 { // ASCII '4'
                let afterFour = oscBuffer.index(after: bodyStart)
                if afterFour == oscBuffer.endIndex || oscBuffer[afterFour] == Self.semicolon {
                    sawRealProgressThisBlock = true
                }
            }
            return
        }
        guard ps == "133" else { return } // only 133 marks segment; ignore titles / OSC 9 / 777.

        let payload = String(bytes: oscBuffer, encoding: .utf8) ?? ""
        let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 2, fields[0] == "133" else { return }

        // EXACT-PARITY guard: the live ``HostOutputSniffer`` ignores a 133 payload over 256 bytes, so a
        // >256-byte A/B/C/D mark (hostile) is dropped here too. The EXPLICIT command-line mark
        // (`133;E;<escaped-cmd>`) is the ONE exception — it legitimately carries a long command and the
        // live sniffer does NOT act on it (its `E` arm is a no-op), so it is bounded only by the general
        // 4096-byte OSC cap the `.osc` state already enforces before this point.
        if fields[1] != "E" {
            guard oscBuffer.count <= Self.cmdOscCap else { return }
        }

        switch fields[1] {
        case "A":
            // Prompt start. If a block is still open here (a stream that re-prompted without a `D`),
            // close it as incomplete ONLY if it actually STARTED EXECUTING (reached its `C`, phase
            // == .output) — a real running command interrupted by a fresh prompt (a nested shell /
            // ssh whose inner shell emits its own OSC-133). A block still in the `.command`/idle
            // phase never ran (an empty prompt, an empty Enter, a Ctrl-C line-abort): DISCARD it so
            // it leaves no phantom "(no command)" block. The incomplete close stamps the C→interrupt
            // duration so the tracker's dedup treats it as a distinct final update (else the client
            // shows it "running…" forever).
            if hasOpenBlock {
                if phase == .output {
                    let duration = runningSince.map { Self.durationMS(from: $0, to: clock()) }
                    if let open = takeOpenBlock(complete: false, durationMS: duration) {
                        completed.append(open)
                    }
                } else {
                    discardOpenBlock()
                }
            }
            phase = .idle
            // Count the new PRIMARY prompt cycle (after closing the interrupted block, which keeps ITS
            // ordinal). A `k=c`/`k=s`/`k=r` mark is a continuation/secondary/right-prompt — libghostty
            // does not start a new `.prompt` row group for those, so neither does the ordinal.
            if Self.isPrimaryPromptStart(fields) {
                promptCycleCount += 1
            }

        case "B":
            // Command start (prompt end). Distinguish a genuine NEW prompt from a PROMPT REDRAW.
            //
            // The `B` mark lives INSIDE `$PROMPT` as a zero-width sequence, so zsh reprints it on
            // every `zle reset-prompt`: the shim's own `TRAPWINCH` fires one per SIGWINCH, and a
            // remote pane resizes constantly (splits, sidebar toggles, window drags), plus starship /
            // transient-prompt hooks fire more. Such a redraw re-fires `B` while we are STILL at the
            // prompt — the open block never saw a `C`, so it is in the `.command` phase with no
            // output. That is the SAME prompt, NOT a new command. Closing the empty block as an
            // incomplete (forever-"running") phantom here is the bug that piled up "(no command)
            // running…" blocks on every resize (wrong Outline, "all loading" Commands panel).
            //
            // So a re-fired `B` in the `.command` phase just RE-ARMS the open block: discard any
            // partial command bytes (the redraw reprints PROMPT — captured as stray command bytes —
            // then re-echoes the input BUFFER, which we recapture cleanly) and keep the SAME open
            // block / index. Only a block that reached the `.output` phase (a real, executing command
            // interrupted by a fresh prompt without a `D`) is closed as incomplete before a new block
            // opens.
            if hasOpenBlock, phase == .command {
                openCommandBytes.removeAll(keepingCapacity: true)
                return
            }
            // (A `B` without a preceding `A` is tolerated — `A` only set phase to idle.)
            // As in the `A` arm: only a block that reached `.output` (a real running command
            // re-prompted without a `D`) is closed as incomplete (duration-stamped so the close is a
            // distinct update); an open block that never executed is discarded, not turned into a
            // phantom.
            if hasOpenBlock {
                if phase == .output {
                    let duration = runningSince.map { Self.durationMS(from: $0, to: clock()) }
                    if let open = takeOpenBlock(complete: false, durationMS: duration) {
                        completed.append(open)
                    }
                } else {
                    discardOpenBlock()
                }
            }
            startOpenBlock()
            phase = .command

        case "E":
            // EXPLICIT command line (slopdesk extension). The shim's `preexec` hook reports the exact
            // typed command from `$1` as `133;E;<escaped>` right BEFORE `C`, so the host does NOT
            // reconstruct it from the terminal ECHO. Echo reconstruction is unreliable under a line editor
            // that repaints the command region in place — zsh-autosuggestions ghost text, zsh-syntax-
            // highlighting re-colors, starship transient redraws — which the CSI stripper cannot undo (it
            // removes the escape sequences but keeps every printed glyph), so the echo-built commandText
            // came out as a soup of every character ever painted there. The explicit mark is immune.
            // `<escaped>` escapes `;`, `\`, ESC, BEL, CR, LF as `\xNN`, so it is a single clean field with
            // no separator / OSC-terminator bytes; ``unescapeCommand`` restores the exact command bytes.
            // Normally `E` arrives with the block already open (from `B`); tolerate a mid-stream join by
            // opening one so the following `C` still captures output against the reported command.
            if !hasOpenBlock {
                startOpenBlock()
                phase = .command
            }
            openCommandExplicit = fields.count >= 3 ? Self.unescapeCommand(fields[2]) : []

        case "C":
            // Output start. A `C` with no `B` (e.g. the very first prompt, or a stream that
            // joined mid-command) still opens a block so the OUTPUT is captured — with an empty
            // commandText. Start the duration clock here (matches the live sniffer's C→D timing).
            if !hasOpenBlock {
                startOpenBlock()
            }
            runningSince = clock()
            phase = .output
            // K2 auto-progress (E14/WI-3): synthesize an INDETERMINATE OSC-9;4 spinner when the typed
            // command matches a configured slow-command prefix AND the program has not already driven its
            // OWN 9;4 in this block. An empty prefix list disables this (matches() → false). This is the
            // host-side shell-integration auto-wrap of known slow commands.
            if !syntheticSpinnerActive,
               !sawRealProgressThisBlock,
               AutoProgressMatcher.matches(
                   commandLine: Self.decodeCommand(currentCommandBytes()),
                   prefixes: autoProgressPrefixes,
               )
            {
                pendingProgress.append(.progress(state: ProgressState.indeterminate.rawValue, percent: 0))
                syntheticSpinnerActive = true
            }

        case "D":
            // Command finished. Only close a block that actually STARTED EXECUTING — one that saw
            // its `C` (phase == .output, `runningSince` set). The zsh shim emits `D;$?` from precmd
            // on EVERY prompt cycle, INCLUDING an empty Enter or a Ctrl-C line-abort: those run
            // precmd but NOT preexec, so no `C` fired and the open block is still in the `.command`
            // phase carrying the PREVIOUS command's `$?`. Minting a "completed" phantom from that
            // (empty commandText + stale exit) piled bogus "(no command)" / red-failed rows into the
            // Commands / Outline on every empty Enter. DROP it silently — mirrors the live
            // ``HostOutputSniffer`` gating `D` on `runningSince` (:415). Discard the unexecuted open
            // block so it leaves no phantom (a following `A`/`B` opens a fresh one). A `D` with no
            // open block at all is the first-prompt phantom `D;0`.
            guard hasOpenBlock, phase == .output else {
                if hasOpenBlock { discardOpenBlock() }
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
        openCommandExplicit = nil
        openOutputBytes.removeAll(keepingCapacity: true)
        openOutputTruncated = false
        hasOpenBlock = true
        // Stamp the cycle's prompt ordinal: the count of primary `A` marks seen so far (0 = none yet —
        // a mid-stream join; the client then skips the outline jump rather than mis-landing).
        openPromptOrdinal = promptCycleCount
        // K2 auto-progress (E14/WI-3): a fresh block starts with no synthetic spinner + no observed
        // real 9;4 (suppression is strictly per-block).
        syntheticSpinnerActive = false
        sawRealProgressThisBlock = false
    }

    /// Discards the currently-open block WITHOUT emitting it and WITHOUT consuming an index — for a
    /// prompt block that never executed (an empty Enter / Ctrl-C line-abort, or an idle-prompt A/B
    /// with no `C`). Such a cycle represents NO command, so it must leave no phantom block — neither a
    /// completed one (the old `D`-arm bug) nor a forever-"running" incomplete one. Unlike
    /// ``takeOpenBlock`` it does NOT bump ``nextIndex`` (the discarded prompt claims no block index),
    /// so the next real command reuses the slot.
    private mutating func discardOpenBlock() {
        // A `.command`/idle-phase block never armed the synthetic spinner (that happens at `C`), so
        // no clear frame is owed; reset the per-block K2 flags defensively so a following block starts
        // clean.
        syntheticSpinnerActive = false
        sawRealProgressThisBlock = false
        hasOpenBlock = false
        runningSince = nil
        openCommandBytes.removeAll(keepingCapacity: true)
        openCommandExplicit = nil
        openOutputBytes.removeAll(keepingCapacity: true)
        openOutputTruncated = false
    }

    /// Materializes + clears the currently-open block, or `nil` if none is open.
    private mutating func takeOpenBlock(
        complete: Bool,
        exitCode: Int32? = nil,
        durationMS: UInt32? = nil,
    ) -> CommandBlock? {
        guard hasOpenBlock else { return nil }
        // K2 auto-progress (E14/WI-3): CLEAR a synthetic spinner when its block closes (complete OR
        // not — a `D`, or an interrupted re-prompt at `A`/`B`/`finish`), UNLESS the program drove its
        // OWN 9;4 (then the program owns the clear — its 9;4;0 / the client's command-finish handler
        // resets it). This is the per-block "double-driving" suppression the plan requires.
        if syntheticSpinnerActive, !sawRealProgressThisBlock {
            pendingProgress.append(.progress(state: ProgressState.clear.rawValue, percent: 0))
        }
        syntheticSpinnerActive = false
        sawRealProgressThisBlock = false
        let index = nextIndex
        nextIndex += 1
        let block = CommandBlock(
            index: index,
            commandText: Self.decodeCommand(currentCommandBytes()),
            output: openOutputBytes,
            exitCode: exitCode,
            durationMS: durationMS,
            complete: complete,
            outputTruncated: openOutputTruncated,
            promptOrdinal: openPromptOrdinal,
        )
        hasOpenBlock = false
        runningSince = nil
        openCommandBytes.removeAll(keepingCapacity: true)
        openCommandExplicit = nil
        openOutputBytes.removeAll(keepingCapacity: true)
        openOutputTruncated = false
        return block
    }

    // MARK: Decoding helpers

    /// The command bytes to surface for the OPEN block: the EXPLICIT preexec-reported command
    /// (``openCommandExplicit``, from the `133;E` mark) when present, else the raw echoed B→C bytes
    /// (``openCommandBytes``) as a fallback for a non-zsh shell, an older shim, or a dropped `E`.
    private func currentCommandBytes() -> [UInt8] {
        openCommandExplicit ?? openCommandBytes
    }

    /// Unescapes a `133;E` command-line field: each `\xNN` two-hex-digit escape → that byte; every other
    /// byte passes through. The shim escapes exactly `;`, `\`, ESC, BEL, CR, LF this way, so the field
    /// carries no separator / OSC-terminator bytes — here we invert it to recover the exact command bytes
    /// (multi-byte UTF-8 rides through untouched, since none of its bytes match the escaped set). Defensive:
    /// a `\` not followed by `xHH` is emitted literally (the shim never produces one, but a hostile stream
    /// might).
    private static func unescapeCommand(_ field: Substring) -> [UInt8] {
        let bytes = Array(field.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x5C, // '\'
               i + 3 < bytes.count,
               bytes[i + 1] == 0x78, // 'x'
               let hi = hexNibble(bytes[i + 2]),
               let lo = hexNibble(bytes[i + 3])
            {
                out.append(UInt8((hi << 4) | lo))
                i += 4
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    /// Whether a `133;A[;k=…]` mark starts a PRIMARY prompt (the only kind libghostty marks as a new
    /// `.prompt` row group): kind absent or `k=i`. `k=c` (continuation), `k=s` (secondary/PS2) and
    /// `k=r` (right prompt — same row as the primary) do NOT start a new prompt row, so they must not
    /// consume a prompt ordinal.
    private static func isPrimaryPromptStart(_ fields: [Substring]) -> Bool {
        for field in fields.dropFirst(2) where field.hasPrefix("k=") {
            return field == "k=i"
        }
        return true
    }

    /// One hex nibble (0–15) for an ASCII hex digit, or `nil` for a non-hex byte.
    private static func hexNibble(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: Int(byte - 0x30) // 0-9
        case 0x41...0x46: Int(byte - 0x41) + 10 // A-F
        case 0x61...0x66: Int(byte - 0x61) + 10 // a-f
        default: nil
        }
    }

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
