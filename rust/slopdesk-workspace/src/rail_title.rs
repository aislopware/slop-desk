//! What a pane is CALLED on every surface that names one: the sidebar row, the tab strip, the pane
//! switcher, the window title.
//!
//! ## Why this is one module and not four call sites
//!
//! A pane has no single name. It has a folder, a foreground process, an OSC title the running
//! program set, a command it is running, a command it just ran, an agent's stated intent and a
//! rename the user typed — and which of those a surface shows is a PRECEDENCE, not a preference.
//! The same precedence, everywhere: a rail row and the window title disagreeing about what the pane
//! is called reads as two panes.
//!
//! So the rules live here once and the surfaces marshal into them. Two rungs are structural
//! ([`row_title`] — the identity a pane keeps while nothing is happening) and one is live
//! ([`live_row_title`] — what it is called right now), and the second is written in terms of the
//! first rather than repeating it.
//!
//! ## The spinner normalisation, which is a rendering rule wearing a title's clothes
//!
//! An agent's OSC title carries its activity glyph, and that glyph changes on every animation tick.
//! Passing it through would rewrite the row's text several times a second — the churn that makes a
//! list view replace its leaves and flash. [`normalized_program_title`] folds every frame of that
//! family onto the ONE static mark, so the mark shows and the text stops moving. It normalises
//! rather than strips: the fact that an agent is running is worth a glyph, just not a new one each
//! frame.

use slopdesk_tree::session::{PaneKind, PaneSpec};
use slopdesk_tree::tab_ordering;

/// The canonical agent mark a normalised program title leads with.
///
/// Pinned to TEXT presentation with a variation selector, because bare U+2733 renders as a colour
/// emoji on Apple platforms — which is a different glyph at a different size on a row sized for
/// text.
pub const AGENT_TITLE_MARK: &str = "✳\u{FE0E}";

/// How long a finished command must have RUN to title the idle pane it ran in, in host-measured
/// milliseconds.
///
/// Sub-second `ls`/`cd` chatter never takes the title, so a resting row does not churn with every
/// trivial command. The same second the busy dot waits before it appears: a command that earns the
/// dot earns the title.
pub const COMMAND_TITLE_MIN_DURATION_MS: u32 = 1000;

