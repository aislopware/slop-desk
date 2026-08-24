//! The RIGHT panel's tab row: which tabs exist, what each is called, what it draws, and how many of
//! them get to say their name at a given width.
//!
//! This exists because the four tabs were written TWICE — once across the panel's own strip and
//! once down the rail the collapsed panel leaves behind — and the two lists had to agree on the
//! mark, the word AND the help text of every surface. They are the same four tabs seen on two axes,
//! exactly the way the tab list is the sidebar's rows seen on two axes, so they are cut once here
//! and drawn by whoever is mounted.
//!
//! ## The width ladder is arithmetic, not a `ViewThatFits`
//!
//! Four tabs carrying a mark and a word want more room than a panel dragged to its minimum has, so
//! the strip gives the words up a rung at a time — every tab named, then only the selected one,
//! then none — rather than truncating, because a tab reading `Simulat…` has stopped saying what it
//! switches to while a mark alone still says it. `SwiftUI` could ask that question by building all
//! three candidates and measuring them; that cost a NAMESPACE PER RUNG, because every candidate is
//! built, so one namespace would put three copies of the travelling plate's geometry on screen at
//! once. Said as arithmetic it is one answer, and both frameworks — and a test — can ask it without
//! building anything.

/// What a panel tab draws before its label.
///
/// The split is NOT between a shape and a brand: `apple.logo` is a brand and takes the same em as
/// `folder`, because Apple's optical grid already makes them agree. The split is between a symbol
/// on that grid and the ONE mark no icon set ships — a drawn path with no grid behind it, which is
/// why it carries its own size.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mark {
    /// An SF Symbol, by NAME — the two frameworks want different types out of it, and what the
    /// decision here is about is WHICH glyph, not how it is loaded.
    Symbol(&'static str),
    /// The drawn Android mark, which no icon set ships.
    Android,
}

/// One of the right panel's four surfaces, in the shipping order of [`ALL`].
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Surface {
    /// The project's embedded workbench.
    Code,
    /// The host's iOS Simulator devices.
    Simulators,
    /// The host's Android emulators and attached hardware.
    Android,
    /// The host's window surface.
    Desktop,
}

impl Surface {
    /// The surface at `index` in the near side's case order, or `None` past the end.
    #[must_use]
    pub const fn from_index(index: u8) -> Option<Self> {
        match index {
            0 => Some(Self::Code),
            1 => Some(Self::Simulators),
            2 => Some(Self::Android),
            3 => Some(Self::Desktop),
            _ => None,
        }
    }

    /// This surface's place in the case order.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::Code => 0,
            Self::Simulators => 1,
            Self::Android => 2,
            Self::Desktop => 3,
        }
    }
}

/// One tab: the surface it selects, the mark that identifies it, the word that names it, and the
/// sentence the pointer gets.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Tab {
    /// What selecting this tab shows.
    pub surface: Surface,
    /// The glyph drawn before the label.
    pub mark: Mark,
    /// The word on the tab.
    pub label: &'static str,
    /// The pointer's sentence, written `Name — sentence`.
    pub help: &'static str,
}

impl Tab {
    /// What a screen reader CALLS this tab. The word, never the sentence: a label is an identity
    /// and gets read on every focus change, so a tab whose label is the whole help text makes the
    /// reader listen to an explanation four times to find out where they are.
    ///
    /// The two shells had drifted to opposite answers — the Mac read the label, the phone read the
    /// help — which is the drift a shared reading exists to prevent.
    #[must_use]
    pub const fn accessibility_label(self) -> &'static str {
        self.label
    }

    /// The elaboration, offered AFTER the label: the help minus the name it opens with, because the
    /// reader has just heard that name as the label and hearing it twice reads as a stutter.
    ///
    /// Every help string is written `Name — sentence`; one without the dash is already a bare
    /// sentence and is offered whole.
    #[must_use]
    pub fn accessibility_hint(self) -> &'static str {
        match self.help.split_once(" — ") {
            Some((_, sentence)) => sentence,
            None => self.help,
        }
    }
}

