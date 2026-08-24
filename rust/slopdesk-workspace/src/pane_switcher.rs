//! What one ⌃⇥ switcher row SAYS, how big the card is, and what a TAP on a row means.
//!
//! A row is a PANE, the same unit the sidebar lists and ⌘1…⌘9 lands on. The card is therefore the
//! sidebar in recency order: one line per pane, carrying only what differs — the pane's identity,
//! then a quiet note for the sub-path it strayed into.
//!
//! ⚠️ THE PROJECT RIDES THE ROW, it does not head a section. Section headers were the tab-era shape
//! and they do not survive the unit change: the display order is the frozen ring's (recency), and a
//! header is only worth its line when consecutive rows share it. Tabs came in project-sized runs;
//! PANES interleave — walk between two repos and the ring reads slopdesk, otty, slopdesk, otty,
//! which under a run-boundary rule is a caption above every single row. Re-sorting to fix that is
//! worse still: the card's order is the order ⇥ steps in, so grouping would make the highlight jump
//! around the list. So each row says its own place, on its own second line.

use slopdesk_tree::session::PaneSpec;
use slopdesk_tree::tab_ordering;

/// The words this surface says.
///
/// The Mac's readout has none — a card that lives for 200ms under a held ⌃ is titled by the hand
/// holding it up — and the phone's cannot borrow that silence: it stays up with nothing held, in a
/// family where every card names itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Word {
    /// The card's title — the SAME words the palette row that opens it wears. A surface and the
    /// command that summons it may not come to have two names.
    Title,
    /// The honest zero state. The ring is frozen at open and its panes can close under it, so the
    /// rows CAN empty mid-gesture — and an empty card that still veils the workspace is the defect
    /// this surface exists to answer, said a second time.
    NoPanes,
    /// The forward step control, for the reader who has no ⇥ to press.
    StepForward,
    /// The backward one. Both are named by what they MOVE, not by the ring's direction: "forward"
    /// is a fact about the frozen order, and nobody is holding it.
    StepBackward,
    /// The join between a row's two place halves.
    PlaceSeparator,
}

impl Word {
    /// Every word, in index order — the order one delivery carries them in.
    pub const ALL: [Self; 5] = [
        Self::Title,
        Self::NoPanes,
        Self::StepForward,
        Self::StepBackward,
        Self::PlaceSeparator,
    ];

    /// What it says.
    #[must_use]
    pub const fn text(self) -> &'static str {
        match self {
            Self::Title => "Pane Switcher",
            Self::NoPanes => "No other panes",
            Self::StepForward => "Next pane",
            Self::StepBackward => "Previous pane",
            Self::PlaceSeparator => " \u{203a} ",
        }
    }
}

/// The highest pane the app binds a ⌘-digit to. Past it a row has no shortcut to show.
pub const HIGHEST_SHORTCUT: usize = 9;

/// Below this a genuine title truncates on nearly every row.
pub const MIN_WIDTH: f64 = 400.0;

/// The app's widest list-panel rung. Past ~75 characters a line stops being scannable.
pub const MAX_WIDTH: f64 = 640.0;

/// Of the window, between the two bounds. At 1280 that is 538; at 1524 and wider it reaches the
/// cap.
pub const WIDTH_FRACTION: f64 = 0.42;

/// The hard share of the window the card may occupy.
///
/// It outranks [`MIN_WIDTH`], because a card wider than its window is not a floating surface.
pub const WIDTH_CEILING_FRACTION: f64 = 0.66;

/// The card may not grow past this share of the window's height; beyond it the rows scroll.
pub const HEIGHT_FRACTION: f64 = 0.7;

/// How wide the card stands in a window `container` points across.
///
/// A fixed width is wrong for this surface in a way it is not wrong for a dialog: the rows carry
/// LIVE text of wildly varying length, so the right measure depends on how much room the window can
/// spare. The band is MEASURED at SF 13 in this row anatomy — 45 characters is the low end of a
/// comfortable measure (390pt of card), 60 lands a real command line (490), 75 is the high end past
/// which the eye loses the line (590).
#[must_use]
pub fn width(container: f64) -> f64 {
    if container <= 0.0 {
        return MIN_WIDTH;
    }
    let ideal = (container * WIDTH_FRACTION).clamp(MIN_WIDTH, MAX_WIDTH);
    ideal.min(container * WIDTH_CEILING_FRACTION)
}

/// The tallest the card may stand in a window `container` points high.
///
/// An unmeasured container has no ceiling: a first layout pass must not clamp the card to zero.
#[must_use]
pub fn max_height(container: f64) -> f64 {
    if container <= 0.0 {
        return f64::INFINITY;
    }
    container * HEIGHT_FRACTION
}