/// Bare interactive shells, which must never title a pane.
///
/// Titling a pane `zsh` says exactly as much as titling it `Terminal`, so these fall through to the
/// rest of the chain. They are still shown in the metadata SLOT — see [`slot_process_name`].
const LOGIN_SHELL_NAMES: [&str; 9] = ["zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "dash", "login"];

/// Agent CLIs, by basename.
///
/// A pane fronted by one of these is an agent session before any status verdict has landed, which
/// is what keeps a row's height from changing the moment the first verdict arrives.
const AGENT_PROCESS_NAMES: [&str; 7] = ["claude", "codex", "gemini", "opencode", "aider", "goose", "amp"];

/// The foreground process as the metadata SLOT shows it: basenamed, with a login shell's leading
/// `-` dropped.
///
/// A bare shell KEEPS its name here. In the slot the question is "what is this pane running", and
/// `zsh` answers it for an idle shell — where an empty slot would read as missing data rather than
/// as quiet.
#[must_use]
pub fn slot_process_name(label: Option<&str>) -> Option<&str> {
    let trimmed = label?.trim();
    // The `-zsh` argv0 convention, dropped once — a name that is only a dash has nothing left.
    let stripped = trimmed.strip_prefix('-').unwrap_or(trimmed);
    let name = stripped
        .rsplit('/')
        .find(|part| !part.is_empty())
        .unwrap_or(stripped);
    (!name.is_empty()).then_some(name)
}

/// The foreground process as a pane TITLE, or `None` to skip that rung.
///
/// [`slot_process_name`]'s cleanup, then the bare interactive shells suppressed. A real foreground
/// program (`vim`, `npm`, `ssh`) titles the pane; the shell it was launched from does not.
#[must_use]
pub fn process_display_name(label: Option<&str>) -> Option<&str> {
    slot_process_name(label).filter(|name| !LOGIN_SHELL_NAMES.contains(&name.to_lowercase().as_str()))
}

/// Whether a resting slot label names a COMMAND rather than the shell the pane is idling in.
///
/// The split decides which register the slot is set in, so it asks the question
/// [`process_display_name`] has been asking since long before the slot existed rather than
/// re-spelling the shell set. Idempotent on an already-cleaned label, which is the form a row
/// actually holds.
#[must_use]
pub fn slot_label_is_command(label: Option<&str>) -> bool {
    process_display_name(label).is_some()
}

/// Whether a pane is an AGENT session.
///
/// True when the pane carries any agent-status verdict — resting at its prompt is still a session —
/// or its foreground process is a known agent CLI, which covers the window before the first
/// verdict. The classification holds for the WHOLE session so a row's height changes at session
/// boundaries and never on a status edge.
#[must_use]
pub fn is_agent_session(has_agent_status: bool, process_label: Option<&str>) -> bool {
    has_agent_status
        || process_display_name(process_label)
            .is_some_and(|name| AGENT_PROCESS_NAMES.contains(&name.to_lowercase().as_str()))
}

/// `title` led with the agent mark, unless it already leads with one.
///
/// The dedupe tests the first SCALAR against U+2733 rather than the mark as a STRING: the variation
/// selector rides the mark's own grapheme cluster, so a string test against the normalised
/// `✳\u{FE0E}` answers false for a title carrying a bare `✳` — and that title would then wear the
/// mark twice on every surface that adds it.
#[must_use]
pub fn agent_marked_title(title: &str) -> String {
    if title.starts_with('✳') {
        title.to_owned()
    } else {
        format!("{AGENT_TITLE_MARK} {title}")
    }
}

/// A PROGRAM-SET title cleaned for a row: one leading agent-activity glyph folded onto the static
/// mark, everything else left alone.
///
/// A leading glyph counts only when a space or the end of the title follows it — `★ prod` is user
/// content and keeps its star. Whitespace is trimmed and an empty result is `None`, so a caller's
/// chain falls through rather than showing a blank row.
#[must_use]
pub fn normalized_program_title(title: Option<&str>) -> Option<String> {
    let text = title?.trim();
    let normalized = match text.chars().next() {
        Some(glyph) if is_activity_glyph(glyph) => {
            let rest = skip_variation_selectors(text.get(glyph.len_utf8()..).unwrap_or_default());
            if rest.is_empty() || rest.chars().next().is_some_and(char::is_whitespace) {
                let body = rest.trim();
                if body.is_empty() {
                    String::new()
                } else {
                    format!("{AGENT_TITLE_MARK} {body}")
                }
            } else {
                text.to_owned()
            }
        },
        _ => text.to_owned(),
    };
    (!normalized.is_empty()).then_some(normalized)
}

/// The parent-qualified title `parent/leaf`, or `None` when the row should be left alone.
///
/// Two panes in worktrees of the same repository are both called `myapp`, and the title alone
/// cannot tell them apart. Qualifying by the parent segment does, which is why the rewrite runs
/// only on a title that IS the folder name: an explicit rename is a name the user chose, and a path
/// with no parent above the leaf has nothing to qualify with.
#[must_use]
pub(crate) fn parent_qualified_title(cwd: Option<&str>, title: &str) -> Option<String> {
    let path = cwd?;
    if PaneSpec::cwd_display_name(Some(path)).as_deref() != Some(title) {
        return None;
    }
    let components: Vec<&str> = path.trim().split('/').filter(|part| !part.is_empty()).collect();
    let parent = components.get(components.len().checked_sub(2)?)?;
    Some(format!("{parent}/{title}"))
}

/// Everything the STRUCTURAL title reads, which is what a pane is called while nothing is happening
/// in it.
#[derive(Clone, Copy, Debug)]
pub struct RowTitle<'a> {
    /// What kind of pane it is. Only a terminal titles itself by where it is.
    pub kind: PaneKind,
    /// The title on the pane's spec, or `None` when there is no spec at all — which is a different
    /// fact from a spec whose title is blank.
    pub spec_title: Option<&'a str>,
    /// Whether that title was typed by the user rather than promoted from somewhere.
    pub user_renamed: bool,
    /// The pane's working directory.
    pub cwd: Option<&'a str>,
    /// The title the running program last asserted.
    pub live_title: Option<&'a str>,
    /// The host-reported foreground process.
    pub process_label: Option<&'a str>,
    /// The project section this pane is drawn under, supplied only where a header already names the
    /// project.
    pub project_key: Option<&'a str>,
}

