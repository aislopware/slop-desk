//! The sidebar's one layout rule: panes bucketed by project, sections A→Z, rows in creation order —
//! and what "the adjacent tab" means when a tab is closed.
//!
//! There is no grouping menu, no date buckets, no recency sort and no manual reorder. What matters
//! here is that the bucketing exists ONCE. It has two runners at two granularities — the rail draws
//! it per PANE, so a split tab straddling two projects appears in both, and the close rule reads it
//! per TAB to decide where focus lands — and two hand-written first-appearance loops would drift.
//! The drift shows up as focus landing in a project the sidebar never drew.
//!
//! ## Why the display order is not the tab array
//!
//! A session's tabs are in CREATION order; the sidebar draws them in PROJECT order. The two
//! disagree the moment a new tab for an already-open project appends past another project's tab.
//! Any rule phrased as "the adjacent tab" has to mean adjacent ON SCREEN, so it reads the grouped
//! order — not the array.
//!
//! ## The comparison
//!
//! Sections order by the header the eye actually scans — the key's basename — using a natural
//! comparison: case-insensitive, with digit runs read as numbers so `app2` precedes `app10`. The
//! full key breaks a header tie, which makes the order TOTAL: two worktrees with the same basename
//! would otherwise compare equal and shuffle between renders.
//!
//! [`natural_compare`] differs from the platform collator it replaces in one respect: it does not
//! fold diacritics, so `Café` and `Cafe` are distinct rather than adjacent. Section headers are
//! directory basenames, where that is a rounding error — but it is a real difference and not an
//! oversight.

use std::cmp::Ordering;

use crate::identity::{PaneId, TabId};
use crate::session::{PaneSpec, Session};

/// The bucket a keyless element lands in.
const OTHER_SECTION_HEADER: &str = "Other";

/// Normalizes a raw project key for BUCKETING: trimmed, trailing slashes stripped, blank treated as
/// absent.
///
/// The trailing-slash strip is load-bearing. A pane's directory and its git toplevel can differ by
/// exactly one slash while naming the same project; without folding that, one directory becomes two
/// identically-titled sections.
#[must_use]
pub fn normalized_project_key(key: Option<&str>) -> Option<String> {
    let trimmed = key?.trim();
    let mut end = trimmed.len();
    while end > 1 && trimmed.get(..end).is_some_and(|slice| slice.ends_with('/')) {
        end -= 1;
    }
    let folded = trimmed.get(..end).unwrap_or(trimmed);
    (!folded.is_empty()).then(|| folded.to_owned())
}

/// The section header for a project key: its last path component, or the whole trimmed key when
/// there is no component to take. A blank key is the keyless bucket.
#[must_use]
pub fn project_section_header(key: Option<&str>) -> String {
    let Some(trimmed) = key.map(str::trim).filter(|key| !key.is_empty()) else {
        return OTHER_SECTION_HEADER.to_owned();
    };
    trimmed
        .split('/')
        .rfind(|part| !part.is_empty())
        .map_or_else(|| trimmed.to_owned(), str::to_owned)
}

/// A natural, case-insensitive comparison: digit runs compare as numbers, everything else by folded
/// character.
///
/// `app2` precedes `app10` because the digits are read as quantities rather than as text.
/// Diacritics are NOT folded — see the module docs.
#[must_use]
fn natural_compare(lhs: &str, rhs: &str) -> Ordering {
    let mut left = lhs.chars().peekable();
    let mut right = rhs.chars().peekable();
    loop {
        let (Some(a), Some(b)) = (left.peek().copied(), right.peek().copied()) else {
            // Whichever ran out first is the shorter, and so the lesser.
            return left.peek().is_some().cmp(&right.peek().is_some());
        };
        if a.is_ascii_digit() && b.is_ascii_digit() {
            let run_left = take_digits(&mut left);
            let run_right = take_digits(&mut right);
            let ordering = compare_digit_runs(&run_left, &run_right);
            if ordering != Ordering::Equal {
                return ordering;
            }
        } else {
            left.next();
            right.next();
            let ordering = folded(a).cmp(&folded(b));
            if ordering != Ordering::Equal {
                return ordering;
            }
        }
    }
}

fn folded(value: char) -> char {
    value.to_lowercase().next().unwrap_or(value)
}