/// The width the card takes on a COMPACT screen — the phone's rung of the same measure.
///
/// ⚠️ NEITHER BOUND ABOVE SURVIVES THE MOVE, and that is arithmetic rather than taste. The floor is
/// 400 and an iPhone's whole screen is 390, so the "a real command, untruncated" guarantee is not
/// available at any width here. The ceiling is worse: applied to a 390pt screen it answers with a
/// 257pt card — every row truncated, a third of the screen spent on ground whose only job is to be
/// not-the-card. Its premise is the workspace BEHIND, and a phone screen has no behind.
///
/// So the compact rung keeps exactly the one bound that was never about the window: past ~75
/// characters the eye loses the line, on any screen.
///
/// An unmeasured container yields the CAP rather than the floor: the phone's frame is a max width,
/// so the enclosing padding still bounds it, where returning the floor would ask a 390pt screen for
/// a card wider than itself.
#[must_use]
pub fn compact_width(container: f64) -> f64 {
    if container <= 0.0 {
        return MAX_WIDTH;
    }
    container.min(MAX_WIDTH)
}

/// How tall the ROWS stand: their true height, capped at the ceiling past which they scroll.
///
/// The Mac asks a laid-out stack for its fitting size and takes the smaller of that and the
/// ceiling. `SwiftUI` cannot be asked: a scroll view claims every point it is OFFERED along its
/// axis, so a two-row card left to the framework stands 70% of the screen tall with its two rows at
/// the top. The sum is exact rather than an estimate — the row is a fixed-height object in both
/// halves, which is what makes the list's rhythm a constant beat — so the caller passes that height
/// in.
#[must_use]
pub fn list_height(rows: usize, row_height: f64, container: f64) -> f64 {
    #[expect(
        clippy::cast_precision_loss,
        reason = "a row count large enough to lose precision is a list nobody can scroll"
    )]
    let total = rows as f64 * row_height;
    total.min(max_height(container))
}

/// A walk around the frozen ring: how many single steps, and which way.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Walk {
    /// The direction each step takes, in the gesture's own sense.
    pub forward: bool,
    /// How many of them. Zero when the highlight is already on the target.
    pub steps: usize,
}

/// The WALK a tap is — the phone's commit rule, and the reason it is a walk rather than a jump.
///
/// A Mac commits by releasing the ⌃ it is holding. A phone has no modifier to release, so the touch
/// gesture that picks a pane is a tap on its row. What that tap must NOT become is a SECOND COMMIT
/// DOOR: the store's commit unwinds the follow-along preview before it stages focus, and refuses a
/// candidate whose pane closed under the gesture. A view reaching past it for a plain reveal would
/// have neither guard. So a tap is spelled in the gesture's two existing verbs: STEP until the
/// highlight is the tapped row, then COMMIT.
///
/// The direction is the SHORTER way round the ring, and that is not cosmetic: every step previews
/// its pane, so the count is the number of device-focus writes a single tap costs. They all land
/// inside one runloop turn — nothing renders between them — but half a ring of them is still half a
/// ring more than the walk needs. A tie goes FORWARD, the direction a bare ⇥ walks.
///
/// ⚠️ CANDIDATE INDEX SPACE, NOT ROW SPACE. A candidate whose pane closed under the held gesture is
/// dropped from the rows, so the third ROW can be the fourth CANDIDATE — and the highlight the
/// gesture moves is the candidate's.
#[must_use]
pub const fn walk(from: usize, to: usize, count: usize) -> Walk {
    if count <= 1 {
        return Walk {
            forward: true,
            steps: 0,
        };
    }
    // Both ends are folded into the ring before the subtraction, so an index the caller kept past a
    // shrink cannot walk the wrong way rather than the long way.
    let ahead = (to % count + count - from % count) % count;
    if ahead == 0 {
        return Walk {
            forward: true,
            steps: 0,
        };
    }
    let behind = count - ahead;
    if ahead <= behind {
        Walk {
            forward: true,
            steps: ahead,
        }
    } else {
        Walk {
            forward: false,
            steps: behind,
        }
    }
}

/// A title that only restates the place line under it yields to the pane's program.
///
/// BOTH halves of that line count. The project is the obvious case (`slopdesk` over `slopdesk`),
/// but the note's LAST component is the same stutter one level down: a shell sitting in
/// `Sources/…/Overlays` titles itself by the folder-name rung, and the row then reads `Overlays`
/// over `slopdesk › Sources/SlopDeskClientCore/Overlays`. That was invisible while the path lived
/// in a section header the row could not see; with the place on the row it is a line saying one
/// word twice.
#[must_use]
pub fn unrepeated<'a>(
    title: &'a str,
    project: Option<&str>,
    note: Option<&str>,
    process_label: Option<&'a str>,
) -> &'a str {
    let note_tail = note.and_then(|note| note.rsplit('/').find(|part| !part.is_empty()));
    if Some(title) != project && Some(title) != note_tail {
        return title;
    }
    crate::rail_title::slot_process_name(process_label).unwrap_or(title)
}

