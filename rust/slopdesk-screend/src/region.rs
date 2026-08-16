//! A rule's `region` spec — which slice of the detection input its gate evaluates against.
//!
//! Ported from Swift `ManifestRegion`, which was itself a port of herdr's `region()` +
//! `validate_region_name`. The round trip is why this file is short: the Swift copy had to
//! reimplement `str::lines()` byte-exactly (Swift's grapheme-based `split` never splits `\r\n`)
//! and re-derive Rust's `trim()` from `whitespacesAndNewlines`. Here those are the language.

use crate::detect::Input;

/// Which slice of the screen (or which OSC field) a rule reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Region {
    /// The retained OSC 0/2 window title, alone.
    OscTitle,
    /// The retained OSC 9 progress payload, alone.
    OscProgress,
    /// The whole detection text.
    WholeRecent,
    /// Everything after the last codex-style `›` prompt line.
    AfterLastPromptMarker,
    /// Everything before the CURRENT codex prompt line (one with no block marker after it).
    BeforeCurrentPromptMarker,
    /// The whole text, but empty when a current codex prompt line exists.
    WholeRecentWithoutCurrentPromptMarker,
    /// The last codex block marker line above the current prompt.
    CurrentPromptBlockMarker,
    /// Everything from that block marker down.
    AfterCurrentPromptBlockMarker,
    /// The body of the last box: between its top border and the next horizontal rule.
    PromptBoxBody,
    /// Everything above the last box's top border.
    AbovePromptBox,
    /// The last non-blank line above the last box.
    LastNonEmptyAbovePromptBox,
    /// Everything after the last horizontal rule.
    AfterLastHorizontalRule,
    /// The last `n` lines, blank ones included.
    BottomLines(usize),
    /// From the `n`-th non-blank line counted from the bottom, down.
    BottomNonEmptyLines(usize),
    /// Down to the `n`-th non-blank line counted from the top.
    TopNonEmptyLines(usize),
}

impl Region {
    /// Parses a (pre-trimmed) region spec. `None` = invalid name, which rejects the whole
    /// manifest — a typo must never silently degrade to `whole_recent`.
    #[must_use]
    pub fn parse(spec: &str) -> Option<Self> {
        match spec {
            "osc_title" => return Some(Self::OscTitle),
            "osc_progress" => return Some(Self::OscProgress),
            "whole_recent" => return Some(Self::WholeRecent),
            "after_last_prompt_marker" => return Some(Self::AfterLastPromptMarker),
            "before_current_prompt_marker" => return Some(Self::BeforeCurrentPromptMarker),
            "whole_recent_without_current_prompt_marker" => {
                return Some(Self::WholeRecentWithoutCurrentPromptMarker);
            },
            "current_prompt_block_marker" => return Some(Self::CurrentPromptBlockMarker),
            "after_current_prompt_block_marker" => return Some(Self::AfterCurrentPromptBlockMarker),
            "prompt_box_body" => return Some(Self::PromptBoxBody),
            "above_prompt_box" => return Some(Self::AbovePromptBox),
            "last_non_empty_above_prompt_box" => return Some(Self::LastNonEmptyAbovePromptBox),
            "after_last_horizontal_rule" => return Some(Self::AfterLastHorizontalRule),
            _ => {},
        }
        if let Some(count) = plain_count(spec, "bottom_lines") {
            return Some(Self::BottomLines(count));
        }
        if let Some(count) = plain_count(spec, "bottom_non_empty_lines") {
            return Some(Self::BottomNonEmptyLines(count));
        }
        top_count(spec).map(Self::TopNonEmptyLines)
    }

    /// TRUE for the one spec family that needs an engine-3 manifest.
    #[must_use]
    pub fn is_top_non_empty_lines(spec: &str) -> bool {
        spec.starts_with("top_non_empty_lines(")
    }

    /// Resolves this region against one detection input. The OSC regions ignore the screen.
    #[must_use]
    pub fn resolve(self, input: &Input) -> &str {
        match self {
            Self::OscTitle => input.osc_title.as_str(),
            Self::OscProgress => input.osc_progress.as_str(),
            _ => self.resolve_screen(input.screen.as_str()),
        }
    }