fn take_digits(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) -> String {
    let mut run = String::new();
    while let Some(digit) = chars.peek().copied().filter(char::is_ascii_digit) {
        run.push(digit);
        chars.next();
    }
    run
}

/// Compares two digit runs as quantities, falling back to their written length so `007` and `7`
/// stay distinguishable rather than compared equal — which would make the order non-total.
fn compare_digit_runs(lhs: &str, rhs: &str) -> Ordering {
    let significant_lhs = lhs.trim_start_matches('0');
    let significant_rhs = rhs.trim_start_matches('0');
    significant_lhs
        .len()
        .cmp(&significant_rhs.len())
        .then_with(|| significant_lhs.cmp(significant_rhs))
        .then_with(|| lhs.len().cmp(&rhs.len()))
}

/// The SECTION order: named projects A→Z by their displayed header, the keyless bucket last.
///
/// Last, because the list used to follow first appearance — which made where a project sat a fact
/// about when you happened to open it rather than about what it was called.
#[must_use]
fn section_ordering(lhs: Option<&str>, rhs: Option<&str>) -> Ordering {
    match (lhs, rhs) {
        (None, None) => Ordering::Equal,
        (None, Some(_)) => Ordering::Greater,
        (Some(_), None) => Ordering::Less,
        (Some(left), Some(right)) => {
            natural_compare(&project_section_header(Some(left)), &project_section_header(Some(right)))
                // The key breaks a header tie, which is what makes this order TOTAL.
                .then_with(|| natural_compare(left, right))
        },
    }
}

/// Whether one section precedes another.
#[must_use]
pub fn section_precedes(lhs: Option<&str>, rhs: Option<&str>) -> bool {
    section_ordering(lhs, rhs).is_lt()
}

/// The By-Project key for a pane: its host-pushed project key, else its working directory.
///
/// A transient plugin cache directory is NEVER a project key. The host's resolver can race a
/// shell's internal step into one, which would file a real project's pane under a phantom section;
/// a guarded-out source falls through to the next, so the answer self-heals once the shell settles.
///
/// The lookups are parameters so every caller shares ONE copy of this precedence: the rail reads a
/// store, the close rule reads whichever session owns the closing tab, and the host reads its own
/// document cells.
pub fn pane_project_key(
    pane: PaneId,
    project_key: impl Fn(PaneId) -> Option<String>,
    cwd: impl Fn(PaneId) -> Option<String>,
) -> Option<String> {
    project_key_of(project_key(pane).as_deref(), cwd(pane).as_deref())
}

/// The same precedence over the two VALUES, for a caller that already has both in hand.
///
/// [`pane_project_key`] takes lookups because its callers hold a store, a session or a document and
/// resolving every pane's cells up front would be the wasteful half. A caller resolving a whole
/// LIST at once has already paid that, and threading an id back through a closure to reach a value
/// it is holding would be ceremony. The precedence itself is here and only here.
#[must_use]
pub fn project_key_of(project_key: Option<&str>, cwd: Option<&str>) -> Option<String> {
    if let Some(key) = project_key
        && !key.is_empty()
        && !PaneSpec::looks_like_transient_plugin_cwd(key)
    {
        return Some(key.to_owned());
    }
    cwd.filter(|cwd| !PaneSpec::looks_like_transient_plugin_cwd(cwd))
        .map(str::to_owned)
}

/// A TAB's key for close-selection purposes: its ACTIVE pane's, else its first pane's.
///
/// A tab is one row per PANE in the sidebar, so a split tab straddling two projects genuinely has
/// no single section — it draws in both. The pane being looked at is the honest answer to "which
/// section did this tab live in", and it is the one the close gesture was aimed at.
pub fn tab_project_key(
    tab: TabId,
    session: &Session,
    pane_key: impl Fn(PaneId) -> Option<String>,
) -> Option<String> {
    let tab = session.tabs.iter().find(|candidate| candidate.id == tab)?;
    if let Some(active) = tab.active_pane
        && let Some(key) = pane_key(active)
    {
        return Some(key);
    }
    tab.all_pane_ids().into_iter().find_map(pane_key)
}

