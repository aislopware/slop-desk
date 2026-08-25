//! Which pane session a command from the embedded editor lands in, and what bytes it becomes.
//!
//! The embedded workbench ships its own integrated terminal. That shell is outside everything this
//! app provides — no agent detection, no PTY fan-out to the other clients, no replay, no scrollback
//! journal — so the editor's "run this" affordances are pointed at a real `SlopDesk` pane instead.
//!
//! Pointing them somewhere means CHOOSING, and the editor cannot choose: focus is a client-side
//! fact, and a project may have several panes across several clients. So the host picks, under
//! rules whose failure mode is REFUSING rather than typing into the wrong shell:
//!
//!   1. the pane's cwd must live under the workbench's folder — a command meant for this project
//!      never lands in another one;
//!   2. no agent may be detected in it — typing a shell command at Claude Code's prompt sends it to
//!      the AGENT, which is the one outcome that would be actively destructive;
//!   3. its foreground process must be a SHELL — a pane sitting in vim, less, or a running build is
//!      not waiting for a command line, and keystrokes there mean something else entirely.
//!
//! What survives all three is a pane at a prompt in this project, which is what the user means by
//! "my terminal". Usually there is exactly one; the ranking below only settles the rest.
//!
//! ## The two rules it does NOT own
//! Containment is [`slopdesk_probe::path_confine`] and shell quoting is
//! [`slopdesk_ids::shell_quoting`] — both were written more than once before, in more than one
//! language, and both are the kind of rule whose copies disagree quietly. This module asks them.

use slopdesk_ids::shell_quoting;
use slopdesk_probe::path_confine::{self, Shape};

/// One candidate pane, flattened from the host's live session for the router's benefit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgePane {
    /// The pane's id, which is also the tie-breaker when two candidates rank identically.
    pub pane_id: String,
    /// The host-observed cwd (OSC-7 / prompt-edge probe), `None` until observed. A pane whose cwd
    /// is unknown is never chosen: containment is what keeps a command inside its own project.
    pub cwd: Option<String>,
    /// Whether an agent was detected in this pane.
    pub has_agent: bool,
    /// The foreground process basename, empty when it could not be read.
    pub foreground: String,
}

/// Why no pane could take the command. Each maps to one sentence the editor shows the user — the
/// point being that a refusal explains itself, since the alternative (silence) reads as a broken
/// feature.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// No pane of this project is open anywhere.
    NoPaneInProject,
    /// Panes exist, but every one is running something or hosting an agent.
    NoIdlePane,
}

impl Refusal {
    /// The sentence the editor shows when nothing could take the command.
    #[must_use]
    pub const fn message(self) -> &'static str {
        match self {
            Self::NoPaneInProject => "SlopDesk: no terminal pane is open in this project.",
            Self::NoIdlePane => {
                "SlopDesk: every terminal pane in this project is busy (a command is running, or an agent \
                 has it)."
            },
        }
    }
}

/// Foreground processes that mean "sitting at a prompt".
///
/// Login shells arrive with a leading dash (`-zsh`) from the process table, so both spellings are
/// listed. Anything else — an editor, a pager, a build, an agent — means the pane is busy.
pub const SHELL_NAMES: &[&str] = &[
    "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "-sh", "-bash", "-zsh",
    "-fish", "-ksh", "-tcsh", "-csh",
];

/// Whether `name` is a shell sitting at a prompt.
#[must_use]
pub fn is_shell(name: &str) -> bool {
    SHELL_NAMES.contains(&name)
}

/// The pane that should receive a command issued from the workbench rooted at `root`, or why none
/// can.
///
/// `directory` is where the command is ABOUT (the acting file's folder) — used only to RANK, never
/// to filter, so a project with one shell always works no matter which file is open.
///
/// # Errors
/// [`Refusal::NoPaneInProject`] when nothing is open under `root`; [`Refusal::NoIdlePane`] when
/// every pane that is has an agent in it or is running something.
pub fn choose<'a>(
    panes: &'a [BridgePane],
    root: &str,
    directory: Option<&str>,
) -> Result<&'a BridgePane, Refusal> {
    let in_project: Vec<&BridgePane> = panes
        .iter()
        .filter(|pane| {
            pane.cwd
                .as_deref()
                .is_some_and(|cwd| path_confine::confine(root, cwd, Shape::AbsoluteOnly).is_some())
        })
        .collect();
    if in_project.is_empty() {
        return Err(Refusal::NoPaneInProject);
    }
    let mut idle = in_project
        .into_iter()
        .filter(|pane| !pane.has_agent && is_shell(&pane.foreground));
    let mut best = idle.next().ok_or(Refusal::NoIdlePane)?;
    for candidate in idle {
        if prefers(candidate, best, directory) {
            best = candidate;
        }
    }
    Ok(best)
}

/// Ranking, in order: the pane standing CLOSEST to the acting file (most shared path components),
/// then the deeper cwd, then the lower pane id. The last clause is not taste — it makes the choice
/// reproducible for a given set of panes, which is what lets a test pin the behaviour at all.
fn prefers(candidate: &BridgePane, incumbent: &BridgePane, directory: Option<&str>) -> bool {
    let candidate_depth = shared_components(candidate.cwd.as_deref(), directory);
    let incumbent_depth = shared_components(incumbent.cwd.as_deref(), directory);
    if candidate_depth != incumbent_depth {
        return candidate_depth > incumbent_depth;
    }
    let candidate_cwd = candidate.cwd.as_deref().unwrap_or_default();
    let incumbent_cwd = incumbent.cwd.as_deref().unwrap_or_default();
    if candidate_cwd.len() != incumbent_cwd.len() {
        return candidate_cwd.len() > incumbent_cwd.len();
    }
    candidate.pane_id < incumbent.pane_id
}

