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
/// Scope: text placement only. Implements the cursor/erase/scroll/alt-screen state machine
/// (CUP/CUU..CUB/CHA/VPA/ED/EL/ICH/DCH/ECH/IL/DL/SU/SD/REP, DECSTBM, DECOM, DECAWM with
/// deferred wrap, DECSC/DECRC, IND/RI/NEL/RIS/DECALN, alt screen 47/1047/1049, SO/SI + DEC
/// special-graphics G0/G1, UTF-8 with wide/combining width). SGR colors/attributes are parsed
/// and DISCARDED — the dump is plain text. Unknown sequences are consumed and ignored
/// (validate-then-drop: PTY bytes are semi-trusted; the model never traps, never allocates
/// beyond the fixed grid).
///
/// Starting mid-stream is expected (the ring truncates oldest-first) — full-screen apps repaint,
/// so the grid converges to truth after one redraw cycle regardless of the entry point.
public struct TerminalScreenModel {
    // MARK: Cell / grid

    /// One grid cell. A wide (2-column) character occupies its lead cell plus a CONTINUATION
    /// cell that renders as nothing; overwriting either half blanks the partner.
    private struct Cell {
        var text: String = " "
        var isContinuation = false
    }

    private struct Grid {
        var cells: [[Cell]]
        init(rows: Int, cols: Int) {
            cells = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
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
    private var csiCurrent: Int?
    private var csiIntermediate: UInt8 = 0

    // UTF-8 accumulation
    private var utf8Pending: [UInt8] = []
    private var utf8Expected = 0

    // MARK: Init / feed

    public init(rows: Int, cols: Int) {
        // Clamp to a sane grid — the callers validate, but the model itself never traps.
        self.rows = min(max(rows, 1), 512)
        self.cols = min(max(cols, 1), 1024)
        main = Grid(rows: self.rows, cols: self.cols)
        alt = Grid(rows: self.rows, cols: self.cols)
        scrollBottom = self.rows - 1
    }

    /// Feeds raw PTY bytes through the state machine. Stateful across calls — a sequence split
    /// over two chunks parses identically to one contiguous buffer.
    public mutating func feed(_ data: Data) {
        for byte in data { consume(byte) }
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
            csiCurrent = nil
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
            if csiParams.count < 32 { csiParams.append(csiCurrent ?? 0) }
            csiCurrent = nil
        case UInt8(ascii: "?"),
             UInt8(ascii: ">"),
             UInt8(ascii: "<"),
             UInt8(ascii: "="):
            csiPrivate = byte
        case 0x20...0x2F: // intermediates (e.g. the space in `CSI Ps SP q`)
            csiIntermediate = byte
        case 0x40...0x7E: // final
            if let current = csiCurrent, csiParams.count < 32 { csiParams.append(current) }
            state = .ground
            // An intermediate marks a sequence family we don't model (DECSCUSR etc.) — consumed.
            if csiIntermediate == 0 { csiDispatch(final: byte) }
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
        case UInt8(ascii: "m"),
             UInt8(ascii: "n"),
             UInt8(ascii: "c"),
             UInt8(ascii: "t"),
             UInt8(ascii: "g"),
             UInt8(ascii: "q"):
            break // SGR / DSR / DA / window ops / TBC / DECLL — text placement unaffected
        default:
            break // unknown final — consumed
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
            if clearAltOnEnter { alt = Grid(rows: rows, cols: cols) }
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
    }

    private mutating func decAlignmentTest() {
        var grid = usingAlt ? alt : main
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
        var grid = usingAlt ? alt : main
        for r in scrollTop...scrollBottom {
            let source = r + count
            grid.cells[r] = source <= scrollBottom
                ? grid.cells[source]
                : Array(repeating: Cell(), count: cols)
        }
        setGrid(grid)
    }

    private mutating func scrollDown(_ n: Int) {
        let count = min(max(n, 1), scrollBottom - scrollTop + 1)
        var grid = usingAlt ? alt : main
        for r in stride(from: scrollBottom, through: scrollTop, by: -1) {
            let source = r - count
            grid.cells[r] = source >= scrollTop
                ? grid.cells[source]
                : Array(repeating: Cell(), count: cols)
        }
        setGrid(grid)
    }

    // MARK: Erase / insert / delete

    private mutating func eraseInDisplay(mode: Int) {
        var grid = usingAlt ? alt : main
        switch mode {
        case 0:
            for c in cursorCol..<cols { grid.cells[cursorRow][c] = Cell() }
            for r in (cursorRow + 1)..<rows {
                grid.cells[r] = Array(repeating: Cell(), count: cols)
            }
        case 1:
            for r in 0..<cursorRow {
                grid.cells[r] = Array(repeating: Cell(), count: cols)
            }
            for c in 0...cursorCol { grid.cells[cursorRow][c] = Cell() }
        case 2,
             3:
            grid = Grid(rows: rows, cols: cols)
        default:
            break
        }
        setGrid(grid)
        wrapPending = false
    }

    private mutating func eraseInLine(mode: Int) {
        var grid = usingAlt ? alt : main
        switch mode {
        case 0:
            for c in cursorCol..<cols { grid.cells[cursorRow][c] = Cell() }
        case 1:
            for c in 0...cursorCol { grid.cells[cursorRow][c] = Cell() }
        case 2:
            grid.cells[cursorRow] = Array(repeating: Cell(), count: cols)
        default:
            break
        }
        setGrid(grid)
        wrapPending = false
    }

    private mutating func insertLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = min(max(n, 1), scrollBottom - cursorRow + 1)
        var grid = usingAlt ? alt : main
        for r in stride(from: scrollBottom, through: cursorRow, by: -1) {
            let source = r - count
            grid.cells[r] = source >= cursorRow
                ? grid.cells[source]
                : Array(repeating: Cell(), count: cols)
        }
        setGrid(grid)
        cursorCol = 0
        wrapPending = false
    }