    /// The screen-reading half. Every arm returns a SLICE of `content`, never a new string —
    /// the Swift port rebuilt a `String` per rule per region, ~20 allocations per pane per scan.
    #[must_use]
    #[expect(
        clippy::too_many_lines,
        reason = "one arm per region; splitting it would hide the table"
    )]
    pub fn resolve_screen(self, content: &str) -> &str {
        let lines: Vec<&str> = content.lines().collect();
        match self {
            // Handled in `resolve`; a bare `resolve_screen` on an OSC region reads nothing.
            Self::OscTitle | Self::OscProgress => "",
            Self::WholeRecent => content,
            Self::AfterLastPromptMarker => {
                lines
                    .iter()
                    .rposition(|line| is_codex_prompt_line(line))
                    .map_or(content, |index| suffix_from_line(content, &lines, index + 1))
            },
            Self::BeforeCurrentPromptMarker => {
                current_codex_prompt_index(&lines)
                    .map_or(content, |index| prefix_to_line(content, &lines, index))
            },
            Self::WholeRecentWithoutCurrentPromptMarker => {
                if current_codex_prompt_index(&lines).is_some() {
                    ""
                } else {
                    content
                }
            },
            Self::CurrentPromptBlockMarker => {
                current_codex_prompt_index(&lines)
                    .and_then(|prompt| {
                        lines[..prompt]
                            .iter()
                            .rev()
                            .find(|line| is_codex_block_marker_line(line))
                    })
                    .copied()
                    .unwrap_or_default()
            },
            Self::AfterCurrentPromptBlockMarker => {
                current_codex_prompt_index(&lines)
                    .and_then(|prompt| {
                        lines[..prompt]
                            .iter()
                            .rposition(|line| is_codex_block_marker_line(line))
                    })
                    .map_or("", |block| suffix_from_line(content, &lines, block))
            },
            Self::PromptBoxBody => {
                prompt_box_top_border_index(&lines).map_or("", |top| {
                    let start = byte_offset_of_line(&lines, content.len(), top + 1);
                    let end_line = lines[top + 1..]
                        .iter()
                        .position(|line| is_horizontal_rule(line))
                        .map_or(lines.len(), |offset| top + 1 + offset);
                    let end = byte_offset_of_line(&lines, content.len(), end_line);
                    slice(content, start, end)
                })
            },
            Self::AbovePromptBox => {
                prompt_box_top_border_index(&lines)
                    .map_or(content, |top| prefix_to_line(content, &lines, top))
            },
            Self::LastNonEmptyAbovePromptBox => {
                Self::AbovePromptBox
                    .resolve_screen(content)
                    .lines()
                    .rfind(|line| !line.trim().is_empty())
                    .unwrap_or_default()
            },
            Self::AfterLastHorizontalRule => {
                let mut last_rule_end = 0;
                let mut offset = 0;
                for line in &lines {
                    let next = offset + line.len() + 1;
                    if is_horizontal_rule(line) {
                        last_rule_end = next.min(content.len());
                    }
                    offset = next;
                }
                slice(content, last_rule_end, content.len())
            },
            Self::BottomLines(count) => suffix_from_line(content, &lines, lines.len().saturating_sub(count)),
            Self::BottomNonEmptyLines(count) => {
                if count == 0 {
                    return "";
                }
                let mut start = None;
                let mut taken = 0;
                for (index, line) in lines.iter().enumerate().rev() {
                    if line.trim().is_empty() {
                        continue;
                    }
                    start = Some(index);
                    taken += 1;
                    if taken == count {
                        break;
                    }
                }
                start.map_or("", |index| suffix_from_line(content, &lines, index))
            },
            Self::TopNonEmptyLines(count) => {
                if count == 0 {
                    return "";
                }
                let mut end = None;
                let mut taken = 0;
                for (index, line) in lines.iter().enumerate() {
                    if line.trim().is_empty() {
                        continue;
                    }
                    end = Some(index);
                    taken += 1;
                    if taken == count {
                        break;
                    }
                }
                end.map_or("", |index| prefix_to_line(content, &lines, index + 1))
            },
        }
    }
}

/// herdr `region_count`: a bare `usize` parse (so `+1` / `01` are accepted, as upstream's is).
fn plain_count(spec: &str, name: &str) -> Option<usize> {
    let inner = spec.strip_prefix(name)?.strip_prefix('(')?.strip_suffix(')')?;
    inner.parse().ok()
}

/// herdr `top_region_count`: a canonical positive bounded count — digits only, no leading zero,
/// at most `u16::MAX`.
fn top_count(spec: &str) -> Option<usize> {
    let inner = spec.strip_prefix("top_non_empty_lines(")?.strip_suffix(')')?;
    if inner.is_empty() || inner.starts_with('0') || !inner.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let count: usize = inner.parse().ok()?;
    u16::try_from(count).is_ok().then_some(count)
}

