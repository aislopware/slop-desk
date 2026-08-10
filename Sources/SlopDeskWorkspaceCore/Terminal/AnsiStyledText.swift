import Foundation

// MARK: - AnsiStyledText (raw VT bytes → STYLED lines)

/// The VT skimmer that keeps the colours. It is the same small, never-trapping pass
/// ``BlockOutputSanitizer`` has always made over a block's captured output — the CR line-rewrite so a
/// progress bar collapses to its final frame, `ESC [ K` truncation, C0 dropping, the zsh
/// `PROMPT_EOL_MARK` chop — except that every byte it writes carries the SGR state that was live when
/// it was written. The plain-text path is this pass with the styles discarded, so the two can never
/// drift apart. The STYLED reading had one consumer — the command ladder's peek card — and that was
/// removed whole (user-directed 2026-08-10); the pass stays because it IS the clipboard's skimmer
/// now, and rewriting it back to a plain one would put the 22 sanitizer pins at risk for nothing.
///
/// It is NOT a terminal emulator: no cursor addressing, no scroll regions, no alternate screen. The
/// host's captured output is already the on-screen byte stream for one command, so a linear pass with
/// column rewriting reproduces what the user saw closely enough to preview.
///
/// PURE + `nonisolated` — headlessly unit-testable, and the plain-text (clipboard) path's own pass.

/// One colour as the wire expressed it — resolved to an actual `Color` by the VIEW layer, which is
/// the only layer that knows the profile's palette. `nil` (the absence of this value) means "the
/// surface's default".
public enum AnsiColor: Equatable, Hashable, Sendable {
    /// A palette slot: 0–7 standard, 8–15 bright, 16–255 the xterm cube + greyscale ramp.
    case indexed(UInt8)
    /// A direct 24-bit colour (`ESC [ 38 ; 2 ; r ; g ; b m`).
    case rgb(r: UInt8, g: UInt8, b: UInt8)
}

/// The SGR state one run of text was written under.
public struct AnsiStyle: Equatable, Hashable, Sendable {
    public var foreground: AnsiColor?
    public var background: AnsiColor?
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var underline: Bool
    /// Reverse video (SGR 7) — the view swaps fore/background rather than the parser, because the
    /// DEFAULTS it swaps in are the surface's, which only the view knows.
    public var inverse: Bool

    public init(
        foreground: AnsiColor? = nil,
        background: AnsiColor? = nil,
        bold: Bool = false,
        dim: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        inverse: Bool = false,
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
    }

    /// The unstyled state — what a line starts in and what `ESC [ 0 m` returns it to.
    public static let plain = Self()

    /// True when nothing at all is set — the fast path for a view that would otherwise build an
    /// attributed run for ordinary text.
    public var isPlain: Bool { self == .plain }
}

/// A maximal stretch of text written under ONE style.
public struct AnsiRun: Equatable, Sendable {
    public let text: String
    public let style: AnsiStyle

    public init(text: String, style: AnsiStyle) {
        self.text = text
        self.style = style
    }
}

