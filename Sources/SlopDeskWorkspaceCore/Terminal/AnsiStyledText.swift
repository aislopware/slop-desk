import CSlopDeskFFI
import Foundation

// MARK: - AnsiStyledText (raw VT bytes → STYLED lines)

/// The VT skimmer that keeps the colours — the clipboard's reading, and the coloured one.
///
/// ## This is a call, not an implementation
/// The pass is `slopdesk_sanitize::styled`, reached through `slopdesk_styled_lines` (docs/55). What
/// used to be here was a second VT grammar: a hand-rolled escape skipper, a hand-rolled SGR
/// decoder and a hand-rolled string-sequence scan, sitting beside the `vtscan` module that already
/// owned all three for the replay passes. Two grammars over one byte stream is how a sequence one
/// side skips and the other prints becomes a bug nobody can localise.
///
/// The rules the pass keeps are the ones this file always had: the CR line-rewrite so a progress
/// bar collapses to its final frame, `ESC [ K` truncation, C0 dropping, the zsh `PROMPT_EOL_MARK`
/// chop. The plain-text path is this pass with the styles discarded, so the two can never drift.
///
/// It is NOT a terminal emulator: no cursor addressing, no scroll regions, no alternate screen. The
/// host's captured output is already the on-screen byte stream for one command, so a linear pass
/// with column rewriting reproduces what the user saw closely enough to preview.

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
    /// The first guess at the answer's size. A command's captured output is usually a few lines;
    /// the retry below exists to be correct on the one that is a build log, not to be rare.
    private static let firstGuessBytes = 16 * 1024

    /// `[u8 flags][u8 fg kind][u8 fg a][u8 fg b][u8 fg c][u8 bg × 4][u32 BE text length]`.
    private static let runHeaderBytes = 13

    /// Skims `bytes` into LINES of styled runs. One entry per line INCLUDING the last, unterminated
    /// one (so joining the entries with `\n` reproduces the plain text byte for byte — the property
    /// ``BlockOutputSanitizer/plainText(from:)`` is expressed on).
    public nonisolated static func lines(from bytes: Data) -> [[AnsiRun]] {
        bytes.withUnsafeBytes { raw -> [[AnsiRun]] in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: firstGuessBytes) { out in
                let needed = call(raw, into: out)
                guard needed > 0 else { return [[]] }
                guard needed > out.count else { return decode(out, needed) ?? [[]] }
                // The answer outgrew the guess — a build log rather than a command's few lines.
                // Nothing was written, so this is a clean retry, and the wrapped function is pure,
                // so the second call cannot disagree with the first.
                var wide = [UInt8](repeating: 0, count: needed)
                return wide.withUnsafeMutableBufferPointer { buffer in
                    let again = call(raw, into: buffer)
                    guard again > 0, again <= buffer.count else { return [[]] }
                    return decode(buffer, again) ?? [[]]
                }
            }
        }
    }

    // MARK: The door

    /// One invocation of the C entry point. Returns how many bytes the answer needs; see
    /// `rust/slopdesk-ffi/include/slopdesk_ffi.h` for the convention.
    private nonisolated static func call(
        _ bytes: UnsafeRawBufferPointer,
        into out: UnsafeMutableBufferPointer<UInt8>,
    ) -> Int {
        slopdesk_styled_lines(
            bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
            bytes.count,
            out.baseAddress,
            out.count,
        )
    }

    /// Reads the door's `[kind, a, b, c]`. Kind `0` is ABSENT, which is not a palette slot: the
    /// surface's default is not a colour the stream named, and painting it as one would put a
    /// pane's own background over text nothing coloured.
    private nonisolated static func colour(_ kind: UInt8, _ a: UInt8, _ b: UInt8, _ c: UInt8) -> AnsiColor? {
        switch kind {
        case 1: .indexed(a)
        case 2: .rgb(r: a, g: b, b: c)
        default: nil
        }
    }

    /// Walks `[u32 BE lines] ( [u32 BE runs] ( [run header][text] )* )*`.
    ///
    /// `nil` on any walk that would leave the answer, which is a shape disagreement between the two
    /// sides rather than bad input — the pass itself never refuses.
    private nonisolated static func decode(
        _ bytes: UnsafeMutableBufferPointer<UInt8>,
        _ count: Int,
    ) -> [[AnsiRun]]? {
        guard count <= bytes.count else { return nil }
        var cursor = 0
        func word() -> Int? {
            guard cursor + 4 <= count else { return nil }
            defer { cursor += 4 }
            return Int(bytes[cursor]) << 24 | Int(bytes[cursor + 1]) << 16
                | Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
        }
        guard let lineCount = word() else { return nil }
        var out: [[AnsiRun]] = []
        out.reserveCapacity(lineCount)
        for _ in 0..<lineCount {
            guard let runCount = word() else { return nil }
            var runs: [AnsiRun] = []
            runs.reserveCapacity(runCount)
            for _ in 0..<runCount {
                guard cursor + runHeaderBytes <= count else { return nil }
                let flags = bytes[cursor]
                let style = AnsiStyle(
                    foreground: colour(
                        bytes[cursor + 1], bytes[cursor + 2], bytes[cursor + 3], bytes[cursor + 4],
                    ),
                    background: colour(
                        bytes[cursor + 5], bytes[cursor + 6], bytes[cursor + 7], bytes[cursor + 8],
                    ),
                    bold: flags & 1 != 0,
                    dim: flags & 2 != 0,
                    italic: flags & 4 != 0,
                    underline: flags & 8 != 0,
                    inverse: flags & 16 != 0,
                )
                cursor += 9
                guard let length = word(), cursor + length <= count else { return nil }
                let slice = UnsafeRawBufferPointer(
                    rebasing: UnsafeRawBufferPointer(bytes)[cursor..<(cursor + length)],
                )
                cursor += length
                // The repairing initialiser: the bytes came back from a Rust `String`, so no failure
                // arm is reachable, and a preview must never lose a line to one byte.
                runs.append(AnsiRun(text: String(decoding: slice, as: UTF8.self), style: style))
            }
            out.append(runs)
        }
        return out
    }
}
