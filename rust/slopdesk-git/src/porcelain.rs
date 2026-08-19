//! The porcelain `XY` pair, and the byte it packs into.
//!
//! `git status --porcelain` prints two characters per changed path: `X` is the INDEX against HEAD,
//! `Y` is the WORKTREE against the index, and each axis counts independently — an `MM` file is both
//! staged and modified. The client mirrors the nibble table's inverse to name a change category and
//! `golden/golden_vectors.json` freezes the packed byte, so both halves of this file are a wire
//! contract rather than a local choice.
//!
//! ## Why the letters are derived here rather than read off
//!
//! `git2::Status` is a bitflag set, not a pair of characters — it is already split into
//! `INDEX_*` and `WT_*` groups, which is why it maps onto `XY` at all, but the mapping still has to
//! be written down. It is written down the way libgit2's own `examples/status.c` writes it, because
//! that file exists precisely to emulate porcelain from these flags and is the closest thing to a
//! reference implementation the binding has.
//!
//! Two rules in it look like accidents and are not:
//!
//!  - **An untracked file is `??`, not ` ?`.** `WT_NEW` sets BOTH columns when the index column is
//!    otherwise blank, because porcelain's `??` says "git has never seen this", which is a
//!    statement about the index as much as the worktree.
//!  - **A conflict is not a bitflag pair at all.** `git2` reports one `CONFLICTED` bit and does not
//!    say which of porcelain's seven unmerged pairs it is. Those come from the INDEX's conflict
//!    entries instead — see [`unmerged`].

use git2::Status;

/// The `XY` pair for one status entry, as porcelain would print it.
///
/// Follows libgit2's `examples/status.c` exactly, including the order the assignments happen in: a
/// later flag OVERWRITES an earlier one on the same axis, so `INDEX_TYPECHANGE` beats
/// `INDEX_MODIFIED` on a file carrying both, and that precedence is the reference behaviour rather
/// than a preference.
#[must_use]
pub const fn pair(status: Status) -> (char, char) {
    let mut index = ' ';
    let mut worktree = ' ';
    if status.contains(Status::INDEX_NEW) {
        index = 'A';
    }
    if status.contains(Status::INDEX_MODIFIED) {
        index = 'M';
    }
    if status.contains(Status::INDEX_DELETED) {
        index = 'D';
    }
    if status.contains(Status::INDEX_RENAMED) {
        index = 'R';
    }
    if status.contains(Status::INDEX_TYPECHANGE) {
        index = 'T';
    }
    if status.contains(Status::WT_NEW) {
        // Untracked is `??`: both columns, and only when the index column has nothing else to say.
        // A file that is staged-added and then deleted from the worktree is `AD`, not `A?`.
        if index == ' ' {
            index = '?';
        }
        worktree = '?';
    }
    if status.contains(Status::WT_MODIFIED) {
        worktree = 'M';
    }
    if status.contains(Status::WT_DELETED) {
        worktree = 'D';
    }
    if status.contains(Status::WT_RENAMED) {
        worktree = 'R';
    }
    if status.contains(Status::WT_TYPECHANGE) {
        worktree = 'T';
    }
    (index, worktree)
}

/// The `XY` pair for an UNMERGED path, from which of the three index stages are present.
///
/// Porcelain's seven unmerged pairs are a function of exactly this — stage 1 is the common
/// ancestor, stage 2 is ours, stage 3 is theirs — and `git2` cannot answer it from
/// [`Status::CONFLICTED`], which is one bit for all seven.
///
/// The letters read from OUR side first, which is the direction that is easy to get backwards:
/// `UD` is "we modified it, they deleted it", so the absent stage is THEIRS. Getting the pair
/// mirrored would still produce a plausible-looking conflict marker, which is why every row here is
/// pinned in this module's tests.
#[must_use]
#[expect(
    clippy::match_same_arms,
    reason = "the no-stage row answers ('U', 'U') for a different reason than the all-stage row, and \
              merging them would hide the one that is a backstop rather than a rule"
)]
pub const fn unmerged(ancestor: bool, ours: bool, theirs: bool) -> (char, char) {
    match (ancestor, ours, theirs) {
        // Both sides changed a file that existed before: the ordinary merge conflict.
        (true, true, true) => ('U', 'U'),
        // It existed, we kept it, they removed it — and the mirror of that.
        (true, true, false) => ('U', 'D'),
        (true, false, true) => ('D', 'U'),
        // It existed and both sides removed it. A conflict only because the removals disagree
        // about something else in the same merge.
        (true, false, false) => ('D', 'D'),
        // It did not exist before and both sides added it.
        (false, true, true) => ('A', 'A'),
        // Added on one side only, against a rename or a delete on the other.
        (false, true, false) => ('A', 'U'),
        (false, false, true) => ('U', 'A'),
        // No stage at all is not an unmerged entry; it cannot be reached from a conflict iterator
        // and is answered as the ordinary conflict rather than as a blank pair, because a blank
        // would pack to `0x00` — the byte a CLEAN file carries.
        (false, false, false) => ('U', 'U'),
    }
}

