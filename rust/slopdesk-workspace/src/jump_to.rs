//! The ⌘J Jump-To panel's rows — which detections and which blocks earn one, and what each is
//! called.
//!
//! The panel lists two things that arrived by different roads: the interactive spans
//! [`slopdesk_terminal::link`] found in the focused pane's scrollback, and the OSC-133 command and
//! prompt blocks its shell reported. Both become rows of the SAME picker, so both are classified
//! from the one vocabulary the picker already speaks — [`Kind`] — rather than from a second enum
//! that would have to be kept in step with it.
//!
//! ## What is decided here
//! - **The collapse.** Every path-like detection reads as [`Kind::Path`]. The detector is pure and
//!   cannot `stat`, so it cannot tell a file from a folder; one honest "Path" badge beats a guessed
//!   File/Folder split that is wrong half the time.
//! - **The dedup.** A path printed forty times in a build log is ONE row. The key is the CLASSIFIED
//!   kind beside the raw text, not the detected one, so `/etc/hosts` and `file:///etc/hosts` stay
//!   two rows while an absolute path and the same path with a `:12:3` suffix — which read as
//!   different raws — stay two as well.
//! - **The cap.** [`MAX_LINK_ITEMS`] bounds the LINK half. Terminal output is attacker-influenced
//!   and a pathological scrollback can hold thousands of distinct paths; the block half needs no
//!   cap because the block index is already bounded where it is kept.
//! - **The skip.** A block whose command text is still empty is mid-capture, not a row.
//!
//! Only the ORDER and the CLASSIFICATION cross back: the caller keeps its own detections and blocks
//! and is told which of them to draw, so no scrollback text makes a second trip through the
//! boundary just to be handed back unchanged.

use std::collections::HashSet;

use slopdesk_terminal::link::DetectedLinkKind;

use crate::open_quickly::Kind;

/// The ceiling on LINK rows — validate-then-bound over attacker-influenced terminal output.
pub const MAX_LINK_ITEMS: usize = 200;

/// One detection that earned a row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LinkRow {
    /// Where it sits in the caller's own detections, which are what it draws from.
    pub index: usize,
    /// What the row is called — the badge and the symbol are this kind's.
    pub kind: Kind,
}

/// Which detections and which blocks earn a row, in draw order.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Rows {
    /// The surviving detections, in detection order — they lead the panel.
    pub links: Vec<LinkRow>,
    /// The surviving blocks, as indices into the caller's array, in the order it gave them (the
    /// panel is fed newest-first).
    pub blocks: Vec<usize>,
}

/// What a detection is called in the picker's vocabulary.
#[must_use]
pub const fn kind_of(detected: DetectedLinkKind) -> Kind {
    match detected {
        DetectedLinkKind::Url => Kind::Url,
        DetectedLinkKind::FileUrl => Kind::FileUrl,
        DetectedLinkKind::AbsolutePath
        | DetectedLinkKind::TildePath
        | DetectedLinkKind::RelativePath
        | DetectedLinkKind::PathLineCol => Kind::Path,
    }
}