/// The pane's STRUCTURAL title: the identity it keeps between events.
///
/// A terminal titles itself by its working directory's FOLDER NAME — the identity a coding tool
/// navigates by — with three escapes:
///
/// 1. an explicit rename always wins, gated on the flag rather than on a `title != live_title`
///    heuristic, which would latch a load-time-promoted title as a phantom rename the moment a
///    shell emitted a second OSC title;
/// 2. a pane sitting AT its project root titles by its foreground PROGRAM, because the folder name
///    would restate the section header verbatim — the header says where, line one says who, and an
///    idle shell there yields the empty string for the live chain to answer;
/// 3. a pane whose directory is not known yet titles by its foreground program before falling back
///    to the kind-generic name.
#[must_use]
pub fn row_title(inputs: RowTitle<'_>) -> String {
    let fallback = inputs.live_title.or(inputs.spec_title).unwrap_or_default();
    match title_rung(inputs.shape()) {
        TitleRung::Fallback => fallback.to_owned(),
        TitleRung::SpecTitle => inputs.spec_title.unwrap_or_default().to_owned(),
        TitleRung::AtRootProgram => {
            process_display_name(inputs.process_label)
                .unwrap_or_default()
                .to_owned()
        },
        TitleRung::CwdFolder => PaneSpec::cwd_display_name(inputs.cwd).unwrap_or_default(),
        TitleRung::ProgramElseFallback => {
            process_display_name(inputs.process_label).map_or_else(|| fallback.to_owned(), str::to_owned)
        },
    }
}

/// The fields that decide WHICH rung [`row_title`] takes, and nothing that decides what it says.
///
/// Split off [`RowTitle`] rather than reusing it so the one caller that wants the rung without the
/// string cannot pass a placeholder for a field the rule turns out to read. The live title and the
/// process label are absent here because the chain never consults either to CHOOSE — only to
/// answer — and that is a property worth stating in a type rather than in a comment that could stop
/// being true.
#[derive(Clone, Copy, Debug)]
pub struct TitleShape<'a> {
    /// What kind of pane it is. Only a terminal titles itself by where it is.
    pub kind: PaneKind,
    /// The title on the pane's spec, or `None` for a pane with no spec at all.
    pub spec_title: Option<&'a str>,
    /// Whether that title was typed by the user.
    pub user_renamed: bool,
    /// The pane's working directory.
    pub cwd: Option<&'a str>,
    /// The project section this pane is drawn under, where a header already names it.
    pub project_key: Option<&'a str>,
}

impl<'a> RowTitle<'a> {
    /// The half of these inputs that picks the rung.
    #[must_use]
    pub const fn shape(&self) -> TitleShape<'a> {
        TitleShape {
            kind: self.kind,
            spec_title: self.spec_title,
            user_renamed: self.user_renamed,
            cwd: self.cwd,
            project_key: self.project_key,
        }
    }
}

/// Which rung of [`row_title`]'s chain a pane's structural title comes off.
///
/// Named rather than inlined because ONE caller needs the rung without the string:
/// [`titles_by_process`] below. The two program rungs stay apart because their EMPTY answers
/// differ — an at-root idle shell yields `""` on purpose, so the live chain can speak for it, while
/// a pane with no folder name and no program falls back.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TitleRung {
    /// The live title, else the spec's — a pane with no spec, and every non-terminal.
    Fallback,
    /// A name the user typed.
    SpecTitle,
    /// The foreground program, because the folder name would restate the section header.
    AtRootProgram,
    /// The working directory's folder name.
    CwdFolder,
    /// The foreground program, because the directory is not known yet.
    ProgramElseFallback,
}

fn title_rung(shape: TitleShape<'_>) -> TitleRung {
    let Some(spec_title) = shape.spec_title else {
        return TitleRung::Fallback;
    };
    if shape.kind != PaneKind::Terminal {
        return TitleRung::Fallback;
    }
    if shape.user_renamed && !spec_title.is_empty() {
        return TitleRung::SpecTitle;
    }
    if let Some(key) = tab_ordering::normalized_project_key(shape.project_key)
        && tab_ordering::normalized_project_key(shape.cwd).as_deref() == Some(key.as_str())
    {
        return TitleRung::AtRootProgram;
    }
    if PaneSpec::cwd_display_name(shape.cwd).is_some() {
        TitleRung::CwdFolder
    } else {
        TitleRung::ProgramElseFallback
    }
}