/// Buckets elements into project sections: keys folded, sections alphabetical by header, elements
/// within a section in the order they arrived.
///
/// Sections are PAIRS keyed on an optional string rather than a map behind a sentinel: a stand-in
/// string for the keyless case would merely look coupled to the rail's own collapse key while
/// answering a different question. Absent is its own section, natively.
pub(crate) fn bucketed_by_project<Element>(
    elements: Vec<Element>,
    project_key: impl Fn(&Element) -> Option<String>,
) -> Vec<(Option<String>, Vec<Element>)> {
    // Linear lookup is right at these counts — sections run to the tens.
    let mut sections: Vec<(Option<String>, Vec<Element>)> = Vec::new();
    for element in elements {
        let bucket = normalized_project_key(project_key(&element).as_deref());
        if let Some(section) = sections.iter_mut().find(|(key, _)| *key == bucket) {
            section.1.push(element);
        } else {
            sections.push((bucket, vec![element]));
        }
    }
    sections.sort_by(|(left, _), (right, _)| section_ordering(left.as_deref(), right.as_deref()));
    sections
}

/// The tab ids in the order the sidebar DRAWS them.
pub fn project_grouped_tab_order(
    tabs: Vec<TabId>,
    project_key: impl Fn(TabId) -> Option<String>,
) -> Vec<TabId> {
    bucketed_by_project(tabs, |tab| project_key(*tab))
        .into_iter()
        .flat_map(|(_, tabs)| tabs)
        .collect()
}

/// The tab to focus once one is closed, in preference order.
///
/// 1. The most recently focused SURVIVOR — closing a scratch tab returns you to the one you opened
///    it from, which is where you were actually working.
/// 2. Its neighbour inside its own project section. A fresh launch has no history, and rule one
///    must not be the only thing keeping focus in the project being read.
/// 3. Its neighbour in the full display order — reached only when the closing tab was its project's
///    last, so there is no section left to stay inside.
///
/// "Next, else previous" throughout: the survivor that takes the closed tab's slot. `display_order`
/// still CONTAINS the closing tab. `None` when it is absent from that order, or is the only tab.
pub fn successor_after_close(
    closing: TabId,
    display_order: &[TabId],
    project_key: impl Fn(TabId) -> Option<String>,
    focus_history: &[TabId],
) -> Option<TabId> {
    let closing_index = display_order.iter().position(|tab| *tab == closing)?;
    let survivors: Vec<TabId> = display_order
        .iter()
        .copied()
        .filter(|tab| *tab != closing)
        .collect();
    if survivors.is_empty() {
        return None;
    }

    // The history's newest entry is usually the closing tab itself — it was active when the close
    // was asked for — so identity and liveness are both filtered here.
    if let Some(recent) = focus_history
        .iter()
        .find(|tab| **tab != closing && survivors.contains(tab))
    {
        return Some(*recent);
    }

    let section = normalized_project_key(project_key(closing).as_deref());
    let siblings: Vec<TabId> = display_order
        .iter()
        .copied()
        .filter(|tab| normalized_project_key(project_key(*tab).as_deref()) == section)
        .collect();
    if let Some(sibling) = neighbour(closing, &siblings) {
        return Some(sibling);
    }

    neighbour(closing, display_order).or_else(|| {
        survivors
            .get(closing_index.min(survivors.len().saturating_sub(1)))
            .copied()
    })
}

/// The element after a target, else the one before it.
fn neighbour(target: TabId, list: &[TabId]) -> Option<TabId> {
    let index = list.iter().position(|tab| *tab == target)?;
    if let Some(next) = list.get(index + 1) {
        return Some(*next);
    }
    index.checked_sub(1).and_then(|before| list.get(before)).copied()
}

#[cfg(test)]
mod tests {
    use std::cmp::Ordering;

    use super::{
        bucketed_by_project, natural_compare, normalized_project_key, pane_project_key,
        project_grouped_tab_order, project_section_header, section_precedes, successor_after_close,
        tab_project_key,
    };
    use crate::identity::{PaneId, SessionId, TabId};
    use crate::session::{PaneKind, PaneSpec, Session, Tab};
    use crate::split_tree::SplitNode;

    fn pane(byte: u8) -> PaneId {
        PaneId::from_bytes([byte; 16])
    }

    fn tab(byte: u8) -> TabId {
        TabId::from_bytes([byte; 16])
    }

