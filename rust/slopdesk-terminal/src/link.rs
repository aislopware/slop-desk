//! Paths, `path:line:col` diagnostics and URLs, found in the rows of the terminal grid.
//!
//! The scan that drives the ⌘-hold underline, Jump-To and Hint Mode. It is a deterministic text
//! fold with no host round-trip — the client already knows the pane's cwd from OSC 7 — so the same
//! function answers for all three surfaces and the GUI's only job is mapping `col_start..col_end`
//! to pixels.
//!
//! ## Bounded and total over hostile input
//!
//! Every row here was printed by whatever program holds the far side of a PTY. So the scan is
//! bounded in both directions: at most [`MAX_SCAN_COLUMNS`] cells are read per row, so a
//! pathological megabyte line with no whitespace in it cannot hang the scan, and at most
//! [`MAX_MATCHES_PER_ROW`] spans are emitted, so a row of ten thousand tiny URLs cannot flood the
//! overlay. A span that classifies as nothing is DROPPED rather than guessed at.
//!
//! ## Columns are display cells
//!
//! `col_start..col_end` are terminal CELLS, not bytes and not chars: an East-Asian-wide glyph
//! counts 2, a combining mark counts as its base. That is what lets the geometry seam multiply by
//! the cell width and get a rectangle, with no second measuring pass.

/// Per-row ceiling on emitted spans — the OUTPUT bound, independent of [`MAX_SCAN_COLUMNS`].
pub const MAX_MATCHES_PER_ROW: usize = 512;

/// Default per-row cell-scan ceiling — the anti-hang bound on the INPUT.
pub const MAX_SCAN_COLUMNS: usize = 4096;

/// What a detected span turned out to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum DetectedLinkKind {
    /// A `/`-rooted filesystem path.
    AbsolutePath,
    /// A `~`-anchored path. Expanding it needs the HOST's `$HOME`, so
    /// [`DetectedLink::resolved_absolute`] stays `None`.
    TildePath,
    /// A `./…`, `../…` or bare `dir/file` path, resolved against the pane cwd.
    RelativePath,
    /// Any of the above carrying a `:line` or `:line:col` suffix — compiler and linter output.
    /// `raw` keeps the suffix; the resolved path drops it.
    PathLineCol,
    /// A `scheme://…` URL the policy allows, or an always-on `mailto:` address.
    Url,
    /// A `file://…` URL. Its filesystem path is surfaced in [`DetectedLink::resolved_absolute`].
    FileUrl,
}

/// One detected interactive span in one row.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DetectedLink {
    /// Index into the rows that were scanned — NOT a scrollback line number.
    pub row: usize,
    /// First display cell of the span.
    pub col_start: usize,
    /// One past the last display cell.
    pub col_end: usize,
    /// What the span is.
    pub kind: DetectedLinkKind,
    /// The matched text exactly, line/col suffix included.
    pub raw: String,
    /// The absolute filesystem path when it derives PURELY — an absolute path normalised, a
    /// relative path joined to an absolute cwd, a `file://` path percent-decoded. `None` otherwise: a tilde
    /// path needs `$HOME` and a plain URL is not a filesystem path at all.
    pub resolved_absolute: Option<String>,
}

use slopdesk_sanitize::escape::percent_decoded;

/// Which `scheme://…` URLs are underlined — the "Auto-Detect Link Schemes" setting.
///
/// `http`, `https`, `file` and `mailto` are detected whatever this says; the policy governs only
/// the other schemes.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum LinkSchemePolicy {
    /// Any well-formed scheme. The default.
    All,
    /// The always-on four plus this list, compared case-insensitively.
    Custom(Vec<String>),
}

/// Detects every interactive span in `rows`, in row-major left-to-right order.
///
/// `cwd` is the pane's last-known OSC 7 directory and is used only when it is itself absolute.
/// `max_scan_columns` of `0` scans nothing rather than scanning everything.
#[must_use]
pub fn detect(
    rows: &[&str],
    cwd: Option<&str>,
    schemes: &LinkSchemePolicy,
    max_scan_columns: usize,
) -> Vec<DetectedLink> {
    if max_scan_columns == 0 {
        return Vec::new();
    }
    let mut found = Vec::new();
    for (row, line) in rows.iter().enumerate() {
        let mut matches_this_row = 0;
        for token in tokenize(line, max_scan_columns) {
            if matches_this_row >= MAX_MATCHES_PER_ROW {
                break;
            }
            let (core, leading_cells) = trim_wrapping(&token.text);
            let Some(link) = classify(&core, row, token.cell_start + leading_cells, cwd, schemes) else {
                continue;
            };
            found.push(link);
            matches_this_row += 1;
        }
    }
    found
}

