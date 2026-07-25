import Foundation

// MARK: - TerminalSnapshotRenderer (cold-reattach state-transfer: render the model, not the history)

/// Renders a ``TerminalScreenModel/ReplaySnapshot`` into the MINIMAL VT byte stream that
/// reproduces its visible state on a fresh terminal — the replacement for replaying (however
/// well distilled) the raw byte HISTORY on a cold reattach.
///
/// ## Shape of the output
/// 1. An explicit reset preamble (main screen, plain SGR, full scroll region, wrap on, origin
///    off, `ED 3` + `ED 2`, home). On a fresh surface every step is a no-op; on a warm surface
///    (the warm-overflow snapshot) it IS the wipe that makes the re-render correct.
/// 2. Scrollback, one LOGICAL line per line: soft-wrapped rows are re-joined so the client
///    re-wraps them at its own width (a join is trusted only when the leading row is full to
///    its last column — see ``TerminalScreenModel/ScrollbackLine/softWrapped``).
/// 3. The main grid painted SEQUENTIALLY (every row, blank rows included): after `scrollback +
///    rows` printed lines the viewport holds exactly the grid with row 0 at the top, and the
///    scrollback sits above it — the same adjacency the real history produced.
/// 4. If the alt screen is active: position the main saved cursor, `?1049h`, then paint the
///    alt grid with ABSOLUTE per-row positioning (no scroll risk, blank rows skipped).
/// 5. State re-establishment: DECSTBM, DECOM, DECAWM, DECTCEM, charsets (G0/G1 + SO), the live
///    SGR, the cursor (re-arming DECAWM deferred wrap by re-printing the last column when the
///    model ended wrap-pending), keypad, then the caller's input-mode reassert bytes.
///
/// ## What this guarantees
/// Feeding the output to a FRESH ``TerminalScreenModel`` reproduces the source model's visible
/// state, and rendering is a CANONICALIZATION: `render(feed(render(A))) == render(A)`
/// byte-exact — the differential + idempotence pin the tests enforce over the VT vocabulary.
///
/// Accepted gaps (docs/DECISIONS.md 2026-07-25): OSC 8 hyperlinks and app-set palette colors
/// are not modeled; `REP` across the snapshot boundary repeats nothing; the saved-cursor slot
/// restores position, not its saved SGR/charset.
enum TerminalSnapshotRenderer {
    /// Renders `snapshot`, appending `inputModeReassert` (the
    /// ``TerminalInputModeStripper/finalState(_:)`` net state) as the FINAL bytes — the same
    /// trailing position the stripped-replay path gives it.
    static func render(
        _ snapshot: TerminalScreenModel.ReplaySnapshot,
        inputModeReassert: Data = Data(),
    ) -> Data {
        var out = Data()
        var sgr = SGRTracker()

        // 1. Explicit reset preamble (deterministic — no reliance on DECSTR semantics).
        out.append(contentsOf: Preamble.bytes)

        // 2. Scrollback as logical lines.
        var i = 0
        let scrollback = snapshot.scrollback
        while i < scrollback.count {
            var logical = scrollback[i].cells
            while scrollback[i].softWrapped, i + 1 < scrollback.count {
                i += 1
                logical.append(contentsOf: scrollback[i].cells)
            }
            i += 1
            appendCells(logical, trimmed: true, to: &out, sgr: &sgr)
            // Reset BEFORE the line feed: the scroll this feed causes in the receiving
            // terminal BCE-fills the new bottom row with the LIVE background — a lingering
            // colored bg would paint rows the source model never colored.
            sgr.reset(into: &out)
            out.append(contentsOf: crlf)
        }

        // 3. Main grid, sequentially — EVERY row, so the viewport lands exactly on the grid.
        for (index, row) in snapshot.mainCells.enumerated() {
            appendCells(row, trimmed: true, to: &out, sgr: &sgr)
            if index < snapshot.mainCells.count - 1 {
                sgr.reset(into: &out) // same BCE discipline as the scrollback feed above
                out.append(contentsOf: crlf)
            }
        }

        // 4. Alt screen (active only): seed the main saved-cursor slot via `?1049h`'s own
        //    save, then paint absolutely.
        if snapshot.usingAlt {
            appendCUP(row: snapshot.savedMainRow, col: snapshot.savedMainCol, to: &out)
            sgr.reset(into: &out) // the alt clear-on-enter must fill with the DEFAULT bg
            out.append(contentsOf: Array("\u{1B}[?1049h".utf8))
            for (r, row) in snapshot.altCells.enumerated() where !isBlankRow(row) {
                appendCUP(row: r, col: 0, to: &out)
                appendCells(row, trimmed: true, to: &out, sgr: &sgr)
            }
        } else {
            // Seed the active (main) saved-cursor slot: position + DECSC. Saved SGR/charset
            // fidelity is an accepted gap — DECSC here captures the renderer's current state.
            appendCUP(row: snapshot.savedCursorRow, col: snapshot.savedCursorCol, to: &out)
            out.append(0x1B)
            out.append(UInt8(ascii: "7"))
        }

        // 5. State re-establishment.
        if snapshot.usingAlt {
            // The alt slot: position + DECSC on the active (alt) screen.
            appendCUP(row: snapshot.savedCursorRow, col: snapshot.savedCursorCol, to: &out)
            out.append(0x1B)
            out.append(UInt8(ascii: "7"))
        }
        if snapshot.scrollTop != 0 || snapshot.scrollBottom != snapshot.rows - 1 {
            out.append(contentsOf: Array("\u{1B}[\(snapshot.scrollTop + 1);\(snapshot.scrollBottom + 1)r".utf8))
        }
        if snapshot.originMode { out.append(contentsOf: Array("\u{1B}[?6h".utf8)) }
        if !snapshot.autowrap { out.append(contentsOf: Array("\u{1B}[?7l".utf8)) }
        if !snapshot.cursorVisible { out.append(contentsOf: Array("\u{1B}[?25l".utf8)) }
        if snapshot.applicationKeypad {
            out.append(0x1B)
            out.append(UInt8(ascii: "="))
        }

        // Cursor + deferred wrap — the LAST cursor-affecting emission. Coordinates are
        // ORIGIN-relative when DECOM is on (the CUP is interpreted inside the region above).
        // The charset re-establishment must come AFTER this: the wrap re-arm re-prints a cell
        // that was painted under the default (preamble) charset, and switching G0/G1 first
        // would remap its ASCII through DEC graphics.
        let cupRow = snapshot.originMode ? snapshot.cursorRow - snapshot.scrollTop : snapshot.cursorRow
        if snapshot.wrapPending {
            // Re-arm DECAWM deferred wrap: re-print the last column's occupant (the wide lead
            // when the last cell is a continuation), which leaves the terminal exactly one
            // printable away from wrapping — the state the model ended in.
            let grid = snapshot.usingAlt ? snapshot.altCells : snapshot.mainCells
            let row = grid[snapshot.cursorRow]
            let lastCol = snapshot.cols - 1
            var printCol = lastCol
            var cell = row[lastCol]
            if cell.isContinuation, lastCol > 0 {
                printCol = lastCol - 1
                cell = row[printCol]
            }
            appendCUP(row: cupRow, col: printCol, to: &out)
            sgr.transition(to: cell.style, into: &out)
            out.append(contentsOf: Array((cell.text.isEmpty ? " " : cell.text).utf8))
        } else {
            appendCUP(row: cupRow, col: snapshot.cursorCol, to: &out)
        }

        // Charsets (no cursor / deferred-wrap side effects), then the live SGR.
        if snapshot.g0Graphics { out.append(contentsOf: Array("\u{1B}(0".utf8)) }
        if snapshot.g1Graphics { out.append(contentsOf: Array("\u{1B})0".utf8)) }
        if snapshot.usingG1 { out.append(0x0E) } // SO
        sgr.transition(to: snapshot.style, into: &out)

        out.append(inputModeReassert)
        return out
    }