/// Whether [`row_title`] would read this pane's foreground PROCESS to name it.
///
/// The sidebar's row-model cache fingerprints the process ONLY for a pane that would retitle by it,
/// so a background pane's process tick stays a cache HIT rather than a rebuild of the whole rail —
/// and on Apple's Observation, reading one key of a dictionary depends on the WHOLE dictionary, so
/// this guard decides whether the rail is subscribed to every pane's process at all.
///
/// It is the same question [`row_title`] answers on its way to a string, which is why it is one
/// function and not a predicate written alongside it: a guard that drifted from the chain would
/// either freeze a title the rail had stopped watching for, or subscribe the rail to a dictionary
/// that cannot change what it draws.
#[must_use]
pub fn titles_by_process(shape: TitleShape<'_>) -> bool {
    matches!(
        title_rung(shape),
        TitleRung::AtRootProgram | TitleRung::ProgramElseFallback
    )
}

/// The streamed host window behind a video pane, in the two fields a subtitle reads.
#[derive(Clone, Copy, Debug)]
pub struct SubtitleVideo<'a> {
    /// The owning application on the host.
    pub app_name: Option<&'a str>,
    /// The window's own title.
    pub title: Option<&'a str>,
}

/// Everything LINE TWO reads.
#[derive(Clone, Copy, Debug)]
pub struct Subtitle<'a> {
    /// What kind of pane it is.
    pub kind: PaneKind,
    /// The title on the pane's spec, or `None` when there is no spec at all — which is the same
    /// distinction [`RowTitle`] draws, and here it decides whether there is a second line to write.
    pub spec_title: Option<&'a str>,
    /// The streamed window, for a video pane.
    pub video: Option<SubtitleVideo<'a>>,
    /// The pane's working directory.
    pub cwd: Option<&'a str>,
    /// The title the running program last asserted.
    pub live_title: Option<&'a str>,
    /// The project section this pane is drawn under. `None` on a surface with no section headers,
    /// where the full path is the only place the location can be shown.
    pub project_key: Option<&'a str>,
}

/// A field as a second line may show it: trimmed, and absent when that leaves nothing — so a blank
/// field is "no subtitle" rather than an empty line holding a row open.
fn presentable(field: Option<&str>) -> Option<&str> {
    let trimmed = field?.trim();
    (!trimmed.is_empty()).then_some(trimmed)
}

/// What LINE TWO says, or `None` for a single-line row.
///
/// A terminal's second line is WHERE IT IS, said as briefly as the surface allows. Under a section
/// header that already names the project there are three cases and they are all about not repeating
/// the header: a pane AT the project root says nothing (the header said it), one that strayed into
/// the subtree says the relative path (`packages/api`), and one that is somewhere else entirely
/// says its full path — because a stale key across an un-re-pushed `cd` cannot form a relative
/// path, and hiding the location would be a lie rather than a saving.
///
/// A surface with no headers passes no key and gets the full path, which is the same rule with
/// nothing to subtract. A video pane says which host APP it is streaming — except when the window
/// has no title of its own, where the app name has already collapsed into line one and printing it
/// twice would fill a two-line row with one word.
#[must_use]
pub fn pane_subtitle(inputs: Subtitle<'_>) -> Option<String> {
    // No spec at all is no second line: there is nothing yet to describe.
    inputs.spec_title?;
    let generic = generic_subtitle(&inputs);
    if inputs.kind != PaneKind::Terminal {
        return generic;
    }
    let (Some(key), Some(cwd)) = (
        tab_ordering::normalized_project_key(inputs.project_key),
        tab_ordering::normalized_project_key(inputs.cwd),
    ) else {
        return generic;
    };
    if cwd == key {
        return None;
    }
    cwd.strip_prefix(&format!("{key}/"))
        .map(str::to_owned)
        .or(generic)
}

/// The KIND-GENERIC second line: where the shell is, else which host window this is.
fn generic_subtitle(inputs: &Subtitle<'_>) -> Option<String> {
    if let Some(cwd) = presentable(inputs.cwd) {
        return Some(cwd.to_owned());
    }
    if !inputs.kind.is_video() {
        return None;
    }
    let video = inputs.video?;
    let Some(app) = presentable(video.app_name) else {
        return presentable(video.title).map(str::to_owned);
    };
    // An untitled window's LABEL already collapsed to the app name, so line one is reading it too.
    let line_one = presentable(inputs.live_title).or_else(|| presentable(inputs.spec_title));
    if line_one == Some(app) && presentable(video.title) == Some(app) {
        return None;
    }
    Some(app.to_owned())
}

