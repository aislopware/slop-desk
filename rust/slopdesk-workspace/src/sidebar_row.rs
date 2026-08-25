//! What ONE navigator row's ink, weight and tooltip come to, and what its menu offers.
//!
//! Three surfaces render the same pane and may never disagree about it: the Mac's `AppKit`
//! navigator, the phone's `SwiftUI` list row, and — for the title alone — the collapsed-sidebar tab
//! strip. The GATHERING of a row off the live store stays on the near side, which is where the
//! store is; what is here is every answer that gathering then has to reach for.
//!
//! ⚠️ THE ONE SUBTLETY, stated once so neither half has to re-derive it: the WORKING reading is
//! keyed on the raw agent status and NOT on the fused badge. "Badge While Processing" (default OFF)
//! masks the working state out of the badge resolver, so a row that read the badge here would draw
//! a thinking agent exactly like an idle shell on every default install. The toggle governs the
//! badge GLYPH; the working reading is the row's own affordance.

use slopdesk_agent::badge::{Attention, TabBadge, urgent};

/// The three rungs a row title's ink comes off.
///
/// Urgency first: a row that is BROKEN or BLOCKED wears the mark's own hue across the whole title,
/// and it outranks everything below including the active chip — a row you are standing on that just
/// broke still reads as broken. Everything else keeps the neutral ladder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TitleInk {
    /// Wrong or stopped, and waiting on you — the mark's own hue, taken across the whole title.
    Urgent(Attention),
    /// The focused row, and a thinking agent: a shade brighter than the rows doing nothing.
    Primary,
    /// At rest.
    Secondary,
}

impl TitleInk {
    /// The code this rung crosses as: the KIND in the high nibble, the urgent role in the low one.
    ///
    /// One byte rather than a tagged pair, the way [`Entry::code`] carries its own two halves — a
    /// row asks for its ink on every redraw, and the role is only ever read when the kind says
    /// urgent.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Secondary => 0x00,
            Self::Primary => 0x01,
            Self::Urgent(role) => 0x10 | role.code(),
        }
    }
}

/// The three rungs a row title's WEIGHT comes off.
///
/// A state that WAITS on you — a question, a failure, an unread finish — reads bolder than the
/// active row's own step, so "needs you" outranks "you are here" on the one scale both spend: the
/// mail idiom, where bold says *changed* and the mark's hue says what changed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TitleWeight {
    /// At rest.
    Resting,
    /// The focused row.
    Active,
    /// A state that waits on you — one step above [`TitleWeight::Active`].
    Attention,
}

impl TitleWeight {
    /// The code this rung crosses as.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Resting => 0,
            Self::Active => 1,
            Self::Attention => 2,
        }
    }
}

/// The rung a row title's ink comes off, given what the row is.
#[must_use]
pub fn title_ink(badge: Option<TabBadge>, active: bool, working: bool) -> TitleInk {
    if let Some(role) = badge.and_then(urgent) {
        return TitleInk::Urgent(role);
    }
    if active || working {
        TitleInk::Primary
    } else {
        TitleInk::Secondary
    }
}

/// The weight a row title is set at.
#[must_use]
pub fn title_weight(badge: Option<TabBadge>, active: bool) -> TitleWeight {
    if badge.and_then(slopdesk_agent::badge::attention).is_some() {
        return TitleWeight::Attention;
    }
    if active {
        TitleWeight::Active
    } else {
        TitleWeight::Resting
    }
}

/// The state the row's INK and its (accessibility-hidden) mark speak visually, kept legible for
/// `VoiceOver`.
///
/// The working reading first, then an attention badge's own word. A row whose only news is that it
/// is BUSY says nothing — busy is not a state anyone is waiting on.
#[must_use]
pub fn spoken_state(badge: Option<TabBadge>, working: bool) -> Option<&'static str> {
    if working {
        return Some(TabBadge::Running.label());
    }
    let badge = badge?;
    slopdesk_agent::badge::attention(badge).map(|_| badge.label())
}