    // MARK: Pieces

    private static let crlf: [UInt8] = [0x0D, 0x0A]

    private enum Preamble {
        /// `?1049l` main screen · `SGR 0` · `?25h` visible · `r` full region · `?6l` origin
        /// off · `?7h` wrap on · G0/G1 ASCII + SI · `ESC >` keypad normal · `3J` erase saved
        /// lines · `2J` erase screen · `H` home.
        static let bytes: [UInt8] = Array(
            "\u{1B}[?1049l\u{1B}[0m\u{1B}[?25h\u{1B}[r\u{1B}[?6l\u{1B}[?7h\u{1B}(B\u{1B})B\u{0F}\u{1B}>\u{1B}[3J\u{1B}[2J\u{1B}[H"
                .utf8,
        )
    }

    /// Emits a 1-based CUP from 0-based coordinates.
    private static func appendCUP(row: Int, col: Int, to out: inout Data) {
        out.append(contentsOf: Array("\u{1B}[\(max(row, 0) + 1);\(max(col, 0) + 1)H".utf8))
    }

    private static func isBlankRow(_ row: [TerminalScreenModel.Cell]) -> Bool {
        row.allSatisfy { $0 == TerminalScreenModel.Cell() }
    }

    /// Appends a run of cells (continuation cells contribute nothing — the wide lead prints
    /// both columns). `trimmed` drops the FULLY-DEFAULT tail (styled blanks are content: a
    /// colored or underlined space is visible and must be printed).
    private static func appendCells(
        _ cells: [TerminalScreenModel.Cell],
        trimmed: Bool,
        to out: inout Data,
        sgr: inout SGRTracker,
    ) {
        var end = cells.count
        if trimmed {
            while end > 0, cells[end - 1] == TerminalScreenModel.Cell() { end -= 1 }
        }
        for cell in cells.prefix(end) where !cell.isContinuation {
            sgr.transition(to: cell.style, into: &out)
            out.append(contentsOf: Array((cell.text.isEmpty ? " " : cell.text).utf8))
        }
    }

