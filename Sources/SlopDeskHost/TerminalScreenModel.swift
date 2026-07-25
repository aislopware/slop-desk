import Foundation

// MARK: - TerminalScreenModel (host-side rendered-screen reconstruction)

/// A PURE in-memory VT100/xterm screen emulator — the `screen` ctl verb's engine.
///
/// The host keeps no persistent screen buffer (rendering is the client's job), so the rendered
/// screen is reconstructed ON DEMAND: replay the scrollback ring's raw bytes through this model
/// at the pane's live PTY size and dump the resulting grid. That makes a TUI pane (vim, htop,
/// claude) READABLE to an agent — `read` returns the raw byte soup a full-screen app emits,
/// `screen` returns what a human actually sees.
///
/// Scope: text placement + per-cell SGR. Implements the cursor/erase/scroll/alt-screen state
/// machine (CUP/CUU..CUB/CHA/VPA/ED/EL/ICH/DCH/ECH/IL/DL/SU/SD/REP, DECSTBM, DECOM, DECAWM with
/// deferred wrap, DECSC/DECRC, IND/RI/NEL/RIS/DECALN, alt screen 47/1047/1049, SO/SI + DEC
/// special-graphics G0/G1, UTF-8 with wide/combining width). SGR colors/attributes are tracked
/// per cell (16/256/truecolor + the flag set, BCE on erase/scroll fill) for the replay-snapshot
/// renderer; the ``snapshot()`` dump stays plain text (herdr-parity `detection_text` is
/// byte-identical to the pre-SGR model). With `scrollbackLimit > 0` the model also captures
/// lines scrolled off the top of the full-screen main region (xterm semantics: partial scroll
/// regions and the alt screen never accrue scrollback; `ED 3` clears it; oldest-out over the
/// cap). Unknown sequences are consumed and ignored (validate-then-drop: PTY bytes are
/// semi-trusted; the model never traps, never allocates beyond the fixed grid + scrollback cap).
///
/// Starting mid-stream is expected (the ring truncates oldest-first) — full-screen apps repaint,
/// so the grid converges to truth after one redraw cycle regardless of the entry point.
public struct TerminalScreenModel {
    // MARK: Cell / grid

    /// One SGR color: the terminal default, an indexed palette entry, or 24-bit RGB.
    enum SGRColor: Equatable, Sendable {
        case `default`
        case indexed(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    /// The SGR attribute state a cell was printed with (and the parser's live state between
    /// prints). Value-semantic and small — a cell stores one by copy.
    struct CellStyle: Equatable, Sendable {
        var fg: SGRColor = .default
        var bg: SGRColor = .default
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var blink = false
        var inverse = false
        var hidden = false
        var strikethrough = false

        static let plain = Self()

        /// The BCE fill style: erase/scroll fill takes the CURRENT BACKGROUND only (xterm
        /// background-color-erase) — never the foreground/flag attributes.
        var eraseFill: Self {
            var style = Self()
            style.bg = bg
            return style
        }
    }

    /// One grid cell. A wide (2-column) character occupies its lead cell plus a CONTINUATION
    /// cell that renders as nothing; overwriting either half blanks the partner.
    struct Cell: Equatable, Sendable {
        var text: String = " "
        var isContinuation = false
        var style: CellStyle = .plain
    }

    private struct Grid {
        var cells: [[Cell]]
        /// Per-row soft-wrap flag: `wrapped[r]` means row `r` overflowed INTO row `r+1` via
        /// DECAWM autowrap (the two are one logical line). Shifted with the rows by every
        /// scroll/insert/delete; a freshly-filled (blank) row is never wrapped.
        var wrapped: [Bool]
        init(rows: Int, cols: Int, fill: Cell = Cell()) {
            cells = Array(repeating: Array(repeating: fill, count: cols), count: rows)
            wrapped = Array(repeating: false, count: rows)
        }
    }

    /// Saved-cursor state (DECSC/DECRC) — one slot per screen, xterm-style.
    private struct SavedCursor {
        var row = 0
        var col = 0
        var originMode = false
        var g0Graphics = false
        var g1Graphics = false
        var usingG1 = false
        var style = CellStyle.plain
    }

    /// One line captured off the top of the full-screen main region.
    struct ScrollbackLine: Equatable, Sendable {
        var cells: [Cell]
        /// The line continues into its successor (autowrap) — the snapshot renderer re-joins
        /// the pair so the client re-wraps at its own width. Only trusted when the line is
        /// full to the last column (a stale flag on a since-rewritten short row must not
        /// merge unrelated lines).
        var softWrapped: Bool
    }

    // MARK: Public snapshot

    /// The rendered-screen dump. `lines` has exactly `rows` entries, each with trailing
    /// whitespace trimmed (the cursor may sit past a line's trimmed end). Coordinates are
    /// 0-based.
    public struct Snapshot {
        public let rows: Int
        public let cols: Int
        public let cursorRow: Int
        public let cursorCol: Int
        public let cursorVisible: Bool
        public let altScreen: Bool
        public let lines: [String]
    }

    // MARK: State

    public let rows: Int
    public let cols: Int

    private var main: Grid
    private var alt: Grid
    private var usingAlt = false

    private var cursorRow = 0
    private var cursorCol = 0
    private var cursorVisible = true
    /// DECAWM deferred wrap: writing the last column arms this; the NEXT printable wraps first.
    private var wrapPending = false
    private var autowrap = true
    private var originMode = false
    private var scrollTop = 0
    private var scrollBottom: Int

    private var savedMain = SavedCursor()
    private var savedAlt = SavedCursor()

    private var g0Graphics = false
    private var g1Graphics = false
    private var usingG1 = false

    /// The live SGR state — stamped onto every printed cell; BCE fill derives from its bg.
    private var style = CellStyle.plain

    /// DECKPAM/DECKPNM (`ESC =` / `ESC >`): application keypad mode, re-asserted by the
    /// snapshot renderer so a live TUI keeps its keypad across a reattach.
    private var applicationKeypad = false

    /// DECSCUSR (`CSI Ps SP q`) — the last cursor-shape request, 0 = terminal default.
    /// Last-wins global (not per-screen), which is exactly xterm's semantics: the shell
    /// integration's bar-at-prompt cursor must survive a state-transfer reattach.
    private var cursorShape = 0

    /// Captured scrollback (oldest-first), bounded by ``scrollbackLimit`` (0 = capture off —
    /// the default, so the resident detection grid / `screen` verb pay nothing). Stored with a
    /// dead prefix (`scrollbackHead`): per-line eviction at the cap is an index bump, not an
    /// O(cap) `removeFirst` memmove per scrolled line; the prefix is compacted in one move
    /// once it grows to the cap (amortized O(1), storage bounded at 2× the cap).
    private var scrollbackStorage: [ScrollbackLine] = []
    private var scrollbackHead = 0
    let scrollbackLimit: Int

    /// The last printed grapheme (REP repeats it; combining marks attach to its cell).
    private var lastGraphic: (text: String, width: Int)?
    private var lastCellRow = -1
    private var lastCellCol = -1

    // Parser state
    private enum ParseState {
        case ground
        case escape
        /// ESC + one intermediate collected (e.g. `(`, `)`, `#`) — the NEXT byte finishes it.
        case escapeIntermediate(UInt8)
        case csi
        /// OSC/DCS/SOS/PM/APC body — skipped to ST (`ESC \`), BEL also terminates OSC.
        case stringBody(belTerminates: Bool, sawESC: Bool)
    }

    private var state: ParseState = .ground

    // CSI accumulation (bounded: params capped in count + magnitude — validate-then-drop)
    private var csiPrivate: UInt8 = 0
    private var csiParams: [Int] = []
    /// Parallel to `csiParams`: `true` when the param was introduced by a COLON separator
    /// (an SGR sub-parameter, e.g. the `3` in `4:3`) — SGR must not read it as a top-level
    /// code, where `4:0` (underline-off) would misparse as underline + reset-all.
    private var csiColonFlags: [Bool] = []
    private var csiCurrent: Int?
    private var csiNextParamColon = false
    private var csiIntermediate: UInt8 = 0

    // UTF-8 accumulation
    private var utf8Pending: [UInt8] = []
    private var utf8Expected = 0

    // MARK: Init / feed

    public init(rows: Int, cols: Int) {
        self.init(rows: rows, cols: cols, scrollbackLimit: 0)
    }

    /// - Parameter scrollbackLimit: max captured scrollback LINES (0 = capture disabled).
    ///   The replay-snapshot composer passes a real budget; the detection grid keeps 0.
    init(rows: Int, cols: Int, scrollbackLimit: Int) {
        // Clamp to a sane grid — the callers validate, but the model itself never traps.
        self.rows = min(max(rows, 1), 512)
        self.cols = min(max(cols, 1), 1024)
        self.scrollbackLimit = min(max(scrollbackLimit, 0), 100_000)
        main = Grid(rows: self.rows, cols: self.cols)
        alt = Grid(rows: self.rows, cols: self.cols)
        scrollBottom = self.rows - 1
    }

    /// Feeds raw PTY bytes through the state machine. Stateful across calls — a sequence split
    /// over two chunks parses identically to one contiguous buffer.
    public mutating func feed(_ data: Data) {
        // Contiguous walk — `Data.Iterator` costs a per-byte call through Foundation, which is
        // real money at reattach-compose sizes (tens of MiB through this loop).
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw { consume(byte) }
        }
    }