public enum AnsiStyledParser {
    /// Skims `bytes` into LINES of styled runs. One entry per line INCLUDING the last, unterminated
    /// one (so joining the entries with `\n` reproduces the plain text byte for byte — the property
    /// ``BlockOutputSanitizer/plainText(from:)`` is expressed on).
    public nonisolated static func lines(from bytes: Data) -> [[AnsiRun]] {
        guard !bytes.isEmpty else { return [[]] }
        let input = [UInt8](bytes)
        let n = input.count
        var out: [[AnsiRun]] = []
        // The current visual line as a COLUMN-indexed buffer of (byte, style) with a cursor, so a
        // progress bar redrawing one line via `\r` collapses to its final frame rather than every
        // frame concatenated. Columns are BYTES, not characters — a multi-byte scalar occupies
        // several, which is exactly how the pre-styled pass behaved and what its tests pin.
        var line: [(byte: UInt8, style: AnsiStyle)] = []
        var col = 0 // invariant: 0 ≤ col ≤ line.count
        var style = AnsiStyle.plain
        // The column of a reverse-video `%`/`#` followed only by pad whitespace — zsh's
        // PROMPT_EOL_MARK, which lands inside the captured bytes when a command's last line has no
        // trailing newline and would otherwise survive as a bare "%". Chopped at the very end.
        var eolMark: Int?
        var i = 0

        func put(_ b: UInt8) {
            if col < line.count { line[col] = (b, style) } else { line.append((b, style)) }
            col += 1
        }
        func commitLine() {
            out.append(runs(of: line))
            line.removeAll(keepingCapacity: true)
            col = 0
            eolMark = nil
        }

        while i < n {
            let byte = input[i]
            switch byte {
            case 0x1B: // ESC — an escape sequence
                let end = skipEscapeSequence(input, from: i)
                applySGR(input, from: i, upTo: end, to: &style)
                if isEraseToLineEnd(input, from: i, upTo: end), col < line.count {
                    line.removeLast(line.count - col) // `ESC [ K` — erase cursor→end of line
                }
                i = end
            case 0x0A: // LF — commit the current visual line
                commitLine()
                i += 1
            case 0x09: // HT — meaningful whitespace, kept at the cursor
                eolMark = nil
                put(0x09)
                i += 1
            case 0x0D: // CR — `\r\n` is a newline; a lone `\r` rewinds the cursor (overwrite motion)
                if i + 1 < n, input[i + 1] == 0x0A {
                    commitLine()
                    i += 2
                } else {
                    col = 0
                    i += 1
                }
            case 0x00...0x08,
                 0x0B,
                 0x0C,
                 0x0E...0x1F,
                 0x7F:
                i += 1 // other C0 controls + DEL — formatting noise for a preview / a paste
            case 0x23,
                 0x25: // '#' / '%' — a candidate zsh EOL mark iff currently reverse-video
                eolMark = style.inverse ? col : nil
                put(byte)
                i += 1
            case 0x20: // space — pad after the mark; keeps a pending candidate alive
                put(byte)
                i += 1
            default:
                // Printable ASCII or a UTF-8 lead/continuation byte — kept verbatim; any ordinary
                // printable invalidates a pending EOL-mark candidate.
                eolMark = nil
                put(byte)
                i += 1
            }
        }
        // Chop a trailing PROMPT_EOL_MARK from the final, unterminated line, then flush it.
        if let eolMark, eolMark < line.count { line.removeLast(line.count - eolMark) }
        out.append(runs(of: line))
        return out
    }

    /// Coalesces a column buffer into maximal same-style runs, decoding each LOSSILY (an invalid byte
    /// becomes U+FFFD — a preview is best-effort and must never lose the whole line to one bad byte).
    private nonisolated static func runs(of line: [(byte: UInt8, style: AnsiStyle)]) -> [AnsiRun] {
        guard !line.isEmpty else { return [] }
        var result: [AnsiRun] = []
        var buffer: [UInt8] = []
        var current = line[0].style
        for cell in line {
            if cell.style != current {
                // swiftlint:disable:next optional_data_string_conversion
                result.append(AnsiRun(text: String(decoding: buffer, as: UTF8.self), style: current))
                buffer.removeAll(keepingCapacity: true)
                current = cell.style
            }
            buffer.append(cell.byte)
        }
        // swiftlint:disable:next optional_data_string_conversion
        result.append(AnsiRun(text: String(decoding: buffer, as: UTF8.self), style: current))
        return result
    }

    // MARK: Escape-sequence skimming

    /// The index PAST the escape sequence beginning at `start` (where `input[start] == ESC`):
    ///   • CSI `ESC [ … <final 0x40–0x7E>`; • OSC `ESC ] … (BEL | ESC \\)`; • a string sequence
    ///   (DCS/SOS/PM/APC) to its terminator; • a short two/three-byte escape.
    /// An UNTERMINATED sequence at end-of-buffer consumes to the end (never reads past `n`).
    nonisolated static func skipEscapeSequence(_ input: [UInt8], from start: Int) -> Int {
        let n = input.count
        let next = start + 1
        guard next < n else { return n } // a trailing bare ESC — consume it
        switch input[next] {
        case 0x5B: // '[' — CSI
            var j = next + 1
            while j < n {
                if (0x40...0x7E).contains(input[j]) { return j + 1 } // final byte ends the CSI
                j += 1
            }
            return n
        case 0x5D, // ']' OSC
             0x50, // 'P' DCS (sixel, DECRQSS, …)
             0x58, // 'X' SOS
             0x5E, // '^' PM
             0x5F, // '_' APC (kitty graphics)
             0x6B: // 'k' (screen/tmux title)
            var j = next + 1
            while j < n {
                if input[j] == 0x07 { return j + 1 } // BEL terminator
                if input[j] == 0x1B, j + 1 < n, input[j + 1] == 0x5C { return j + 2 } // ST = ESC '\'
                j += 1
            }
            return n
        default:
            // A short escape (charset select `ESC ( X`, keypad `ESC =`, …). Most are two bytes; the
            // charset-designator forms are three.
            let intro = input[next]
            if intro == 0x28 || intro == 0x29 || intro == 0x2A || intro == 0x2B, next + 1 < n {
                return next + 2
            }
            return next + 1
        }
    }