    /// The renderer's mirror of the client terminal's live SGR state — emits one full
    /// reset+set run per style CHANGE, nothing for same-style runs.
    private struct SGRTracker {
        private var current = TerminalScreenModel.CellStyle.plain

        mutating func reset(into out: inout Data) {
            transition(to: .plain, into: &out)
        }

        mutating func transition(to style: TerminalScreenModel.CellStyle, into out: inout Data) {
            guard style != current else { return }
            current = style
            guard style != .plain else {
                out.append(contentsOf: Array("\u{1B}[0m".utf8))
                return
            }
            var codes = ["0"]
            if style.bold { codes.append("1") }
            if style.dim { codes.append("2") }
            if style.italic { codes.append("3") }
            if style.underline { codes.append("4") }
            if style.blink { codes.append("5") }
            if style.inverse { codes.append("7") }
            if style.hidden { codes.append("8") }
            if style.strikethrough { codes.append("9") }
            appendColor(style.fg, base: 30, extended: 38, to: &codes)
            appendColor(style.bg, base: 40, extended: 48, to: &codes)
            out.append(contentsOf: Array("\u{1B}[\(codes.joined(separator: ";"))m".utf8))
        }

        private func appendColor(
            _ color: TerminalScreenModel.SGRColor,
            base: Int,
            extended: Int,
            to codes: inout [String],
        ) {
            switch color {
            case .default:
                break // the leading reset already established it
            case let .indexed(index) where index < 8:
                codes.append("\(base + Int(index))")
            case let .indexed(index) where index < 16:
                codes.append("\(base + 60 + Int(index) - 8)")
            case let .indexed(index):
                codes.append("\(extended);5;\(index)")
            case let .rgb(r, g, b):
                codes.append("\(extended);2;\(r);\(g);\(b)")
            }
        }
    }
}

// MARK: - TerminalReplaySnapshot (the cold-reattach composer)

/// The raw-history → rendered-snapshot transform the reattach path injects: feed the
/// accumulated bytes (ring + un-acked tail + detached out-FIFO backlog, chronological) through
/// the screen model at the live PTY size, then render the resulting STATE once.
///
/// A trailing INCOMPLETE escape sequence or UTF-8 scalar is held back and re-appended RAW
/// after the snapshot (the ``ScrollbackReplayTransform`` discipline): the live tail that
/// follows the replay begins with its continuation bytes, and anything inserted between the
/// halves would corrupt both.
enum TerminalReplaySnapshot {
    /// Scrollback lines the composer's model captures (the client's own scrollback cap is the
    /// real bound; this bounds host memory during composition).
    static let scrollbackLineBudget = 10000

    static func compose(raw: Data, rows: Int, cols: Int) -> Data {
        let escSplit = ScrollbackReplayTransform.splitTrailingIncompleteEscape(raw)
        let utf8Split = escSplit.dangling.isEmpty
            ? splitTrailingIncompleteUTF8(escSplit.head)
            : (head: escSplit.head, dangling: Data())
        let head = utf8Split.head
        let dangling = escSplit.dangling.isEmpty ? utf8Split.dangling : escSplit.dangling

        var model = TerminalScreenModel(rows: rows, cols: cols, scrollbackLimit: scrollbackLineBudget)
        model.feed(head)
        let modes = TerminalInputModeStripper.finalState(head)
        var out = TerminalSnapshotRenderer.render(
            model.replaySnapshot(),
            inputModeReassert: modes.reassertSequence,
        )
        out.append(dangling)
        return out
    }

    /// Splits a trailing INCOMPLETE UTF-8 scalar off `data` (a lead byte whose continuations
    /// have not all arrived). The model would DROP the partial scalar and the client would
    /// print the tail's continuation bytes as garbage; held back raw, the halves reunite.
    static func splitTrailingIncompleteUTF8(_ data: Data) -> (head: Data, dangling: Data) {
        let n = data.count
        guard n > 0 else { return (data, Data()) }
        let window = Array(data.suffix(4))
        // Walk back over trailing continuation bytes to the candidate lead.
        var back = window.count - 1
        var continuations = 0
        while back >= 0, window[back] & 0xC0 == 0x80 {
            continuations += 1
            back -= 1
        }
        guard back >= 0, continuations < 4 else { return (data, Data()) }
        let lead = window[back]
        let expected: Int
        if lead & 0x80 == 0 {
            return (data, Data()) // ASCII — complete
        }
        if lead & 0xE0 == 0xC0 {
            expected = 1
        } else if lead & 0xF0 == 0xE0 {
            expected = 2
        } else if lead & 0xF8 == 0xF0 {
            expected = 3
        } else {
            return (data, Data()) // stray continuation / invalid lead — leave alone
        }
        guard continuations < expected else { return (data, Data()) } // complete scalar
        let danglingCount = continuations + 1
        return (data.dropLast(danglingCount), data.suffix(danglingCount))
    }
}