    /// Dumps the current screen. Trailing whitespace is trimmed per line; continuation cells
    /// of wide characters contribute nothing.
    public func snapshot() -> Snapshot {
        let grid = usingAlt ? alt : main
        let lines = grid.cells.map { row -> String in
            var line = ""
            for cell in row where !cell.isContinuation {
                line += cell.text
            }
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
        return Snapshot(
            rows: rows,
            cols: cols,
            cursorRow: cursorRow,
            cursorCol: cursorCol,
            cursorVisible: cursorVisible,
            altScreen: usingAlt,
            lines: lines,
        )
    }

    // MARK: Replay snapshot (full-state dump for the snapshot renderer)

    /// Everything the replay-snapshot renderer needs to reproduce this model's visible state
    /// on a fresh terminal: attributed grids + scrollback, cursor, deferred wrap, scroll
    /// region, modes, charsets, keypad, live SGR, and the active screen's saved cursor.
    struct ReplaySnapshot: Equatable, Sendable {
        var rows: Int
        var cols: Int
        var scrollback: [ScrollbackLine]
        var mainCells: [[Cell]]
        var mainWrapped: [Bool]
        var altCells: [[Cell]]
        var usingAlt: Bool
        var cursorRow: Int
        var cursorCol: Int
        var cursorVisible: Bool
        var wrapPending: Bool
        var autowrap: Bool
        var originMode: Bool
        var scrollTop: Int
        var scrollBottom: Int
        var g0Graphics: Bool
        var g1Graphics: Bool
        var usingG1: Bool
        var applicationKeypad: Bool
        /// DECSCUSR shape (0 = terminal default — nothing re-emitted).
        var cursorShape: Int
        var style: CellStyle
        var savedCursorRow: Int
        var savedCursorCol: Int
        /// The MAIN screen's saved-cursor position (the slot `?1049h` will overwrite on
        /// entry) — only meaningful when `usingAlt` (then `savedCursorRow/Col` above are the
        /// ALT slot).
        var savedMainRow: Int
        var savedMainCol: Int
    }

    func replaySnapshot() -> ReplaySnapshot {
        let active = usingAlt ? savedAlt : savedMain
        return ReplaySnapshot(
            rows: rows,
            cols: cols,
            scrollback: Array(scrollbackStorage[scrollbackHead...]),
            mainCells: main.cells,
            mainWrapped: main.wrapped,
            altCells: alt.cells,
            usingAlt: usingAlt,
            cursorRow: cursorRow,
            cursorCol: cursorCol,
            cursorVisible: cursorVisible,
            wrapPending: wrapPending,
            autowrap: autowrap,
            originMode: originMode,
            scrollTop: scrollTop,
            scrollBottom: scrollBottom,
            g0Graphics: g0Graphics,
            g1Graphics: g1Graphics,
            usingG1: usingG1,
            applicationKeypad: applicationKeypad,
            cursorShape: cursorShape,
            style: style,
            savedCursorRow: active.row,
            savedCursorCol: active.col,
            savedMainRow: savedMain.row,
            savedMainCol: savedMain.col,
        )
    }

    // MARK: Byte pump

    private mutating func consume(_ byte: UInt8) {
        switch state {
        case .ground:
            consumeGround(byte)
        case .escape:
            consumeEscape(byte)
        case let .escapeIntermediate(intermediate):
            state = .ground
            escFinal(intermediate: intermediate, final: byte)
        case .csi:
            consumeCSI(byte)
        case let .stringBody(belTerminates, sawESC):
            consumeStringBody(byte, belTerminates: belTerminates, sawESC: sawESC)
        }
    }

    private mutating func consumeGround(_ byte: UInt8) {
        if utf8Expected > 0 {
            // Mid multi-byte scalar: a continuation byte extends it; anything else aborts
            // the partial scalar (dropped) and re-dispatches the byte.
            if byte & 0xC0 == 0x80 {
                utf8Pending.append(byte)
                utf8Expected -= 1
                if utf8Expected == 0 { flushUTF8Scalar() }
                return
            }
            utf8Pending.removeAll(keepingCapacity: true)
            utf8Expected = 0
        }
        switch byte {
        case 0x1B:
            state = .escape
        case 0x0D: // CR
            cursorCol = 0
            wrapPending = false
        case 0x0A,
             0x0B,
             0x0C: // LF / VT / FF
            lineFeed()
        case 0x08: // BS
            if cursorCol > 0 { cursorCol -= 1 }
            wrapPending = false
        case 0x09: // HT — default 8-column tab stops
            cursorCol = min(((cursorCol / 8) + 1) * 8, cols - 1)
            wrapPending = false
        case 0x0E: // SO → G1
            usingG1 = true
        case 0x0F: // SI → G0
            usingG1 = false
        case 0x00...0x1F,
             0x7F: // other C0 + DEL — ignored
            break
        case 0x20...0x7E:
            printScalar(Unicode.Scalar(byte))
        default: // 0x80+ — UTF-8 lead byte
            if byte & 0xE0 == 0xC0 { utf8Pending = [byte]
                utf8Expected = 1
            } else if byte & 0xF0 == 0xE0 { utf8Pending = [byte]
                utf8Expected = 2
            } else if byte & 0xF8 == 0xF0 { utf8Pending = [byte]
                utf8Expected = 3
            }
            // Stray continuation / invalid lead → dropped.
        }
    }

    private mutating func flushUTF8Scalar() {
        defer { utf8Pending.removeAll(keepingCapacity: true) }
        guard let text = String(bytes: utf8Pending, encoding: .utf8),
              let scalar = text.unicodeScalars.first
        else { return }
        printScalar(scalar)
    }

    private mutating func consumeEscape(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "["):
            state = .csi
            csiPrivate = 0
            csiParams.removeAll(keepingCapacity: true)
            csiColonFlags.removeAll(keepingCapacity: true)
            csiCurrent = nil
            csiNextParamColon = false
            csiIntermediate = 0
        case UInt8(ascii: "]"): // OSC
            state = .stringBody(belTerminates: true, sawESC: false)
        case UInt8(ascii: "P"),
             UInt8(ascii: "X"),
             UInt8(ascii: "^"),
             UInt8(ascii: "_"): // DCS/SOS/PM/APC
            state = .stringBody(belTerminates: false, sawESC: false)
        case UInt8(ascii: "("),
             UInt8(ascii: ")"),
             UInt8(ascii: "#"),
             UInt8(ascii: "*"),
             UInt8(ascii: "+"),
             UInt8(ascii: "%"):
            state = .escapeIntermediate(byte)
        case UInt8(ascii: "7"): // DECSC
            state = .ground
            saveCursor()
        case UInt8(ascii: "8"): // DECRC
            state = .ground
            restoreCursor()
        case UInt8(ascii: "="): // DECKPAM
            state = .ground
            applicationKeypad = true
        case UInt8(ascii: ">"): // DECKPNM
            state = .ground
            applicationKeypad = false
        case UInt8(ascii: "D"): // IND
            state = .ground
            lineFeed()
        case UInt8(ascii: "E"): // NEL
            state = .ground
            cursorCol = 0
            lineFeed()
        case UInt8(ascii: "M"): // RI
            state = .ground
            reverseIndex()
        case UInt8(ascii: "c"): // RIS
            state = .ground
            fullReset()
        case 0x1B: // ESC ESC — restart
            state = .escape
        default: // =, >, H, N, O, \, unknowns — consumed
            state = .ground
        }
    }