/// The four tabs, in their shipping order.
///
/// Files and Simulators lead because they are the REAL host resources; Desktop trails because it is
/// announced-but-empty. "Emulators" names the Android tab and the help text carries the rest — the
/// surface also lists attached hardware, which no emulator is. Desktop's glyph is `display`, the
/// app's existing GUI-surface vocabulary (`macwindow` read as a blob at strip size).
pub const ALL: [Tab; 4] = [
    Tab {
        // The FOLDER register, not a lone document — the tab opens the whole project tree.
        surface: Surface::Code,
        mark: Mark::Symbol("folder"),
        label: "Files",
        help: "Files — the project's embedded editor",
    },
    Tab {
        surface: Surface::Simulators,
        mark: Mark::Symbol("apple.logo"),
        label: "Simulators",
        help: "Simulators — the host's iOS Simulator devices",
    },
    Tab {
        surface: Surface::Android,
        mark: Mark::Android,
        label: "Emulators",
        help: "Emulators — the host's Android emulators and attached devices",
    },
    Tab {
        surface: Surface::Desktop,
        mark: Mark::Symbol("display"),
        label: "Desktop",
        help: "Desktop — the host's window surface",
    },
];

/// The tab that selects `surface`.
#[must_use]
pub fn tab(surface: Surface) -> Option<Tab> {
    ALL.into_iter().find(|tab| tab.surface == surface)
}

/// How many tabs get to say their name at the width the strip actually has.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Labelling {
    /// Every tab says its name.
    All,
    /// Only the selected tab does.
    SelectedOnly,
    /// None of them do; the marks stand alone.
    None,
}

impl Labelling {
    /// The discriminant a renderer switches on.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::All => 0,
            Self::SelectedOnly => 1,
            Self::None => 2,
        }
    }

    /// The rung `code` names; anything past the end is the one that always fits.
    #[must_use]
    pub const fn from_code(code: u8) -> Self {
        match code {
            0 => Self::All,
            1 => Self::SelectedOnly,
            _ => Self::None,
        }
    }

    /// Whether the tab selecting `surface` says its name at this rung.
    #[must_use]
    pub fn names(self, surface: Surface, selected: Surface) -> bool {
        match self {
            Self::All => true,
            Self::SelectedOnly => surface == selected,
            Self::None => false,
        }
    }
}

/// Which rung of the width ladder a strip of `available` points can afford.
///
/// `named` is what each tab costs BEYOND its bare cell — the label's measured width plus the gap
/// and the collar around it — one entry per tab in [`ALL`]'s order, measured by the caller because
/// only the renderer can measure its own type. Everything else is this decision's: a bare cell is
/// square, the tabs sit `gap` apart, and the rung is the widest one that still fits.
///
/// A `named` shorter than [`ALL`] reads the missing tabs as costing nothing, which loses a rung
/// boundary rather than reading past the end of the caller's array.
#[must_use]
pub fn labelling(available: f64, cell: f64, gap: f64, named: &[f64], selected: Surface) -> Labelling {
    // Four cells and the three gaps between them. Spelled as literals rather than cast from
    // `ALL.len()` because a `usize as f64` is a lossy cast this workspace denies, and the tab count
    // is a shipped fact a test pins rather than a number that varies at runtime.
    let bare = cell * 4.0 + gap * 3.0;
    let every_name: f64 = named.iter().take(ALL.len()).sum();
    if bare + every_name <= available {
        return Labelling::All;
    }
    let one_name = named.get(usize::from(selected.index())).copied().unwrap_or(0.0);
    if bare + one_name <= available {
        return Labelling::SelectedOnly;
    }
    Labelling::None
}

#[cfg(test)]
mod tests {
    use super::{ALL, Labelling, Mark, Surface, labelling, tab};

    /// The count `labelling`'s bare-strip arithmetic is written against.
    #[test]
    fn the_strip_holds_the_four_tabs_the_ladder_measures() {
        assert_eq!(
            ALL.len(),
            4,
            "labelling()'s `cell * 4 + gap * 3` names this count"
        );
    }