/// Byte offset at which `lines[index]` starts (`index` may equal `lines.len()`), clamped.
///
/// Line lengths are summed as `len + 1` — the `\n`-only accounting herdr uses. A `\r\n` document
/// therefore under-counts by one byte per line, exactly as upstream does; [`slice`] clamps, so
/// the drift can only ever shorten a region, never trap.
fn byte_offset_of_line(lines: &[&str], total: usize, index: usize) -> usize {
    lines[..index.min(lines.len())]
        .iter()
        .map(|line| line.len() + 1)
        .sum::<usize>()
        .min(total)
}

fn suffix_from_line<'a>(content: &'a str, lines: &[&str], index: usize) -> &'a str {
    slice(
        content,
        byte_offset_of_line(lines, content.len(), index),
        content.len(),
    )
}

fn prefix_to_line<'a>(content: &'a str, lines: &[&str], index: usize) -> &'a str {
    slice(content, 0, byte_offset_of_line(lines, content.len(), index))
}

/// A total byte-range slice: clamped to the content, and to the nearest char boundary at or
/// below each end. The offsets are line boundaries of valid UTF-8 by construction, so the
/// boundary walk only ever runs on the `\r\n` drift above — where a shorter region is the safe
/// answer and a panic would be an unhandled hostile screen.
fn slice(content: &str, start: usize, end: usize) -> &str {
    let lower = floor_boundary(content, start.min(content.len()));
    let upper = floor_boundary(content, end.clamp(lower, content.len()));
    content.get(lower..upper).unwrap_or_default()
}

const fn floor_boundary(content: &str, mut index: usize) -> usize {
    while index > 0 && !content.is_char_boundary(index) {
        index -= 1;
    }
    index
}

// MARK: - Line predicates (herdr, exact)

fn is_codex_prompt_line(line: &str) -> bool {
    line == "›" || line.starts_with("› ")
}

fn is_codex_block_marker_line(line: &str) -> bool {
    line.starts_with('•') || line.starts_with('■') || line.starts_with('✗') || line.starts_with('✓')
}

/// The last codex prompt line — "current" only when no block marker appears below it.
fn current_codex_prompt_index(lines: &[&str]) -> Option<usize> {
    let prompt = lines.iter().rposition(|line| is_codex_prompt_line(line))?;
    let has_marker_below = lines[prompt + 1..]
        .iter()
        .any(|line| is_codex_block_marker_line(line));
    (!has_marker_below).then_some(prompt)
}

/// The 2nd horizontal rule counted from the BOTTOM — the top border of the last box.
fn prompt_box_top_border_index(lines: &[&str]) -> Option<usize> {
    let mut seen = 0;
    for (index, line) in lines.iter().enumerate().rev() {
        if is_horizontal_rule(line) {
            seen += 1;
            if seen == 2 {
                return Some(index);
            }
        }
    }
    None
}

