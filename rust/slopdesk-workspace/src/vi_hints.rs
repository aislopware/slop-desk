//! The vi / copy-mode reference card: the three hint tables, their headings, the mode pill's
//! wording, and the arithmetic that decides how the card re-flows.
//!
//! ## The tables are the HONESTY surface
//!
//! The card lists ONLY the keys the copy-mode handler actually wires — a faithful subset of full vi
//! — and [`advertised_keys`] is what a test reads to prove it. Since the E17 lift
//! (`docs/DECISIONS.md` 2026-07-14: the fork gained a set-selection / viewport-info ABI) that
//! subset includes the cursor motions `h`/`l`, `w`/`b`/`e`, `0`/`^`/`$`, plus the visual
//! anchor-swap `o` and the `Y` line-yank, all previously omitted as unwired. Still deliberately
//! absent: `H`/`M`/`L` (screen-relative jumps, not wired). `f` arms Hint Mode, which is its own
//! overlay over its own seam.
//!
//! ## The reflow is ARITHMETIC, not a `ViewThatFits`
//!
//! The card used to ask "which of my three layouts fits?" by BUILDING all three and measuring them
//! — the same question, and the same cost, that [`crate::panel_tabs`] was rewritten as arithmetic
//! for. Two reasons it has to be arithmetic. `ViewThatFits` has no `AppKit` equivalent at all, so
//! an `AppKit` card could only re-derive the ladder from prose; and a candidate that is BUILT is a
//! candidate that exists — every row, every keycap, three times — to answer a question about width.
//! Said as a comparison it is one answer, both frameworks ask it the same way, and the RUNG
//! BOUNDARIES are pinnable without mounting anything.
//!
//! What the renderer still owns is the MEASUREMENT: only it can ask its own type what one column
//! costs. [`layout`] takes the three widths it measured and answers with the rung.

/// One reference entry: the key chip(s) and what they do.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Hint {
    /// The chips, left to right. May contain [`SEPARATOR`], which is not a key.
    pub keys: &'static [&'static str],
    /// What those keys do.
    pub label: &'static str,
}

/// The RANGE token, which is not a key.
///
/// It sits in a [`Hint::keys`] array so `1 … 9` reads as one row, but a renderer draws it as bare
/// text rather than as a chip, and [`advertised_keys`] filters it out so the honesty test never has
/// to know about it.
pub const SEPARATOR: &str = "…";

/// The pill's a11y hint, and the `×` plate's tooltip — one string, because they name one action.
pub const EXIT_HELP: &str = "Exit vi mode";

/// What `VoiceOver` calls the card as a whole.
pub const BAR_ACCESSIBILITY_LABEL: &str = "Vi mode key hints";

/// What the mode pill reads when no visual selection is being extended.
pub const PLAIN_MODE_LABEL: &str = "VI";

/// The card's three columns, in their drawn order.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Column {
    /// Cursor and viewport movement — the TALL column, at eight rows.
    Motion,
    /// The visual modes and the yanks.
    Selection,
    /// Find, match stepping, and the two ways out.
    Search,
}

impl Column {
    /// Every column, in drawn order.
    pub const ALL: [Self; 3] = [Self::Motion, Self::Selection, Self::Search];

    /// The column at `index` in [`ALL`](Self::ALL), or `None` past the end.
    #[must_use]
    pub const fn from_index(index: u8) -> Option<Self> {
        match index {
            0 => Some(Self::Motion),
            1 => Some(Self::Selection),
            2 => Some(Self::Search),
            _ => None,
        }
    }

    /// This column's place in [`ALL`](Self::ALL).
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::Motion => 0,
            Self::Selection => 1,
            Self::Search => 2,
        }
    }

    /// The column's caps heading.
    #[must_use]
    pub const fn heading(self) -> &'static str {
        match self {
            Self::Motion => "MOTION",
            Self::Selection => "SELECT",
            Self::Search => "SEARCH",
        }
    }

    /// The column's rows, top to bottom.
    #[must_use]
    pub const fn hints(self) -> &'static [Hint] {
        match self {
            Self::Motion => MOTION,
            Self::Selection => SELECTION,
            Self::Search => SEARCH,
        }
    }
}

/// Cursor and viewport movement.
pub const MOTION: &[Hint] = &[
    Hint {
        keys: &["h", "j", "k", "l"],
        label: "Move cursor",
    },
    Hint {
        keys: &["w", "b", "e"],
        label: "Word motions",
    },
    Hint {
        keys: &["0", "^", "$"],
        label: "Line start / end",
    },
    Hint {
        keys: &["⌃d", "⌃u"],
        label: "Half page",
    },
    Hint {
        keys: &["⌃f", "⌃b"],
        label: "Full page",
    },
    Hint {
        keys: &["g", "G"],
        label: "Top / bottom",
    },
    Hint {
        keys: &["[", "]"],
        label: "Prev / next prompt",
    },
    Hint {
        keys: &["1", SEPARATOR, "9"],
        label: "Repeat count",
    },
];

