import Foundation

// MARK: - TerminalInputModeStripper (replay hygiene: history must not arm the client's input reporting)

/// Strips INPUT-AFFECTING terminal mode changes from a scrollback REPLAY stream and reports the
/// net final state so the caller can re-assert it AFTER the replay.
///
/// ## Why
/// Replayed history is executed by the client terminal like live output. A prior life's TUI
/// (`nvim`, `claude`) enabled mouse tracking (`?1000–1006h`), in-band resize (`?2048h`), and kitty
/// keyboard reporting (`CSI > flags u`) near the START of its run and disabled them near the END —
/// megabytes apart. During the seconds the replay takes to render, the client terminal is
/// transiently armed exactly as the TUI left it: enabling `?2048h` makes it emit an in-band size
/// report (`CSI 48;…t`) IMMEDIATELY, and any user scroll / click / keystroke mid-replay emits SGR
/// mouse reports / kitty release events. All of that rides the wire back as PTY *input* to a shell
/// sitting at a plain prompt — the `zsh: command not found: 18M65…` reattach garbage this type
/// fixes. The matching disables arrive later in the replay, too late.
///
/// The fix: mode changes are removed from the replayed bytes entirely, and only the NET final
/// state (what a terminal replaying the stream would end at) is re-asserted after the replay via
/// ``InputModeFinalState/reassertSequence``. A session whose TUIs all exited nets to all-off —
/// nothing is emitted, nothing is ever armed. A session still INSIDE a TUI nets to that TUI's
/// modes — the single trailing re-assert restores them, so a live `vim` keeps its mouse across a
/// cold reattach (re-asserting `?2048h` also makes the client send one fresh size report, which is
/// exactly what a live in-band-resize consumer wants after a reattach).
///
/// ## Scope
/// Stripped (the set that changes what the CLIENT SENDS): DECCKM `?1`, mouse `?9/1000/1001/1002/
/// 1003/1005/1006/1015/1016`, focus `?1004`, bracketed paste `?2004`, color-scheme notifications
/// `?2031` (report-on-enable, like 2048), in-band resize `?2048`, and the kitty keyboard ops
/// `CSI > flags u` (push) / `CSI < n u` (pop) / `CSI = flags ; mode u` (set). Display state
/// (alt-screen `?1049`, cursor `?25`, autowrap `?7`, sync `?2026`…) passes through untouched —
/// the replay needs it to render. A DECSET with MIXED params (`?1049;2004h`) is rewritten to
/// keep the non-stripped params.
///
/// ## Where it runs
/// ONLY on the replay-side transform (``ScrollbackReplayTransform``), FIRST — on the raw stream,
/// before the distiller: the net state must be computed in true chronological order, and the
/// distiller reorders it (an open B→C span's bytes are flushed out of sequence or replaced by the
/// committed command line). The un-acked live tail is NEVER touched (byte-exact resume) — a mode
/// change there is at most milliseconds of transient arming, and its consumer may genuinely be
/// alive.
///
/// The kitty simulation uses a single stack (the real protocol keeps one per main/alt screen);
/// pushes and pops in replayed history overwhelmingly balance out per TUI run, and a live TUI's
/// net entries are re-asserted onto whichever screen the replay ends on — the one that TUI is on.
///
/// PURE + `nonisolated`, mirroring ``TerminalQueryStripper`` (the codebase's "mirror, don't
/// share" convention for these small VT machines).
enum TerminalInputModeStripper {
    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07

    /// DEC private modes whose set/reset is stripped from replay and tracked for re-assert.
    /// 2031 (color-scheme notifications) is in the set for the same reason as 2048: the terminal
    /// emits a report (`CSI ? 997 ; 1|2 n`) the instant the mode is set.
    static let trackedModes: Set<Int> = [
        1, 9, 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1015, 1016, 2004, 2031, 2048,
    ]

    /// Returns `data` with the tracked sequences removed, plus the net final state a terminal
    /// replaying `data` would end at. A truncated trailing sequence passes through unchanged
    /// (mirrors the query stripper: a ring head-cut artifact is display noise).
    static func strip(_ data: Data) -> (data: Data, state: InputModeFinalState) {
        let bytes = [UInt8](data)
        var out = Data(capacity: bytes.count)
        var state = InputModeFinalState()
        var i = 0
        let n = bytes.count

        while i < n {
            let b = bytes[i]
            guard b == esc, i + 1 < n else {
                out.append(b)
                i += 1
                continue
            }
            switch bytes[i + 1] {
            case UInt8(ascii: "["): // CSI
                guard let seq = parseCSI(bytes, at: i) else {
                    out.append(contentsOf: bytes[i...]) // truncated — passthrough
                    i = n
                    continue
                }
                if let rewritten = process(seq, state: &state) {
                    out.append(rewritten)
                } else {
                    out.append(contentsOf: bytes[i..<seq.end])
                }
                i = seq.end
            case UInt8(ascii: "]"), // OSC — kept whole; body must not be parsed as CSI
                 UInt8(ascii: "P"), // DCS
                 UInt8(ascii: "X"), // SOS
                 UInt8(ascii: "^"), // PM
                 UInt8(ascii: "_"): // APC
                let belTerminates = bytes[i + 1] == UInt8(ascii: "]")
                guard let end = stringSequenceEnd(bytes, bodyStart: i + 2, belTerminates: belTerminates) else {
                    out.append(contentsOf: bytes[i...])
                    i = n
                    continue
                }
                out.append(contentsOf: bytes[i..<end])
                i = end
            default: // any other ESC pair — keep
                out.append(contentsOf: bytes[i...(i + 1)])
                i += 2
            }
        }
        return (out, state)
    }