    #[test]
    fn a_trailing_slash_never_splits_one_directory_into_two_sections() {
        assert_eq!(
            normalized_project_key(Some("/work/alpha/")),
            normalized_project_key(Some("/work/alpha"))
        );
        assert_eq!(
            normalized_project_key(Some("  /work/alpha  ")).as_deref(),
            Some("/work/alpha")
        );
    }

    #[test]
    fn the_root_keeps_its_only_slash() {
        assert_eq!(normalized_project_key(Some("/")).as_deref(), Some("/"));
    }

    #[test]
    fn a_blank_key_is_absent_rather_than_empty() {
        assert!(normalized_project_key(Some("   ")).is_none());
        assert!(normalized_project_key(None).is_none());
    }

    #[test]
    fn a_header_is_the_basename_the_eye_scans() {
        assert_eq!(project_section_header(Some("/Users/me/proj/foo")), "foo");
        assert_eq!(project_section_header(Some("bare")), "bare");
        assert_eq!(project_section_header(None), "Other");
        assert_eq!(project_section_header(Some("  ")), "Other");
    }

    #[test]
    fn digit_runs_compare_as_numbers() {
        assert_eq!(natural_compare("app2", "app10"), Ordering::Less);
        assert_eq!(natural_compare("app10", "app2"), Ordering::Greater);
        assert_eq!(natural_compare("app2", "app2"), Ordering::Equal);
    }

    #[test]
    fn the_comparison_ignores_case_but_stays_total() {
        assert_eq!(natural_compare("Alpha", "alpha"), Ordering::Equal);
        assert_eq!(natural_compare("alpha", "beta"), Ordering::Less);
        assert_eq!(
            natural_compare("007", "7"),
            Ordering::Greater,
            "padding still distinguishes them"
        );
    }

    #[test]
    fn sections_order_by_header_not_by_key() {
        // The key would put zeta first; the header is what the eye reads.
        assert!(section_precedes(Some("/w/zeta/alpha"), Some("/w/alpha/beta")));
    }

    #[test]
    fn the_keyless_bucket_is_always_last() {
        assert!(section_precedes(Some("/w/zzz"), None));
        assert!(!section_precedes(None, Some("/w/aaa")));
        assert!(!section_precedes(None, None));
    }

    #[test]
    fn two_worktrees_with_the_same_basename_keep_a_stable_order() {
        assert!(section_precedes(
            Some("/w/feature-a/myapp"),
            Some("/w/feature-b/myapp")
        ));
        assert!(!section_precedes(
            Some("/w/feature-b/myapp"),
            Some("/w/feature-a/myapp")
        ));
    }

    #[test]
    fn bucketing_folds_the_keys_and_keeps_arrival_order_inside_a_section() {
        let sections = bucketed_by_project(vec![1_u32, 2, 3, 4], |value| {
            match value {
                1 | 3 => Some("/w/beta/".to_owned()),
                2 => Some("/w/alpha".to_owned()),
                _ => None,
            }
        });
        assert_eq!(sections, vec![
            (Some("/w/alpha".to_owned()), vec![2]),
            (Some("/w/beta".to_owned()), vec![1, 3]),
            (None, vec![4]),
        ],);
    }

    #[test]
    fn a_hosts_project_key_beats_the_working_directory() {
        let key = pane_project_key(
            pane(1),
            |_| Some("/w/toplevel".to_owned()),
            |_| Some("/w/toplevel/sub".to_owned()),
        );
        assert_eq!(key.as_deref(), Some("/w/toplevel"));
    }

    #[test]
    fn a_plugin_cache_directory_is_never_a_project_key() {
        let poisoned = "/home/me/.zinit/plugins/zsh-users---zsh-autosuggestions".to_owned();
        // Poisoned host key, good directory: it falls through rather than filing the pane under a
        // phantom section.
        let fallen_through = pane_project_key(
            pane(1),
            |_| Some(poisoned.clone()),
            |_| Some("/w/real".to_owned()),
        );
        assert_eq!(fallen_through.as_deref(), Some("/w/real"));
        // Both poisoned: the pane lands in Other and self-heals when the shell settles.
        let both = pane_project_key(pane(1), |_| Some(poisoned.clone()), |_| Some(poisoned.clone()));
        assert!(both.is_none());
    }