/// A leading run of `─` (U+2500). The line is a rule when nothing follows the run, or when the
/// run is at least 3 long — which is what permits `── (bypass permissions on) ─` annotations.
fn is_horizontal_rule(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return false;
    }
    let run = trimmed.chars().take_while(|c| *c == '─').count();
    if run == 0 {
        return false;
    }
    let suffix: String = trimmed.chars().skip(run).collect();
    suffix.trim_start().is_empty() || run >= 3
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen(text: &str) -> Input {
        Input {
            screen: text.to_owned(),
            osc_title: String::new(),
            osc_progress: String::new(),
        }
    }

    #[test]
    fn every_bundled_region_name_parses() {
        for spec in [
            "osc_title",
            "osc_progress",
            "whole_recent",
            "after_last_prompt_marker",
            "before_current_prompt_marker",
            "whole_recent_without_current_prompt_marker",
            "current_prompt_block_marker",
            "after_current_prompt_block_marker",
            "prompt_box_body",
            "above_prompt_box",
            "last_non_empty_above_prompt_box",
            "after_last_horizontal_rule",
            "bottom_lines(5)",
            "bottom_non_empty_lines(3)",
            "top_non_empty_lines(2)",
        ] {
            assert!(Region::parse(spec).is_some(), "{spec}");
        }
        assert!(Region::parse("nope").is_none());
        assert!(Region::parse("bottom_lines()").is_none());
    }

    #[test]
    fn top_non_empty_lines_is_canonical_only() {
        assert_eq!(
            Region::parse("top_non_empty_lines(1)"),
            Some(Region::TopNonEmptyLines(1))
        );
        // A leading zero, a sign, or a spare space is a typo, not a count.
        assert!(Region::parse("top_non_empty_lines(01)").is_none());
        assert!(Region::parse("top_non_empty_lines(+1)").is_none());
        assert!(Region::parse("top_non_empty_lines( 1)").is_none());
        assert!(Region::parse("top_non_empty_lines(65536)").is_none());
        // …while the OTHER two keep herdr's laxer bare parse.
        assert_eq!(Region::parse("bottom_lines(+1)"), Some(Region::BottomLines(1)));
    }

    #[test]
    fn a_rule_is_a_run_of_box_drawing_dashes() {
        assert!(is_horizontal_rule("───"));
        assert!(is_horizontal_rule("─"));
        assert!(is_horizontal_rule("─── (bypass permissions on) ─"));
        // A short run followed by text is a bullet, not a border.
        assert!(!is_horizontal_rule("─ item"));
        assert!(!is_horizontal_rule(""));
        assert!(!is_horizontal_rule("text"));
    }

    #[test]
    fn the_prompt_box_body_sits_between_the_last_two_rules() {
        let text = "chatter\n───\nabove box\n───\ntype here\n───\n";
        assert_eq!(Region::PromptBoxBody.resolve_screen(text), "type here\n");
        assert_eq!(
            Region::AbovePromptBox.resolve_screen(text),
            "chatter\n───\nabove box\n"
        );
        assert_eq!(
            Region::LastNonEmptyAbovePromptBox.resolve_screen(text),
            "above box"
        );
    }

    #[test]
    fn a_dialog_footer_sits_after_the_last_rule() {
        let text = "───\n1. yes\n2. no\n───\nesc to cancel\n";
        assert_eq!(
            Region::AfterLastHorizontalRule.resolve_screen(text),
            "esc to cancel\n"
        );
    }

    #[test]
    fn the_codex_prompt_is_current_only_with_no_marker_below() {
        let live = "› ask me\n";
        assert_eq!(
            Region::WholeRecentWithoutCurrentPromptMarker.resolve_screen(live),
            ""
        );
        let answered = "› ask me\n• ran a tool\n";
        assert_eq!(
            Region::WholeRecentWithoutCurrentPromptMarker.resolve_screen(answered),
            answered
        );
        assert_eq!(Region::AfterCurrentPromptBlockMarker.resolve_screen(answered), "");
        let followed = "• ran a tool\n› ask me\n";
        assert_eq!(
            Region::CurrentPromptBlockMarker.resolve_screen(followed),
            "• ran a tool"
        );
        assert_eq!(
            Region::AfterCurrentPromptBlockMarker.resolve_screen(followed),
            followed
        );
    }

    #[test]
    fn counted_regions_count_the_right_lines() {
        let text = "a\n\nb\n\nc\n";
        assert_eq!(Region::BottomLines(2).resolve_screen(text), "\nc\n");
        assert_eq!(Region::BottomNonEmptyLines(2).resolve_screen(text), "b\n\nc\n");
        assert_eq!(Region::TopNonEmptyLines(2).resolve_screen(text), "a\n\nb\n");
        assert_eq!(Region::BottomNonEmptyLines(0).resolve_screen(text), "");
        assert_eq!(Region::TopNonEmptyLines(0).resolve_screen(text), "");
        // Asking for more than exist yields everything there is, never a panic.
        assert_eq!(Region::BottomLines(99).resolve_screen(text), text);
        assert_eq!(Region::BottomNonEmptyLines(99).resolve_screen(text), text);
    }

    #[test]
    fn the_osc_regions_never_read_the_screen() {
        let mut input = screen("a screen");
        input.osc_title = "✳ Claude".to_owned();
        input.osc_progress = "4;0;".to_owned();
        assert_eq!(Region::OscTitle.resolve(&input), "✳ Claude");
        assert_eq!(Region::OscProgress.resolve(&input), "4;0;");
        assert_eq!(Region::WholeRecent.resolve(&input), "a screen");
    }

    #[test]
    fn crlf_offsets_drift_downward_and_never_trap() {
        // `str::lines()` strips the `\r`, but the offset math counts `len + 1` — so a CRLF
        // document's offsets fall SHORT. Clamping is what keeps that a shorter region.
        let text = "one\r\ntwo\r\nthree\r\n";
        for region in [
            Region::BottomLines(1),
            Region::BottomNonEmptyLines(2),
            Region::TopNonEmptyLines(1),
        ] {
            let out = region.resolve_screen(text);
            assert!(text.contains(out), "{out:?} must be a slice of the input");
        }
    }

    #[test]
    fn a_multibyte_screen_slices_on_char_boundaries() {
        let text = "❯ ask\n───\n✳ working\n";
        for region in [
            Region::AfterLastHorizontalRule,
            Region::BottomLines(2),
            Region::TopNonEmptyLines(1),
            Region::AbovePromptBox,
        ] {
            let _ = region.resolve_screen(text);
        }
    }
}