    /// True iff `input[start…end]` is an ERASE-TO-END-OF-LINE CSI (`ESC [ K` / `ESC [ 0 K`) — the form
    /// a progress bar uses to clear stale trailing characters after a shorter frame.
    nonisolated static func isEraseToLineEnd(_ input: [UInt8], from start: Int, upTo end: Int) -> Bool {
        guard end - start >= 3, input[start + 1] == 0x5B, input[end - 1] == 0x4B else { return false }
        if end - 1 > start + 2, (0x3C...0x3F).contains(input[start + 2]) { return false } // private-mode
        var value = 0
        var sawDigit = false
        for j in (start + 2)..<(end - 1) {
            let b = input[j]
            guard (0x30...0x39).contains(b) else { return false }
            if value < 100_000_000 { value = value * 10 + Int(b - 0x30) } // capped — never trap
            sawDigit = true
        }
        return !sawDigit || value == 0
    }

    // MARK: SGR

    /// Applies the escape sequence `input[start..<end]` to `style` when it is an SGR (a CSI ending in
    /// `m`); leaves it untouched otherwise. A PRIVATE-mode CSI (`ESC [ ? … m`) is not one.
    nonisolated static func applySGR(
        _ input: [UInt8], from start: Int, upTo end: Int, to style: inout AnsiStyle,
    ) {
        guard end - start >= 3, input[start + 1] == 0x5B, input[end - 1] == 0x6D else { return }
        // `ESC [ m` == `ESC [ 0 m` — a full reset.
        guard end - 1 > start + 2 else {
            style = .plain
            return
        }
        var params: [Int] = []
        var value = 0
        var sawDigit = false
        for j in (start + 2)..<(end - 1) {
            let b = input[j]
            if b == 0x3B || b == 0x3A { // ';' or ':' — both separate parameters in the wild
                params.append(sawDigit ? value : 0)
                value = 0
                sawDigit = false
            } else if (0x30...0x39).contains(b) {
                // Capped so a degenerate digit run (`ESC [ 99999…m`) can never overflow Int and TRAP.
                if value < 100_000_000 { value = value * 10 + Int(b - 0x30) }
                sawDigit = true
            } else {
                return // an intermediate/private byte — not a plain SGR we interpret
            }
        }
        params.append(sawDigit ? value : 0)
        apply(params: params, to: &style)
    }

    /// Folds decoded SGR parameters into `style`. Extended colour (`38`/`48`) consumes its own
    /// arguments; a truncated extended form simply stops (never reads past the end).
    nonisolated static func apply(params: [Int], to style: inout AnsiStyle) {
        var index = 0
        while index < params.count {
            let param = params[index]
            switch param {
            case 0: style = .plain
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 22:
                style.bold = false
                style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.foreground = .indexed(UInt8(param - 30))
            case 39: style.foreground = nil
            case 40...47: style.background = .indexed(UInt8(param - 40))
            case 49: style.background = nil
            case 90...97: style.foreground = .indexed(UInt8(param - 90 + 8))
            case 100...107: style.background = .indexed(UInt8(param - 100 + 8))
            case 38,
                 48:
                let (colour, consumed) = extendedColour(params, from: index + 1)
                if let colour {
                    if param == 38 { style.foreground = colour } else { style.background = colour }
                }
                index += consumed
            default:
                break // an SGR this preview does not model (blink, framed, overline…)
            }
            index += 1
        }
    }

    /// Decodes the argument of a `38`/`48` at `from`: `5 ; N` (palette) or `2 ; r ; g ; b` (direct),
    /// returning the colour and how many parameters it consumed. A truncated or unknown form yields
    /// `nil` and consumes what it saw, so the scan always advances.
    private nonisolated static func extendedColour(
        _ params: [Int], from: Int,
    ) -> (AnsiColor?, Int) {
        guard from < params.count else { return (nil, 0) }
        switch params[from] {
        case 5:
            guard from + 1 < params.count else { return (nil, 1) }
            return (.indexed(clampByte(params[from + 1])), 2)
        case 2:
            guard from + 3 < params.count else { return (nil, params.count - from) }
            return (
                .rgb(
                    r: clampByte(params[from + 1]),
                    g: clampByte(params[from + 2]),
                    b: clampByte(params[from + 3]),
                ),
                4,
            )
        default:
            return (nil, 1)
        }
    }

    /// Clamps a decoded parameter into a byte — a malformed `38;2;999;…` must not trap on conversion.
    private nonisolated static func clampByte(_ value: Int) -> UInt8 {
        UInt8(Swift.min(Swift.max(value, 0), 255))
    }
}
