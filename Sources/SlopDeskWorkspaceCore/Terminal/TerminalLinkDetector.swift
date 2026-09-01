// The terminal's path / `path:line:col` / URL scan, as the Swift face of `rust/slopdesk-terminal`'s
// `link`, reached through `rust/slopdesk-ffi`'s `link_detect` door.
//
// ## What is not here any more
//
// The scan. Tokenizing a row into whitespace-delimited runs while counting display cells, the
// balanced-bracket trim that keeps `…/Swift_(programming_language)` whole while stripping prose's
// `(https://x.com).`, the scheme grammar and its always-on four, the `:line:col` split, the
// lexical normalisation that resolves `a/../b` without touching the filesystem, and the
// East-Asian-wide / zero-width cell table underneath all of it. All Rust's, in a crate that
// forbids `unsafe`. This file owns the shape of the answer and one handle's lifetime.
//
// ## Why the scan crosses as an arena
//
// The answer is a list of records each carrying up to two strings, and neither the record count nor
// the total text length is knowable before the scan runs — so there is no buffer for a caller to
// size in advance. The door runs the scan, parks the result, and answers both counts; this file
// reads the records out and copies the one flat string buffer once. Ten call sites see the same
// free function they always did: the handle never escapes ``detect(rows:cwd:schemes:maxScanColumns:)``,
// so two overlays scanning at once share nothing.
//
// ## The width entries this file used to publish are gone
//
// Two overloads of `displayCellWidth(of:)` stood here so that a caller walking a line cell by cell
// did not have to build a one-character `String` per column. All three such callers moved to Rust
// — `ViLineMotion` to `slopdesk_terminal::vimotion` and `HintLabelAssigner` to the hint scan, each
// now reading the widths in-crate with no crossing at all; the third, `ScrollbackWrapMapper`, was
// deleted outright once the terminal engine started reporting each logical line's real screen rows.
// The overloads outlived their last caller, so they and both doors behind them were deleted rather
// than left as a face nobody dials.

import CSlopDeskFFI
import SlopDeskArena

// MARK: - The shape of a detected span

/// The classification of a span detected by ``TerminalLinkDetector``. Mirrors the
/// `docs/ui-shell/spec/user-interface__files-and-links.md` "Path and Link Detection" list.
///
/// - ``absolutePath``: a `/…`-rooted filesystem path (`/usr/local/bin/foo`).
/// - ``tildePath``: a `~`-anchored path (`~/project/file.swift`) — anchored at the host `$HOME`,
///   which the pure detector cannot expand (see ``DetectedLink/resolvedAbsolute``).
/// - ``relativePath``: a `./…` / `../…` (or bare `dir/file` carrying a line/col suffix) path,
///   resolved against the pane cwd.
/// - ``pathLineCol``: any of the above carrying a `:line` or `:line:col` suffix
///   (`src/lib.rs:42`, `src/lib.rs:42:5`) — compiler/linter output. The `raw` keeps the suffix; the
///   resolved path drops it.
/// - ``url``: a `scheme://…` URL (subject to the scheme policy) or an always-on `mailto:` address.
/// - ``fileURL``: a `file://…` URL — its filesystem path is surfaced in `resolvedAbsolute`.
public enum DetectedLinkKind: Equatable, Hashable, Sendable, CaseIterable {
    case absolutePath
    case tildePath
    case relativePath
    case pathLineCol
    case url
    case fileURL
}

/// One detected interactive span in a terminal row.
///
/// `colStart ..< colEnd` are **display cell columns** (East-Asian-wide / fullwidth glyphs count as 2
/// cells, combining marks as the base) so the geometry seam can map a match straight to a
/// `CGRect` (`originX + cellWidth * colStart`, width `cellWidth * (colEnd − colStart)`) without a
/// second width pass. `colEnd` is exclusive. `raw` is the exact matched substring (line/col suffix
/// included). `resolvedAbsolute` is the absolute filesystem path when it can be derived PURELY (an
/// absolute path, normalized; a relative path joined to an absolute cwd; a `file://` path) — and
/// `nil` otherwise (tilde paths need the host `$HOME`; plain URLs are not filesystem paths).
public struct DetectedLink: Equatable, Hashable, Sendable {
    public var row: Int
    public var colStart: Int
    public var colEnd: Int
    public var kind: DetectedLinkKind
    public var raw: String
    public var resolvedAbsolute: String?

    public init(
        row: Int,
        colStart: Int,
        colEnd: Int,
        kind: DetectedLinkKind,
        raw: String,
        resolvedAbsolute: String?,
    ) {
        self.row = row
        self.colStart = colStart
        self.colEnd = colEnd
        self.kind = kind
        self.raw = raw
        self.resolvedAbsolute = resolvedAbsolute
    }
}