    #[test]
    fn the_tabs_stand_in_their_shipping_order_and_each_index_finds_its_own() {
        for (position, entry) in ALL.into_iter().enumerate() {
            assert_eq!(usize::from(entry.surface.index()), position);
            assert_eq!(Surface::from_index(entry.surface.index()), Some(entry.surface));
            assert_eq!(tab(entry.surface), Some(entry));
        }
        assert_eq!(Surface::from_index(4), None);
    }

    /// One mark is a drawn path rather than a symbol, and it is the only one.
    #[test]
    fn only_the_android_tab_carries_a_mark_no_icon_set_ships() {
        let drawn = ALL.into_iter().filter(|tab| tab.mark == Mark::Android).count();
        assert_eq!(drawn, 1);
        assert_eq!(
            tab(Surface::Code).map(|tab| tab.mark),
            Some(Mark::Symbol("folder"))
        );
    }

    /// The hint is the help minus the name, so a reader never hears the name twice.
    #[test]
    fn the_hint_drops_the_name_the_label_already_said() {
        for entry in ALL {
            let hint = entry.accessibility_hint();
            assert_eq!(entry.accessibility_label(), entry.label);
            assert!(!hint.starts_with(entry.label), "{} stutters: {hint}", entry.label);
            assert!(entry.help.ends_with(hint));
        }
    }

    /// A help string with no dash is already a bare sentence and is offered whole.
    #[test]
    fn a_dashless_help_is_offered_whole() {
        let bare = super::Tab {
            surface: Surface::Code,
            mark: Mark::Android,
            label: "Files",
            help: "just a sentence",
        };
        assert_eq!(bare.accessibility_hint(), "just a sentence");
    }

    #[test]
    fn the_ladder_gives_the_words_up_one_rung_at_a_time() {
        let (cell, gap) = (28.0, 6.0);
        let named = [40.0, 70.0, 66.0, 56.0];
        let bare = cell * 4.0 + gap * 3.0;
        let every: f64 = named.iter().sum();
        assert_eq!(
            labelling(bare + every, cell, gap, &named, Surface::Code),
            Labelling::All,
        );
        assert_eq!(
            labelling(bare + every - 0.5, cell, gap, &named, Surface::Code),
            Labelling::SelectedOnly,
        );
        assert_eq!(
            labelling(bare + 40.0, cell, gap, &named, Surface::Code),
            Labelling::SelectedOnly,
        );
        assert_eq!(
            labelling(bare + 39.5, cell, gap, &named, Surface::Code),
            Labelling::None,
        );
    }

    /// The middle rung is measured against the SELECTED tab's word, not the first one's.
    #[test]
    fn the_selected_tabs_own_word_is_what_the_middle_rung_pays_for() {
        let (cell, gap) = (28.0, 6.0);
        let named = [40.0, 70.0, 66.0, 56.0];
        let bare = cell * 4.0 + gap * 3.0;
        assert_eq!(
            labelling(bare + 40.0, cell, gap, &named, Surface::Simulators),
            Labelling::None,
        );
        assert_eq!(
            labelling(bare + 70.0, cell, gap, &named, Surface::Simulators),
            Labelling::SelectedOnly,
        );
    }

    /// A short measurement array loses a rung boundary rather than reading past its end.
    #[test]
    fn a_short_measurement_is_read_as_free_rather_than_out_of_bounds() {
        assert_eq!(
            labelling(1000.0, 28.0, 6.0, &[], Surface::Desktop),
            Labelling::All
        );
    }

    #[test]
    fn each_rung_names_the_tabs_it_promises() {
        assert!(Labelling::All.names(Surface::Desktop, Surface::Code));
        assert!(!Labelling::SelectedOnly.names(Surface::Desktop, Surface::Code));
        assert!(Labelling::SelectedOnly.names(Surface::Code, Surface::Code));
        assert!(!Labelling::None.names(Surface::Code, Surface::Code));
        for code in 0..3_u8 {
            assert_eq!(Labelling::from_code(code).code(), code);
        }
    }
}
