//! The SHAPE of a settings page: which groups it shows, in what order, what each row is, and which
//! platform each of those belongs to.
//!
//! [`settings_catalog`](crate::settings_catalog) says what a control OFFERS and
//! [`settings_rows`](crate::settings_rows) says what a setting IS. Neither says where it appears.
//! That was 2100 lines of `SwiftUI` body, and page structure is the last thing in Settings that was
//! still a fact spelled in a view.
//!
//! ## A platform gate is DATA
//!
//! This is the reason the module exists, more than the de-duplication. "The Dock icon group is
//! macOS-only" is a fact about the group, and it was spelled thirty-seven times as `#if os(macOS)`
//! scattered through one file — a form of conditional the two UI halves cannot share, cannot test,
//! and cannot even see the total of. As a [`Platform`] field on a group it is a value: the Mac
//! renderer asks for [`Platform::Mac`] rows, the phone renderer asks for [`Platform::Phone`] rows,
//! and NEITHER carries a gate. That is what lets `SlopDeskMacUI` hold its "not one `#if os(...)`"
//! rule while still drawing the macOS-only groups (docs/56 §3).
//!
//! ## What does NOT cross, and why
//!
//! A row names its setting by KEY; it does not carry a binding. `@Default(.onLaunch)` is a Swift
//! property wrapper over `UserDefaults`, so the key → binding step stays in each renderer as a
//! `switch`, exactly as `AllSettingsListView.inlineControl(for:)` already does. A row's LABEL does
//! not cross either — it is already in [`settings_rows`](crate::settings_rows), keyed by the same
//! string, and saying it twice here is what this whole port exists to stop.
//!
//! GOLDEN-SAFE: metadata only. Nothing here reads or writes a value or touches a wire codec.

use crate::settings_catalog::{ApplyTiming, Group, Ladder, Section};

/// Which UI half draws a group or a row.
///
/// `Both` is the default and the common case; the two others are the settings whose BACKING is
/// absent on the other platform — a Dock, `LaunchServices` deep-links and `NSSound` on one side,
/// nothing on the other. A row is never hidden because a small screen is crowded: docs/56 §3 says
/// layout diverges and capability does not.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    /// Drawn by both halves.
    Both,
    /// macOS only — the backing API does not exist on iOS.
    Mac,
    /// iOS only.
    Phone,
}

impl Platform {
    /// The case index a platform crosses as.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::Both => 0,
            Self::Mac => 1,
            Self::Phone => 2,
        }
    }

    /// Whether a half that identifies as `mac` draws this.
    #[must_use]
    pub const fn shown_on(self, mac: bool) -> bool {
        match self {
            Self::Both => true,
            Self::Mac => mac,
            Self::Phone => !mac,
        }
    }
}

/// What a row DRAWS. The renderer maps this to its framework's widget; the choice of widget for a
/// given setting is a design decision and belongs here rather than in whichever half was written
/// first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Control {
    /// A switch, with the leading SF Symbol the group's icon rail runs through.
    Toggle {
        /// The leading SF Symbol.
        glyph: &'static str,
    },
    /// A one-line pop-up menu over a [`Group`]'s options.
    ///
    /// The alternative is [`Control::Cards`], and the rule for picking is a MEASUREMENT of the
    /// longest label: a card is a fixed-width tile, so a group whose longest option is a sentence
    /// ("Only when source tab is unfocused") cannot use one.
    Menu {
        /// The options the menu lists.
        group: Group,
        /// The leading SF Symbol, when the group runs an icon rail through this row.
        glyph: Option<&'static str>,
    },
    /// A row of selectable cards over a [`Group`]'s options — art per option, chosen when the
    /// options differ in a way a word cannot show (a caret shape, a window size).
    Cards {
        /// The options the cards stand for.
        group: Group,
    },
    /// A slider with preset stops over a [`Ladder`].
    Slider {
        /// The scale, its stops and its readout.
        ladder: Ladder,
    },
    /// A free-text field.
    Text {
        /// The leading SF Symbol, when the group runs an icon rail through this row.
        glyph: Option<&'static str>,
    },
    /// A group the renderer draws itself, named by id.
    ///
    /// The escape hatch, and it is deliberately NARROW: it is for a group that is not a list of
    /// settings at all — a permission prompt, an install card with a privileged step, a live status
    /// readout. Reaching for it to avoid describing a plain toggle would put the row's words back
    /// in a view, which is the thing this module removes.
    Bespoke {
        /// What the renderer switches on to draw it.
        id: &'static str,
    },
}