/// A whitespace-delimited run, with the display cell its first cluster occupies.
#[derive(Debug, Clone)]
struct RawToken {
    text: String,
    cell_start: usize,
}

/// Splits `line` on spaces and tabs, tracking display cells and stopping once `max_scan_columns`
/// cells have been consumed.
///
/// A token that BEGAN inside the bound but runs past it is kept truncated: bounded work, and never
/// a span reported outside the region actually examined.
fn tokenize(line: &str, max_scan_columns: usize) -> Vec<RawToken> {
    let mut tokens = Vec::new();
    let mut cell = 0;
    let mut current = String::new();
    let mut current_start = 0;
    for cluster in clusters(line) {
        if cell >= max_scan_columns {
            break;
        }
        let width = cluster_cells(cluster);
        if cluster == " " || cluster == "\t" {
            if !current.is_empty() {
                tokens.push(RawToken {
                    text: core::mem::take(&mut current),
                    cell_start: current_start,
                });
            }
            cell += width;
            continue;
        }
        if current.is_empty() {
            current_start = cell;
        }
        current.push_str(cluster);
        cell += width;
    }
    if !current.is_empty() {
        tokens.push(RawToken {
            text: current,
            cell_start: current_start,
        });
    }
    tokens
}

/// Openers stripped from the front of a token.
const LEADING_TRIM: [char; 9] = ['(', '[', '{', '<', '"', '\'', '`', '\u{201C}', '\u{2018}'];

/// Sentence punctuation and closers stripped from the back. `:` is deliberately ABSENT — the
/// `:line:col` suffix has to survive this.
const TRAILING_TRIM: [char; 14] = [
    '.', ',', ';', '!', '?', ')', ']', '}', '>', '"', '\'', '`', '\u{201D}', '\u{2019}',
];

/// Closers whose trim is balanced against their opener inside the same token.
const BALANCED_CLOSERS: [(char, char); 3] = [(')', '('), (']', '['), ('}', '{')];

/// Strips wrapping brackets/quotes and trailing sentence punctuation, so `(https://x.com).` becomes
/// `https://x.com`.
///
/// A closing bracket is trimmed only when UNBALANCED — more of it than its opener remains in the
/// token. That keeps a URL whose path legitimately ends in a matched close
/// (`…/Swift_(programming_language)`) intact while still stripping prose's `(https://x.com)`, which
/// is the same rule iTerm2 and ghostty settle on.
///
/// Returns the core plus the cells removed from the FRONT, so the caller can advance `cell_start`;
/// a trailing trim never moves it.
fn trim_wrapping(text: &str) -> (String, usize) {
    let mut chars: Vec<char> = text.chars().collect();
    let mut leading_cells = 0;
    while chars.first().is_some_and(|first| LEADING_TRIM.contains(first)) {
        if let Some(first) = chars.first() {
            leading_cells += scalar_cells(*first);
        }
        chars.remove(0);
    }
    while let Some(&last) = chars.last() {
        if !TRAILING_TRIM.contains(&last) {
            break;
        }
        if let Some(&(_, opener)) = BALANCED_CLOSERS.iter().find(|&&(closer, _)| closer == last) {
            let close_count = chars.iter().filter(|&&c| c == last).count();
            let open_count = chars.iter().filter(|&&c| c == opener).count();
            if close_count <= open_count {
                break;
            }
        }
        chars.pop();
    }
    (chars.into_iter().collect(), leading_cells)
}

