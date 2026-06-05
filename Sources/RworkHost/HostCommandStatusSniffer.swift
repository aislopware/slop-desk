import Foundation
import RworkProtocol

/// A **non-destructive** sibling of ``HostTitleBellSniffer`` that observes (never consumes)
/// the host's outbound PTY byte stream and recognizes the **OSC 133** semantic command marks
/// the shell-integration shim emits (FinalTerm/iTerm2 standard — see ``ShellIntegration``):
///
/// - `OSC 133 ; C` (`ESC ] 133 ; C  <terminator>`) — the command's OUTPUT begins, i.e. a
///   command STARTED running (zsh `preexec`). Emitted as ``WireMessage/commandStatus(_:)``
///   with ``WireMessage/CommandStatus/running``.
/// - `OSC 133 ; D [; <exit> ]` — the command FINISHED (zsh `precmd` of the NEXT prompt,
///   carrying the previous command's `$?`). Emitted as `.commandStatus(.idle(...))` with the
///   parsed exit code and the **host-measured C→D duration** in milliseconds.
///
/// `A` (prompt start) and `B` (command-line start) marks are recognized by the grammar but
/// are not surfaced — running vs idle needs only C (start) and D (end), so the sniffer keeps
/// the control channel quiet for them.
///
/// ## Why host-side (and reuse this established pattern)
/// libghostty exposes NO OSC 133 callback to the embedder (its external-IO C API is only
/// `write`/`resize`/`wakeup`); it parses and swallows OSC 133 internally, so the client never
/// sees a mark. The host is the only place that sees the raw byte stream BEFORE it is framed,
/// and it already sniffs THIS stream for title/bell (``HostTitleBellSniffer``) and forwards
/// structured control events. So OSC 133 detection lands here, beside the title sniffer, and
/// the command status rides the SAME head-of-line-independent CONTROL channel — a flood of PTY
/// output on the DATA channel can never delay a `running`/`idle` event.
///
/// ## Duration is measured host-side (authoritative)
/// `runningSince` is set on `C` and the C→D wall-clock delta is the duration carried in the
/// `.idle` event. Measuring it on the host (not the client) means a slow/jittery network can
/// never inflate the figure the long-command-notification threshold compares against. The
/// `clock` is injectable so a unit test drives the duration deterministically.
///
/// ## `D` without a matching `C` is ignored (no phantom notifications)
/// The very first `precmd` runs with no preceding command, so the shim emits a `D;0` for a
/// command that never started. With no `runningSince` set, the sniffer drops that `D` — it
/// never emits a spurious `.idle` (which would otherwise be a 0-duration phantom).
///
/// ## Non-destructive + streaming-safe
/// Like ``HostTitleBellSniffer``, ``observe(_:)`` only OBSERVES: the caller forwards the
/// original bytes UNCHANGED. The OSC 133 grammar is a true byte-at-a-time state machine
/// (split-robust across chunk boundaries, stray-ESC re-entrant, capped against an
/// unterminated OSC) — the same audited grammar as ``HostTitleBellSniffer`` /
/// `TerminalModeTracker`, scoped here to the `133;…` payloads only.
///
/// `@unchecked Sendable`: mutable parser/timing state is guarded by ``lock`` (in practice it
/// is only ever called from the single serial `PTYReadLoop` `onChunk` sink, but the lock makes
/// it safe to capture in the `@Sendable` closure regardless — mirrors the title sniffer).
public final class HostCommandStatusSniffer: @unchecked Sendable {

    /// - Parameter clock: the wall-clock source for C→D duration. Injectable so a test advances
    ///   it deterministically; defaults to `Date.init` in production.
    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    private let lock = NSLock()
    private let clock: @Sendable () -> Date

    /// When the foreground command started (set on `C`, cleared on `D`); `nil` when idle.
    private var runningSince: Date?

    // MARK: Parser state (the OSC-only subset of the shared grammar)