/// One command block, in the two fields a title reads.
#[derive(Clone, Copy, Debug)]
pub struct CommandTitleBlock<'a> {
    /// What was typed.
    pub command_text: &'a str,
    /// Host-measured wall clock, or `None` while the block is still open.
    pub duration_ms: Option<u32>,
}

/// The idle shell's LAST-COMMAND title: the most recent finished block that ran long enough to
/// matter, regardless of how it exited.
///
/// Exit status is the badge's story and the tooltip's; the title only says WHAT. A short or
/// still-open block is SKIPPED rather than title-clearing, so an `ls` after a long build leaves the
/// build's title standing instead of flashing the row back to the generic name.
#[must_use]
pub fn last_command_title<'a>(blocks: &'a [CommandTitleBlock<'a>]) -> Option<&'a str> {
    blocks.iter().rev().find_map(|block| {
        if block.duration_ms? < COMMAND_TITLE_MIN_DURATION_MS {
            return None;
        }
        let command = block.command_text.trim();
        (!command.is_empty()).then_some(command)
    })
}

/// Everything the LIVE title reads — what the pane is called right now.
#[derive(Clone, Copy, Debug)]
pub struct LiveRowTitle<'a> {
    /// What [`row_title`] answered for this pane.
    pub structural_title: &'a str,
    /// Whether the structural title is a rename the user typed.
    pub user_renamed: bool,
    /// Whether this pane is an agent session ([`is_agent_session`]).
    pub is_agent: bool,
    /// The agent's latched session intent — its first prompt, which is the task's identity.
    pub intent: Option<&'a str>,
    /// The command line running right now, if the caller's busy gate has opened.
    pub running_command: Option<&'a str>,
    /// The OSC title the running program asserted, already normalised.
    pub program_title: Option<&'a str>,
    /// The foreground-PROCESS title, so the structural rung can be recognised as one.
    pub process_title: Option<&'a str>,
    /// What kind of pane it is.
    pub kind: PaneKind,
    /// The pane's folder name, as a rung below the command history.
    pub cwd_title: Option<&'a str>,
    /// The kind-generic name, read only when nothing else answers.
    pub fallback: &'a str,
}

/// The title a surface actually SHOWS, in one precedence every surface shares.
///
/// - An explicit RENAME wins — unless it equals the kind-generic fallback, which carries no
///   identity and can only be a seed committed by accident. Yielding there heals those panes
///   without a migration.
/// - An AGENT titles by its session INTENT over the structural title every agent row shares:
///   `claude` four times says nothing about which task is which.
/// - A non-empty structural title reads next, EXCEPT that a bare foreground-PROGRAM title upgrades
///   in place to the full running command line — the same fact with its arguments back. A FOLDER
///   title is an identity and never yields.
/// - An EMPTY structural title — the at-root idle shell — reads the running command, then the last
///   executed command, then the folder name, and only a pane with no directory at all reaches the
///   fallback.
///
/// Wherever the running command would title the row, a program-asserted title outranks it: nvim's
/// `main.swift - NVIM` says more than `vi .`.
#[must_use]
pub fn live_row_title(inputs: LiveRowTitle<'_>, blocks: &[CommandTitleBlock<'_>]) -> String {
    if inputs.user_renamed
        && !inputs.structural_title.is_empty()
        && inputs.structural_title != inputs.fallback
    {
        return inputs.structural_title.to_owned();
    }
    if inputs.is_agent
        && let Some(intent) = inputs.intent.map(str::trim).filter(|text| !text.is_empty())
    {
        return intent.to_owned();
    }
    let running = inputs
        .running_command
        .map(str::trim)
        .filter(|text| !text.is_empty());
    if !inputs.structural_title.is_empty() {
        if inputs.kind == PaneKind::Terminal
            && inputs.process_title == Some(inputs.structural_title)
            && let Some(running) = running
        {
            return inputs.program_title.unwrap_or(running).to_owned();
        }
        return inputs.structural_title.to_owned();
    }
    if inputs.kind != PaneKind::Terminal {
        return inputs.fallback.to_owned();
    }
    if let Some(running) = running {
        return inputs.program_title.unwrap_or(running).to_owned();
    }
    last_command_title(blocks)
        .or(inputs.cwd_title)
        .unwrap_or(inputs.fallback)
        .to_owned()
}