/// Who ELSE is on this pane, as the lines that say so.
///
/// Two different facts, both useful — a client can be looking at a pane it does not hold, and
/// holding one it is not showing. Viewing first: it is the softer claim.
///
/// Written HERE rather than inside the tooltip because two surfaces spend them differently — the
/// Mac splices them into a hover, the phone prints them under the row title — and a fan-out named
/// "Held by" on one half and something else on the other is a disagreement about the WORKSPACE, not
/// about a layout.
#[must_use]
pub fn presence_lines(viewers: &[&str], holders: &[&str]) -> Vec<String> {
    let mut lines = Vec::new();
    if !viewers.is_empty() {
        lines.push(format!("Also open on {}", viewers.join(", ")));
    }
    if !holders.is_empty() {
        lines.push(format!("Held by {}", holders.join(", ")));
    }
    lines
}

/// The presence lines as ONE line — what a surface with no pointer to hang a tooltip off prints
/// under the row title.
///
/// [`None`] for the common case (this client alone), so a row with nothing to report grows no
/// second line rather than an empty one. Joined with ` · ` rather than the tooltip's newline: this
/// lands in ONE line under a row title, where the tooltip has a popover's worth of rows to spend.
#[must_use]
pub fn presence(viewers: &[&str], holders: &[&str]) -> Option<String> {
    let lines = presence_lines(viewers, holders);
    (!lines.is_empty()).then(|| lines.join(" \u{b7} "))
}

/// The hover tooltip — the full cwd, the untruncated readout, the last command, and who else is on
/// this pane.
///
/// The presence lines are a CUT of this and not a second reading: [`presence_lines`] writes them
/// once and both spenders splice the SAME strings, so a row and its hover can never name one
/// fan-out two ways. The cut exists because the rest of the tooltip is overflow RECOVERY — the
/// untruncated cwd, the clipped readout, facts the row already shows — while the presence pair is
/// the only thing in there that is not on screen anywhere else.
///
/// [`None`] when there is nothing to say; every empty part is dropped rather than printed blank.
#[must_use]
pub fn tooltip(
    cwd: Option<&str>,
    detail: Option<&str>,
    last_command: Option<&str>,
    viewers: &[&str],
    holders: &[&str],
) -> Option<String> {
    let mut parts: Vec<String> = [cwd, detail, last_command]
        .into_iter()
        .flatten()
        .filter(|part| !part.is_empty())
        .map(str::to_owned)
        .collect();
    // Appended rather than interleaved: they are written non-empty or not at all, so they need none
    // of the drop above.
    parts.extend(presence_lines(viewers, holders));
    (!parts.is_empty()).then(|| parts.join("\n"))
}

/// The tooltip's last-command line from a finished block: `command · duration · exit N`.
///
/// Parts the block does not carry are simply omitted; a block with none of the three has no line.
#[must_use]
pub fn command_line(
    command: &str,
    duration_label: Option<&str>,
    status_label: Option<&str>,
) -> Option<String> {
    let command = command.trim();
    let parts: Vec<&str> = [
        (!command.is_empty()).then_some(command),
        duration_label,
        status_label,
    ]
    .into_iter()
    .flatten()
    .collect();
    (!parts.is_empty()).then(|| parts.join(" \u{b7} "))
}

/// The row menu's plain verbs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verb {
    /// Open the inline rename on THIS row's tab, even a background one — the mouse-reachable twin
    /// of ⌘R and the palette's "Rename Pane".
    Rename,
    /// Acknowledge the pane's completion / attention badge.
    ClearBadge,
}

impl Verb {
    /// Every verb, in index order.
    pub const ALL: [Self; 2] = [Self::Rename, Self::ClearBadge];

    /// Its title.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::Rename => "Rename",
            Self::ClearBadge => "Clear Badge",
        }
    }
}