/// How many leading path COMPONENTS two absolute paths share (`/a/b/c` vs `/a/b/d` → 2).
///
/// A component count, not a character count: `/a/bee` shares one component with `/a/b`, not four
/// characters' worth.
#[must_use]
pub fn shared_components(left: Option<&str>, right: Option<&str>) -> usize {
    let (Some(left), Some(right)) = (left, right) else {
        return 0;
    };
    left.split('/')
        .filter(|part| !part.is_empty())
        .zip(right.split('/').filter(|part| !part.is_empty()))
        .take_while(|(left, right)| left == right)
        .count()
}

/// The bytes a command line becomes on the PTY: the text, then a carriage RETURN — the byte a real
/// Return key sends (the tty's `ICRNL` turns it into the newline the shell reads).
///
/// Same convention as the agent-control `run` verb, deliberately: two ways to type into a pane
/// should not disagree about what Enter is.
#[must_use]
pub fn keystrokes(text: &str) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(text.len() + 1);
    bytes.extend_from_slice(text.as_bytes());
    bytes.push(b'\r');
    bytes
}

/// `cd <dir>` for the pane.
///
/// The quoting matters more than it looks: a project path with a space or a quote in it would
/// otherwise become several arguments, and this text is typed into a live shell.
#[must_use]
pub fn change_directory_command_line(directory: &str) -> String {
    format!("cd {}", shell_quoting::single_quoted(directory))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a refusal where the fixture put an idle shell IS the failure report — a default pane here \
                  would let the ranking break and still read as a choice"
    )]

    use super::{
        BridgePane, Refusal, change_directory_command_line, choose, is_shell, keystrokes, shared_components,
    };

    fn pane(id: &str, cwd: Option<&str>, has_agent: bool, foreground: &str) -> BridgePane {
        BridgePane {
            pane_id: id.to_owned(),
            cwd: cwd.map(ToOwned::to_owned),
            has_agent,
            foreground: foreground.to_owned(),
        }
    }

    #[test]
    fn a_pane_outside_the_project_is_never_chosen() {
        let panes = [pane("a", Some("/other/repo"), false, "zsh")];
        assert_eq!(choose(&panes, "/work/repo", None), Err(Refusal::NoPaneInProject));
    }

    #[test]
    fn a_pane_with_no_observed_cwd_is_never_chosen() {
        let panes = [pane("a", None, false, "zsh")];
        assert_eq!(choose(&panes, "/work/repo", None), Err(Refusal::NoPaneInProject));
    }

    /// The one outcome that would be actively destructive: typing a shell command at an agent's
    /// prompt sends it to the AGENT.
    #[test]
    fn a_pane_hosting_an_agent_is_refused_rather_than_typed_into() {
        let panes = [pane("a", Some("/work/repo"), true, "zsh")];
        assert_eq!(choose(&panes, "/work/repo", None), Err(Refusal::NoIdlePane));
    }

    #[test]
    fn a_pane_running_something_is_not_waiting_for_a_command_line() {
        let panes = [pane("a", Some("/work/repo"), false, "vim")];
        assert_eq!(choose(&panes, "/work/repo", None), Err(Refusal::NoIdlePane));
    }

    #[test]
    fn a_login_shell_arrives_with_a_leading_dash_and_still_counts() {
        assert!(is_shell("-zsh"));
        assert!(is_shell("zsh"));
        assert!(!is_shell("zshx"));
    }

    /// A root of `/` contains nothing: the confinement rule refuses a predicate that would say
    /// "inside" for every path on the machine.
    #[test]
    fn the_machine_root_is_not_a_project() {
        let panes = [pane("a", Some("/work/repo"), false, "zsh")];
        assert_eq!(choose(&panes, "/", None), Err(Refusal::NoPaneInProject));
    }

    #[test]
    fn the_pane_closest_to_the_acting_file_wins() {
        let panes = [
            pane("a", Some("/work/repo"), false, "zsh"),
            pane("b", Some("/work/repo/src/net"), false, "bash"),
        ];
        let chosen =
            choose(&panes, "/work/repo", Some("/work/repo/src/net")).expect("the nearer shell takes it");
        assert_eq!(chosen.pane_id, "b");
    }

    /// With nothing to be near, the DEEPER cwd wins, and the pane id settles a tie — the clause
    /// that makes the choice reproducible.
    #[test]
    fn depth_then_pane_id_settles_the_rest() {
        let panes = [
            pane("b", Some("/work/repo/src"), false, "zsh"),
            pane("a", Some("/work/repo/src"), false, "zsh"),
            pane("c", Some("/work/repo"), false, "zsh"),
        ];
        assert_eq!(
            choose(&panes, "/work/repo", None)
                .expect("three idle shells, one wins")
                .pane_id,
            "a",
        );
    }

    #[test]
    fn shared_components_counts_components_not_characters() {
        assert_eq!(shared_components(Some("/a/bee"), Some("/a/b")), 1);
        assert_eq!(shared_components(Some("/a/b/c"), Some("/a/b/d")), 2);
        assert_eq!(shared_components(None, Some("/a")), 0);
    }

    #[test]
    fn enter_is_a_carriage_return() {
        assert_eq!(keystrokes("ls"), b"ls\r".to_vec());
    }

    #[test]
    fn a_project_path_with_a_space_stays_one_word() {
        assert_eq!(
            change_directory_command_line("/Users/x/My Project"),
            "cd '/Users/x/My Project'"
        );
    }

    #[test]
    fn each_refusal_explains_itself() {
        assert!(Refusal::NoPaneInProject.message().contains("no terminal pane"));
        assert!(Refusal::NoIdlePane.message().contains("busy"));
    }
}