    private mutating func deleteLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = min(max(n, 1), scrollBottom - cursorRow + 1)
        var grid = usingAlt ? alt : main
        for r in cursorRow...scrollBottom {
            let source = r + count
            grid.cells[r] = source <= scrollBottom
                ? grid.cells[source]
                : Array(repeating: Cell(), count: cols)
        }
        setGrid(grid)
        cursorCol = 0
        wrapPending = false
    }

    private mutating func insertChars(_ n: Int) {
        let count = min(max(n, 1), cols - cursorCol)
        var grid = usingAlt ? alt : main
        var row = grid.cells[cursorRow]
        row.removeSubrange((cols - count)..<cols)
        row.insert(contentsOf: Array(repeating: Cell(), count: count), at: cursorCol)
        grid.cells[cursorRow] = row
        setGrid(grid)
        wrapPending = false
    }

    private mutating func deleteChars(_ n: Int) {
        let count = min(max(n, 1), cols - cursorCol)
        var grid = usingAlt ? alt : main
        var row = grid.cells[cursorRow]
        row.removeSubrange(cursorCol..<(cursorCol + count))
        row.append(contentsOf: Array(repeating: Cell(), count: count))
        grid.cells[cursorRow] = row
        setGrid(grid)
        wrapPending = false
    }

    private mutating func eraseChars(_ n: Int) {
        let count = min(max(n, 1), cols - cursorCol)
        var grid = usingAlt ? alt : main
        for c in cursorCol..<(cursorCol + count) { grid.cells[cursorRow][c] = Cell() }
        setGrid(grid)
        wrapPending = false
    }

    private mutating func setGrid(_ grid: Grid) {
        if usingAlt { alt = grid } else { main = grid }
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
        put(text: String(Character(resolved)), width: width)
        lastGraphic = (String(Character(resolved)), width)
    }

    /// Appends a zero-width scalar (combining mark, ZWJ, variation selector) to the LAST
    /// printed cell — width stays what the base character established.
    private mutating func attachCombining(_ scalar: Unicode.Scalar) {
        guard lastCellRow >= 0, lastCellRow < rows, lastCellCol >= 0, lastCellCol < cols else { return }
        var grid = usingAlt ? alt : main
        grid.cells[lastCellRow][lastCellCol].text.unicodeScalars.append(scalar)
        setGrid(grid)
    }

    private mutating func put(text: String, width: Int) {
        if wrapPending, autowrap {
            wrapPending = false
            cursorCol = 0
            lineFeed()
        }
        // A wide char that doesn't fit in the remaining columns wraps whole (or pins).
        if width == 2, cursorCol >= cols - 1 {
            if autowrap {
                blankCell(row: cursorRow, col: cursorCol)
                cursorCol = 0
                lineFeed()
            } else {
                cursorCol = max(cols - 2, 0)
            }
        }

        var grid = usingAlt ? alt : main
        clearWidePartner(&grid, row: cursorRow, col: cursorCol)
        grid.cells[cursorRow][cursorCol] = Cell(text: text)
        lastCellRow = cursorRow
        lastCellCol = cursorCol
        if width == 2, cursorCol + 1 < cols {
            clearWidePartner(&grid, row: cursorRow, col: cursorCol + 1)
            grid.cells[cursorRow][cursorCol + 1] = Cell(text: "", isContinuation: true)
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
        var grid = usingAlt ? alt : main
        clearWidePartner(&grid, row: row, col: col)
        grid.cells[row][col] = Cell()
        setGrid(grid)
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