/// The row menu's checkboxes: three PER-PANE badge overrides.
///
/// Each is seeded from the pane's CURRENT effective gates, so the first flip preserves the other
/// two, and an absent override follows the global answer the config file resolves to.
///
/// It used to carry three more — two notification toggles and the host-local sleep assertion — and
/// they left with the settings GUI. Each was a SETTING wearing a context-menu row: a global answer
/// reached through a right-click on one pane, written by the app into a store the user could not
/// see. A per-pane badge override is a different thing entirely: it belongs to the pane, it dies
/// with it, and there is nowhere in a config file to state it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Switch {
    /// Badge a pane whose agent is thinking.
    BadgeWhileProcessing,
    /// Badge a pane whose agent finished.
    BadgeWhenComplete,
    /// Badge a pane whose agent is blocked on a question.
    BadgeWhenAwaitingInput,
}

impl Switch {
    /// Every switch, in index order.
    pub const ALL: [Self; 3] = [
        Self::BadgeWhileProcessing,
        Self::BadgeWhenComplete,
        Self::BadgeWhenAwaitingInput,
    ];

    /// Its title.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::BadgeWhileProcessing => "Badge While Processing",
            Self::BadgeWhenComplete => "Badge When Task Completes",
            Self::BadgeWhenAwaitingInput => "Badge When Awaiting Input",
        }
    }

    /// This switch's own index.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::BadgeWhileProcessing => 0,
            Self::BadgeWhenComplete => 1,
            Self::BadgeWhenAwaitingInput => 2,
        }
    }
}

/// One entry of a rail row's right-click / long-press menu.
///
/// The menu is a VALUE because it is a verb table, and a verb table written twice diverges on the
/// first new verb — the failure mode that is silent in both halves until a user notices their
/// phone's menu is not their Mac's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Entry {
    /// A plain verb.
    Action(Verb),
    /// A checkbox. The state it reads is the caller's, gathered off the store.
    Toggle(Switch),
    /// A rule between groups.
    Separator,
}

impl Entry {
    /// The code this entry crosses as: the kind in the high nibble, the member in the low one.
    ///
    /// One byte rather than a struct because the whole menu is nine of them and a caller walks the
    /// list once: a record per entry would cost a crossing per row of a context menu that opens
    /// under a finger.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Separator => 0x00,
            Self::Action(verb) => {
                match verb {
                    Verb::Rename => 0x10,
                    Verb::ClearBadge => 0x11,
                }
            },
            Self::Toggle(switch) => 0x20 | switch.index(),
        }
    }
}

/// The menu for a row, in menu order.
///
/// Fixed now — it used to take a `prevent_sleep_offered` flag, because that one row was absent in a
/// preview or a pre-injection shell that had no live preferences store. Nothing here is conditional
/// any more: every entry is answerable from the pane alone.
#[must_use]
pub fn menu() -> Vec<Entry> {
    vec![
        Entry::Action(Verb::Rename),
        Entry::Separator,
        Entry::Action(Verb::ClearBadge),
        Entry::Separator,
        Entry::Toggle(Switch::BadgeWhileProcessing),
        Entry::Toggle(Switch::BadgeWhenComplete),
        Entry::Toggle(Switch::BadgeWhenAwaitingInput),
    ]
}

/// Which of the row's six detail sources won, so the near side can hand back the string it already
/// holds instead of taking a copy of it home.
///
/// A source rather than a text for the reason the two list doors answer in indices: the caller
/// owns every candidate already, and the only thing it cannot decide for itself is the ORDER.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Detail {
    /// The blocked question — the caller gates it on `needsPermission` plus a non-empty label.
    Question = 0,
    /// The todo scent, while working and the inspector feed is live.
    Scent = 1,
    /// The host's last assistant line, while working and the feed is cold.
    WorkingLabel = 2,
    /// The agent's FINAL assistant line, at done-unseen.
    DoneLine = 3,
    /// The FAILING command, off the block model.
    ErrorLine = 4,
    /// The RUNNING command of a busy non-agent shell.
    CommandLine = 5,
}

impl Detail {
    /// The byte the C door answers with.
    #[must_use]
    pub const fn code(self) -> u8 {
        self as u8
    }
}