/// The panel's rows: the deduped, capped detections first, then the non-empty blocks.
#[must_use]
pub fn rows(links: &[(DetectedLinkKind, &str)], blocks: &[&str]) -> Rows {
    let mut seen: HashSet<(u8, &str)> = HashSet::with_capacity(links.len().min(MAX_LINK_ITEMS));
    let mut kept = Vec::with_capacity(links.len().min(MAX_LINK_ITEMS));

    for (index, (detected, raw)) in links.iter().enumerate() {
        let kind = kind_of(*detected);
        if !seen.insert((kind.code(), raw)) {
            continue;
        }
        kept.push(LinkRow { index, kind });
        if kept.len() >= MAX_LINK_ITEMS {
            break;
        }
    }

    Rows {
        links: kept,
        blocks: blocks
            .iter()
            .enumerate()
            .filter(|(_, text)| !text.is_empty())
            .map(|(index, _)| index)
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use slopdesk_terminal::link::DetectedLinkKind;

    use super::{MAX_LINK_ITEMS, Rows, kind_of, rows};
    use crate::open_quickly::Kind;

    /// The collapse, spelled out: four path forms read as one badge, and the two URL forms keep
    /// theirs. A `file://` URL that read as a plain URL would lose the "File" badge the row earns
    /// for carrying a real filesystem path.
    #[test]
    fn every_path_form_collapses_and_the_two_url_forms_do_not() {
        for path in [
            DetectedLinkKind::AbsolutePath,
            DetectedLinkKind::TildePath,
            DetectedLinkKind::RelativePath,
            DetectedLinkKind::PathLineCol,
        ] {
            assert_eq!(kind_of(path), Kind::Path, "{path:?}");
        }
        assert_eq!(kind_of(DetectedLinkKind::Url), Kind::Url);
        assert_eq!(kind_of(DetectedLinkKind::FileUrl), Kind::FileUrl);
    }

    #[test]
    fn the_links_lead_in_detection_order_and_the_blocks_follow_in_the_order_given() {
        let answer = rows(
            &[
                (DetectedLinkKind::AbsolutePath, "/usr/local/bin/foo"),
                (DetectedLinkKind::Url, "https://example.test/x"),
                (DetectedLinkKind::FileUrl, "file:///a/b.txt"),
            ],
            &["git status", "ls -la"],
        );
        assert_eq!(answer.links.iter().map(|row| row.index).collect::<Vec<_>>(), [
            0, 1, 2
        ]);
        assert_eq!(answer.links.iter().map(|row| row.kind).collect::<Vec<_>>(), [
            Kind::Path,
            Kind::Url,
            Kind::FileUrl
        ]);
        assert_eq!(answer.blocks, [0, 1]);
    }

    /// The same path printed three times is one row — a build log repeats a path per warning.
    #[test]
    fn a_repeated_detection_earns_one_row() {
        let answer = rows(&[(DetectedLinkKind::AbsolutePath, "/etc/hosts"); 3], &[]);
        assert_eq!(answer.links.len(), 1);
        assert_eq!(
            answer.links.first().map(|row| row.index),
            Some(0),
            "the FIRST sighting is the row"
        );
    }

    /// The dedup key carries the kind, so a path and the `file://` URL naming it stay two rows: they
    /// badge differently and they open differently.
    #[test]
    fn the_same_text_under_two_kinds_stays_two_rows() {
        let answer = rows(
            &[
                (DetectedLinkKind::AbsolutePath, "/etc/hosts"),
                (DetectedLinkKind::FileUrl, "/etc/hosts"),
            ],
            &[],
        );
        assert_eq!(answer.links.len(), 2);
    }

    /// …and the collapse runs BEFORE the dedup, so two path FORMS spelling the same raw are one row
    /// rather than two identically-badged ones.
    #[test]
    fn two_path_forms_of_one_raw_collapse_to_a_single_row() {
        let answer = rows(
            &[
                (DetectedLinkKind::AbsolutePath, "/etc/hosts"),
                (DetectedLinkKind::PathLineCol, "/etc/hosts"),
            ],
            &[],
        );
        assert_eq!(answer.links.len(), 1);
    }

    #[test]
    fn a_still_forming_block_is_skipped_without_shifting_the_ones_around_it() {
        let answer = rows(&[], &["make build", "", "ls"]);
        assert_eq!(answer.blocks, [0, 2], "the index is the CALLER's, not a rank");
    }

    /// A pathological scrollback is bounded, and the bound counts DISTINCT rows: a log that repeats
    /// three paths ten thousand times still fills three.
    #[test]
    fn the_link_half_is_capped_at_the_ceiling() {
        let raws: Vec<String> = (0..MAX_LINK_ITEMS + 50).map(|n| format!("/p/{n}")).collect();
        let links: Vec<_> = raws
            .iter()
            .map(|raw| (DetectedLinkKind::AbsolutePath, raw.as_str()))
            .collect();
        assert_eq!(rows(&links, &[]).links.len(), MAX_LINK_ITEMS);
    }

    #[test]
    fn nothing_detected_and_nothing_captured_answers_nothing() {
        assert_eq!(rows(&[], &[]), Rows::default());
    }
}