/// The visual modes and the yanks.
///
/// Every row here is WIRED (the honesty rule): the cursor motions plus `o` and `Y` joined the card
/// with the E17 ceiling lift; `f` rides the Hint Mode overlay via its own seam.
pub const SELECTION: &[Hint] = &[
    Hint {
        keys: &["v"],
        label: "Visual",
    },
    Hint {
        keys: &["V"],
        label: "Visual line",
    },
    Hint {
        keys: &["⌃v"],
        label: "Visual block",
    },
    Hint {
        keys: &["o"],
        label: "Swap ends",
    },
    Hint {
        keys: &["y", "↩"],
        label: "Yank + exit",
    },
    Hint {
        keys: &["Y"],
        label: "Yank line",
    },
    Hint {
        keys: &["f"],
        label: "Hint links",
    },
];

/// Find, match stepping, and the two ways out.
pub const SEARCH: &[Hint] = &[
    Hint {
        keys: &["/"],
        label: "Find forward",
    },
    Hint {
        keys: &["?"],
        label: "Find backward",
    },
    Hint {
        keys: &["n", "N"],
        label: "Next / prev match",
    },
    Hint {
        keys: &["Esc", "q"],
        label: "Exit vi mode",
    },
    Hint {
        keys: &["⌘/"],
        label: "Toggle this bar",
    },
];

/// Every key chip the card advertises, flattened across all three columns with [`SEPARATOR`]
/// dropped.
///
/// The honesty surface a test reads to prove the card lists ONLY wired keys (e.g. never the
/// once-dead `o`). The renderers draw from the SAME tables, so this cannot drift from what is
/// shown.
#[must_use]
pub fn advertised_keys() -> Vec<&'static str> {
    Column::ALL
        .into_iter()
        .flat_map(Column::hints)
        .flat_map(|hint| hint.keys)
        .copied()
        .filter(|key| *key != SEPARATOR)
        .collect()
}

/// The four vi visual-selection modes, `None` being plain scrollback navigation.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum VisualMode {
    /// Not extending a selection.
    None,
    /// Character-wise.
    Char,
    /// Line-wise.
    Line,
    /// Block-wise.
    Block,
}

impl VisualMode {
    /// The mode at `index`, in the near side's case order; anything past the end is [`None`].
    ///
    /// [`None`]: VisualMode::None
    #[must_use]
    pub const fn from_index(index: u8) -> Self {
        match index {
            1 => Self::Char,
            2 => Self::Line,
            3 => Self::Block,
            _ => Self::None,
        }
    }

    /// The pill label ACTUALLY drawn, with the plain-mode fallback folded in.
    ///
    /// The `?? "VI"` used to be spelled at the pill, which made the enum's own answer incomplete:
    /// four cases, three labels, and the fourth left to whoever drew it. Two renderers is what
    /// turns that into a defect rather than a shrug.
    #[must_use]
    pub const fn pill_label(self) -> &'static str {
        match self {
            Self::None => PLAIN_MODE_LABEL,
            Self::Char => "VISUAL",
            Self::Line => "VISUAL LINE",
            Self::Block => "VISUAL BLOCK",
        }
    }
}

/// The pill's combined a11y label, so `VoiceOver` reads "Vi mode VISUAL 5".
#[must_use]
pub fn pill_accessibility_label(mode: VisualMode, count: Option<u32>) -> String {
    let mut label = String::from("Vi mode ");
    label.push_str(mode.pill_label());
    if let Some(count) = count {
        label.push(' ');
        label.push_str(&count.to_string());
    }
    label
}

/// Which of the three arrangements the card's width affords.
///
/// The middle rung exists because MOTION is the tall column (eight rows against seven and five): at
/// a width that cannot take three columns, stacking the two SHORT ones beside it costs less height
/// than stacking all three, and a narrow split pane still gets the whole card rather than a clipped
/// one.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Layout {
    /// MOTION | SELECT | SEARCH.
    ThreeColumns,
    /// MOTION beside SELECT-over-SEARCH.
    MotionBesideStack,
    /// One tall column.
    OneColumn,
}

impl Layout {
    /// The discriminant a renderer switches on.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::ThreeColumns => 0,
            Self::MotionBesideStack => 1,
            Self::OneColumn => 2,
        }
    }

    /// The rung `code` names; anything past the end is the one that always fits.
    #[must_use]
    pub const fn from_code(code: u8) -> Self {
        match code {
            0 => Self::ThreeColumns,
            1 => Self::MotionBesideStack,
            _ => Self::OneColumn,
        }
    }

    /// The columns each of this layout's slots draws, in order.
    ///
    /// One group is one horizontal slot, and the columns inside it stack vertically. Returning the
    /// arrangement as a list of COLUMN GROUPS rather than as three hand-written view bodies is what
    /// keeps the two renderers from disagreeing about which column got stacked with which.
    #[must_use]
    pub const fn groups(self) -> &'static [&'static [Column]] {
        match self {
            Self::ThreeColumns => &[&[Column::Motion], &[Column::Selection], &[Column::Search]],
            Self::MotionBesideStack => &[&[Column::Motion], &[Column::Selection, Column::Search]],
            Self::OneColumn => &[&[Column::Motion, Column::Selection, Column::Search]],
        }
    }
}