/// The row's ONE live-detail line, by precedence — question, scent, working label, done line, then
/// the two command-shaped rungs.
///
/// The two command rungs are DROPPED when they would only echo `title` one line up, and dropping
/// one falls through to the next rather than ending the ladder: a shell that titles its pane after
/// the command it runs must not silence a genuine failure line sitting behind it. Prose sources are
/// never gated — a sentence quoting the title is still news.
///
/// `None` is the resting state and never a placeholder: nothing live means the tooltip carries no
/// detail line at all.
///
/// The answer carries the WINNER as well as its line, because the two are different facts: a caller
/// drawing the line wants the string, and a caller pinning the ladder wants to know which rung it
/// came off. Absence, not emptiness, is what darkens a rung — every one of these is pre-gated by
/// the caller on state this rule cannot see (a live inspector feed, an unseen finish), so a rung
/// that is present-but-blank is a caller's own answer and is taken at its word.
#[must_use]
pub fn detail<'a>(
    question: Option<&'a str>,
    scent: Option<&'a str>,
    working_label: Option<&'a str>,
    done_line: Option<&'a str>,
    error_line: Option<&'a str>,
    command_line: Option<&'a str>,
    title: &str,
) -> Option<(Detail, &'a str)> {
    if let Some(question) = question {
        return Some((Detail::Question, question));
    }
    if let Some(scent) = scent {
        return Some((Detail::Scent, scent));
    }
    if let Some(label) = working_label {
        return Some((Detail::WorkingLabel, label));
    }
    if let Some(done) = done_line {
        return Some((Detail::DoneLine, done));
    }
    if let Some(error) = error_line
        && !echoes_title(error, title)
    {
        return Some((Detail::ErrorLine, error));
    }
    if let Some(command) = command_line
        && !echoes_title(command, title)
    {
        return Some((Detail::CommandLine, command));
    }
    None
}

/// Whether a command-shaped line would only REPEAT the title one line up: equal, or one is the
/// other's leading word(s) — `npm` over `npm test`, the shell titling the pane by its command.
///
/// Case-insensitive and WORD-BOUNDED, which is the whole subtlety: the prefix test carries a
/// trailing space so `api` never swallows `apitool run`.
#[must_use]
pub fn echoes_title(line: &str, title: &str) -> bool {
    let line = line.trim().to_lowercase();
    let title = title.trim().to_lowercase();
    if line.is_empty() || title.is_empty() {
        return false;
    }
    line == title
        || line
            .strip_prefix(&title)
            .is_some_and(|rest| rest.starts_with(' '))
        || title
            .strip_prefix(&line)
            .is_some_and(|rest| rest.starts_with(' '))
}