impl Control {
    /// The case index a control crosses as.
    #[must_use]
    pub const fn kind(self) -> u8 {
        match self {
            Self::Toggle { .. } => 0,
            Self::Menu { .. } => 1,
            Self::Cards { .. } => 2,
            Self::Slider { .. } => 3,
            Self::Text { .. } => 4,
            Self::Bespoke { .. } => 5,
        }
    }

    /// The [`Group`] or [`Ladder`] index this control draws over, if it draws over one.
    ///
    /// One accessor for both because no control carries both, and a renderer that has already read
    /// [`Control::kind`] knows which of the two it is holding.
    #[must_use]
    pub const fn argument(self) -> Option<u8> {
        match self {
            Self::Menu { group, .. } | Self::Cards { group } => Some(group.index()),
            Self::Slider { ladder } => Some(ladder.index()),
            Self::Toggle { .. } | Self::Text { .. } | Self::Bespoke { .. } => None,
        }
    }

    /// The leading SF Symbol, where the control has one.
    #[must_use]
    pub const fn glyph(self) -> Option<&'static str> {
        match self {
            Self::Toggle { glyph } => Some(glyph),
            Self::Menu { glyph, .. } | Self::Text { glyph } => glyph,
            Self::Cards { .. } | Self::Slider { .. } | Self::Bespoke { .. } => None,
        }
    }

    /// What the renderer switches on for a [`Control::Bespoke`] group, empty for every other kind.
    #[must_use]
    pub const fn bespoke_id(self) -> &'static str {
        match self {
            Self::Bespoke { id } => id,
            Self::Toggle { .. }
            | Self::Menu { .. }
            | Self::Cards { .. }
            | Self::Slider { .. }
            | Self::Text { .. } => "",
        }
    }
}

/// One row on a settings page.
#[derive(Debug, Clone, Copy)]
pub struct LayoutRow {
    /// The setting this row edits — a `SettingsKey` name, or a
    /// [`settings_rows`](crate::settings_rows) key for a render field. The row's LABEL is looked up
    /// from that table by this key, so it is never spelled twice.
    ///
    /// Empty for a [`Control::Bespoke`] group, which edits no single setting.
    pub key: &'static str,
    /// The gray line under the label, in the register of a page that has already named its section.
    /// Deliberately NOT the flat index's description — docs/56 §18.
    pub subtitle: &'static str,
    /// What the row draws.
    pub control: Control,
    /// Which half draws it.
    pub platform: Platform,
}

/// One titled group of rows on a settings page.
#[derive(Debug, Clone, Copy)]
pub struct LayoutGroup {
    /// The page this group sits on.
    pub section: Section,
    /// The group header.
    pub title: &'static str,
    /// The rows, in reading order.
    pub rows: &'static [LayoutRow],
    /// The footer that tells the reader when an edit here takes effect.
    pub timing: ApplyTiming,
    /// Which half draws the group at all.
    pub platform: Platform,
}

/// Every group, page by page, in the order each page renders them.
///
/// Order here IS the rendered order, which is why this is one flat slice rather than a map: a map
/// would need a second list to say the order, and the two would drift.
pub const GROUPS: &[LayoutGroup] = &[
    // ── General ────────────────────────────────────────────────────────────────────────────────
    LayoutGroup {
        section: Section::General,
        title: "General",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "general.onLaunch",
            subtitle: "What a cold start opens.",
            control: Control::Menu {
                group: Group::OnLaunch,
                glyph: None,
            },
            platform: Platform::Both,
        }],
    },
    // The tab row drops `multiple_tabs` (a tab close loses exactly one tab, so the policy could
    // never fire) but otherwise shares the window row's wording — `CloseConfirmationTab`'s options
    // are a prefix of `CloseConfirmation`'s, so the two rows cannot describe one policy differently.
    LayoutGroup {
        section: Section::General,
        title: "Close Confirmation",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[
            LayoutRow {
                key: "shell.closeConfirm.tab",
                subtitle: "When to ask before a tab goes away. ⌘W closes a pane and only ever asks \
                           mid-command.",
                control: Control::Menu {
                    group: Group::CloseConfirmationTab,
                    glyph: None,
                },
                platform: Platform::Both,
            },
            LayoutRow {
                key: "shell.closeConfirm.window",
                subtitle: "When to ask before a window goes away.",
                control: Control::Menu {
                    group: Group::CloseConfirmation,
                    glyph: None,
                },
                platform: Platform::Both,
            },
        ],
    },
    LayoutGroup {
        section: Section::General,
        title: "Privacy & New Panes",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "features.redactSecrets",
            subtitle: "Mask token- and key-shaped runs in tab titles so a screen share can't leak them.",
            control: Control::Toggle { glyph: "eye.slash" },
            platform: Platform::Both,
        }],
    },
    // The one device-local knob on this page (docs/45 §8.2), and the one whose DEFAULT differs by
    // platform — which is exactly why it needs a control on both. `Platform::Both`, emphatically.
    LayoutGroup {
        section: Section::General,
        title: "Shared Focus",
        timing: ApplyTiming::Live,
        platform: Platform::Both,
        rows: &[LayoutRow {
            key: "follow-session-focus",
            subtitle: "Switching tab or pane here moves every device that follows. Off keeps this device's \
                       view to itself — the others still see where it is looking.",
            control: Control::Toggle { glyph: "viewfinder" },
            platform: Platform::Both,
        }],
    },
    // macOS-only: `DefaultTerminalIntegration` is LaunchServices plus a System-Settings deep-link,
    // and iOS has neither. It reuses the first-launch sheet's actions so the buttons stay REACHABLE
    // after "Skip Setup", which is the bug that put it on this page.
    LayoutGroup {
        section: Section::General,
        title: "OS Integration",
        timing: ApplyTiming::Live,
        platform: Platform::Mac,
        rows: &[LayoutRow {
            key: "",
            subtitle: "",
            control: Control::Bespoke { id: "os-integration" },
            platform: Platform::Mac,
        }],
    },
];