    // MARK: CSI

    private struct CSISequence {
        let params: ArraySlice<UInt8> // 0x30–0x3F (digits ; : < = > ?)
        let intermediates: ArraySlice<UInt8> // 0x20–0x2F
        let final: UInt8 // 0x40–0x7E
        let end: Int // index just past the final byte
    }

    private static func parseCSI(_ bytes: [UInt8], at start: Int) -> CSISequence? {
        var j = start + 2
        let paramsStart = j
        while j < bytes.count, (0x30...0x3F).contains(bytes[j]) {
            j += 1
        }
        let intersStart = j
        while j < bytes.count, (0x20...0x2F).contains(bytes[j]) {
            j += 1
        }
        guard j < bytes.count, (0x40...0x7E).contains(bytes[j]) else { return nil }
        return CSISequence(
            params: bytes[paramsStart..<intersStart],
            intermediates: bytes[intersStart..<j],
            final: bytes[j],
            end: j + 1,
        )
    }

    /// Applies one CSI to the tracked state. Returns `nil` to KEEP the sequence verbatim,
    /// an empty `Data` to DROP it, or a rewritten sequence (mixed-param DECSET keeping only the
    /// non-stripped params).
    private static func process(_ seq: CSISequence, state: inout InputModeFinalState) -> Data? {
        guard seq.intermediates.isEmpty else { return nil } // `$p`, `SP q`… — never ours
        switch seq.final {
        case UInt8(ascii: "h"),
             UInt8(ascii: "l"):
            guard seq.params.first == UInt8(ascii: "?") else { return nil } // ANSI SM/RM — keep
            let isSet = seq.final == UInt8(ascii: "h")
            var kept: [Substring] = []
            var touched = false
            // Same lossy split discipline as the query stripper / mode tracker.
            // swiftlint:disable:next optional_data_string_conversion
            for field in String(decoding: seq.params.dropFirst(), as: UTF8.self).split(separator: ";") {
                if let mode = Int(field), trackedModes.contains(mode) {
                    state.apply(mode: mode, enabled: isSet)
                    touched = true
                } else {
                    kept.append(field)
                }
            }
            if !touched { return nil }
            if kept.isEmpty { return Data() }
            return Data("\u{1B}[?\(kept.joined(separator: ";"))\(isSet ? "h" : "l")".utf8)
        case UInt8(ascii: "s"),
             UInt8(ascii: "r"):
            // XTSAVE / XTRESTORE (`CSI ? Pm s|r`) — a save/restore DOOR into the tracked modes
            // that bypasses h/l: replaying a raw `?1000s … ?1000r` pair can re-arm mouse
            // reporting mid-replay (the exact garbage-input class this type exists to strip),
            // and an untracked restore desyncs the net-state simulation. Same strip/rewrite
            // discipline as h/l. A NON-`?` final here is DECSTBM (`r`) / SCOSC-DECSLRM (`s`) —
            // display state, kept verbatim via the guard.
            guard seq.params.first == UInt8(ascii: "?") else { return nil }
            let isSave = seq.final == UInt8(ascii: "s")
            var kept: [Substring] = []
            var touched = false
            // swiftlint:disable:next optional_data_string_conversion
            for field in String(decoding: seq.params.dropFirst(), as: UTF8.self).split(separator: ";") {
                if let mode = Int(field), trackedModes.contains(mode) {
                    if isSave { state.save(mode: mode) } else { state.restore(mode: mode) }
                    touched = true
                } else {
                    kept.append(field)
                }
            }
            if !touched { return nil }
            if kept.isEmpty { return Data() }
            return Data("\u{1B}[?\(kept.joined(separator: ";"))\(isSave ? "s" : "r")".utf8)
        case UInt8(ascii: "u"):
            switch seq.params.first {
            case UInt8(ascii: ">"): // kitty push
                state.kittyPush(flags: leadingInt(seq.params.dropFirst()) ?? 0)
                return Data()
            case UInt8(ascii: "<"): // kitty pop
                state.kittyPop(count: leadingInt(seq.params.dropFirst()) ?? 1)
                return Data()
            case UInt8(ascii: "="): // kitty set-current
                let fields = seq.params.dropFirst().split(separator: UInt8(ascii: ";"))
                state.kittySet(
                    flags: fields.first.flatMap(leadingInt) ?? 0,
                    mode: fields.dropFirst().first.flatMap(leadingInt) ?? 1,
                )
                return Data()
            default:
                return nil // `?u` query (query stripper's business), bare `u`… — keep
            }
        default:
            return nil
        }
    }