/// The error readout: the FAILING command, trimmed — the culprit's NAME, never its number.
///
/// The exit code rides the badge's `!<code>` one line up, so this takes only whether there IS one:
/// no code means no failure evidence to attribute, and a blank command means the badge's reading
/// stands alone. Both answer `None`, and the caller falls through to the running command.
#[must_use]
pub fn error_line(has_exit_code: bool, command_text: Option<&str>) -> Option<&str> {
    if !has_exit_code {
        return None;
    }
    let command = command_text.unwrap_or_default().trim();
    (!command.is_empty()).then_some(command)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        Attention, Detail, Entry, Switch, TabBadge, TitleInk, TitleWeight, Verb, command_line, detail,
        echoes_title, error_line, menu, presence, presence_lines, spoken_state, title_ink, title_weight,
        tooltip,
    };

    /// A row you are standing on that just broke still reads as broken.
    #[test]
    fn urgency_outranks_the_active_chip() {
        assert_eq!(
            title_ink(Some(TabBadge::Error), true, false),
            TitleInk::Urgent(Attention::Failed),
        );
        assert_eq!(
            title_ink(Some(TabBadge::AwaitingInput), false, false),
            TitleInk::Urgent(Attention::Awaiting),
        );
        // A finish is not urgent, so the neutral ladder answers.
        assert_eq!(
            title_ink(Some(TabBadge::Finished), true, false),
            TitleInk::Primary
        );
        assert_eq!(title_ink(None, false, true), TitleInk::Primary);
        assert_eq!(title_ink(None, false, false), TitleInk::Secondary);
    }

    /// "Needs you" outranks "you are here" on the one scale both spend.
    #[test]
    fn attention_outranks_the_active_step_in_weight() {
        assert_eq!(
            title_weight(Some(TabBadge::Finished), false),
            TitleWeight::Attention
        );
        assert_eq!(title_weight(Some(TabBadge::Error), true), TitleWeight::Attention);
        assert_eq!(title_weight(Some(TabBadge::Running), true), TitleWeight::Active);
        assert_eq!(title_weight(None, true), TitleWeight::Active);
        assert_eq!(title_weight(None, false), TitleWeight::Resting);
    }

    /// The subtlety the module header names: busy says nothing, and working is not the badge.
    #[test]
    fn a_merely_busy_row_speaks_no_state() {
        assert_eq!(spoken_state(Some(TabBadge::CommandBusy), false), None);
        assert_eq!(spoken_state(Some(TabBadge::Running), false), None);
        assert_eq!(spoken_state(None, false), None);
        // Working wins even with the badge masked out by the default-OFF gate.
        assert_eq!(spoken_state(None, true), Some("Agent working"));
        assert_eq!(
            spoken_state(Some(TabBadge::AwaitingInput), false),
            Some("Awaiting input")
        );
    }

    /// The cut and the tooltip must splice the same strings.
    #[test]
    fn the_presence_cut_and_the_tooltip_say_the_same_two_lines() {
        let viewers = ["iPad"];
        let holders = ["Studio"];
        assert_eq!(presence_lines(&viewers, &holders), vec![
            "Also open on iPad".to_owned(),
            "Held by Studio".to_owned()
        ],);
        assert_eq!(
            presence(&viewers, &holders).as_deref(),
            Some("Also open on iPad \u{b7} Held by Studio")
        );
        let hover = tooltip(Some("/a/b"), None, None, &viewers, &holders).expect("a tooltip");
        for line in presence_lines(&viewers, &holders) {
            assert!(hover.contains(&line), "{hover:?}");
        }
    }

    #[test]
    fn a_row_with_nothing_to_report_grows_no_line() {
        assert!(presence_lines(&[], &[]).is_empty());
        assert_eq!(presence(&[], &[]), None);
        assert_eq!(tooltip(None, None, None, &[], &[]), None);
        assert_eq!(tooltip(Some(""), Some(""), None, &[], &[]), None);
    }

    #[test]
    fn the_tooltip_drops_empty_parts_rather_than_printing_them() {
        assert_eq!(
            tooltip(Some("/a/b"), Some(""), Some("make \u{b7} 1.3s"), &[], &[]).as_deref(),
            Some("/a/b\nmake \u{b7} 1.3s"),
        );
    }

    #[test]
    fn a_command_line_joins_only_the_parts_the_block_carries() {
        assert_eq!(
            command_line("make check", Some("1.3s"), Some("exit 0")).as_deref(),
            Some("make check \u{b7} 1.3s \u{b7} exit 0"),
        );
        assert_eq!(command_line("  make  ", None, None).as_deref(), Some("make"));
        assert_eq!(command_line("   ", None, None), None);
        assert_eq!(command_line("", None, Some("exit 1")).as_deref(), Some("exit 1"));
    }

    /// Every switch this menu offers is answerable from the PANE. A row for a global setting would
    /// be a control with no writer behind it, which is what the notify and sleep rows became.
    #[test]
    fn the_menu_offers_only_per_pane_switches() {
        let entries = menu();
        let toggles: Vec<Switch> = entries
            .iter()
            .filter_map(|entry| {
                match entry {
                    Entry::Toggle(switch) => Some(*switch),
                    _ => None,
                }
            })
            .collect();
        assert_eq!(toggles, Switch::ALL.to_vec());
        assert_eq!(toggles.len(), 3, "the three badge overrides, and nothing global");
    }

    #[test]
    fn no_two_entries_share_a_code_and_every_title_is_distinct() {
        let mut codes: Vec<u8> = menu().iter().map(|entry| entry.code()).collect();
        codes.retain(|code| *code != Entry::Separator.code());
        codes.sort_unstable();
        let count = codes.len();
        codes.dedup();
        assert_eq!(codes.len(), count);

        let mut titles: Vec<&str> = Verb::ALL
            .iter()
            .map(|verb| verb.title())
            .chain(Switch::ALL.iter().map(|switch| switch.title()))
            .collect();
        for title in &titles {
            assert!(!title.is_empty());
        }
        titles.sort_unstable();
        let count = titles.len();
        titles.dedup();
        assert_eq!(titles.len(), count);
    }

    /// One source at a time, hard cut between them — and the ladder is the ladder even when every
    /// rung is lit.
    #[test]
    fn the_detail_ladder_takes_the_highest_lit_rung() {
        let lit = [Some("why?"), Some("3/5"), Some("thinking"), Some("finished")];
        let [question, scent, working, done] = lit;
        let error = Some("npm test");
        let command = Some("vim");
        assert_eq!(
            detail(question, scent, working, done, error, command, ""),
            Some((Detail::Question, "why?")),
        );
        assert_eq!(
            detail(None, scent, working, done, error, command, ""),
            Some((Detail::Scent, "3/5")),
        );
        assert_eq!(
            detail(None, None, working, done, error, command, ""),
            Some((Detail::WorkingLabel, "thinking")),
        );
        assert_eq!(
            detail(None, None, None, done, error, command, ""),
            Some((Detail::DoneLine, "finished")),
        );
        assert_eq!(
            detail(None, None, None, None, error, command, ""),
            Some((Detail::ErrorLine, "npm test")),
        );
        assert_eq!(
            detail(None, None, None, None, None, command, ""),
            Some((Detail::CommandLine, "vim")),
        );
        assert_eq!(detail(None, None, None, None, None, None, ""), None);
    }

    /// A rung that is present but BLANK is the caller's own answer, and is taken at its word: only
    /// absence darkens a rung.
    #[test]
    fn a_lit_but_blank_rung_still_outranks_everything_under_it() {
        assert_eq!(
            detail(Some(""), Some("3/5"), None, None, None, None, ""),
            Some((Detail::Question, "")),
        );
    }

    /// A shell that titles its pane after the command it runs must not silence the failure line
    /// sitting behind the running one: a dropped rung falls THROUGH rather than ending the ladder.
    #[test]
    fn a_title_echo_drops_its_rung_and_keeps_walking() {
        assert_eq!(
            detail(None, None, None, None, Some("npm test"), Some("vim"), "npm test"),
            Some((Detail::CommandLine, "vim")),
            "the error rung echoed the title; the running command is still news",
        );
        assert_eq!(
            detail(None, None, None, None, Some("npm test"), Some("npm"), "npm test"),
            None,
            "both command rungs echo it — absence is the resting state",
        );
    }

    /// Word-BOUNDED, which is the whole subtlety of the echo test.
    #[test]
    fn an_echo_is_the_whole_leading_word_and_never_half_of_one() {
        assert!(echoes_title("npm test", "NPM TEST"), "case-insensitive");
        assert!(echoes_title("npm", "npm test"), "the title extends the line");
        assert!(echoes_title("  npm test  ", "npm"), "the line extends the title");
        assert!(
            !echoes_title("apitool run", "api"),
            "`api` never swallows `apitool`"
        );
        assert!(!echoes_title("", "npm"), "an empty side echoes nothing");
        assert!(!echoes_title("npm", "   "), "a blank title echoes nothing");
    }

    /// The badge already carries the number, so this carries only the name — and only when there is
    /// a failure to attribute one to.
    #[test]
    fn the_error_line_is_the_culprits_name_and_never_its_number() {
        assert_eq!(error_line(true, Some("  npm test  ")), Some("npm test"));
        assert_eq!(
            error_line(false, Some("npm test")),
            None,
            "no code, no attribution"
        );
        assert_eq!(
            error_line(true, Some("   ")),
            None,
            "the badge's reading stands alone"
        );
        assert_eq!(error_line(true, None), None);
    }
}
