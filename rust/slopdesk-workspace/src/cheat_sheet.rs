//! How a reference sheet's runs of shortcuts are dealt into columns.
//!
//! The rule that matters is BALANCE BY HEIGHT, not by count. A grid pairs sections into ROWS, so a
//! short category beside a tall one is centred against it and floats halfway down the card with
//! dead air above and below; halving the LIST is worse still, because the real table has one
//! category with three times the rows of the next. Each section costs its rows PLUS the header line
//! it draws above them, and it joins whichever column is currently shortest — which keeps the
//! registry's declared order reading down the page while the two columns end level.
//!
//! It answers in COLUMN INDICES against the caller's own section order, so nothing about a binding,
//! a glyph or a category crosses: the caller keeps its rows and is told only where each one goes.

/// One section's rendered cost: its rows plus the header line drawn above them.
const HEADER_LINES: u32 = 1;

/// Which column each section belongs in, given how many rows each one has.
///
/// Greedy shortest-first, in the caller's order. `columns` is clamped to at least one, so a caller
/// that asks for zero columns gets one rather than a division by zero, and the answer always has
/// exactly one entry per section — no section can be dropped or placed twice.
#[must_use]
pub fn column_assignment(row_counts: &[u32], columns: u32) -> Vec<u32> {
    let width = columns.max(1);
    let mut heights = vec![0_u64; width as usize];
    let mut out = Vec::with_capacity(row_counts.len());
    for rows in row_counts {
        // The shortest column, and the FIRST of them on a tie — which is what makes an even table
        // alternate 0, 1, 0, 1 rather than piling onto whichever index happened to be scanned last.
        // `min_by_key` returns the first of several equal minima, which is exactly that tie rule.
        let target = heights
            .iter()
            .enumerate()
            .min_by_key(|(_, height)| **height)
            .map_or(0, |(index, _)| index);
        if let Some(height) = heights.get_mut(target) {
            *height += u64::from(*rows) + u64::from(HEADER_LINES);
        }
        out.push(u32::try_from(target).unwrap_or(0));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::column_assignment;

    /// Total rendered height of each column, the way the card stacks it.
    fn heights(row_counts: &[u32], assignment: &[u32], columns: usize) -> Vec<u32> {
        let mut out = vec![0_u32; columns];
        for (rows, column) in row_counts.iter().zip(assignment) {
            if let Some(height) = out.get_mut(*column as usize) {
                *height += rows + 1;
            }
        }
        out
    }

    #[test]
    fn one_long_section_is_balanced_against_several_short_ones() {
        // The shape that breaks a naive split: one huge category, then three small ones.
        let counts = [18, 4, 3, 2];
        let assignment = column_assignment(&counts, 2);
        let tall = heights(&counts, &assignment, 2);
        // Halving the LIST would put 18+4 in one column against 3+2 in the other — 24 to 7.
        assert!(tall.first().unwrap_or(&0).abs_diff(*tall.get(1).unwrap_or(&0)) <= 18);
        assert_eq!(
            assignment.first(),
            Some(&0),
            "the first section opens the first column"
        );
        assert!(
            assignment.iter().skip(1).all(|column| *column == 1),
            "with one section at 19 units and the rest at 5/4/3, all three belong beside it",
        );
    }

    #[test]
    fn a_uniform_table_splits_down_the_middle() {
        assert_eq!(column_assignment(&[5, 5, 5, 5], 2), [0, 1, 0, 1]);
    }

    #[test]
    fn every_section_is_placed_exactly_once() {
        let counts = [7, 2, 9, 1, 4, 6];
        let assignment = column_assignment(&counts, 2);
        assert_eq!(assignment.len(), counts.len());
        assert!(assignment.iter().all(|column| *column < 2));
    }

    #[test]
    fn an_empty_section_still_costs_its_header_line() {
        assert_eq!(column_assignment(&[0, 0, 0], 2), [0, 1, 0]);
    }

    #[test]
    fn a_zero_column_count_clamps_to_one_rather_than_dividing_by_zero() {
        assert_eq!(column_assignment(&[3], 0), [0]);
        assert_eq!(column_assignment(&[3, 4, 5], 0), [0, 0, 0]);
    }

    #[test]
    fn no_sections_is_an_answer_rather_than_a_trap() {
        assert!(column_assignment(&[], 2).is_empty());
    }

    #[test]
    fn a_single_column_takes_the_whole_table_in_order() {
        assert_eq!(column_assignment(&[9, 1, 4], 1), [0, 0, 0]);
    }

    #[test]
    fn a_third_column_is_filled_before_any_column_takes_a_second_section() {
        assert_eq!(column_assignment(&[4, 4, 4, 4], 3), [0, 1, 2, 0]);
    }
}