/// Whether a character is a frame of an agent's activity spinner: any braille cell, or one of the
/// asterisk family claude cycles through.
const fn is_activity_glyph(glyph: char) -> bool {
    matches!(glyph, '\u{2800}'..='\u{28FF}' | '·' | '✢' | '✳' | '✶' | '✻' | '✽')
}

/// `text` with any leading variation selectors dropped.
///
/// They are part of the glyph's own cluster rather than of what follows it, so a mark pinned to
/// text presentation must not read as "a glyph with a non-space after it".
fn skip_variation_selectors(text: &str) -> &str {
    let mut rest = text;
    while let Some(next) = rest.chars().next() {
        if matches!(next, '\u{FE00}'..='\u{FE0F}' | '\u{E0100}'..='\u{E01EF}') {
            rest = rest.get(next.len_utf8()..).unwrap_or_default();
        } else {
            break;
        }
    }
    rest
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal_row(cwd: Option<&str>) -> RowTitle<'_> {
        RowTitle {
            kind: PaneKind::Terminal,
            spec_title: Some("Terminal"),
            user_renamed: false,
            cwd,
            live_title: None,
            process_label: None,
            project_key: None,
        }
    }

    fn live(structural: &str) -> LiveRowTitle<'_> {
        LiveRowTitle {
            structural_title: structural,
            user_renamed: false,
            is_agent: false,
            intent: None,
            running_command: None,
            program_title: None,
            process_title: None,
            kind: PaneKind::Terminal,
            cwd_title: None,
            fallback: "Terminal",
        }
    }

    #[test]
    fn a_slot_name_is_a_basename_without_the_login_dash() {
        assert_eq!(slot_process_name(Some("zsh")), Some("zsh"));
        assert_eq!(slot_process_name(Some("-zsh")), Some("zsh"));
        assert_eq!(slot_process_name(Some("/bin/bash")), Some("bash"));
        assert_eq!(slot_process_name(Some("/usr/local/bin/npm")), Some("npm"));
        assert_eq!(slot_process_name(Some("/opt/tool/")), Some("tool"));
        assert_eq!(slot_process_name(None), None);
        assert_eq!(slot_process_name(Some("  ")), None);
        assert_eq!(slot_process_name(Some("-")), None);
    }

    #[test]
    fn a_bare_shell_titles_nothing_but_still_fills_the_slot() {
        assert_eq!(process_display_name(Some("zsh")), None);
        assert_eq!(process_display_name(Some("-ZSH")), None);
        assert_eq!(process_display_name(Some("/usr/bin/vim")), Some("vim"));
        assert!(slot_label_is_command(Some("make")));
        assert!(!slot_label_is_command(Some("zsh")));
        assert!(!slot_label_is_command(None));
    }

    #[test]
    fn an_agent_session_is_the_verdict_or_the_process() {
        assert!(is_agent_session(true, None));
        assert!(is_agent_session(false, Some("/usr/local/bin/claude")));
        assert!(is_agent_session(false, Some("Codex")));
        assert!(!is_agent_session(false, Some("zsh")));
        assert!(!is_agent_session(false, Some("vim")));
    }

    #[test]
    fn the_mark_is_added_once_however_the_title_spells_it() {
        assert_eq!(agent_marked_title("fix the flash"), "✳\u{FE0E} fix the flash");
        assert_eq!(agent_marked_title("✳\u{FE0E} fix"), "✳\u{FE0E} fix");
        assert_eq!(agent_marked_title("✳ fix"), "✳ fix");
    }

    #[test]
    fn every_spinner_frame_normalises_to_the_one_mark() {
        assert_eq!(
            normalized_program_title(Some("✻ Claude Code")).as_deref(),
            Some("✳\u{FE0E} Claude Code"),
        );
        assert_eq!(
            normalized_program_title(Some("⠋ Claude Code")).as_deref(),
            Some("✳\u{FE0E} Claude Code"),
        );
        assert_eq!(
            normalized_program_title(Some("✳\u{FE0E} Claude Code")).as_deref(),
            Some("✳\u{FE0E} Claude Code"),
        );
        assert_eq!(
            normalized_program_title(Some("★ prod")).as_deref(),
            Some("★ prod")
        );
        assert_eq!(normalized_program_title(Some("✳")).as_deref(), None);
        assert_eq!(normalized_program_title(Some("  ")).as_deref(), None);
        assert_eq!(normalized_program_title(None), None);
    }

    #[test]
    fn a_folder_title_qualifies_by_its_parent_and_a_rename_does_not() {
        assert_eq!(
            parent_qualified_title(Some("/a/b/repo"), "repo").as_deref(),
            Some("b/repo"),
        );
        assert_eq!(
            parent_qualified_title(Some("/a/b/repo/"), "repo").as_deref(),
            Some("b/repo"),
        );
        assert_eq!(parent_qualified_title(Some("/a/b/repo"), "renamed"), None);
        assert_eq!(parent_qualified_title(Some("/repo"), "repo"), None);
        assert_eq!(parent_qualified_title(None, "repo"), None);
    }

    #[test]
    fn a_terminal_titles_by_its_folder() {
        assert_eq!(row_title(terminal_row(Some("/Volumes/x/slopdesk"))), "slopdesk");
        assert_eq!(row_title(terminal_row(None)), "Terminal");
    }

    #[test]
    fn a_rename_wins_and_a_video_pane_keeps_its_chain() {
        let mut inputs = terminal_row(Some("/a/repo"));
        inputs.spec_title = Some("deploy");
        inputs.user_renamed = true;
        assert_eq!(row_title(inputs), "deploy");

        inputs.kind = PaneKind::Desktop;
        inputs.live_title = Some("Xcode");
        assert_eq!(row_title(inputs), "Xcode");
    }

    #[test]
    fn at_the_project_root_the_program_titles_the_pane() {
        let mut inputs = terminal_row(Some("/a/repo"));
        inputs.project_key = Some("/a/repo/");
        inputs.process_label = Some("/usr/bin/vim");
        assert_eq!(row_title(inputs), "vim");

        inputs.process_label = Some("-zsh");
        assert_eq!(row_title(inputs), "", "an idle shell yields to the live chain");

        inputs.cwd = Some("/a/repo/sub");
        assert_eq!(row_title(inputs), "sub", "away from the root the folder answers");
    }

    #[test]
    fn a_pane_with_no_directory_titles_by_its_program() {
        let mut inputs = terminal_row(None);
        inputs.process_label = Some("/usr/bin/ssh");
        assert_eq!(row_title(inputs), "ssh");
        inputs.process_label = Some("zsh");
        assert_eq!(row_title(inputs), "Terminal");
    }

    #[test]
    fn only_a_command_that_ran_long_enough_titles_the_idle_pane() {
        let build = CommandTitleBlock {
            command_text: "make check",
            duration_ms: Some(9_000),
        };
        let quick = CommandTitleBlock {
            command_text: "ls",
            duration_ms: Some(4),
        };
        let open = CommandTitleBlock {
            command_text: "npm test",
            duration_ms: None,
        };
        let blank = CommandTitleBlock {
            command_text: "   ",
            duration_ms: Some(9_000),
        };
        assert_eq!(last_command_title(&[build, quick]), Some("make check"));
        assert_eq!(last_command_title(&[build, open]), Some("make check"));
        assert_eq!(last_command_title(&[build, blank]), Some("make check"));
        assert_eq!(last_command_title(&[quick]), None);
        assert_eq!(last_command_title(&[]), None);
    }

    #[test]
    fn the_live_chain_reads_intent_then_structure_then_history() {
        let mut inputs = live("slopdesk");
        assert_eq!(live_row_title(inputs, &[]), "slopdesk");

        inputs.is_agent = true;
        inputs.intent = Some("  fix the rail flash  ");
        assert_eq!(live_row_title(inputs, &[]), "fix the rail flash");

        inputs.is_agent = false;
        inputs.intent = None;
        inputs.user_renamed = true;
        inputs.structural_title = "Terminal";
        assert_eq!(
            live_row_title(inputs, &[]),
            "Terminal",
            "a rename that equals the fallback carries no identity, so the chain runs on",
        );
    }

    #[test]
    fn a_program_title_outranks_the_command_it_was_launched_with() {
        let mut inputs = live("");
        inputs.running_command = Some("vi .");
        assert_eq!(live_row_title(inputs, &[]), "vi .");
        inputs.program_title = Some("main.swift - NVIM");
        assert_eq!(live_row_title(inputs, &[]), "main.swift - NVIM");
    }

    #[test]
    fn a_process_structural_title_upgrades_to_the_command_line_and_a_folder_does_not() {
        let mut inputs = live("sleep");
        inputs.process_title = Some("sleep");
        inputs.running_command = Some("sleep 30 && make");
        assert_eq!(live_row_title(inputs, &[]), "sleep 30 && make");

        inputs.structural_title = "slopdesk";
        assert_eq!(live_row_title(inputs, &[]), "slopdesk");
    }

    #[test]
    fn an_empty_structural_title_falls_through_history_then_folder() {
        let build = CommandTitleBlock {
            command_text: "make check",
            duration_ms: Some(9_000),
        };
        let mut inputs = live("");
        inputs.cwd_title = Some("slopdesk");
        assert_eq!(live_row_title(inputs, &[build]), "make check");
        assert_eq!(live_row_title(inputs, &[]), "slopdesk");
        inputs.cwd_title = None;
        assert_eq!(live_row_title(inputs, &[]), "Terminal");
    }

    // MARK: Line two

    fn subtitle(cwd: Option<&str>) -> Subtitle<'_> {
        Subtitle {
            kind: PaneKind::Terminal,
            spec_title: Some("Terminal"),
            video: None,
            cwd,
            live_title: None,
            project_key: None,
        }
    }

    #[test]
    fn a_pane_with_no_spec_has_no_second_line() {
        let mut inputs = subtitle(Some("/w/app"));
        inputs.spec_title = None;
        assert_eq!(pane_subtitle(inputs), None);
    }

    #[test]
    fn a_terminal_under_a_header_says_only_what_the_header_does_not() {
        let mut inputs = subtitle(Some("/w/app"));
        inputs.project_key = Some("/w/app");
        assert_eq!(pane_subtitle(inputs), None, "at the root, the header said it");

        inputs.cwd = Some("/w/app/packages/api");
        assert_eq!(pane_subtitle(inputs), Some("packages/api".to_owned()));

        inputs.cwd = Some("/elsewhere/entirely");
        assert_eq!(
            pane_subtitle(inputs),
            Some("/elsewhere/entirely".to_owned()),
            "no relative path can be formed, and hiding the location would lie"
        );
    }

    #[test]
    fn a_trailing_slash_does_not_make_a_root_pane_look_astray() {
        let mut inputs = subtitle(Some("/w/app/"));
        inputs.project_key = Some("/w/app");
        assert_eq!(pane_subtitle(inputs), None);
    }

    #[test]
    fn a_surface_with_no_headers_shows_the_whole_path() {
        assert_eq!(
            pane_subtitle(subtitle(Some("/w/app/packages/api"))),
            Some("/w/app/packages/api".to_owned()),
            "the same rule with nothing to subtract"
        );
        assert_eq!(
            pane_subtitle(subtitle(Some("   "))),
            None,
            "a blank cwd is no line"
        );
        assert_eq!(pane_subtitle(subtitle(None)), None);
    }

    #[test]
    fn a_video_pane_names_the_host_app_unless_line_one_already_did() {
        let mut inputs = subtitle(None);
        inputs.kind = PaneKind::Desktop;
        inputs.video = Some(SubtitleVideo {
            app_name: Some("Xcode"),
            title: Some("SlopDesk.xcodeproj"),
        });
        inputs.live_title = Some("SlopDesk.xcodeproj");
        assert_eq!(pane_subtitle(inputs), Some("Xcode".to_owned()));

        // An untitled window's label collapses to the app name, so line one is reading it too.
        inputs.video = Some(SubtitleVideo {
            app_name: Some("Xcode"),
            title: Some("Xcode"),
        });
        inputs.live_title = Some("Xcode");
        assert_eq!(pane_subtitle(inputs), None);

        inputs.video = Some(SubtitleVideo {
            app_name: None,
            title: Some("Xcode"),
        });
        assert_eq!(
            pane_subtitle(inputs),
            Some("Xcode".to_owned()),
            "with no app to name, the window's own title stands"
        );
    }

    #[test]
    fn a_video_panes_cwd_still_wins_and_its_project_key_never_applies() {
        let mut inputs = subtitle(Some("/w/app/sub"));
        inputs.kind = PaneKind::Desktop;
        inputs.project_key = Some("/w/app");
        assert_eq!(
            pane_subtitle(inputs),
            Some("/w/app/sub".to_owned()),
            "only a terminal's line two is relative to its section"
        );
    }
}
