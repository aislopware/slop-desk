//! Which rows the sidebar SHOWS, in what order, and what they are called when two of them collide.
//!
//! [`rail_title`](crate::rail_title) says what ONE pane is called on its own. This says what
//! happens to a pane once it is standing next to every other one: whether the search field keeps
//! it, which section it lands in, where it sits inside that section, and what its label becomes
//! when a neighbour claims the same one.
//!
//! ## Why the answers are indices
//!
//! A row is a whole record on the near side — an id, a kind, a badge, a live title, a selection
//! flag. Almost none of that decides where it goes, so almost none of it crosses. What crosses is
//! the two or three fields each rule reads; what comes back is the ORDER, naming every row by its
//! position in the list the caller already holds. Nothing is copied that the caller could point at.
//!
//! ## One collision rule, two things collide
//!
//! Two ROWS can share a title (`src` in `api/` and in `web/`) and two SECTIONS can share a header
//! (two worktrees of `myapp`), and both are broken the same way: take the parent segment of the
//! path the label came from. They are one function here — [`disambiguated_label`] — because they
//! are one rule, and a second copy is how the row list and the header list start disagreeing about
//! which `myapp` you are looking at.

use crate::rail_title::parent_qualified_title;
use crate::tab_ordering::bucketed_by_project;

/// The fields the search field reads on one row.
///
/// Two of them are never drawn. A git-repo row shows its git line where its path would be, so
/// without the raw `cwd` it could not be found by path at all; and the foreground process answers
/// "which pane is running the thing I am looking for" without taking any room to do it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RowFields<'a> {
    /// The row's visible title.
    pub title: &'a str,
    /// The row's visible subtitle, when it has one.
    pub subtitle: Option<&'a str>,
    /// The pane's working directory — hidden, and searchable.
    pub cwd: Option<&'a str>,
    /// The foreground process — hidden, and searchable.
    pub process_label: Option<&'a str>,
}

/// One row as the sectioning reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlanRow<'a> {
    /// The pane's OWN project key, not its tab's. A split tab's two panes belong to their
    /// respective projects, and which section a pane draws in must not change with which pane
    /// is focused.
    pub project_key: Option<&'a str>,
    /// Where this row's tab sits in the display order. A row whose tab is absent from that order
    /// sorts last, stably — [`usize::MAX`] is that absence.
    pub tab_rank: usize,
}

/// Where one row ends up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placement {
    /// The row's index in the list the caller passed in.
    pub row_index: usize,
    /// Which section it landed in, counting from the first section drawn.
    pub section: usize,
}

/// A label that may have to be told apart from an identical one, and the path it came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Label<'a> {
    /// What is currently shown — a row's title, or a section's header.
    pub text: &'a str,
    /// The path the label was derived from: the pane's cwd, or the section's project key. `None`
    /// when there is nothing to qualify it with, which is also how a label the user typed arrives.
    pub source: Option<&'a str>,
}

/// Whether a row survives `query`.
///
/// A blank query keeps everything. Matching is case-folded containment across the two visible
/// fields and the two hidden ones — folded on both sides, so a query and a title that differ only
/// in case still meet.
#[must_use]
pub fn row_matches(row: RowFields<'_>, query: &str) -> bool {
    let needle = query.trim().to_lowercase();
    if needle.is_empty() {
        return true;
    }
    [Some(row.title), row.subtitle, row.cwd, row.process_label]
        .into_iter()
        .flatten()
        .any(|field| field.to_lowercase().contains(&needle))
}

