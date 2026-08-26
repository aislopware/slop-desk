//! How a flat device list becomes a SECTIONED one — the ordering, the grouping, the fact both
//! panels lift out of a group, and the identity a row animates on.
//!
//! Both panels arrive at the same four answers from different data. The simulator panel splits on
//! `isBooted` and lifts a RUNTIME; the Android panel splits on whether `adb` has handed the device
//! a transport id and lifts a VERSION. Underneath, the shape is one machine: the running devices
//! come first as a single group that is NOT cut by family, every other device falls into its
//! family's group in rank order, each group states a fact its every member agrees on, and any row
//! disagreeing with its heading keeps printing its own.
//!
//! It was written twice, once per panel, in two files that differed in their nouns and in nothing
//! else — which is the shape the one-implementation rule exists for. A phone and a Mac render each
//! of these lists, so a rule that drifted would not drift into a bug, it would drift into two
//! products.
//!
//! ## What crosses, and what does not
//!
//! [`sections`] takes ROWS of scalars and answers INDICES into the caller's own array, the way
//! [`crate::android_sidebar`] does — the panel still holds the device, and handing one back over a
//! C ABI would be a copy made only to be compared with the one it came from. What it does answer in
//! words is the part the caller does not have: the heading, the lifted fact, and the row identity
//! that is the heading joined to the row's key.
//!
//! ## The empty value is not a fact
//!
//! A value that is absent, and one that is present and EMPTY, are the same non-fact to the lift:
//! `/simulators.json` can carry an empty runtime string, and lifting it would print a heading
//! ending in a dangling separator — the panel promoting the ABSENCE of a fact into the place it
//! prints facts.
//!
//! They are NOT the same to [`Member::shows_value`], which asks a different question: does this row
//! still have something of its own to say. A row carrying no value at all in a group that lifted
//! nothing says nothing; a row carrying an empty string in the same group is a row whose value the
//! group failed to lift, and it prints what it has. Both panels were already spelled this way.

/// One device, as the fold reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Row<'a> {
    /// The family's rank — a `DeviceKind`'s byte. A rank past the end of the caller's title table
    /// falls into rank `0`, which is the same fallback `DeviceKind::from_byte` makes: a device
    /// classified by a newer build must appear in the wrong group rather than vanish from the list.
    pub rank: u8,
    /// Whether this device belongs in the running group instead of its family's.
    pub is_running: bool,
    /// The fact a group might lift — a runtime, a version label — or `None` when the device has
    /// none.
    pub value: Option<&'a str>,
    /// The device's stable key, which is the second half of every row identity.
    pub key: &'a str,
}

/// One row's place in a rendered section.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Member {
    /// Which row of the CALLER's array this is.
    pub index: usize,
    /// Whether the row still prints its own value — false exactly when the heading already said it.
    pub shows_value: bool,
    /// `heading/key`: stable while a device keeps its group, and different the moment it moves, so
    /// a list animating on it animates a boot as a move rather than as a delete and an insert.
    pub row_identity: String,
}

/// One rendered group.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Section {
    /// The heading.
    pub title: String,
    /// Whether this is the running group — the one that is not cut by family.
    pub is_running: bool,
    /// The fact every member agreed on, or `None` when they did not.
    pub shared: Option<String>,
    /// The members, in the caller's own order.
    pub members: Vec<Member>,
}