    private mutating func escFinal(intermediate: UInt8, final: UInt8) {
        switch intermediate {
        case UInt8(ascii: "("): // designate G0
            g0Graphics = final == UInt8(ascii: "0")
        case UInt8(ascii: ")"): // designate G1
            g1Graphics = final == UInt8(ascii: "0")
        case UInt8(ascii: "#"):
            if final == UInt8(ascii: "8") { decAlignmentTest() }
        default:
            break
        }
    }

    private mutating func consumeCSI(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            let digit = Int(byte - UInt8(ascii: "0"))
            // Clamp magnitude — a hostile parameter can't force huge loops.
            csiCurrent = min((csiCurrent ?? 0) * 10 + digit, 9999)
        case UInt8(ascii: ";"),
             UInt8(ascii: ":"):
            if csiParams.count < 32 {
                csiParams.append(csiCurrent ?? 0)
                csiColonFlags.append(csiNextParamColon)
            }
            csiCurrent = nil
            csiNextParamColon = byte == UInt8(ascii: ":")
        case UInt8(ascii: "?"),
             UInt8(ascii: ">"),
             UInt8(ascii: "<"),
             UInt8(ascii: "="):
            csiPrivate = byte
        case 0x20...0x2F: // intermediates (e.g. the space in `CSI Ps SP q`)
            csiIntermediate = byte
        case 0x40...0x7E: // final
            if let current = csiCurrent, csiParams.count < 32 {
                csiParams.append(current)
                csiColonFlags.append(csiNextParamColon)
            }
            state = .ground
            // An intermediate marks a sequence family the model consumes unmodeled — except
            // DECSCUSR (`SP q`), whose last-wins shape the snapshot renderer must re-emit.
            if csiIntermediate == 0 {
                csiDispatch(final: byte)
            } else if csiIntermediate == 0x20, byte == UInt8(ascii: "q"), csiPrivate == 0 {
                cursorShape = min(rawParam(0, default: 0), 6)
            }
        case 0x1B:
            state = .escape
        case 0x0D:
            cursorCol = 0
            wrapPending = false
        case 0x0A:
            lineFeed()
        case 0x08:
            if cursorCol > 0 { cursorCol -= 1 }
        default: // other C0 during CSI — ignored
            break
        }
    }

    private mutating func consumeStringBody(_ byte: UInt8, belTerminates: Bool, sawESC: Bool) {
        if sawESC {
            // ESC \ = ST ends the body; ESC + anything else stays in the body (xterm eats it).
            state = byte == UInt8(ascii: "\\")
                ? .ground
                : .stringBody(belTerminates: belTerminates, sawESC: false)
            return
        }
        if byte == 0x1B {
            state = .stringBody(belTerminates: belTerminates, sawESC: true)
        } else if belTerminates, byte == 0x07 {
            state = .ground
        }
    }

    // MARK: CSI dispatch

    private func param(_ index: Int, default def: Int) -> Int {
        guard index < csiParams.count else { return def }
        let value = csiParams[index]
        return value == 0 ? def : value
    }

    private func rawParam(_ index: Int, default def: Int) -> Int {
        index < csiParams.count ? csiParams[index] : def
    }

    private mutating func csiDispatch(final: UInt8) {
        switch final {
        case UInt8(ascii: "A"): // CUU
            moveCursor(rowDelta: -param(0, default: 1), colDelta: 0)
        case UInt8(ascii: "B"),
             UInt8(ascii: "e"): // CUD / VPR
            moveCursor(rowDelta: param(0, default: 1), colDelta: 0)
        case UInt8(ascii: "C"),
             UInt8(ascii: "a"): // CUF / HPR
            moveCursor(rowDelta: 0, colDelta: param(0, default: 1))
        case UInt8(ascii: "D"): // CUB
            moveCursor(rowDelta: 0, colDelta: -param(0, default: 1))
        case UInt8(ascii: "E"): // CNL
            cursorCol = 0
            moveCursor(rowDelta: param(0, default: 1), colDelta: 0)
        case UInt8(ascii: "F"): // CPL
            cursorCol = 0
            moveCursor(rowDelta: -param(0, default: 1), colDelta: 0)
        case UInt8(ascii: "G"),
             UInt8(ascii: "`"): // CHA / HPA
            cursorCol = clampCol(param(0, default: 1) - 1)
            wrapPending = false
        case UInt8(ascii: "H"),
             UInt8(ascii: "f"): // CUP / HVP
            setCursorPosition(row: param(0, default: 1) - 1, col: param(1, default: 1) - 1)
        case UInt8(ascii: "I"): // CHT
            for _ in 0..<param(0, default: 1) {
                cursorCol = min(((cursorCol / 8) + 1) * 8, cols - 1)
            }
            wrapPending = false
        case UInt8(ascii: "Z"): // CBT
            for _ in 0..<param(0, default: 1) {
                cursorCol = max(((cursorCol - 1) / 8) * 8, 0)
            }
            wrapPending = false
        case UInt8(ascii: "d"): // VPA
            let target = originMode ? scrollTop + param(0, default: 1) - 1 : param(0, default: 1) - 1
            cursorRow = clampRow(target)
            wrapPending = false
        case UInt8(ascii: "J"): // ED
            eraseInDisplay(mode: rawParam(0, default: 0))
        case UInt8(ascii: "K"): // EL
            eraseInLine(mode: rawParam(0, default: 0))
        case UInt8(ascii: "L"): // IL
            insertLines(param(0, default: 1))
        case UInt8(ascii: "M"): // DL
            deleteLines(param(0, default: 1))
        case UInt8(ascii: "P"): // DCH
            deleteChars(param(0, default: 1))
        case UInt8(ascii: "@"): // ICH
            insertChars(param(0, default: 1))
        case UInt8(ascii: "X"): // ECH
            eraseChars(param(0, default: 1))
        case UInt8(ascii: "S"): // SU
            scrollUp(param(0, default: 1))
        case UInt8(ascii: "T"): // SD
            scrollDown(param(0, default: 1))
        case UInt8(ascii: "b"): // REP
            if let last = lastGraphic {
                for _ in 0..<min(param(0, default: 1), cols * 2) { put(text: last.text, width: last.width) }
            }
        case UInt8(ascii: "r"): // DECSTBM
            setScrollRegion(top: param(0, default: 1) - 1, bottom: param(1, default: rows) - 1)
        case UInt8(ascii: "h"):
            setModes(enable: true)
        case UInt8(ascii: "l"):
            setModes(enable: false)
        case UInt8(ascii: "s"): // ANSI save cursor
            if csiPrivate == 0 { saveCursor() }
        case UInt8(ascii: "u"): // ANSI restore cursor
            if csiPrivate == 0 { restoreCursor() }
        case UInt8(ascii: "m"):
            // SGR — tracked for the replay snapshot. `CSI > m` / `CSI ? m` (modifyOtherKeys
            // etc.) are different sequences and NOT SGR.
            if csiPrivate == 0 { applySGR() }
        case UInt8(ascii: "n"),
             UInt8(ascii: "c"),
             UInt8(ascii: "t"),
             UInt8(ascii: "g"),
             UInt8(ascii: "q"):
            break // DSR / DA / window ops / TBC / DECLL — text placement unaffected
        default:
            break // unknown final — consumed
        }
    }

    // MARK: SGR

    /// Applies an SGR parameter run to the live ``style``. Colon-flagged params are SUB-params
    /// (e.g. underline style `4:3`) and never read as top-level codes; `38`/`48`/`58` consume
    /// their color arguments regardless of separator form. Unknown codes are ignored.
    private mutating func applySGR() {
        if csiParams.isEmpty {
            style = .plain // bare `CSI m` == `CSI 0 m`
            return
        }
        var i = 0
        while i < csiParams.count {
            if csiColonFlags[i] {
                i += 1 // orphan sub-param of a code we don't model (4:x, 58:…)
                continue
            }
            let code = csiParams[i]
            switch code {
            case 0: style = .plain
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 5,
                 6: style.blink = true
            case 7: style.inverse = true
            case 8: style.hidden = true
            case 9: style.strikethrough = true
            case 21: style.underline = true // xterm: doubly-underlined — render as underline
            case 22: style.bold = false
                style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 25: style.blink = false
            case 27: style.inverse = false
            case 28: style.hidden = false
            case 29: style.strikethrough = false
            case 30...37: style.fg = .indexed(UInt8(code - 30))
            case 39: style.fg = .default
            case 40...47: style.bg = .indexed(UInt8(code - 40))
            case 49: style.bg = .default
            case 90...97: style.fg = .indexed(UInt8(code - 90 + 8))
            case 100...107: style.bg = .indexed(UInt8(code - 100 + 8))
            case 38,
                 48:
                let parsed = parseSGRColor(at: i)
                if let color = parsed.color {
                    if code == 38 { style.fg = color } else { style.bg = color }
                }
                i = parsed.next
                continue
            case 58: // underline color (unmodeled) — still consume its arguments
                i = parseSGRColor(at: i).next
                continue
            default:
                break
            }
            i += 1
        }
    }

    /// Parses the extended-color arguments after a `38`/`48`/`58` at `index`.
    /// Returns the decoded color (nil for malformed/unknown subtype) and the index of the
    /// first param NOT consumed. Both wild forms decode: semicolon (`38;2;r;g;b`, strict
    /// shape) and colon (`38:2:r:g:b` / `38:2::r:g:b` with a colorspace-id — the color is
    /// the LAST three args of the colon run).
    private func parseSGRColor(at index: Int) -> (color: SGRColor?, next: Int) {
        // A colon run is self-delimiting: consume it whole regardless of validity.
        var runEnd = index + 1
        while runEnd < csiParams.count, csiColonFlags[runEnd] { runEnd += 1 }
        if runEnd > index + 1 {
            let args = Array(csiParams[(index + 1)..<runEnd])
            switch args[0] {
            case 5 where args.count >= 2 && (0...255).contains(args[1]):
                return (.indexed(UInt8(args[1])), runEnd)
            case 2 where args.count >= 4:
                let r = args[args.count - 3]
                let g = args[args.count - 2]
                let b = args[args.count - 1]
                guard (0...255).contains(r), (0...255).contains(g), (0...255).contains(b) else {
                    return (nil, runEnd)
                }
                return (.rgb(UInt8(r), UInt8(g), UInt8(b)), runEnd)
            default:
                return (nil, runEnd)
            }
        }
        // Semicolon form — consume exactly the strict shape.
        let subtype = index + 1
        guard subtype < csiParams.count else { return (nil, subtype) }
        switch csiParams[subtype] {
        case 5:
            guard subtype + 1 < csiParams.count else { return (nil, subtype + 1) }
            let value = csiParams[subtype + 1]
            guard (0...255).contains(value) else { return (nil, subtype + 2) }
            return (.indexed(UInt8(value)), subtype + 2)
        case 2:
            guard subtype + 3 < csiParams.count else { return (nil, csiParams.count) }
            let r = csiParams[subtype + 1]
            let g = csiParams[subtype + 2]
            let b = csiParams[subtype + 3]
            guard (0...255).contains(r), (0...255).contains(g), (0...255).contains(b) else {
                return (nil, subtype + 4)
            }
            return (.rgb(UInt8(r), UInt8(g), UInt8(b)), subtype + 4)
        default:
            return (nil, subtype + 1)
        }
    }

    private mutating func setModes(enable: Bool) {
        guard csiPrivate == UInt8(ascii: "?") else { return } // SM/RM (IRM etc.) unmodeled
        for mode in csiParams {
            switch mode {
            case 6: // DECOM
                originMode = enable
                setCursorPosition(row: 0, col: 0)
            case 7: // DECAWM
                autowrap = enable
                wrapPending = false
            case 25: // DECTCEM
                cursorVisible = enable
            case 47,
                 1047:
                switchScreen(toAlt: enable, saveRestoreCursor: false, clearAltOnEnter: mode == 1047)
            case 1049:
                switchScreen(toAlt: enable, saveRestoreCursor: true, clearAltOnEnter: true)
            default:
                break // mouse / bracketed-paste / kitty modes — no grid effect
            }
        }
    }

    // MARK: Screen switching / reset

    private mutating func switchScreen(toAlt: Bool, saveRestoreCursor: Bool, clearAltOnEnter: Bool) {
        guard toAlt != usingAlt else { return }
        if toAlt {
            if saveRestoreCursor { saveCursor() }
            usingAlt = true
            if clearAltOnEnter { alt = Grid(rows: rows, cols: cols, fill: blankFill()) }
            if saveRestoreCursor { setCursorPosition(row: 0, col: 0) }
        } else {
            usingAlt = false
            if saveRestoreCursor { restoreCursor() }
        }
        wrapPending = false
    }

    private mutating func fullReset() {
        main = Grid(rows: rows, cols: cols)
        alt = Grid(rows: rows, cols: cols)
        usingAlt = false
        cursorRow = 0
        cursorCol = 0
        cursorVisible = true
        wrapPending = false
        autowrap = true
        originMode = false
        scrollTop = 0
        scrollBottom = rows - 1
        g0Graphics = false
        g1Graphics = false
        usingG1 = false
        savedMain = SavedCursor()
        savedAlt = SavedCursor()
        lastGraphic = nil
        style = .plain
        applicationKeypad = false
        cursorShape = 0
        // Scrollback survives RIS (xterm: only `ED 3` erases saved lines).
    }

    // MARK: BCE fill helpers

    /// A blank cell in the CURRENT erase style (xterm background-color-erase: fills take the
    /// live background, never the other attributes).
    private func blankFill() -> Cell {
        Cell(text: " ", style: style.eraseFill)
    }

    private func blankRowCells() -> [Cell] {
        Array(repeating: blankFill(), count: cols)
    }

    private mutating func decAlignmentTest() {
        var grid = takeActiveGrid()
        for r in 0..<rows {
            for c in 0..<cols { grid.cells[r][c] = Cell(text: "E") }
        }
        setGrid(grid)
        scrollTop = 0
        scrollBottom = rows - 1
        setCursorPosition(row: 0, col: 0)
    }

    // MARK: Cursor

    private func clampRow(_ row: Int) -> Int { min(max(row, 0), rows - 1) }
    private func clampCol(_ col: Int) -> Int { min(max(col, 0), cols - 1) }

    private mutating func saveCursor() {
        let saved = SavedCursor(
            row: cursorRow, col: cursorCol, originMode: originMode,
            g0Graphics: g0Graphics, g1Graphics: g1Graphics, usingG1: usingG1,
            style: style,
        )
        if usingAlt { savedAlt = saved } else { savedMain = saved }
    }

    private mutating func restoreCursor() {
        let saved = usingAlt ? savedAlt : savedMain
        cursorRow = clampRow(saved.row)
        cursorCol = clampCol(saved.col)
        originMode = saved.originMode
        g0Graphics = saved.g0Graphics
        g1Graphics = saved.g1Graphics
        usingG1 = saved.usingG1
        style = saved.style
        wrapPending = false
    }

    private mutating func setCursorPosition(row: Int, col: Int) {
        if originMode {
            cursorRow = min(max(scrollTop + row, scrollTop), scrollBottom)
        } else {
            cursorRow = clampRow(row)
        }
        cursorCol = clampCol(col)
        wrapPending = false
    }

    private mutating func moveCursor(rowDelta: Int, colDelta: Int) {
        if rowDelta != 0 {
            // Relative vertical motion pins inside the scroll region when starting inside it.
            let top = cursorRow >= scrollTop ? scrollTop : 0
            let bottom = cursorRow <= scrollBottom ? scrollBottom : rows - 1
            cursorRow = min(max(cursorRow + rowDelta, top), bottom)
        }
        if colDelta != 0 {
            cursorCol = clampCol(cursorCol + colDelta)
        }
        wrapPending = false
    }

    private mutating func setScrollRegion(top: Int, bottom: Int) {
        let t = clampRow(top)
        let b = clampRow(bottom)
        guard t < b else { return } // degenerate region — ignored, xterm-style
        scrollTop = t
        scrollBottom = b
        setCursorPosition(row: 0, col: 0)
    }

    // MARK: Scrolling / line feed

    private mutating func lineFeed() {
        wrapPending = false
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private mutating func reverseIndex() {
        wrapPending = false
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private mutating func scrollUp(_ n: Int) {
        let count = min(max(n, 1), scrollBottom - scrollTop + 1)
        var grid = takeActiveGrid()
        // Scrollback capture (xterm): only the MAIN screen with a FULL-SCREEN scroll region
        // accrues history — a DECSTBM sub-region discards, and the alt screen never captures.
        if !usingAlt, scrollTop == 0, scrollBottom == rows - 1, scrollbackLimit > 0 {
            for r in 0..<count {
                scrollbackStorage.append(ScrollbackLine(
                    cells: grid.cells[r],
                    // The join guard: a wrap flag is only trusted on a line still FULL to its
                    // last column (a since-rewritten short row must not merge with its old
                    // continuation).
                    softWrapped: grid.wrapped[r] && rowReachesLastColumn(grid.cells[r]),
                ))
            }
            let overflow = scrollbackStorage.count - scrollbackHead - scrollbackLimit
            if overflow > 0 {
                scrollbackHead += overflow
                if scrollbackHead >= scrollbackLimit {
                    scrollbackStorage.removeFirst(scrollbackHead)
                    scrollbackHead = 0
                }
            }
        }
        for r in scrollTop...scrollBottom {
            let source = r + count
            if source <= scrollBottom {
                grid.cells[r] = grid.cells[source]
                grid.wrapped[r] = grid.wrapped[source]
            } else {
                grid.cells[r] = blankRowCells()
                grid.wrapped[r] = false
            }
        }
        setGrid(grid)
    }

    /// Whether a row's LAST column carries content — the soft-wrap join guard.
    private func rowReachesLastColumn(_ cells: [Cell]) -> Bool {
        guard let last = cells.last else { return false }
        return last != Cell()
    }

    private mutating func scrollDown(_ n: Int) {
        let count = min(max(n, 1), scrollBottom - scrollTop + 1)
        var grid = takeActiveGrid()
        for r in stride(from: scrollBottom, through: scrollTop, by: -1) {
            let source = r - count
            if source >= scrollTop {
                grid.cells[r] = grid.cells[source]
                grid.wrapped[r] = grid.wrapped[source]
            } else {
                grid.cells[r] = blankRowCells()
                grid.wrapped[r] = false
            }
        }
        setGrid(grid)
    }

    // MARK: Erase / insert / delete

    private mutating func eraseInDisplay(mode: Int) {
        var grid = takeActiveGrid()
        switch mode {
        case 0:
            eraseCells(&grid, row: cursorRow, columns: cursorCol..<cols)
            for r in (cursorRow + 1)..<rows {
                grid.cells[r] = blankRowCells()
                grid.wrapped[r] = false
            }
        case 1:
            for r in 0..<cursorRow {
                grid.cells[r] = blankRowCells()
                grid.wrapped[r] = false
            }
            eraseCells(&grid, row: cursorRow, columns: 0..<(cursorCol + 1))
        case 2,
             3:
            grid = Grid(rows: rows, cols: cols, fill: blankFill())
            // ED 3 = xterm "Erase Saved Lines". (The screen-clearing side keeps the model's
            // long-standing 2≡3 behaviour — herdr-parity pins it.)
            if mode == 3 {
                scrollbackStorage.removeAll()
                scrollbackHead = 0
            }
        default:
            break
        }
        setGrid(grid)
        wrapPending = false
    }

    private mutating func eraseInLine(mode: Int) {
        var grid = takeActiveGrid()
        switch mode {
        case 0:
            eraseCells(&grid, row: cursorRow, columns: cursorCol..<cols)
        case 1:
            eraseCells(&grid, row: cursorRow, columns: 0..<(cursorCol + 1))
        case 2:
            grid.cells[cursorRow] = blankRowCells()
        default:
            break
        }
        setGrid(grid)
        wrapPending = false
    }

    private mutating func insertLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = min(max(n, 1), scrollBottom - cursorRow + 1)
        var grid = takeActiveGrid()
        for r in stride(from: scrollBottom, through: cursorRow, by: -1) {
            let source = r - count
            if source >= cursorRow {
                grid.cells[r] = grid.cells[source]
                grid.wrapped[r] = grid.wrapped[source]
            } else {
                grid.cells[r] = blankRowCells()
                grid.wrapped[r] = false
            }
        }
        setGrid(grid)
        cursorCol = 0
        wrapPending = false
    }

    private mutating func deleteLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = min(max(n, 1), scrollBottom - cursorRow + 1)
        var grid = takeActiveGrid()
        for r in cursorRow...scrollBottom {
            let source = r + count
            if source <= scrollBottom {
                grid.cells[r] = grid.cells[source]
                grid.wrapped[r] = grid.wrapped[source]
            } else {
                grid.cells[r] = blankRowCells()
                grid.wrapped[r] = false
            }
        }
        setGrid(grid)
        cursorCol = 0
        wrapPending = false
    }

    private mutating func insertChars(_ n: Int) {
        let count = min(max(n, 1), cols - cursorCol)
        var grid = takeActiveGrid()
        var row = grid.cells[cursorRow]
        // The shift splits a wide pair at two seams — the insertion point (a blank lands between
        // the halves) and the right edge (the continuation is pushed off, the lead is not). A
        // split half blanks whole, as with erasing and overwriting.
        if row[cursorCol].isContinuation {
            if cursorCol > 0 { row[cursorCol - 1] = Cell() }
            row[cursorCol] = Cell()
        }
        if row[cols - count].isContinuation, cols - count > 0 {
            row[cols - count - 1] = Cell()
        }
        row.removeSubrange((cols - count)..<cols)
        row.insert(contentsOf: Array(repeating: blankFill(), count: count), at: cursorCol)
        grid.cells[cursorRow] = row
        setGrid(grid)
        wrapPending = false
    }

    private mutating func deleteChars(_ n: Int) {
        let count = min(max(n, 1), cols - cursorCol)
        var grid = takeActiveGrid()
        var row = grid.cells[cursorRow]
        // The deleted range can split a wide pair at either end: a lead left behind at the start,
        // or a continuation shifted onto the cursor from past the end. Both halves blank.
        if row[cursorCol].isContinuation, cursorCol > 0 {
            row[cursorCol - 1] = Cell()
        }
        if cursorCol + count < cols, row[cursorCol + count].isContinuation {
            row[cursorCol + count] = Cell()
        }
        row.removeSubrange(cursorCol..<(cursorCol + count))
        row.append(contentsOf: Array(repeating: blankFill(), count: count))
        grid.cells[cursorRow] = row
        setGrid(grid)
        wrapPending = false
    }

    private mutating func eraseChars(_ n: Int) {
        let count = min(max(n, 1), cols - cursorCol)
        var grid = takeActiveGrid()
        eraseCells(&grid, row: cursorRow, columns: cursorCol..<(cursorCol + count))
        setGrid(grid)
        wrapPending = false
    }

    private mutating func setGrid(_ grid: Grid) {
        if usingAlt { alt = grid } else { main = grid }
    }

    /// Detaches the ACTIVE grid for in-place mutation: the stored slot's buffers are released
    /// (parked on empty arrays) so the returned grid holds the ONLY reference to them —
    /// mutations then run in place instead of CoW-copying a whole row per touched cell, which
    /// is the difference between ~1 MiB/s and >50 MiB/s on the reattach compose path.
    /// Every take MUST reach ``setGrid(_:)`` before any other active-grid access.
    private mutating func takeActiveGrid() -> Grid {
        var grid: Grid
        if usingAlt {
            grid = alt
            alt.cells = []
            alt.wrapped = []
        } else {
            grid = main
            main.cells = []
            main.wrapped = []
        }
        return grid
    }

    // MARK: Printing

    private mutating func printScalar(_ scalar: Unicode.Scalar) {
        var resolved = scalar
        let graphicsActive = usingG1 ? g1Graphics : g0Graphics
        if graphicsActive, let mapped = Self.decGraphics[scalar.value] {
            resolved = mapped
        }
        let width = Self.scalarWidth(resolved)
        if width == 0 {
            attachCombining(resolved)
            return
        }
        // ASCII (the overwhelming majority of PTY output) reuses a prebuilt String — a fresh
        // `String(Character(_:))` per printed byte is a measurable slice of the compose walk.
        let text = resolved.value < 0x80
            ? Self.asciiText[Int(resolved.value)]
            : String(Character(resolved))
        put(text: text, width: width)
        lastGraphic = (text, width)
    }

    /// Single-scalar Strings for the ASCII range, indexed by scalar value.
    private static let asciiText: [String] = (0..<0x80).map {
        String(UnicodeScalar(UInt8($0)))
    }

    /// Appends a zero-width scalar (combining mark, ZWJ, variation selector) to the LAST
    /// printed cell — width stays what the base character established.
    private mutating func attachCombining(_ scalar: Unicode.Scalar) {
        guard lastCellRow >= 0, lastCellRow < rows, lastCellCol >= 0, lastCellCol < cols else { return }
        var grid = takeActiveGrid()
        grid.cells[lastCellRow][lastCellCol].text.unicodeScalars.append(scalar)
        setGrid(grid)
    }

    private mutating func put(text: String, width: Int) {
        if wrapPending, autowrap {
            wrapPending = false
            // The row being left continues into its successor — one logical line.
            markWrapped(row: cursorRow)
            cursorCol = 0
            lineFeed()
        }
        // A wide char that doesn't fit in the remaining columns wraps whole (or pins).
        if width == 2, cursorCol >= cols - 1 {
            if autowrap {
                blankCell(row: cursorRow, col: cursorCol)
                markWrapped(row: cursorRow)
                cursorCol = 0
                lineFeed()
            } else {
                cursorCol = max(cols - 2, 0)
            }
        }

        var grid = takeActiveGrid()
        clearWidePartner(&grid, row: cursorRow, col: cursorCol)
        grid.cells[cursorRow][cursorCol] = Cell(text: text, style: style)
        lastCellRow = cursorRow
        lastCellCol = cursorCol
        if width == 2, cursorCol + 1 < cols {
            clearWidePartner(&grid, row: cursorRow, col: cursorCol + 1)
            grid.cells[cursorRow][cursorCol + 1] = Cell(text: "", isContinuation: true, style: style)
        }
        setGrid(grid)

        let advance = width
        if cursorCol + advance >= cols {
            if autowrap {
                cursorCol = cols - 1
                wrapPending = true
            } else {
                cursorCol = cols - 1
            }
        } else {
            cursorCol += advance
        }
    }

    private mutating func blankCell(row: Int, col: Int) {
        var grid = takeActiveGrid()
        clearWidePartner(&grid, row: row, col: col)
        grid.cells[row][col] = blankFill()
        setGrid(grid)
    }

    /// Marks `row` as soft-wrapping into its successor on the ACTIVE grid.
    private mutating func markWrapped(row: Int) {
        guard row >= 0, row < rows else { return }
        if usingAlt { alt.wrapped[row] = true } else { main.wrapped[row] = true }
    }

    /// Erases `columns` on `row`. An erase that splits a wide pair blanks the half OUTSIDE the
    /// range too — a lone lead cell would still render two columns wide, and a lone continuation
    /// cell would render as nothing, either way disagreeing with what a terminal shows. Only the
    /// range's two edges can split a pair; interior partners are inside the range and erased anyway.
    private func eraseCells(_ grid: inout Grid, row: Int, columns: Range<Int>) {
        guard !columns.isEmpty else { return }
        clearWidePartner(&grid, row: row, col: columns.lowerBound)
        clearWidePartner(&grid, row: row, col: columns.upperBound - 1)
        let fill = blankFill()
        for col in columns {
            grid.cells[row][col] = fill
        }
    }

    /// Overwriting half a wide pair blanks the other half (no orphan continuation cells).
    private func clearWidePartner(_ grid: inout Grid, row: Int, col: Int) {
        let cell = grid.cells[row][col]
        if cell.isContinuation, col > 0 {
            grid.cells[row][col - 1] = Cell()
        } else if col + 1 < cols, grid.cells[row][col + 1].isContinuation {
            grid.cells[row][col + 1] = Cell()
        }
    }

    // MARK: Width tables

    /// DEC special-graphics (line drawing) — `ESC ( 0` maps ASCII `j…~` to box characters.
    private static let decGraphics: [UInt32: Unicode.Scalar] = [
        0x60: "\u{25C6}", // ` ◆
        0x61: "\u{2592}", // a ▒
        0x66: "\u{00B0}", // f °
        0x67: "\u{00B1}", // g ±
        0x6A: "\u{2518}", // j ┘
        0x6B: "\u{2510}", // k ┐
        0x6C: "\u{250C}", // l ┌
        0x6D: "\u{2514}", // m └
        0x6E: "\u{253C}", // n ┼
        0x6F: "\u{23BA}", // o ⎺
        0x70: "\u{23BB}", // p ⎻
        0x71: "\u{2500}", // q ─
        0x72: "\u{23BC}", // r ⎼
        0x73: "\u{23BD}", // s ⎽
        0x74: "\u{251C}", // t ├
        0x75: "\u{2524}", // u ┤
        0x76: "\u{2534}", // v ┴
        0x77: "\u{252C}", // w ┬
        0x78: "\u{2502}", // x │
        0x79: "\u{2264}", // y ≤
        0x7A: "\u{2265}", // z ≥
        0x7B: "\u{03C0}", // { π
        0x7C: "\u{2260}", // | ≠
        0x7D: "\u{00A3}", // } £
        0x7E: "\u{00B7}", // ~ ·
    ]

    /// Display width of a scalar: 0 (combining/format), 2 (East Asian wide + emoji), else 1.
    /// A pragmatic wcwidth subset — good column math for the TUIs agents actually read.
    static func scalarWidth(_ scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        // Everything below the first zero-width range (U+0300) is width 1 — the ASCII fast
        // path skips the full range cascade for the common case.
        if v < 0x0300 { return 1 }
        switch v {
        case 0x0300...0x036F,
             0x0483...0x0489,
             0x0591...0x05BD,
             0x0610...0x061A,
             0x064B...0x065F,
             0x06D6...0x06DC,
             0x0E31,
             0x0E34...0x0E3A,
             0x1AB0...0x1AFF,
             0x1DC0...0x1DFF,
             0x200B...0x200F,
             0x20D0...0x20FF,
             0xFE00...0xFE0F,
             0xFE20...0xFE2F:
            return 0
        case 0x1100...0x115F,
             0x231A...0x231B,
             0x2329...0x232A,
             0x23E9...0x23EC,
             0x25FD...0x25FE,
             0x2614...0x2615,
             0x2648...0x2653,
             0x267F,
             0x2693,
             0x26A1,
             0x26AA...0x26AB,
             0x26BD...0x26BE,
             0x26C4...0x26C5,
             0x26CE,
             0x26D4,
             0x26EA,
             0x26F2...0x26F3,
             0x26F5,
             0x26FA,
             0x26FD,
             0x2705,
             0x270A...0x270B,
             0x2728,
             0x274C,
             0x274E,
             0x2753...0x2755,
             0x2757,
             0x2795...0x2797,
             0x27B0,
             0x27BF,
             0x2B1B...0x2B1C,
             0x2B50,
             0x2B55,
             0x2E80...0x303E,
             0x3041...0x33FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xA000...0xA4CF,
             0xA960...0xA97F,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE30...0xFE4F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x1F004,
             0x1F0CF,
             0x1F18E,
             0x1F191...0x1F19A,
             0x1F200...0x1F2FF,
             0x1F300...0x1F64F,
             0x1F680...0x1F6FF,
             0x1F900...0x1F9FF,
             0x1FA70...0x1FAFF,
             0x20000...0x2FFFD,
             0x30000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}

public extension TerminalScreenModel.Snapshot {
    /// The screen text the agent-detection engine scans (herdr's `detection_text`, exact):
    /// every visible row (each already trailing-trimmed by ``TerminalScreenModel/snapshot()``,
    /// wide-char continuation cells contributing nothing), trailing blank rows dropped,
    /// `\n`-joined with one trailing `\n` — or `""` for an all-blank screen.
    var detectionText: String {
        var rows = lines
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        guard !rows.isEmpty else { return "" }
        return rows.joined(separator: "\n") + "\n"
    }
}