/// Which arrangement a card of `available` points can afford.
///
/// The three widths are what ONE column costs at its intrinsic width — its widest row, chips, gap
/// and label together — measured by the caller, because only the renderer can measure its own type.
/// The DECISION is shared; the measurement is the framework's.
///
/// `gap` is the space between two side-by-side columns. The stacked rung is measured against the
/// WIDER of the two short columns, because a vertical stack is as wide as its widest child — the
/// same arithmetic `ViewThatFits` was doing by building the thing and asking it.
#[must_use]
pub fn layout(available: f64, gap: f64, motion: f64, selection: f64, search: f64) -> Layout {
    if motion + selection + search + gap * 2.0 <= available {
        return Layout::ThreeColumns;
    }
    if motion + f64::max(selection, search) + gap <= available {
        return Layout::MotionBesideStack;
    }
    Layout::OneColumn
}

#[cfg(test)]
mod tests {
    use super::{Column, Layout, SEPARATOR, VisualMode, advertised_keys, layout, pill_accessibility_label};

    #[test]
    fn every_index_round_trips() {
        for column in Column::ALL {
            assert_eq!(Column::from_index(column.index()), Some(column));
        }
        assert_eq!(Column::from_index(3), None);
        for code in 0..3_u8 {
            assert_eq!(Layout::from_code(code).code(), code);
        }
    }

    /// The card lists WIRED keys and nothing else, and the range token is not one of them.
    #[test]
    fn the_advertised_keys_are_the_tables_with_the_range_token_dropped() {
        let keys = advertised_keys();
        assert!(!keys.contains(&SEPARATOR), "the range token is not a key");
        for wired in ["h", "l", "w", "b", "e", "0", "^", "$", "o", "Y", "f"] {
            assert!(keys.contains(&wired), "{wired} is wired but unadvertised");
        }
        for unwired in ["H", "M", "L"] {
            assert!(!keys.contains(&unwired), "{unwired} is advertised but not wired");
        }
        let rows: usize = Column::ALL.into_iter().map(|c| c.hints().len()).sum();
        assert_eq!(rows, 20, "a row was added or lost without this gate noticing");
    }

    /// MOTION is the tall column, which is the whole reason the middle rung exists.
    #[test]
    fn motion_is_the_tall_column() {
        assert!(Column::Motion.hints().len() > Column::Selection.hints().len());
        assert!(Column::Selection.hints().len() > Column::Search.hints().len());
    }

    #[test]
    fn the_ladder_descends_one_rung_at_a_time_as_the_card_narrows() {
        let (gap, motion, selection, search) = (8.0, 100.0, 80.0, 70.0);
        let three = motion + selection + search + gap * 2.0;
        assert_eq!(
            layout(three, gap, motion, selection, search),
            Layout::ThreeColumns
        );
        assert_eq!(
            layout(three - 0.5, gap, motion, selection, search),
            Layout::MotionBesideStack,
        );
        let stacked = motion + selection + gap;
        assert_eq!(
            layout(stacked, gap, motion, selection, search),
            Layout::MotionBesideStack,
        );
        assert_eq!(
            layout(stacked - 0.5, gap, motion, selection, search),
            Layout::OneColumn
        );
    }

    /// The stacked rung is measured against the WIDER short column, never the second one named.
    #[test]
    fn the_stack_is_as_wide_as_its_widest_child() {
        let (gap, motion) = (8.0, 100.0);
        let available = motion + 90.0 + gap;
        assert_eq!(
            layout(available, gap, motion, 90.0, 20.0),
            Layout::MotionBesideStack
        );
        assert_eq!(
            layout(available, gap, motion, 20.0, 90.0),
            Layout::MotionBesideStack
        );
        assert_eq!(
            layout(available - 0.5, gap, motion, 20.0, 90.0),
            Layout::OneColumn
        );
    }

    /// Every column appears in every rung exactly once — a grouping that dropped one would clip the
    /// card rather than reflow it.
    #[test]
    fn every_rung_draws_every_column_once() {
        for code in 0..3_u8 {
            let mut seen: Vec<Column> = Layout::from_code(code)
                .groups()
                .iter()
                .flat_map(|g| *g)
                .copied()
                .collect();
            seen.sort_by_key(|column| column.index());
            assert_eq!(seen, Column::ALL.to_vec(), "rung {code}");
        }
    }

    #[test]
    fn the_pill_reads_mode_then_count_and_falls_back_to_the_plain_word() {
        assert_eq!(pill_accessibility_label(VisualMode::None, None), "Vi mode VI");
        assert_eq!(
            pill_accessibility_label(VisualMode::Char, Some(5)),
            "Vi mode VISUAL 5",
        );
        assert_eq!(
            pill_accessibility_label(VisualMode::Block, None),
            "Vi mode VISUAL BLOCK",
        );
        assert_eq!(VisualMode::from_index(9), VisualMode::None);
    }
}