/// The sectioned reading of `rows`.
///
/// `running_title` heads the group of running devices, which is emitted FIRST and only when it has
/// a member; `family_titles` is the panel's group headings in rank order, and a family with no
/// member of its own is not emitted at all. Within every group the members keep the order they
/// arrived in: the host already decided what that order means — a merge on the Android side, a boot
/// order on the simulator's — and re-sorting here would overrule it.
#[must_use]
pub fn sections(rows: &[Row<'_>], running_title: &str, family_titles: &[&str]) -> Vec<Section> {
    let mut out = Vec::new();
    let running: Vec<usize> = indices(rows, |row| row.is_running);
    if !running.is_empty() {
        out.push(section(running_title, true, &running, rows));
    }
    for (rank, title) in family_titles.iter().enumerate() {
        let family = indices(rows, |row| {
            !row.is_running && effective_rank(row.rank, family_titles.len()) == rank
        });
        if !family.is_empty() {
            out.push(section(title, false, &family, rows));
        }
    }
    out
}

/// The rank a row is filed under, with a rank no build of the caller's table knows falling to `0`.
const fn effective_rank(rank: u8, families: usize) -> usize {
    let rank = rank as usize;
    if rank < families { rank } else { 0 }
}

/// The caller's indices whose row passes `keep`, in the caller's order.
fn indices(rows: &[Row<'_>], keep: impl Fn(&Row<'_>) -> bool) -> Vec<usize> {
    rows.iter()
        .enumerate()
        .filter(|(_, row)| keep(row))
        .map(|(index, _)| index)
        .collect()
}

/// One group, once its members are known.
fn section(title: &str, is_running: bool, members: &[usize], rows: &[Row<'_>]) -> Section {
    let held: Vec<&Row<'_>> = members.iter().filter_map(|index| rows.get(*index)).collect();
    let shared = lift(&held);
    Section {
        title: title.to_owned(),
        is_running,
        members: members
            .iter()
            .filter_map(|index| rows.get(*index).map(|row| (*index, row)))
            .map(|(index, row)| {
                Member {
                    index,
                    shows_value: row.value != shared.as_deref(),
                    row_identity: format!("{title}/{}", row.key),
                }
            })
            .collect(),
        shared,
    }
}

/// The one value every member states, or `None` when any of them states another — or none, or the
/// empty one, which this fold reads as the same non-fact.
fn lift(members: &[&Row<'_>]) -> Option<String> {
    let first = members.first()?.value?;
    if first.is_empty() {
        return None;
    }
    members
        .iter()
        .all(|row| row.value == Some(first))
        .then(|| first.to_owned())
}

#[cfg(test)]
mod tests {
    use super::{Row, sections};

    const FAMILIES: [&str; 3] = ["Phone", "Tablet", "Watch"];

    const fn row<'a>(key: &'a str, rank: u8, is_running: bool, value: Option<&'a str>) -> Row<'a> {
        Row {
            rank,
            is_running,
            value,
            key,
        }
    }

    fn shape(sections: &[super::Section]) -> Vec<(&str, Vec<usize>)> {
        sections
            .iter()
            .map(|section| {
                (
                    section.title.as_str(),
                    section.members.iter().map(|member| member.index).collect(),
                )
            })
            .collect()
    }

    fn lifted(sections: &[super::Section]) -> Vec<Option<&str>> {
        sections.iter().map(|section| section.shared.as_deref()).collect()
    }

    fn shown(sections: &[super::Section]) -> Vec<Vec<bool>> {
        sections
            .iter()
            .map(|section| section.members.iter().map(|m| m.shows_value).collect())
            .collect()
    }

    fn identities(sections: &[super::Section]) -> Vec<Vec<&str>> {
        sections
            .iter()
            .map(|section| section.members.iter().map(|m| m.row_identity.as_str()).collect())
            .collect()
    }

    #[test]
    fn the_running_group_comes_first_and_is_not_cut_by_family() {
        let rows = [
            row("a", 0, false, None),
            row("b", 1, true, None),
            row("c", 0, true, None),
        ];
        assert_eq!(shape(&sections(&rows, "Attached", &FAMILIES)), vec![
            ("Attached", vec![1, 2]),
            ("Phone", vec![0])
        ]);
    }

    #[test]
    fn a_list_with_nothing_running_has_no_running_group() {
        let rows = [row("a", 1, false, None)];
        assert_eq!(shape(&sections(&rows, "Attached", &FAMILIES)), vec![(
            "Tablet",
            vec![0]
        )]);
        assert!(sections(&[], "Attached", &FAMILIES).is_empty());
    }

    #[test]
    fn families_come_in_rank_order_and_an_empty_one_is_not_drawn() {
        let rows = [
            row("a", 2, false, None),
            row("b", 0, false, None),
            row("c", 2, false, None),
        ];
        assert_eq!(shape(&sections(&rows, "Attached", &FAMILIES)), vec![
            ("Phone", vec![1]),
            ("Watch", vec![0, 2])
        ]);
    }

    #[test]
    fn members_keep_the_order_they_arrived_in() {
        // The host already decided this order — a merge on one side, a boot order on the other — so
        // a stable partition is the rule and not an accident of how the grouping was written.
        let rows = [
            row("z", 0, false, None),
            row("m", 0, false, None),
            row("a", 0, false, None),
        ];
        assert_eq!(shape(&sections(&rows, "Attached", &FAMILIES)), vec![(
            "Phone",
            vec![0, 1, 2]
        )]);
    }

    #[test]
    fn a_rank_no_family_table_knows_lands_in_the_first_group_rather_than_vanishing() {
        let rows = [row("a", 9, false, None)];
        assert_eq!(shape(&sections(&rows, "Attached", &FAMILIES)), vec![(
            "Phone",
            vec![0]
        )]);
    }

    #[test]
    fn a_group_that_agrees_lifts_its_fact_and_stops_every_row_repeating_it() {
        let rows = [
            row("a", 0, false, Some("iOS 26.5")),
            row("b", 0, false, Some("iOS 26.5")),
        ];
        let answer = sections(&rows, "Running", &FAMILIES);
        assert_eq!(lifted(&answer), vec![Some("iOS 26.5")]);
        assert_eq!(shown(&answer), vec![vec![false, false]]);
    }

    #[test]
    fn a_group_that_disagrees_lifts_nothing_and_every_row_keeps_its_own() {
        let rows = [
            row("a", 0, false, Some("iOS 26.5")),
            row("b", 0, false, Some("iOS 18.5")),
        ];
        let answer = sections(&rows, "Running", &FAMILIES);
        assert_eq!(lifted(&answer), vec![None]);
        assert_eq!(shown(&answer), vec![vec![true, true]]);
    }

    #[test]
    fn an_absent_value_anywhere_is_a_disagreement() {
        // Not "the others agree, so lift theirs": a heading is read as true of every row under it.
        let rows = [row("a", 0, false, Some("Android 15")), row("b", 0, false, None)];
        let answer = sections(&rows, "Attached", &FAMILIES);
        assert_eq!(lifted(&answer), vec![None]);
        assert_eq!(
            shown(&answer),
            vec![vec![true, false]],
            "the row with a version prints it; the row with none has nothing to print"
        );
    }

    #[test]
    fn an_empty_value_is_not_a_fact_worth_lifting_but_is_still_the_rows_own() {
        // Lifted, it would print a heading ending in a dangling separator. Left on the row, it is
        // what that row has — and the two questions have different answers on purpose.
        let rows = [row("a", 0, false, Some("")), row("b", 0, false, Some(""))];
        let answer = sections(&rows, "Running", &FAMILIES);
        assert_eq!(lifted(&answer), vec![None]);
        assert_eq!(shown(&answer), vec![vec![true, true]]);
    }

    #[test]
    fn each_group_decides_for_itself_rather_than_for_the_whole_list() {
        let rows = [
            row("a", 0, true, Some("iOS 18.5")),
            row("b", 0, false, Some("iOS 26.5")),
            row("c", 0, false, Some("iOS 26.5")),
        ];
        assert_eq!(lifted(&sections(&rows, "Running", &FAMILIES)), vec![
            Some("iOS 18.5"),
            Some("iOS 26.5")
        ]);
    }

    #[test]
    fn a_row_identity_names_its_group_so_a_boot_reads_as_a_move() {
        let cold = sections(&[row("k", 0, false, None)], "Attached", &FAMILIES);
        let hot = sections(&[row("k", 0, true, None)], "Attached", &FAMILIES);
        assert_eq!(identities(&cold), vec![vec!["Phone/k"]]);
        assert_eq!(identities(&hot), vec![vec!["Attached/k"]]);
    }
}