/// URL, then `mailto:`, then filesystem path — the first that matches wins.
fn classify(
    core: &str,
    row: usize,
    cell_start: usize,
    cwd: Option<&str>,
    schemes: &LinkSchemePolicy,
) -> Option<DetectedLink> {
    if core.is_empty() {
        return None;
    }
    classify_url(core, row, cell_start, schemes)
        .or_else(|| classify_mailto(core, row, cell_start))
        .or_else(|| classify_path(core, row, cell_start, cwd))
}

/// `scheme://…`, including `file://…`.
///
/// A scheme the policy excludes is DROPPED rather than reinterpreted as a path: it is unambiguously
/// a URL, and one the user asked not to have detected.
fn classify_url(
    core: &str,
    row: usize,
    cell_start: usize,
    schemes: &LinkSchemePolicy,
) -> Option<DetectedLink> {
    let separator = core.find("://")?;
    let scheme = core.get(..separator)?;
    if !is_valid_scheme(scheme) {
        return None;
    }
    // A bare `scheme://` with nothing after it is not a link.
    if core.get(separator + 3..).is_none_or(str::is_empty) {
        return None;
    }
    let lowered = scheme.to_lowercase();
    let (kind, resolved) = if lowered == "file" {
        (DetectedLinkKind::FileUrl, file_url_path(core))
    } else if is_scheme_allowed(&lowered, schemes) {
        (DetectedLinkKind::Url, None)
    } else {
        return None;
    };
    Some(DetectedLink {
        row,
        col_start: cell_start,
        col_end: cell_start + text_cells(core),
        kind,
        raw: core.to_owned(),
        resolved_absolute: resolved,
    })
}

/// `mailto:user@host` — always detected, policy or not. A bare `mailto:` with no `@` is dropped.
fn classify_mailto(core: &str, row: usize, cell_start: usize) -> Option<DetectedLink> {
    let lowered = core.to_lowercase();
    if !lowered.starts_with("mailto:") {
        return None;
    }
    let address = core.get("mailto:".len()..)?;
    if address.is_empty() || !address.contains('@') {
        return None;
    }
    Some(DetectedLink {
        row,
        col_start: cell_start,
        col_end: cell_start + text_cells(core),
        kind: DetectedLinkKind::Url,
        raw: core.to_owned(),
        resolved_absolute: None,
    })
}

/// The four shapes a filesystem candidate can have.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PathShape {
    Absolute,
    Tilde,
    RelativeDot,
    BareRelative,
}

/// Absolute, tilde, relative and `path:line[:col]` filesystem paths.
fn classify_path(core: &str, row: usize, cell_start: usize, cwd: Option<&str>) -> Option<DetectedLink> {
    // Trailing colons come off FIRST. A log line's `/path:` is the obvious case, but the one that
    // matters is the standard compiler diagnostic `path:line:col:` — its trailing colon would defeat
    // the suffix split, leaving `:line:col` baked into the resolved path so open and reveal both
    // fail. Then split the numeric suffix off what is left.
    let cleaned = core.trim_end_matches(':');
    let (path_part, suffix) = split_line_col(cleaned);
    if path_part.is_empty() {
        return None;
    }
    let shape = path_shape(&path_part)?;
    // Decorative prompt art — a starship cat's `/ᐠ`, a powerline glyph — frequently starts with `/`
    // and is not a path. Such art is a SINGLE exotic glyph after the root; a real path is
    // structured. So drop a candidate only when it is BOTH single-segment AND carries no ordinary
    // path character. A multi-segment path (`/дом/данные`, `~/デスクトップ`, where the anchor counts
    // as a segment) or any path with an ASCII alphanumeric in it still passes, so a genuine
    // non-Latin path keeps its underline and only the lone-glyph decoration is dropped.
    let has_ordinary_char = path_part.chars().any(|c| c.is_ascii_alphanumeric());
    let segment_count = path_part.split('/').filter(|segment| !segment.is_empty()).count();
    if !has_ordinary_char && segment_count < 2 {
        return None;
    }
    let has_line_col = !suffix.is_empty();
    // A bare `dir/file` with no `./` or `../` anchor is a link ONLY with a line:col suffix.
    // Otherwise prose like `and/or` and an SCP remote like `git@host:org/repo` would light up.
    if shape == PathShape::BareRelative && !has_line_col {
        return None;
    }
    let raw = format!("{path_part}{suffix}");
    let cells = text_cells(&raw);
    Some(DetectedLink {
        row,
        col_start: cell_start,
        col_end: cell_start + cells,
        kind: if has_line_col {
            DetectedLinkKind::PathLineCol
        } else {
            kind_for(shape)
        },
        raw,
        resolved_absolute: resolve_path(&path_part, shape, cwd),
    })
}