/// Every row's place in the drawn list, in draw order.
///
/// Sections come out alphabetical by the header they will show, the keyless "Other" bucket last;
/// rows inside a section follow the display order of their tabs, ties broken by the order they
/// arrived so a split tab's panes keep their pre-order. Every input row comes back exactly once —
/// the rail draws what it is given, and a row silently dropped here would be a pane you could no
/// longer reach.
#[must_use]
pub fn plan(rows: &[PlanRow<'_>]) -> Vec<Placement> {
    let sections = bucketed_by_project((0..rows.len()).collect(), |index| {
        rows.get(*index)
            .and_then(|row| row.project_key.map(str::to_owned))
    });
    let mut out = Vec::with_capacity(rows.len());
    for (section, (_, mut members)) in sections.into_iter().enumerate() {
        // Arrival order IS the tiebreak, so a stable sort on the rank alone is the whole rule.
        members.sort_by_key(|index| rows.get(*index).map_or(usize::MAX, |row| row.tab_rank));
        out.extend(
            members
                .into_iter()
                .map(|row_index| Placement { row_index, section }),
        );
    }
    out
}

/// What `items[index]` should be called once identical labels have been told apart, or `None` to
/// leave it exactly as it is.
///
/// A label no one else claims stands. A shared one takes its source's parent segment
/// (`feature-a/myapp`), and only when the label was DERIVED from that path — a name the user typed
/// that happens to collide is their word for that pane, and a rail that rewrote it would be
/// answering a question nobody asked. A label with no parent to name also stands: two identical
/// rows are a smaller problem than one row wearing a label that means nothing.
#[must_use]
pub fn disambiguated_label(items: &[Label<'_>], index: usize) -> Option<String> {
    let subject = items.get(index)?;
    let collides = items
        .iter()
        .enumerate()
        .any(|(other, candidate)| other != index && candidate.text == subject.text);
    if !collides {
        return None;
    }
    parent_qualified_title(subject.source, subject.text)
}

#[cfg(test)]
mod tests {
    use super::{Label, Placement, PlanRow, RowFields, disambiguated_label, plan, row_matches};

    const fn row<'a>(
        title: &'a str,
        subtitle: Option<&'a str>,
        cwd: Option<&'a str>,
        process: Option<&'a str>,
    ) -> RowFields<'a> {
        RowFields {
            title,
            subtitle,
            cwd,
            process_label: process,
        }
    }

    const fn planned(project_key: Option<&str>, tab_rank: usize) -> PlanRow<'_> {
        PlanRow {
            project_key,
            tab_rank,
        }
    }

    const fn label<'a>(text: &'a str, source: Option<&'a str>) -> Label<'a> {
        Label { text, source }
    }

    fn labelled(items: &[Label<'_>]) -> Vec<Option<String>> {
        (0..items.len())
            .map(|index| disambiguated_label(items, index))
            .collect()
    }

    #[test]
    fn a_blank_query_keeps_every_row() {
        let candidate = row("api", None, None, None);
        assert!(row_matches(candidate, ""));
        assert!(row_matches(candidate, "   "));
    }

    #[test]
    fn the_hidden_fields_are_searchable_and_the_fold_runs_both_ways() {
        let candidate = row("API", Some("2 ahead"), Some("/w/myapp/api"), Some("zsh"));
        assert!(row_matches(candidate, "api"), "the title, case-folded");
        assert!(row_matches(candidate, "AHEAD"), "the subtitle");
        assert!(
            row_matches(candidate, "myapp"),
            "the path, which a git row never draws"
        );
        assert!(row_matches(candidate, "zsh"), "the foreground process");
        assert!(!row_matches(candidate, "nowhere"));
    }

    #[test]
    fn sections_are_alphabetical_and_the_keyless_bucket_is_last() {
        let rows = [
            planned(None, 0),
            planned(Some("/w/zeta"), 1),
            planned(Some("/w/alpha"), 2),
        ];
        assert_eq!(
            plan(&rows),
            [
                Placement {
                    row_index: 2,
                    section: 0
                },
                Placement {
                    row_index: 1,
                    section: 1
                },
                Placement {
                    row_index: 0,
                    section: 2
                },
            ],
            "alpha, zeta, then the panes with no project at all"
        );
    }

    #[test]
    fn rows_inside_a_section_follow_their_tabs_then_their_arrival() {
        let rows = [
            planned(Some("/w/app"), 3),
            planned(Some("/w/app"), 1),
            // Two panes of one tab: same rank, so the split's pre-order decides.
            planned(Some("/w/app"), 1),
        ];
        assert_eq!(
            plan(&rows)
                .iter()
                .map(|place| place.row_index)
                .collect::<Vec<_>>(),
            [1, 2, 0]
        );
    }

    #[test]
    fn a_row_whose_tab_is_missing_sorts_last_without_disappearing() {
        let rows = [planned(Some("/w/app"), usize::MAX), planned(Some("/w/app"), 0)];
        let placements = plan(&rows);
        assert_eq!(
            placements.iter().map(|place| place.row_index).collect::<Vec<_>>(),
            [1, 0]
        );
        assert_eq!(placements.len(), rows.len(), "every row is still drawn");
    }

    #[test]
    fn a_key_that_differs_only_by_a_trailing_slash_is_one_section() {
        let rows = [planned(Some("/w/app"), 0), planned(Some("/w/app/"), 1)];
        let placements = plan(&rows);
        assert!(
            placements.iter().all(|place| place.section == 0),
            "a cwd and a git toplevel that differ by a slash name one project"
        );
    }

    #[test]
    fn a_shared_row_title_takes_its_folder_and_a_unique_one_is_left_alone() {
        assert_eq!(
            labelled(&[
                label("src", Some("/w/api/src")),
                label("src", Some("/w/web/src")),
                label("docs", Some("/w/api/docs")),
            ]),
            [Some("api/src".to_owned()), Some("web/src".to_owned()), None]
        );
    }

    #[test]
    fn a_shared_section_header_takes_its_keys_parent() {
        assert_eq!(
            labelled(&[
                label("myapp", Some("/w/feature-a/myapp")),
                label("myapp", Some("/w/feature-b/myapp")),
                label("solo", Some("/w/solo")),
                label("Other", None),
            ]),
            [
                Some("feature-a/myapp".to_owned()),
                Some("feature-b/myapp".to_owned()),
                None,
                None,
            ],
            "the same rule the rows use, on the headers"
        );
    }

    #[test]
    fn a_label_the_user_typed_stands_even_when_it_collides() {
        assert_eq!(
            labelled(&[label("scratch", Some("/w/api")), label("scratch", Some("/w/web")),]),
            [None, None],
            "neither title was derived from its folder, so neither is rewritten"
        );
    }

    #[test]
    fn an_index_past_the_end_answers_nothing() {
        assert_eq!(disambiguated_label(&[label("a", None)], 7), None);
    }
}