    private enum State {
        /// Outside any escape sequence (opaque content).
        case ground
        /// Saw `ESC` (`0x1B`); waiting to classify the next byte (`]` → OSC).
        case escape
        /// Inside an OSC sequence (`ESC ]`). Collecting payload until `BEL` or `ST`.
        case osc
        /// Inside an OSC and the previous byte was `ESC` — waiting for the `\` of an `ST`
        /// terminator (`ESC \`), else a new sequence start.
        case oscEscape
        /// An over-cap OSC being DISCARDED: still inside the OSC (consume its terminator here,
        /// don't re-parse it in ground), no longer buffering. Bounded O(n).
        case oscDiscard
        /// Inside a discarded OSC and the previous byte was `ESC` (possible `ST`).
        case oscDiscardEscape
    }

    private var state: State = .ground
    /// Accumulated OSC payload bytes (without the leading `ESC ]` or the terminator). Bounded.
    private var oscBuffer: [UInt8] = []

    /// Cap on the buffered OSC payload. The marks we care about (`133;…`) are tiny; anything
    /// longer is abandoned + resynced so a hostile/unterminated OSC cannot make us buffer
    /// unboundedly or wedge the parser.
    private static let oscCap = 256

    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let rightBracket: UInt8 = 0x5D  // ']'
    private static let backslash: UInt8 = 0x5C     // '\'

    // MARK: Observe

    /// Observes a chunk of the OUTBOUND byte stream and returns the `.commandStatus` control
    /// messages detected in it, in order. **Does not modify or consume the bytes** — the caller
    /// forwards the original chunk to the client unchanged.
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
            if byte == Self.esc { state = .escape }
            // else: opaque content byte — ignore (and a ground BEL is the title sniffer's bell,
            // not ours).

        case .escape:
            switch byte {
            case Self.rightBracket:
                state = .osc
                oscBuffer.removeAll(keepingCapacity: true)
            case Self.esc:
                state = .escape // `ESC ESC` — stay, classify the second ESC.
            default:
                state = .ground // some other escape (CSI etc.) — not an OSC; ignore.
            }

        case .osc:
            switch byte {
            case Self.bel:
                finishOSC(into: &messages)
                state = .ground
            case Self.esc:
                state = .oscEscape // possible `ST` (`ESC \`).
            default:
                oscBuffer.append(byte)
                if oscBuffer.count > Self.oscCap {
                    // Overlong — abandon WITHOUT emitting a mark, but stay INSIDE the OSC so its
                    // terminator (BEL / ST) is consumed by `.oscDiscard`, not re-parsed in ground
                    // (where a following `133;C` could be misread). Bounded, no buffering.
                    oscBuffer.removeAll(keepingCapacity: true)
                    state = .oscDiscard
                }
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
                state = .ground // `ESC \` = ST terminator of the discarded OSC.
            } else {
                // Stray ESC inside the discarded OSC — re-classify as a NEW sequence's introducer.
                state = .escape
                step(byte, into: &messages)
            }

        case .oscEscape:
            if byte == Self.backslash {
                finishOSC(into: &messages) // `ESC \` = ST: OSC complete.
                state = .ground
            } else {
                // Stray ESC inside the OSC: end this OSC, then re-classify the ESC as a NEW
                // sequence's introducer (re-enter `.escape`, NOT `.ground`) so a following
                // mark's `]` is not misread as content (the audited stray-ESC fix).
                finishOSC(into: &messages)
                state = .escape
                step(byte, into: &messages)
            }
        }
    }

    // MARK: OSC handling — OSC 133 C / D only

    private func finishOSC(into messages: inout [WireMessage]) {
        defer { oscBuffer.removeAll(keepingCapacity: true) }
        let payload = String(decoding: oscBuffer, as: UTF8.self)
        // Expected: "133;A" | "133;B" | "133;C" | "133;D" | "133;D;<exit>" (+ extra ;k=v).
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