/// One porcelain status character as its 4-bit code.
///
/// **The client mirrors this inverse** to name the change category, so the table is a wire contract
/// and not an internal choice. `15` is the escape hatch for a character no porcelain version has
/// printed yet — it packs, it travels, and it names no category, which is what an unknown should
/// do.
#[must_use]
pub const fn nibble(character: char) -> u8 {
    match character {
        ' ' => 0,
        'M' => 1,
        'A' => 2,
        'D' => 3,
        'R' => 4,
        'C' => 5,
        'U' => 6,
        '?' => 7,
        '!' => 8,
        'T' => 9,
        _ => 15,
    }
}

/// Packs `X` (index) and `Y` (worktree) into one byte: high nibble `X`, low nibble `Y`.
#[must_use]
pub const fn pack(x: char, y: char) -> u8 {
    (nibble(x) << 4) | nibble(y)
}

#[cfg(test)]
mod tests {
    use git2::Status;

    use super::{pack, pair, unmerged};

    #[test]
    fn each_axis_answers_independently_and_a_file_can_be_on_both() {
        assert_eq!(pair(Status::INDEX_MODIFIED | Status::WT_MODIFIED), ('M', 'M'));
        assert_eq!(pair(Status::INDEX_NEW), ('A', ' '));
        assert_eq!(pair(Status::WT_DELETED), (' ', 'D'));
        assert_eq!(pair(Status::CURRENT), (' ', ' '));
    }

    #[test]
    fn an_untracked_file_takes_both_columns_but_never_overwrites_a_real_one() {
        assert_eq!(pair(Status::WT_NEW), ('?', '?'));
        // Staged as an addition, then removed from the worktree. Porcelain says `AD`, and the `?`
        // must not claim the index column a real staging already holds.
        assert_eq!(pair(Status::INDEX_NEW | Status::WT_DELETED), ('A', 'D'));
    }

    #[test]
    fn a_later_flag_wins_its_axis_the_way_the_reference_emulation_orders_them() {
        assert_eq!(
            pair(Status::INDEX_MODIFIED | Status::INDEX_TYPECHANGE),
            ('T', ' ')
        );
        assert_eq!(pair(Status::WT_MODIFIED | Status::WT_TYPECHANGE), (' ', 'T'));
    }

    /// Every one of porcelain's seven unmerged pairs, in the direction that is easy to mirror.
    #[test]
    fn the_seven_unmerged_pairs_read_from_our_side_first() {
        assert_eq!(unmerged(true, true, true), ('U', 'U'));
        assert_eq!(unmerged(true, true, false), ('U', 'D'));
        assert_eq!(unmerged(true, false, true), ('D', 'U'));
        assert_eq!(unmerged(true, false, false), ('D', 'D'));
        assert_eq!(unmerged(false, true, true), ('A', 'A'));
        assert_eq!(unmerged(false, true, false), ('A', 'U'));
        assert_eq!(unmerged(false, false, true), ('U', 'A'));
    }

    /// A conflict must never pack to the byte a clean file carries, whatever the stages say.
    #[test]
    fn no_unmerged_pair_packs_to_clean() {
        for ancestor in [false, true] {
            for ours in [false, true] {
                for theirs in [false, true] {
                    let (x, y) = unmerged(ancestor, ours, theirs);
                    assert_ne!(pack(x, y), 0, "{ancestor} {ours} {theirs} packed clean");
                }
            }
        }
    }

    #[test]
    fn the_nibble_table_is_the_wire_and_an_unknown_character_still_travels() {
        assert_eq!(pack(' ', ' '), 0x00);
        assert_eq!(pack('M', 'M'), 0x11);
        assert_eq!(pack('?', '?'), 0x77);
        assert_eq!(pack('R', 'M'), 0x41);
        assert_eq!(pack('~', ' '), 0xF0);
    }
}