    #[test]
    fn an_empty_host_key_falls_through_to_the_directory() {
        let key = pane_project_key(pane(1), |_| Some(String::new()), |_| Some("/w/real".to_owned()));
        assert_eq!(key.as_deref(), Some("/w/real"));
    }

    #[test]
    fn a_tabs_key_is_its_focused_panes() {
        let mut session = Session::single_pane(
            SessionId::from_bytes([0; 16]),
            "work",
            tab(1),
            pane(1),
            PaneSpec::new(PaneKind::Terminal, "shell"),
        );
        session.tabs.push(Tab::new(tab(2), SplitNode::Leaf(pane(2))));
        let key = tab_project_key(tab(2), &session, |id| {
            (id == pane(2)).then(|| "/w/beta".to_owned())
        });
        assert_eq!(key.as_deref(), Some("/w/beta"));
        assert!(tab_project_key(tab(9), &session, |_| Some("/w".to_owned())).is_none());
    }

    #[test]
    fn a_tab_whose_focused_pane_has_no_key_falls_back_to_its_first_that_does() {
        let mut session = Session::single_pane(
            SessionId::from_bytes([0; 16]),
            "work",
            tab(1),
            pane(1),
            PaneSpec::new(PaneKind::Terminal, "shell"),
        );
        if let Some(first) = session.tabs.first_mut() {
            first.active_pane = None;
        }
        let key = tab_project_key(tab(1), &session, |_| Some("/w/alpha".to_owned()));
        assert_eq!(key.as_deref(), Some("/w/alpha"));
    }

    #[test]
    fn the_display_order_is_project_order_not_creation_order() {
        // Created beta, alpha, beta — the sidebar draws alpha's tab first, then beta's two.
        let order = project_grouped_tab_order(vec![tab(1), tab(2), tab(3)], |id| {
            if id == tab(2) {
                Some("/w/alpha".to_owned())
            } else {
                Some("/w/beta".to_owned())
            }
        });
        assert_eq!(order, vec![tab(2), tab(1), tab(3)]);
    }

    #[test]
    fn closing_returns_focus_to_the_tab_you_opened_it_from() {
        let order = [tab(1), tab(2), tab(3)];
        let next = successor_after_close(tab(3), &order, |_| Some("/w/alpha".to_owned()), &[tab(3), tab(1)]);
        assert_eq!(next, Some(tab(1)), "history wins over adjacency");
    }

    #[test]
    fn with_no_history_focus_stays_inside_the_closing_tabs_project() {
        let order = [tab(1), tab(2), tab(3)];
        let project = |id: TabId| {
            if id == tab(2) {
                Some("/w/alpha".to_owned())
            } else {
                Some("/w/beta".to_owned())
            }
        };
        // Closing beta's first tab lands on beta's other tab, not on the adjacent alpha.
        assert_eq!(successor_after_close(tab(1), &order, project, &[]), Some(tab(3)));
    }

    #[test]
    fn the_last_tab_of_a_project_falls_back_to_the_full_display_order() {
        let order = [tab(1), tab(2), tab(3)];
        let project = |id: TabId| {
            if id == tab(2) {
                Some("/w/alpha".to_owned())
            } else {
                Some("/w/beta".to_owned())
            }
        };
        assert_eq!(
            successor_after_close(tab(2), &order, project, &[]),
            Some(tab(3)),
            "its section died with it, so the neighbour on screen wins",
        );
    }

    #[test]
    fn closing_the_last_tab_in_the_order_falls_back_to_the_one_before() {
        let order = [tab(1), tab(2)];
        assert_eq!(
            successor_after_close(tab(2), &order, |_| Some("/w/alpha".to_owned()), &[]),
            Some(tab(1)),
        );
    }

    #[test]
    fn closing_the_only_tab_or_an_absent_one_selects_nothing() {
        assert!(successor_after_close(tab(1), &[tab(1)], |_| None, &[]).is_none());
        assert!(successor_after_close(tab(9), &[tab(1), tab(2)], |_| None, &[]).is_none());
    }

    #[test]
    fn a_stale_history_entry_is_skipped_rather_than_selected() {
        let order = [tab(1), tab(2)];
        let closed_long_ago = tab(7);
        assert_eq!(
            successor_after_close(tab(2), &order, |_| Some("/w/a".to_owned()), &[
                closed_long_ago,
                tab(1)
            ]),
            Some(tab(1)),
        );
    }
}