/// Which URL schemes the detector underlines / makes clickable — the "Auto-Detect Link Schemes" setting.
///
/// `http`, `https`, `file`, and `mailto` are **always** detected regardless of this policy (hard-coded);
/// this only governs OTHER `scheme://…` forms.
public enum LinkSchemePolicy: Equatable, Hashable, Sendable {
    /// Detect ANY `scheme://…` (the default, labeled "All" in Settings).
    case all
    /// Detect only the always-on schemes plus this user list (labeled "Custom" in Settings, e.g. `codex`,
    /// `ssh`, `vscode`). Compared case-insensitively.
    case custom([String])
}

// MARK: - The face

/// The PURE, headless heart of the terminal's path/URL/link detection: scan
/// `[String]` rows and return every detected path, `path:line:col`, URL, `file://`, and `mailto:`
/// span with its cell columns and (where derivable) resolved absolute path.
///
/// ## Why a pure enum
/// Detection is a deterministic text scan with **no host round-trip** (the client already tracks
/// the pane cwd via OSC 7). Keeping it a pure, environment-free function makes it unit-testable
/// headless and lets the same code drive the ⌘-hold underline, Jump-To, and Hint Mode overlays.
/// The thin GUI surfaces feed it `viewportTextRows()` and map `colStart ..< colEnd` to pixels.
///
/// ## Validate-then-drop & bounds (CLAUDE.md §3 habit, applied to untrusted terminal bytes)
/// Terminal output is attacker-influenced (a remote program prints whatever it likes), so the scan is
/// bounded and total: each row is scanned for at most `maxScanColumns` **cells** (a pathological
/// no-whitespace megabyte line can never make this hang), at most ``maxMatchesPerRow`` matches are
/// emitted per row, classification never force-unwraps, and an unrecognised / disallowed span is
/// simply dropped (never a trap). Bare `dir/file` runs without a `./`/`../` prefix are only accepted
/// when they carry a line:col suffix — otherwise ordinary prose (`and/or`, `TODO/DONE`, `git@host:org/repo`)
/// would light up.
///
/// Pinned by `TerminalLinkDetectorTests` (each form, the CJK cell-column mapping, the scheme policy,
/// the column bound, and the no-match noise are revert-to-confirm-fail) on this side, and by
/// `rust/slopdesk-terminal/src/link.rs`'s own tests on the other.
public enum TerminalLinkDetector {
    /// Hard cap on emitted matches per row (output bound, independent of `maxScanColumns`).
    ///
    /// Agreement with `link::MAX_MATCHES_PER_ROW` is a `slopdesk-invariants` gate, not a comment.
    public static let maxMatchesPerRow = 512

    /// Default per-row cell-scan ceiling — the anti-hang bound. Pinned against
    /// `link::MAX_SCAN_COLUMNS` by the same gate.
    public static let maxScanColumnsDefault = 4096

    /// Detect every interactive span in `rows`.
    ///
    /// - Parameters:
    ///   - rows: terminal rows top→bottom (a viewport slice for the overlays, or scrollback for
    ///     Jump-To). The returned `row` is the index into THIS array.
    ///   - cwd: the pane's last-known working directory (OSC 7). Used to resolve relative paths to an
    ///     absolute `resolvedAbsolute`; ignored unless it is itself absolute.
    ///   - schemes: which `scheme://…` URLs are detected (`http(s)`/`file`/`mailto` are always on).
    ///   - maxScanColumns: per-row cell-scan ceiling (default 4096) — the anti-hang bound.
    /// - Returns: detected links in row-major, left-to-right order.
    public static func detect(
        rows: [String],
        cwd: String?,
        schemes: LinkSchemePolicy,
        maxScanColumns: Int = maxScanColumnsDefault,
    ) -> [DetectedLink] {
        let (rowBlob, rowLengths) = flatten(rows)
        let schemeList: [String]
        let schemeMode: UInt32
        switch schemes {
        case .all:
            schemeList = []
            schemeMode = UInt32(SLOPDESK_LINK_SCHEMES_ALL)
        case let .custom(allowed):
            schemeList = allowed
            schemeMode = UInt32(SLOPDESK_LINK_SCHEMES_CUSTOM)
        }
        let (schemeBlob, schemeLengths) = flatten(schemeList)
        let cwdBytes = Array((cwd ?? "").utf8)

        guard let scan = slopdesk_link_scan(
            rowBlob, rowBlob.count,
            rowLengths, rowLengths.count,
            cwdBytes, cwdBytes.count,
            schemeMode,
            schemeBlob, schemeBlob.count,
            schemeLengths, schemeLengths.count,
            maxScanColumns,
        ) else { return [] }
        defer { slopdesk_link_scan_free(scan) }

        let counts = slopdesk_link_scan_counts(scan)
        var arena = [UInt8](repeating: 0, count: counts.arena_length)
        let written = arena.withUnsafeMutableBufferPointer {
            slopdesk_link_scan_take_arena(scan, $0.baseAddress, $0.count)
        }
        precondition(written == counts.arena_length, "the arena answered a size it would not fill")

        // One borrow for every string in the scan: the arena is read `link_count × 2` times at
        // most, and each read is a rebase inside a buffer that is already there.
        return arena.withUnsafeBytes { raw -> [DetectedLink] in
            var out: [DetectedLink] = []
            out.reserveCapacity(counts.link_count)
            for index in 0..<counts.link_count {
                let record = slopdesk_link_scan_link(scan, index)
                guard let kind = kind(of: record.kind) else { continue }
                out.append(DetectedLink(
                    row: record.row,
                    colStart: record.col_start,
                    colEnd: record.col_end,
                    kind: kind,
                    raw: text(raw, record.raw_offset, record.raw_length),
                    resolvedAbsolute: record.has_resolved
                        ? text(raw, record.resolved_offset, record.resolved_length)
                        : nil,
                ))
            }
            return out
        }
    }