fn path_shape(path: &str) -> Option<PathShape> {
    if path.starts_with('/') {
        Some(PathShape::Absolute)
    } else if path == "~" || path.starts_with("~/") {
        Some(PathShape::Tilde)
    } else if path.starts_with("./") || path.starts_with("../") {
        Some(PathShape::RelativeDot)
    } else if path.contains('/') {
        Some(PathShape::BareRelative)
    } else {
        None
    }
}

const fn kind_for(shape: PathShape) -> DetectedLinkKind {
    match shape {
        PathShape::Absolute => DetectedLinkKind::AbsolutePath,
        PathShape::Tilde => DetectedLinkKind::TildePath,
        PathShape::RelativeDot | PathShape::BareRelative => DetectedLinkKind::RelativePath,
    }
}

/// Resolves to an absolute path PURELY — no `$HOME`, no disk.
///
/// A tilde path stays unresolved on purpose: `~` expansion needs the HOST's home directory and is
/// done host-side by the open/reveal action, where it is a fact rather than a guess.
fn resolve_path(path: &str, shape: PathShape, cwd: Option<&str>) -> Option<String> {
    match shape {
        PathShape::Absolute => Some(lexically_normalize(path)),
        PathShape::Tilde => None,
        PathShape::RelativeDot | PathShape::BareRelative => {
            let cwd = cwd.filter(|cwd| cwd.starts_with('/'))?;
            Some(lexically_normalize(&format!("{cwd}/{path}")))
        },
    }
}

/// Splits a trailing `:line` or `:line:col` numeric suffix off `text`, keeping the suffix's leading
/// colon.
///
/// A clock time `12:34` yields `("12", ":34")` — and `12` then fails the path-shape test, which is
/// how times and `host:port` pairs stay out of the results.
fn split_line_col(text: &str) -> (String, String) {
    let chars: Vec<char> = text.chars().collect();

    // The start index of a `:<digits>` run ENDING at `end`, if there is one.
    let colon_number = |end: usize| -> Option<usize> {
        let mut index = end;
        let mut saw_digit = false;
        while index > 0 && chars.get(index - 1).is_some_and(char::is_ascii_digit) {
            index -= 1;
            saw_digit = true;
        }
        (saw_digit && index > 0 && chars.get(index - 1) == Some(&':')).then(|| index - 1)
    };

    let split_at = |at: usize| -> (String, String) {
        (
            chars.get(..at).unwrap_or_default().iter().collect(),
            chars.get(at..).unwrap_or_default().iter().collect(),
        )
    };

    let Some(col_start) = colon_number(chars.len()) else {
        return (text.to_owned(), String::new());
    };
    split_at(colon_number(col_start).unwrap_or(col_start))
}