/// The PROJECT a terminal pane belongs to: its project's folder name, or — for a pane with no
/// project key yet — its own folder name, so the row still names a place rather than nowhere.
///
/// [`None`] when there is no cwd at all.
#[must_use]
pub fn project_name(project_key: Option<&str>, cwd: Option<&str>) -> Option<String> {
    tab_ordering::normalized_project_key(project_key).map_or_else(
        || PaneSpec::cwd_display_name(cwd),
        |key| Some(tab_ordering::project_section_header(Some(&key))),
    )
}

/// Where the pane sits BELOW its project root, or [`None`] at the root itself — the project half of
/// the place line already said it.
///
/// A cwd OUTSIDE the key's subtree — a stale key across an un-re-pushed `cd` — gives its own folder
/// name instead: hiding the location would lie, and a relative path cannot be formed.
#[must_use]
pub fn relative_path(project_key: Option<&str>, cwd: Option<&str>) -> Option<String> {
    let key = tab_ordering::normalized_project_key(project_key)?;
    let trimmed = cwd?.trim();
    if trimmed.is_empty() {
        return None;
    }
    let mut end = trimmed.len();
    while end > 1 && trimmed.get(..end).is_some_and(|slice| slice.ends_with('/')) {
        end -= 1;
    }
    let path = trimmed.get(..end).unwrap_or(trimmed);
    if path == key {
        return None;
    }
    path.strip_prefix(&format!("{key}/")).map_or_else(
        || PaneSpec::cwd_display_name(Some(path)),
        |rest| Some(rest.to_owned()),
    )
}

/// The row's quiet remainder: where the pane sits below its project.
///
/// A pane at its root has no note at all, which is the common row and the reason the list reads
/// quiet. The tab's pane COUNT used to ride here, back when a row was a tab and the count was the
/// only thing that could say "this destination holds three shells". A row is now one of those
/// shells, so the count would be a fact about the row's neighbours rather than about the row.
#[must_use]
pub fn note(project_key: Option<&str>, cwd: Option<&str>) -> Option<String> {
    relative_path(project_key, cwd)
}

/// The place line the switcher stacks under the title, as ONE string — for surfaces that carry a
/// single subtitle slot.
///
/// [`None`] when the pane has neither half. A half that draws the two registers separately (the
/// switcher rows do, so the project can go a shade heavier) still spells the separator from
/// [`Word::PlaceSeparator`].
#[must_use]
pub fn place_line(project: Option<&str>, note: Option<&str>) -> Option<String> {
    let parts: Vec<&str> = [project, note].into_iter().flatten().collect();
    if parts.is_empty() {
        return None;
    }
    let joined = parts.join(Word::PlaceSeparator.text());
    (!joined.is_empty()).then_some(joined)
}

#[cfg(test)]
mod tests {
    use super::{
        HIGHEST_SHORTCUT, MAX_WIDTH, MIN_WIDTH, Walk, Word, compact_width, list_height, max_height, note,
        place_line, project_name, relative_path, unrepeated, walk, width,
    };

    #[test]
    fn every_word_says_something_distinct() {
        let mut said: Vec<&str> = Word::ALL.iter().map(|word| word.text()).collect();
        for text in &said {
            assert!(!text.is_empty());
        }
        said.sort_unstable();
        let count = said.len();
        said.dedup();
        assert_eq!(said.len(), count);
        assert_eq!(HIGHEST_SHORTCUT, 9);
    }

    /// The clamp that matters on a small window: the card may not eat two thirds of its host.
    #[test]
    fn the_ceiling_fraction_outranks_the_floor() {
        assert!((width(0.0) - MIN_WIDTH).abs() < f64::EPSILON);
        assert!((width(1280.0) - 537.6).abs() < 0.001);
        assert!((width(2000.0) - MAX_WIDTH).abs() < f64::EPSILON);
        // 500 * 0.66 = 330, below the 400 floor — and the ceiling wins.
        assert!((width(500.0) - 330.0).abs() < 0.001);
    }

    /// The phone rung drops both window-relative bounds and keeps only the reading measure.
    #[test]
    fn the_compact_rung_takes_the_screen_up_to_the_reading_cap() {
        assert!((compact_width(390.0) - 390.0).abs() < f64::EPSILON);
        assert!((compact_width(1024.0) - MAX_WIDTH).abs() < f64::EPSILON);
        assert!(
            (compact_width(0.0) - MAX_WIDTH).abs() < f64::EPSILON,
            "an unmeasured phone frame must not ask for a card wider than the screen",
        );
    }