    /// The kind a `SLOPDESK_LINK_KIND_*` code names. `nil` for `SLOPDESK_LINK_KIND_NONE` — the
    /// door's answer to an index past the end, which the reader loop never asks for.
    ///
    /// `package` rather than internal: a hint target of kind LINK carries a link kind in the same
    /// encoding, and so does an authored `OSC 8` run read through
    /// `slopdesk_term_surface_hyperlink_runs` in `SlopDeskTerminal`. Two readings of one code is how
    /// the two overlays start disagreeing about what a span is, so there is one reading and the
    /// module boundary widens to reach it rather than a second `switch` being written.
    package static func kind(of code: UInt32) -> DetectedLinkKind? {
        switch code {
        case UInt32(SLOPDESK_LINK_KIND_ABSOLUTE_PATH): .absolutePath
        case UInt32(SLOPDESK_LINK_KIND_TILDE_PATH): .tildePath
        case UInt32(SLOPDESK_LINK_KIND_RELATIVE_PATH): .relativePath
        case UInt32(SLOPDESK_LINK_KIND_PATH_LINE_COL): .pathLineCol
        case UInt32(SLOPDESK_LINK_KIND_URL): .url
        case UInt32(SLOPDESK_LINK_KIND_FILE_URL): .fileURL
        default: nil
        }
    }

    /// The `SLOPDESK_LINK_KIND_*` code for a kind — ``kind(of:)`` read backwards, for the doors the
    /// client CALLS with a link it already holds (the click-actions table). Total: every kind the
    /// scan can report has a code, which is why this direction needs no `nil`.
    static func code(of kind: DetectedLinkKind) -> UInt32 {
        switch kind {
        case .absolutePath: SLOPDESK_LINK_KIND_ABSOLUTE_PATH
        case .tildePath: SLOPDESK_LINK_KIND_TILDE_PATH
        case .relativePath: SLOPDESK_LINK_KIND_RELATIVE_PATH
        case .pathLineCol: SLOPDESK_LINK_KIND_PATH_LINE_COL
        case .url: SLOPDESK_LINK_KIND_URL
        case .fileURL: SLOPDESK_LINK_KIND_FILE_URL
        }
    }

    /// Concatenates `values` into one UTF-8 buffer and the byte length of each — the boundary's
    /// list-of-strings form, one allocation instead of one per element.
    ///
    /// Module-internal rather than private because `HintLabelAssigner` marshals the SAME four lists
    /// to a door that takes them the same way; a second copy of this would be a second bug.
    static func flatten(_ values: [String]) -> (blob: [UInt8], lengths: [Int]) {
        var blob: [UInt8] = []
        var lengths: [Int] = []
        lengths.reserveCapacity(values.count)
        blob.reserveCapacity(values.reduce(0) { $0 + $1.utf8.count })
        for value in values {
            let before = blob.count
            blob.append(contentsOf: value.utf8)
            lengths.append(blob.count - before)
        }
        return (blob, lengths)
    }

    /// Reads one `(offset, length)` span out of the scan's arena.
    ///
    /// This door spells its pair `size_t`, the way §4 spells every length, so the `Int` overload is
    /// the one it reaches for. `package` for ``kind(of:)``'s reason — one arena reader, not one per
    /// module.
    package static func text(_ arena: UnsafeRawBufferPointer, _ offset: Int, _ length: Int) -> String {
        ArenaText.text(arena, offset, length)
    }
}