fn is_valid_scheme(scheme: &str) -> bool {
    let mut chars = scheme.chars();
    chars.next().is_some_and(|first| first.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.')
}

fn is_scheme_allowed(lowercased_scheme: &str, policy: &LinkSchemePolicy) -> bool {
    if matches!(lowercased_scheme, "http" | "https" | "file" | "mailto") {
        return true;
    }
    match policy {
        LinkSchemePolicy::All => true,
        LinkSchemePolicy::Custom(list) => {
            list.iter()
                .any(|allowed| allowed.to_lowercase() == lowercased_scheme)
        },
    }
}

/// The filesystem path of a `file://…` URL: `file:///a/b` → `/a/b`, `file://host/a/b` → `/a/b`,
/// percent-decoded so `%20` becomes a space. `None` when there is no path component.
fn file_url_path(core: &str) -> Option<String> {
    let separator = core.find("://")?;
    let after_scheme = core.get(separator + 3..)?;
    let path = if after_scheme.starts_with('/') {
        after_scheme
    } else {
        after_scheme.get(after_scheme.find('/')?..)?
    };
    Some(percent_decoded(path).unwrap_or_else(|| path.to_owned()))
}

/// Collapses `.` and `..` segments lexically, with no disk access.
///
/// An absolute input stays absolute and a `..` cannot climb out of the root; a relative input keeps
/// the leading `..` it has no way to resolve.
fn lexically_normalize(path: &str) -> String {
    let is_absolute = path.starts_with('/');
    let mut stack: Vec<&str> = Vec::new();
    for segment in path.split('/').filter(|segment| !segment.is_empty()) {
        match segment {
            "." => {},
            ".." => {
                if stack.last().is_some_and(|last| *last != "..") {
                    stack.pop();
                } else if !is_absolute {
                    stack.push("..");
                }
            },
            other => stack.push(other),
        }
    }
    let joined = stack.join("/");
    if is_absolute { format!("/{joined}") } else { joined }
}

// MARK: display cells

/// Display width of one grapheme cluster in terminal cells: `0` for a zero-width or
/// default-ignorable base, `2` for East-Asian-wide, fullwidth and emoji, else `1`.
///
/// Exposed because Hint Mode's label assigner maps its own matches — git hashes, IPs, user patterns
/// — to cell columns, and those have to line up with the spans this module reports on a CJK row.
/// One source of truth for the width or the two overlays disagree.
#[must_use]
pub fn cluster_cells(cluster: &str) -> usize {
    cluster.chars().next().map_or(0, scalar_cells)
}

/// Display width of `text` in terminal cells — the sum over its grapheme clusters.
#[must_use]
pub fn text_cells(text: &str) -> usize {
    clusters(text).map(cluster_cells).sum()
}

/// Width of a single scalar. Zero-width is checked BEFORE wide, which is what makes U+115F — both a
/// Hangul Jamo filler and default-ignorable — count as nothing rather than two.
///
/// Exposed alongside [`cluster_cells`] because the callers that walk a line one character at a time
/// — vi-style line motion, the hint assigner's column mapping — already hold a scalar. Handing them
/// only the `&str` form would make them build a one-character string per cell to ask a question
/// about the scalar they were already holding.
#[must_use]
pub const fn scalar_cells(scalar: char) -> usize {
    if is_zero_width(scalar) {
        0
    } else if is_wide(scalar) {
        2
    } else {
        1
    }
}

const fn is_zero_width(scalar: char) -> bool {
    matches!(
        scalar as u32,
        // Default_Ignorable_Code_Point, spelled out rather than pulled from a Unicode crate: the
        // set is small, stable, and a dependency here would buy nothing this table does not.
        0x00AD | 0x034F | 0x061C | 0x115F..=0x1160 | 0x17B4..=0x17B5 | 0x180B..=0x180E
            | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x206F | 0x3164 | 0xFE00..=0xFE0F
            | 0xFEFF | 0xFFA0 | 0xFFF0..=0xFFF8 | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A
            | 0xE0000..=0xE0FFF
            // Combining marks, whose width belongs to the base they attach to.
            | 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF
            | 0xFE20..=0xFE2F
    )
}

const fn is_wide(scalar: char) -> bool {
    matches!(
        scalar as u32,
        0x1100..=0x115F      // Hangul Jamo
            | 0x2E80..=0x303E    // CJK radicals through CJK symbols and punctuation
            | 0x3041..=0x33FF    // Hiragana, katakana, CJK compatibility
            | 0x3400..=0x4DBF    // CJK unified ideographs extension A
            | 0x4E00..=0x9FFF    // CJK unified ideographs
            | 0xA000..=0xA4CF    // Yi syllables and radicals
            | 0xAC00..=0xD7A3    // Hangul syllables
            | 0xF900..=0xFAFF    // CJK compatibility ideographs
            | 0xFE30..=0xFE4F    // CJK compatibility forms
            | 0xFF00..=0xFF60    // Fullwidth forms
            | 0xFFE0..=0xFFE6    // Fullwidth signs
            | 0x1F300..=0x1FAFF  // Emoji and pictographs
            | 0x20000..=0x3FFFD // CJK unified ideographs extension B and beyond
    )
}

/// Whether `scalar` continues the cluster it follows rather than starting a new one.
///
/// A pragmatic subset of UAX #29 rather than the whole algorithm: a zero-width scalar extends
/// (combining marks, variation selectors), and so does an emoji skin-tone modifier. The remaining
/// case — the scalar AFTER a zero-width joiner — is handled by the iterator, which needs to know
/// what it just consumed.
const fn extends_cluster(scalar: char) -> bool {
    is_zero_width(scalar) || matches!(scalar as u32, 0x1F3FB..=0x1F3FF)
}

const ZERO_WIDTH_JOINER: char = '\u{200D}';

const fn is_regional_indicator(scalar: char) -> bool {
    matches!(scalar as u32, 0x1F1E6..=0x1F1FF)
}

/// Groups `text` into grapheme clusters.
///
/// Terminals measure in clusters, not scalars: `é` written as `e` plus a combining acute is one
/// cell, and a ZWJ family emoji is two, not eight. Handled here rather than by a segmentation crate
/// because the cases a terminal actually renders — combining marks, variation selectors, ZWJ
/// sequences, skin tones, flag pairs — are exactly the ones above, and a dependency would bring a
/// Unicode table this file measures in five lines.
pub(crate) fn clusters(text: &str) -> impl Iterator<Item = &str> {
    let mut chars = text.char_indices().peekable();
    core::iter::from_fn(move || {
        let (start, first) = chars.next()?;
        // A flag is exactly two regional indicators, so the pair is taken and no more.
        let paired_flag = is_regional_indicator(first)
            && chars.peek().is_some_and(|&(_, next)| is_regional_indicator(next));
        let (mut end, mut previous) = match chars.next_if(|_| paired_flag) {
            Some((_, next)) => (start + first.len_utf8() + next.len_utf8(), next),
            None => (start + first.len_utf8(), first),
        };
        while let Some(&(_, next)) = chars.peek() {
            if !extends_cluster(next) && previous != ZERO_WIDTH_JOINER {
                break;
            }
            chars.next();
            end += next.len_utf8();
            previous = next;
        }
        text.get(start..end)
    })
}

#[cfg(test)]
mod tests {
    use super::{
        DetectedLink, DetectedLinkKind, LinkSchemePolicy, MAX_MATCHES_PER_ROW, MAX_SCAN_COLUMNS, detect,
        text_cells,
    };

    fn scan(line: &str, cwd: Option<&str>) -> Vec<DetectedLink> {
        detect(&[line], cwd, &LinkSchemePolicy::All, MAX_SCAN_COLUMNS)
    }

    fn only(line: &str, cwd: Option<&str>) -> DetectedLink {
        let mut found = scan(line, cwd);
        assert_eq!(found.len(), 1, "{line:?} produced {found:?}");
        found.remove(0)
    }

    #[test]
    fn an_absolute_path_is_normalised_without_touching_the_disk() {
        let link = only("see /usr/local/./bin/../bin/foo now", None);
        assert_eq!(link.kind, DetectedLinkKind::AbsolutePath);
        assert_eq!(link.raw, "/usr/local/./bin/../bin/foo");
        assert_eq!(link.resolved_absolute.as_deref(), Some("/usr/local/bin/foo"));
    }

    #[test]
    fn a_dot_dot_cannot_climb_out_of_the_root() {
        let link = only("/../../etc/passwd", None);
        assert_eq!(link.resolved_absolute.as_deref(), Some("/etc/passwd"));
    }

    #[test]
    fn a_tilde_path_is_detected_but_left_for_the_host_to_expand() {
        let link = only("~/project/file.swift", None);
        assert_eq!(link.kind, DetectedLinkKind::TildePath);
        assert_eq!(link.resolved_absolute, None);
    }

    #[test]
    fn a_relative_path_resolves_only_against_an_absolute_cwd() {
        let link = only("./src/main.rs", Some("/work/repo"));
        assert_eq!(link.kind, DetectedLinkKind::RelativePath);
        assert_eq!(link.resolved_absolute.as_deref(), Some("/work/repo/src/main.rs"));
        // A relative cwd is no better than none.
        assert_eq!(only("./src/main.rs", Some("repo")).resolved_absolute, None);
        assert_eq!(only("./src/main.rs", None).resolved_absolute, None);
    }

    #[test]
    fn a_bare_relative_run_is_a_link_only_when_it_carries_a_line_number() {
        assert!(scan("and/or", None).is_empty());
        assert!(scan("git@host:org/repo", None).is_empty());
        let link = only("src/lib.rs:42:5", Some("/work"));
        assert_eq!(link.kind, DetectedLinkKind::PathLineCol);
        assert_eq!(link.raw, "src/lib.rs:42:5");
        assert_eq!(link.resolved_absolute.as_deref(), Some("/work/src/lib.rs"));
    }

    #[test]
    fn a_compiler_diagnostics_trailing_colon_does_not_land_in_the_resolved_path() {
        // `path:line:col:` — the form every C and Rust diagnostic prints.
        let link = only("/work/src/lib.rs:42:5: error: nope", None);
        assert_eq!(link.kind, DetectedLinkKind::PathLineCol);
        assert_eq!(link.raw, "/work/src/lib.rs:42:5");
        assert_eq!(link.resolved_absolute.as_deref(), Some("/work/src/lib.rs"));
    }

    #[test]
    fn a_line_only_suffix_is_kept_in_raw_and_dropped_from_the_path() {
        let link = only("/work/src/lib.rs:42", None);
        assert_eq!(link.raw, "/work/src/lib.rs:42");
        assert_eq!(link.resolved_absolute.as_deref(), Some("/work/src/lib.rs"));
    }

    #[test]
    fn a_clock_time_and_a_host_port_never_light_up() {
        assert!(scan("12:34", None).is_empty());
        assert!(scan("localhost:8080", None).is_empty());
    }

    #[test]
    fn wrapping_punctuation_comes_off_but_a_balanced_bracket_stays() {
        assert_eq!(only("(https://x.com).", None).raw, "https://x.com");
        assert_eq!(
            only("https://en.wikipedia.org/wiki/Swift_(programming_language)", None).raw,
            "https://en.wikipedia.org/wiki/Swift_(programming_language)"
        );
        // An unbalanced close is still prose punctuation.
        assert_eq!(only("[see https://x.com/a)", None).raw, "https://x.com/a");
    }

    #[test]
    fn the_leading_trim_advances_the_start_column_and_the_trailing_trim_does_not() {
        let link = only("ab (https://x.com).", None);
        // "ab" 2 + space 1 + "(" 1 = 4.
        assert_eq!(link.col_start, 4);
        assert_eq!(link.col_end, 4 + text_cells("https://x.com"));
    }

    #[test]
    fn a_file_url_surfaces_a_percent_decoded_path() {
        let link = only("file:///Users/me/My%20Notes.txt", None);
        assert_eq!(link.kind, DetectedLinkKind::FileUrl);
        assert_eq!(link.resolved_absolute.as_deref(), Some("/Users/me/My Notes.txt"));
        // The host form drops the authority.
        let hosted = only("file://server/share/a.txt", None);
        assert_eq!(hosted.resolved_absolute.as_deref(), Some("/share/a.txt"));
    }

    #[test]
    fn a_malformed_percent_escape_leaves_the_path_undecoded_rather_than_trapping() {
        let link = only("file:///tmp/100%25/a%ZZb", None);
        assert_eq!(link.resolved_absolute.as_deref(), Some("/tmp/100%25/a%ZZb"));
    }

    #[test]
    fn mailto_is_detected_whatever_the_policy_says_and_needs_an_at_sign() {
        let strict = LinkSchemePolicy::Custom(Vec::new());
        let found = detect(&["mailto:me@example.com"], None, &strict, MAX_SCAN_COLUMNS);
        assert_eq!(found.len(), 1);
        assert_eq!(found.first().map(|link| link.kind), Some(DetectedLinkKind::Url));
        assert!(detect(&["mailto:"], None, &strict, MAX_SCAN_COLUMNS).is_empty());
    }

    #[test]
    fn the_custom_policy_gates_other_schemes_and_never_reinterprets_them_as_paths() {
        let policy = LinkSchemePolicy::Custom(vec!["SSH".to_owned()]);
        let rows = ["ssh://host/path", "codex://open/x", "https://x.com", "file:///a"];
        let found = detect(&rows, None, &policy, MAX_SCAN_COLUMNS);
        let rows_hit: Vec<usize> = found.iter().map(|link| link.row).collect();
        // Row 1 is excluded, and it does NOT come back as a path.
        assert_eq!(rows_hit, vec![0, 2, 3]);
    }

    #[test]
    fn a_scheme_that_is_not_a_scheme_falls_through_to_the_path_rules() {
        // Digits cannot start a scheme, so this is not a URL — and it is not a path either.
        assert!(scan("1abc://x", None).is_empty());
    }

    #[test]
    fn cjk_glyphs_count_two_cells_so_the_columns_still_land_on_the_glyph() {
        let link = only("名前 /Users/名前/notes.txt", None);
        // "名前" is 4 cells plus the space.
        assert_eq!(link.col_start, 5);
        assert_eq!(link.col_end, 5 + text_cells("/Users/名前/notes.txt"));
        assert_eq!(text_cells("/Users/名前/notes.txt"), "/Users//notes.txt".len() + 4);
    }

    #[test]
    fn a_combining_mark_and_a_zwj_emoji_each_measure_as_their_base() {
        assert_eq!(text_cells("e\u{0301}"), 1);
        assert_eq!(text_cells("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}"), 2);
        assert_eq!(text_cells("\u{1F44D}\u{1F3FD}"), 2);
        // A flag is ONE cluster, and its width comes from the first regional indicator — which sits
        // at U+1F1E6..U+1F1FF, below the emoji block, so the table calls it narrow. Terminals
        // disagree with each other here; what matters is that the two indicators are not counted
        // twice, because that is what would slide every column after a flag.
        assert_eq!(text_cells("\u{1F1FB}\u{1F1F3}"), 1);
    }

    #[test]
    fn decorative_prompt_art_is_dropped_but_a_non_latin_path_is_not() {
        assert!(scan("/\u{1420}", None).is_empty(), "a lone glyph after the root");
        let link = only("/дом/данные", None);
        assert_eq!(link.kind, DetectedLinkKind::AbsolutePath);
        assert_eq!(only("~/デスクトップ", None).kind, DetectedLinkKind::TildePath);
    }

    #[test]
    fn ordinary_prose_produces_nothing() {
        assert!(scan("TODO/DONE — nothing here at all, really.", None).is_empty());
        assert!(scan("", None).is_empty());
        assert!(scan("     ", None).is_empty());
    }

    #[test]
    fn the_column_scan_stops_at_the_bound_rather_than_running_the_whole_row() {
        let mut line = "x".repeat(64);
        line.push_str(" /a/b");
        // The path begins at cell 65, so a bound below that never sees it.
        assert!(detect(&[&line], None, &LinkSchemePolicy::All, 64).is_empty());
        assert_eq!(detect(&[&line], None, &LinkSchemePolicy::All, 4096).len(), 1);
        // Zero scans nothing rather than everything.
        assert!(detect(&[&line], None, &LinkSchemePolicy::All, 0).is_empty());
    }

    #[test]
    fn a_token_that_begins_inside_the_bound_is_kept_truncated() {
        let line = format!("/a/{}", "b".repeat(100));
        let found = detect(&[&line], None, &LinkSchemePolicy::All, 10);
        assert_eq!(found.len(), 1);
        assert_eq!(found.first().map(|link| link.raw.as_str()), Some("/a/bbbbbbb"));
    }

    #[test]
    fn a_row_can_never_emit_more_than_its_share_of_matches() {
        let line = vec!["/a/b"; MAX_MATCHES_PER_ROW + 50].join(" ");
        let found = detect(&[&line], None, &LinkSchemePolicy::All, usize::MAX);
        assert_eq!(found.len(), MAX_MATCHES_PER_ROW);
    }

    #[test]
    fn rows_are_reported_in_row_major_left_to_right_order() {
        let found = detect(
            &["/a /b", "nothing", "/c"],
            None,
            &LinkSchemePolicy::All,
            MAX_SCAN_COLUMNS,
        );
        let seen: Vec<(usize, usize)> = found.iter().map(|link| (link.row, link.col_start)).collect();
        assert_eq!(seen, vec![(0, 0), (0, 3), (2, 0)]);
    }
}