    #[test]
    fn the_rows_stand_their_true_height_until_the_ceiling() {
        assert!((list_height(2, 44.0, 1000.0) - 88.0).abs() < f64::EPSILON);
        assert!((list_height(100, 44.0, 1000.0) - 700.0).abs() < f64::EPSILON);
        assert!(max_height(0.0).is_infinite());
    }

    /// The claim the walk exists for: never more steps than half the ring.
    #[test]
    fn a_tap_walks_the_shorter_way_round() {
        assert_eq!(walk(0, 3, 10), Walk {
            forward: true,
            steps: 3
        });
        assert_eq!(walk(0, 7, 10), Walk {
            forward: false,
            steps: 3
        });
        assert_eq!(walk(7, 0, 10), Walk {
            forward: true,
            steps: 3
        });
        assert_eq!(walk(3, 3, 10), Walk {
            forward: true,
            steps: 0
        });
        // A tie on an even ring goes forward, the direction a bare ⇥ walks.
        assert_eq!(walk(0, 5, 10), Walk {
            forward: true,
            steps: 5
        });
        assert_eq!(walk(0, 0, 1), Walk {
            forward: true,
            steps: 0
        });
        assert_eq!(walk(0, 0, 0), Walk {
            forward: true,
            steps: 0
        });
    }

    #[test]
    fn no_walk_ever_exceeds_half_the_ring() {
        for count in 1..24_usize {
            for from in 0..count {
                for to in 0..count {
                    let step = walk(from, to, count);
                    assert!(step.steps * 2 <= count, "{from}->{to} of {count}: {step:?}");
                }
            }
        }
    }

    /// A row that says one word twice is the defect; the program name is what stands in.
    #[test]
    fn a_title_that_restates_its_place_yields_to_the_program() {
        assert_eq!(unrepeated("slopdesk", Some("slopdesk"), None, Some("zsh")), "zsh");
        assert_eq!(
            unrepeated(
                "Overlays",
                Some("slopdesk"),
                Some("Sources/ClientCore/Overlays"),
                Some("zsh")
            ),
            "zsh",
        );
        assert_eq!(unrepeated("nvim", Some("slopdesk"), None, Some("zsh")), "nvim");
        // Nothing to yield TO leaves the redundant title standing: a blank line says less.
        assert_eq!(unrepeated("slopdesk", Some("slopdesk"), None, None), "slopdesk");
    }

    #[test]
    fn a_pane_without_a_key_still_names_a_place() {
        assert_eq!(
            project_name(Some("/a/slopdesk"), None).as_deref(),
            Some("slopdesk")
        );
        assert_eq!(project_name(None, Some("/a/b/otty")).as_deref(), Some("otty"));
        assert_eq!(project_name(None, None), None);
        // A key with a trailing slash names the same project as one without.
        assert_eq!(
            project_name(Some("/a/slopdesk/"), None).as_deref(),
            Some("slopdesk")
        );
    }

    #[test]
    fn the_note_is_the_path_below_the_root_and_nothing_at_it() {
        assert_eq!(relative_path(Some("/a/slopdesk"), Some("/a/slopdesk")), None);
        assert_eq!(relative_path(Some("/a/slopdesk"), Some("/a/slopdesk/")), None);
        assert_eq!(
            relative_path(Some("/a/slopdesk"), Some("/a/slopdesk/Sources/Rail")).as_deref(),
            Some("Sources/Rail"),
        );
        assert_eq!(relative_path(None, Some("/a/slopdesk/Sources")), None);
        assert_eq!(
            note(Some("/a/slopdesk"), Some("/a/slopdesk/x")).as_deref(),
            Some("x")
        );
    }

    /// A stale key across an un-re-pushed `cd` must show WHERE the pane is, not hide it.
    #[test]
    fn a_cwd_outside_its_key_names_its_own_folder() {
        assert_eq!(
            relative_path(Some("/a/slopdesk"), Some("/b/otty/Sources")).as_deref(),
            Some("Sources"),
        );
        // Not a prefix match on the raw string: a sibling directory is outside the subtree.
        assert_eq!(
            relative_path(Some("/a/slop"), Some("/a/slopdesk")).as_deref(),
            Some("slopdesk"),
        );
    }

    #[test]
    fn a_place_line_joins_only_the_halves_it_has() {
        assert_eq!(
            place_line(Some("slopdesk"), Some("Sources")).as_deref(),
            Some("slopdesk \u{203a} Sources")
        );
        assert_eq!(place_line(Some("slopdesk"), None).as_deref(), Some("slopdesk"));
        assert_eq!(place_line(None, Some("Sources")).as_deref(), Some("Sources"));
        assert_eq!(place_line(None, None), None);
    }
}