    private static func leadingInt(_ bytes: ArraySlice<UInt8>) -> Int? {
        var value = 0
        var seen = false
        for b in bytes {
            guard (0x30...0x39).contains(b) else { break }
            value = value * 10 + Int(b - 0x30)
            seen = true
        }
        return seen ? value : nil
    }

    /// Scans a string sequence's body from `bodyStart` to just past its terminator. OSC accepts
    /// BEL or ST (`ESC \`); DCS/SOS/PM/APC only ST. `nil` when the buffer ends unterminated.
    private static func stringSequenceEnd(_ bytes: [UInt8], bodyStart: Int, belTerminates: Bool) -> Int? {
        var j = bodyStart
        while j < bytes.count {
            if belTerminates, bytes[j] == bel { return j + 1 }
            if bytes[j] == esc, j + 1 < bytes.count, bytes[j + 1] == UInt8(ascii: "\\") {
                return j + 2
            }
            j += 1
        }
        return nil
    }
}

// MARK: - InputModeFinalState

/// The net input-mode state at the end of a replayed stream — what a terminal executing the raw
/// history would have been left with. ``reassertSequence`` re-creates exactly that state in a
/// fresh terminal (empty when everything nets to defaults, the common all-TUIs-exited case).
struct InputModeFinalState: Equatable {
    /// Tracked DEC private modes seen in the stream: mode → last set/reset. Modes never seen
    /// are absent (fresh-terminal default, off).
    private(set) var modes: [Int: Bool] = [:]

    /// Kitty keyboard stack simulation: `base` is the flags value with an empty stack (mutable
    /// via `CSI = flags u`), `stack` holds pushed entries bottom-to-top.
    private(set) var kittyBase = 0
    private(set) var kittyStack: [Int] = []

    mutating func apply(mode: Int, enabled: Bool) {
        modes[mode] = enabled
    }

    /// XTSAVE/XTRESTORE slots for the tracked modes (`CSI ? Pm s` / `CSI ? Pm r`). A restore
    /// with no prior save yields the fresh-terminal default (off) — xterm's initial-value
    /// semantics.
    private(set) var savedModes: [Int: Bool] = [:]

    mutating func save(mode: Int) {
        savedModes[mode] = modes[mode] ?? false
    }

    mutating func restore(mode: Int) {
        modes[mode] = savedModes[mode] ?? false
    }

    /// Simulation cap on the kitty stack depth (kitty itself caps the stack; entries pushed
    /// beyond the cap are dropped rather than growing unboundedly on a hostile stream).
    private static let stackCap = 32

    mutating func kittyPush(flags: Int) {
        guard kittyStack.count < Self.stackCap else { return }
        kittyStack.append(flags)
    }

    mutating func kittyPop(count: Int) {
        kittyStack.removeLast(Swift.min(Swift.max(count, 0), kittyStack.count))
    }

    mutating func kittySet(flags: Int, mode: Int) {
        let current = kittyStack.last ?? kittyBase
        let updated =
            switch mode {
            case 2: current | flags
            case 3: current & ~flags
            default: flags
            }
        if kittyStack.isEmpty {
            kittyBase = updated
        } else {
            kittyStack[kittyStack.count - 1] = updated
        }
    }

    /// TRUE when the state is a fresh terminal's default — nothing to re-assert.
    var isNeutral: Bool {
        kittyBase == 0 && kittyStack.isEmpty && !modes.values.contains(true)
    }

    /// The byte sequence that re-creates this state in a FRESH terminal: one DECSET per mode that
    /// nets ON (ascending, the order apps enable them), then the kitty base/pushes. Modes that net
    /// OFF emit nothing — a fresh terminal is already off, and an unmatched reset is harmless
    /// noise this transform exists to remove.
    var reassertSequence: Data {
        var out = Data()
        for (mode, enabled) in modes.sorted(by: { $0.key < $1.key }) where enabled {
            out.append(Data("\u{1B}[?\(mode)h".utf8))
        }
        if kittyBase != 0 {
            out.append(Data("\u{1B}[=\(kittyBase);1u".utf8))
        }
        for flags in kittyStack {
            out.append(Data("\u{1B}[>\(flags)u".utf8))
        }
        return out
    }
}