/// The groups one page shows on one half, in render order.
#[must_use]
pub fn groups(section: Section, mac: bool) -> Vec<&'static LayoutGroup> {
    GROUPS
        .iter()
        .filter(|group| group.section == section && group.platform.shown_on(mac))
        .collect()
}

/// The rows one group shows on one half, in render order.
#[must_use]
pub fn rows(group: &'static LayoutGroup, mac: bool) -> Vec<&'static LayoutRow> {
    group
        .rows
        .iter()
        .filter(|row| row.platform.shown_on(mac))
        .collect()
}

/// The group at a flat position, filtered to one half — the indexing the boundary carries.
#[must_use]
pub fn group_at(section: Section, mac: bool, index: usize) -> Option<&'static LayoutGroup> {
    groups(section, mac).get(index).copied()
}

/// The row at a flat position within a filtered group.
#[must_use]
pub fn row_at(
    section: Section,
    mac: bool,
    group_index: usize,
    row_index: usize,
) -> Option<&'static LayoutRow> {
    rows(group_at(section, mac, group_index)?, mac)
        .get(row_index)
        .copied()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings_rows;

    /// Every row names a setting the row table also carries, because the row table is where the
    /// LABEL comes from. A key with no row renders a header with no words under it.
    #[test]
    fn every_row_names_a_setting_that_has_a_label() {
        for group in GROUPS {
            for row in group.rows {
                if matches!(row.control, Control::Bespoke { .. }) {
                    assert!(
                        row.key.is_empty(),
                        "{} draws itself, so it names no single key",
                        group.title
                    );
                    continue;
                }
                assert!(
                    settings_rows::row(row.key).is_some(),
                    "{} → {} names no row, so it has no label to render",
                    group.title,
                    row.key,
                );
            }
        }
    }

    /// A row is never MORE available than the group that contains it — a `Both` row inside a `Mac`
    /// group is a row the phone can never reach, written as though it could.
    #[test]
    fn a_row_is_never_wider_than_its_group() {
        for group in GROUPS {
            for row in group.rows {
                assert!(
                    group.platform == Platform::Both || row.platform == group.platform,
                    "{} is {:?} but a row inside it claims {:?}",
                    group.title,
                    group.platform,
                    row.platform,
                );
            }
        }
    }

    /// Every group has at least one row on the half that draws it. An empty group is a header with
    /// nothing under it, which is what a badly-placed platform gate produces.
    #[test]
    fn no_half_ever_draws_an_empty_group() {
        for mac in [true, false] {
            for section in Section::ALL {
                for group in groups(section, mac) {
                    assert!(
                        !rows(group, mac).is_empty(),
                        "{} draws empty on {}",
                        group.title,
                        if mac { "macOS" } else { "iOS" },
                    );
                }
            }
        }
    }

    /// No page repeats a group header, and no group repeats a key.
    #[test]
    fn a_group_is_named_once_and_edits_each_setting_once() {
        let mut seen_titles = Vec::new();
        let mut seen_keys = Vec::new();
        for group in GROUPS {
            let title = (group.section.id(), group.title);
            assert!(
                !seen_titles.contains(&title),
                "{} appears twice on {}",
                group.title,
                title.0
            );
            seen_titles.push(title);
            for row in group.rows {
                if row.key.is_empty() {
                    continue;
                }
                assert!(
                    !seen_keys.contains(&row.key),
                    "{} is edited twice on this page — two controls over one value",
                    row.key,
                );
                seen_keys.push(row.key);
            }
        }
    }

    /// The macOS-only groups really are the ones with no iOS backing, and the phone still gets
    /// every group that has one. Stated as a COUNT so removing a gate is a visible edit here.
    #[test]
    fn the_general_page_differs_by_exactly_the_groups_ios_cannot_back() {
        let on_mac: Vec<_> = groups(Section::General, true).iter().map(|g| g.title).collect();
        let on_phone: Vec<_> = groups(Section::General, false).iter().map(|g| g.title).collect();
        assert_eq!(on_mac, [
            "General",
            "Close Confirmation",
            "Privacy & New Panes",
            "Shared Focus",
            "OS Integration"
        ]);
        assert_eq!(on_phone, [
            "General",
            "Close Confirmation",
            "Privacy & New Panes",
            "Shared Focus"
        ]);
    }

    /// Positional lookup agrees with the filtered list it indexes into — the property the boundary
    /// relies on, since it crosses a count and then asks for each position.
    #[test]
    fn a_position_resolves_to_the_group_the_filtered_list_holds() {
        for mac in [true, false] {
            for section in Section::ALL {
                let listed = groups(section, mac);
                for (index, group) in listed.iter().enumerate() {
                    assert_eq!(group_at(section, mac, index).map(|g| g.title), Some(group.title));
                    for (row_index, row) in rows(group, mac).iter().enumerate() {
                        assert_eq!(
                            row_at(section, mac, index, row_index).map(|r| r.key),
                            Some(row.key),
                            "{} row {row_index}",
                            group.title,
                        );
                    }
                }
                assert!(
                    group_at(section, mac, listed.len()).is_none(),
                    "one past the end is not a group"
                );
            }
        }
    }

    /// Each control's accessors agree with the variant they read. This is the shape the boundary
    /// carries — a kind plus at most one numeric and one string payload — and the assertion is that
    /// the flattening loses nothing: a `Menu` always names a group, a `Bespoke` always names an id
    /// and never a glyph, and nothing carries a payload its kind cannot use.
    #[test]
    fn a_control_flattens_without_losing_what_it_carries() {
        for group in GROUPS {
            for row in group.rows {
                let control = row.control;
                match control {
                    Control::Toggle { glyph } => {
                        assert_eq!(control.kind(), 0);
                        assert_eq!(control.glyph(), Some(glyph));
                        assert!(control.argument().is_none() && control.bespoke_id().is_empty());
                    },
                    Control::Menu { group: options, .. } | Control::Cards { group: options } => {
                        assert!(control.kind() == 1 || control.kind() == 2);
                        assert_eq!(control.argument(), Some(options.index()));
                        assert!(control.bespoke_id().is_empty());
                    },
                    Control::Slider { ladder } => {
                        assert_eq!(control.kind(), 3);
                        assert_eq!(control.argument(), Some(ladder.index()));
                        assert!(control.glyph().is_none() && control.bespoke_id().is_empty());
                    },
                    Control::Text { glyph } => {
                        assert_eq!(control.kind(), 4);
                        assert_eq!(control.glyph(), glyph);
                        assert!(control.argument().is_none() && control.bespoke_id().is_empty());
                    },
                    Control::Bespoke { id } => {
                        assert_eq!(control.kind(), 5);
                        assert_eq!(control.bespoke_id(), id);
                        assert!(!id.is_empty(), "a bespoke group with no id names nothing to draw");
                        assert!(control.argument().is_none() && control.glyph().is_none());
                    },
                }
            }
        }
    }

    /// A platform crosses as its own index, and `shown_on` is the only reading of it.
    #[test]
    fn a_platform_crosses_by_index_and_answers_one_question() {
        assert_eq!(
            [
                Platform::Both.index(),
                Platform::Mac.index(),
                Platform::Phone.index()
            ],
            [0, 1, 2]
        );
        assert!(Platform::Both.shown_on(true) && Platform::Both.shown_on(false));
        assert!(Platform::Mac.shown_on(true) && !Platform::Mac.shown_on(false));
        assert!(!Platform::Phone.shown_on(true) && Platform::Phone.shown_on(false));
    }
}
