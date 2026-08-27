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
//! ## The other half: the LINE the editor speaks
//! Choosing a pane is only useful once something has been believed, and the believing is the other
//! half of this module: [`route`] picks the workbench WINDOW a file belongs to, [`inbound`] is the
//! whole verb table the extension may speak, and [`open_command`] / [`result_line`] are the two
//! lines the host writes back. Every one of them is validate-then-DROP: a line that is not exactly
//! what the grammar says gets no answer at all, because the alternative is typing an
//! attacker-shaped string at a live shell prompt.
//!
//! The socket, the accept loop, the per-connection read threads and the `(st_dev, st_ino)` rebind
//! guard stay in `CodeBridgeServer.swift`: those are descriptors and threads,
//! and none of them decides anything.
//!
//! ## The two rules it does NOT own
//! Containment is [`slopdesk_probe::path_confine`] and shell quoting is
//! [`slopdesk_ids::shell_quoting`] — both were written more than once before, in more than one
//! language, and both are the kind of rule whose copies disagree quietly. This module asks them.
//! The third is the `:line:col` suffix, which is `slopdesk_terminal::link_action`'s:
//! [`open_command`] takes the path and the suffix ALREADY split, so the one place that knows what a
//! detected link's tail looks like stays the one place, and this crate keeps its dependency list.
//!
//! ## One output byte the port deliberately changes
//! These lines used to be built by Foundation's `JSONSerialization`, which escapes `/` as `\/` and
//! emits keys in an arbitrary order. `serde_json` writes `/` bare and sorts keys, so an `open` line
//! for `/work/a.swift` is a different byte string than it was. Nothing pins those bytes: the sole
//! consumer is `JSON.parse` in `rust/slopdesk-codeseed/resources/bridge/extension.js`, which reads
//! both spellings identically, and no golden vector covers this socket — `golden_vectors.json` pins
//! the mux wire, which is manual binary and nowhere near here. Recorded rather than reconciled, the
//! same way `slopdesk-ctl`'s protocol module records its own `\/`.

use serde_json::{Map, Value};
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

// ---------------------------------------------------------------------------------------------- //
// The line protocol
// ---------------------------------------------------------------------------------------------- //

/// Max bytes of one line the extension may send.
///
/// The largest inbound message is a `run` carrying an editor selection, capped far below this by
/// [`MAX_RUN_TEXT_BYTES`] — so this bound is not about the selection, it is about a peer that never
/// sends a newline at all. The read loop that enforces it is Swift's, because it is the one holding
/// the buffer; the NUMBER is here so there is one of it.
pub const MAX_LINE_BYTES: usize = 64 * 1024;

/// Max bytes of command text a single `run` may carry.
///
/// An editor selection is the source, and a selection large enough to exceed this was not meant to
/// be typed at a shell prompt — a paste that size is a mistake being made very fast.
pub const MAX_RUN_TEXT_BYTES: usize = 8 * 1024;

/// Max bytes of the correlation id a `run` or `cd` carries.
///
/// The id is echoed back verbatim in [`result_line`], so it is attacker-chosen text that the host
/// re-emits: bounding it is what keeps a reply line proportional to the request that asked for it.
pub const MAX_RUN_ID_BYTES: usize = 64;

/// One connected workbench window, flattened for the router's benefit.
///
/// `fd` is the connection's descriptor, which is both the ANSWER [`route`] gives and the tie-break
/// it settles on — see there for why a descriptor is a legitimate ordering key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeWindow {
    /// The connection's descriptor.
    pub fd: i32,
    /// The workspace folder this window announced in its `hello`, empty until it has.
    pub root: String,
}

/// The window that should own `target`: the connection whose workspace folder CONTAINS it, deepest
/// folder first. `None` when no open folder contains the path.
///
/// **Deepest wins** because nested checkouts open as separate windows, and a file inside the inner
/// repo belongs in the inner repo's window — the outer one would open the same bytes under a
/// project the user is not looking at.
///
/// **A tie breaks on the LOWER descriptor**, and that half is a rule too rather than an arbitrary
/// pick. Two windows on the same folder is the ordinary multi-client case, and without a total
/// order the winner would be whatever the caller's dictionary iterated first — so the same file,
/// opened twice from the same set of windows, would land in two different places. A user who has
/// learned where their opens go would be right half the time, which is worse than either answer
/// being wrong consistently. The cost of getting the tie-break backwards is not a security fault;
/// it is that the feature stops being predictable, which for an accelerator is the whole of its
/// value.
///
/// Depth is measured in BYTES of the root rather than in path components, and the two cannot
/// disagree here: every candidate contains `target`, so each root is a component-prefix of the same
/// path, and one prefix is longer than another exactly when it names more components. Equal-length
/// distinct spellings differ only in separators, which [`slopdesk_probe::path_confine`] has already
/// declared equivalent.
///
/// `None` for an empty or relative `target` falls out of containment: a bridge routes ABSOLUTE host
/// paths, and joining a relative one to a workspace folder would invent a file nobody named.
#[must_use]
pub fn route(target: &str, windows: &[BridgeWindow]) -> Option<i32> {
    let mut best: Option<&BridgeWindow> = None;
    for window in windows
        .iter()
        .filter(|window| path_confine::confine(&window.root, target, Shape::AbsoluteOnly).is_some())
    {
        let takes = best.is_none_or(|incumbent| {
            window.root.len() > incumbent.root.len()
                || (window.root.len() == incumbent.root.len() && window.fd < incumbent.fd)
        });
        if takes {
            best = Some(window);
        }
    }
    best.map(|window| window.fd)
}

/// The editor asking for a command line to be typed into one of this project's terminal panes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunRequest {
    /// The extension's correlation token, echoed back in the result line.
    pub id: String,
    /// The workbench window's workspace folder — the project the command belongs to.
    pub root: String,
    /// The acting file's directory, when the request came from one. Ranking only, see [`choose`].
    pub directory: Option<String>,
    /// The command line itself, exactly as it will be typed.
    pub text: String,
}

/// A line the extension sent, once it has been believed.
///
/// The `run` payload is BOXED so the two variants are the same size. `variant_size_differences` is
/// denied crate-wide and a four-string variant standing beside a one-string one is precisely what
/// that lint names; the indirection costs one allocation on a path that is already parsing JSON.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Inbound {
    /// The opening announcement — the window's workspace folder, which is what makes it routable.
    Hello(String),
    /// A command line to type into one of this project's terminal panes.
    Run(Box<RunRequest>),
}

/// The one verb table the bridge socket has. `None` for everything else.
///
/// Validate-then-drop, and the stakes are higher here than anywhere else in this module: what
/// survives gets TYPED at a live shell prompt of a process the user owns. So every field is checked
/// for the shape the host will actually use it as — an absolute root, because a relative one names
/// no window the host can resolve; a non-empty bounded id, because it comes back out in the reply;
/// text that [`is_typeable`] accepts. A line that fails any of them is answered with silence, which
/// leaves the connection exactly as it was.
///
/// A `cd` is not a second verb so much as a `run` whose text the HOST writes: the editor names a
/// directory and [`change_directory_command_line`] quotes it, so the shell-quoting rule has one
/// tested home rather than a second copy written in JavaScript.
#[must_use]
pub fn inbound(line: &[u8]) -> Option<Inbound> {
    let parsed = serde_json::from_slice::<Value>(line).ok()?;
    let object = parsed.as_object()?;
    match text_field(object, "t")? {
        "hello" => Some(Inbound::Hello(absolute_field(object, "root")?.to_owned())),
        "run" => run_inbound(object, None),
        "cd" => {
            let path = absolute_field(object, "path")?;
            run_inbound(object, Some(change_directory_command_line(path)))
        },
        _ => None,
    }
}

/// One field of the object, when it is present AND a string. A number where a path belongs is a
/// different message, not a coercible one.
fn text_field<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key)?.as_str()
}

/// The same, when it also names an absolute path. The `/` test is deliberately the cheap one rather
/// than full confinement: the host has no root to confine against yet at this point, and every
/// later use of the value goes through [`path_confine`] anyway.
fn absolute_field<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    text_field(object, key).filter(|value| value.starts_with('/'))
}

/// The shape `run` and `cd` share: correlation id, project root, optional acting directory, and the
/// text — carried by a `run`, built by the host for a `cd`.
///
/// A relative `cwd` is DROPPED rather than refusing the whole line: it only ranks, so losing it
/// costs nothing, while believing it would rank on a path the host cannot resolve.
fn run_inbound(object: &Map<String, Value>, built: Option<String>) -> Option<Inbound> {
    let id = text_field(object, "id")?;
    if id.is_empty() || id.len() > MAX_RUN_ID_BYTES {
        return None;
    }
    let root = absolute_field(object, "root")?;
    let text = match built {
        Some(built) => built,
        None => text_field(object, "text")?.to_owned(),
    };
    if !is_typeable(&text) {
        return None;
    }
    Some(Inbound::Run(Box::new(RunRequest {
        id: id.to_owned(),
        root: root.to_owned(),
        directory: absolute_field(object, "cwd").map(ToOwned::to_owned),
        text,
    })))
}

/// Whether `text` may be typed at a live shell prompt.
///
/// Non-empty, within [`MAX_RUN_TEXT_BYTES`], and free of C0 controls other than tab and newline. An
/// embedded ESC in a selection is not text to a shell's line editor, it is a KEYBINDING — `vi` mode
/// makes that vivid — and a NUL truncates the line at the write, so everything after it is typed as
/// a command of its own. Newline and tab survive because a multi-line selection is exactly what
/// "run selection" means.
///
/// Scanned as BYTES, which is the same answer the scalar scan it replaces gave: every byte of a
/// multi-byte UTF-8 sequence is `>= 0x80`, so no continuation byte can be mistaken for a control.
#[must_use]
pub fn is_typeable(text: &str) -> bool {
    !text.is_empty()
        && text.len() <= MAX_RUN_TEXT_BYTES
        && !text
            .bytes()
            .any(|byte| (byte < 0x20 && byte != b'\n' && byte != b'\t') || byte == 0x7F)
}

/// The `open` line for a target already split into its path and its `:line[:col]` suffix.
///
/// The suffix is carried as NUMBERS rather than left on the path, because the extension turns them
/// into a selection and a path with `:42:7` still attached simply does not exist on disk. Numbers
/// the suffix does not actually hold are dropped rather than defaulted: no `line` key at all means
/// "the editor keeps its own position", which is a different instruction from "go to line 0".
///
/// Empty when the value will not serialise — the caller writes nothing rather than a half line.
/// That arm is unreachable in practice (every leaf here is a Rust `String`, a `bool` or an `i64`),
/// and it exists so the module does not have to prove that to the lint table.
#[must_use]
pub fn open_command(path: &str, suffix: &str) -> String {
    let mut message = Map::new();
    message.insert("t".to_owned(), Value::from("open"));
    message.insert("path".to_owned(), Value::from(path));
    let mut numbers = suffix.split(':').filter_map(|part| part.parse::<i64>().ok());
    if let Some(line) = numbers.next() {
        message.insert("line".to_owned(), Value::from(line));
        if let Some(column) = numbers.next() {
            message.insert("col".to_owned(), Value::from(column));
        }
    }
    line_of(&Value::Object(message))
}

/// The result line for a finished `run`.
///
/// `pane_title` names where the command landed so the editor can say so; `message` is the sentence
/// shown when it did not. Both are omitted rather than emitted empty, because the extension tells
/// "absent" and "empty" apart and an empty `pane` would have it announce a pane with no name.
#[must_use]
pub fn result_line(id: &str, ok: bool, pane_title: Option<&str>, message: Option<&str>) -> String {
    let mut fields = Map::new();
    fields.insert("t".to_owned(), Value::from("result"));
    fields.insert("id".to_owned(), Value::from(id));
    fields.insert("ok".to_owned(), Value::Bool(ok));
    if let Some(pane) = pane_title {
        fields.insert("pane".to_owned(), Value::from(pane));
    }
    if let Some(text) = message {
        fields.insert("message".to_owned(), Value::from(text));
    }
    line_of(&Value::Object(fields))
}

/// One NDJSON line: the compact encoding, then the newline that terminates it.
///
/// The newline is part of the answer rather than the caller's to add, so the two writers above
/// cannot disagree about whose job it was — a missing one concatenates two commands into a line the
/// extension drops whole.
fn line_of(value: &Value) -> String {
    serde_json::to_string(value).map_or_else(
        |_| String::new(),
        |mut line| {
            line.push('\n');
            line
        },
    )
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a refusal where the fixture put an idle shell IS the failure report — a default pane here \
                  would let the ranking break and still read as a choice"
    )]

    use super::{
        BridgePane, BridgeWindow, Inbound, MAX_RUN_ID_BYTES, MAX_RUN_TEXT_BYTES, Refusal, RunRequest,
        change_directory_command_line, choose, inbound, is_shell, is_typeable, keystrokes, open_command,
        result_line, route, shared_components,
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

    // ------------------------------------------------------------------------------------------ //
    // The line protocol
    // ------------------------------------------------------------------------------------------ //

    fn window(fd: i32, root: &str) -> BridgeWindow {
        BridgeWindow {
            fd,
            root: root.to_owned(),
        }
    }

    fn run(inbound: Option<Inbound>) -> Option<RunRequest> {
        match inbound {
            Some(Inbound::Run(request)) => Some(*request),
            _ => None,
        }
    }

    #[test]
    fn route_finds_the_window_that_owns_the_file() {
        let windows = [window(4, "/work/alpha"), window(5, "/work/beta")];
        assert_eq!(route("/work/beta/x.swift", &windows), Some(5));
    }

    /// No connected window owns the path ⇒ nothing, NOT a nearest guess: the caller falls back to
    /// the CLI, and dropping a file into an unrelated project's window is worse than a slow open.
    #[test]
    fn an_unowned_path_names_no_window() {
        let windows = [window(4, "/work/alpha")];
        assert_eq!(route("/elsewhere/x.swift", &windows), None);
        assert_eq!(route("/work/alpha/x.swift", &[]), None);
    }

    /// A relative or empty target names no window either — the bridge routes ABSOLUTE host paths,
    /// and `""` is the shape the suffix splitter produces for a target that is all suffix
    /// (`":12"`).
    #[test]
    fn a_relative_or_empty_target_names_no_window() {
        let windows = [window(4, "/a/b")];
        assert_eq!(route("main.swift", &windows), None);
        assert_eq!(route("", &windows), None);
    }

    /// Nested checkouts open as separate windows; the DEEPEST containing folder wins, so a file
    /// inside the inner repo lands in the inner repo's window.
    #[test]
    fn the_deepest_containing_root_wins() {
        let windows = [
            window(4, "/work"),
            window(5, "/work/alpha/vendor"),
            window(6, "/work/alpha"),
        ];
        assert_eq!(route("/work/alpha/vendor/x.swift", &windows), Some(5));
        assert_eq!(route("/work/alpha/x.swift", &windows), Some(6));
        assert_eq!(route("/work/x.swift", &windows), Some(4));
    }

    /// Two windows on the SAME folder — the ordinary multi-client case — route deterministically,
    /// in either presentation order, so an open never lands in a coin-flip window.
    #[test]
    fn a_tie_breaks_on_the_lower_descriptor_whichever_order_they_arrive_in() {
        let windows = [window(9, "/work"), window(3, "/work")];
        assert_eq!(route("/work/x.swift", &windows), Some(3));
        let reversed = [window(3, "/work"), window(9, "/work")];
        assert_eq!(route("/work/x.swift", &reversed), Some(3));
    }

    #[test]
    fn the_open_line_carries_a_bare_path() {
        assert_eq!(
            open_command("/work/a.swift", ""),
            "{\"path\":\"/work/a.swift\",\"t\":\"open\"}\n",
            "no suffix ⇒ no caret — the editor keeps its own position"
        );
    }

    /// The `:line[:col]` suffix the hint-mode detector produces is carried as NUMBERS — the
    /// extension turns them into a selection, and a path with the suffix still on it does not
    /// exist.
    #[test]
    fn the_open_line_splits_the_line_col_suffix() {
        assert_eq!(
            open_command("/work/a.swift", ":42"),
            "{\"line\":42,\"path\":\"/work/a.swift\",\"t\":\"open\"}\n"
        );
        assert_eq!(
            open_command("/work/a.swift", ":42:7"),
            "{\"col\":7,\"line\":42,\"path\":\"/work/a.swift\",\"t\":\"open\"}\n"
        );
    }

    /// Host paths carry quotes and backslashes; the command goes through a real JSON writer, so
    /// they survive instead of handing the extension a line it silently drops.
    #[test]
    fn a_hostile_path_is_escaped_rather_than_dropped() {
        let line = open_command(r#"/work/we"ird\path/a.swift"#, "");
        assert_eq!(
            line,
            "{\"path\":\"/work/we\\\"ird\\\\path/a.swift\",\"t\":\"open\"}\n"
        );
    }

    /// Every line the host writes is ONE line — the extension reads NDJSON, and a command without
    /// its terminator concatenates into the next one and both are dropped.
    #[test]
    fn every_written_line_ends_in_exactly_one_newline() {
        for line in [
            open_command("/work/a.swift", ":1:2"),
            result_line("7", true, Some("zsh"), None),
        ] {
            assert_eq!(line.matches('\n').count(), 1);
            assert!(line.ends_with('\n'));
        }
    }

    #[test]
    fn a_hello_announces_the_windows_folder() {
        assert_eq!(
            inbound(br#"{"t":"hello","v":1,"root":"/work/alpha"}"#),
            Some(Inbound::Hello("/work/alpha".to_owned()))
        );
    }

    /// Validate-then-drop: everything that is not a well-formed hello with an ABSOLUTE root leaves
    /// the connection unrouted rather than routable to a path the host cannot resolve.
    #[test]
    fn everything_else_leaves_the_connection_unrouted() {
        let cases: [&[u8]; 8] = [
            br#"{"t":"hello","root":"relative"}"#,
            br#"{"t":"hello"}"#,
            br#"{"t":"hello","root":42}"#,
            br#"{"t":"unknown","root":"/work"}"#,
            br#"{"root":"/work"}"#,
            br#"["t","hello"]"#,
            b"not json at all",
            b"",
        ];
        for line in cases {
            assert_eq!(inbound(line), None, "rejected: {}", String::from_utf8_lossy(line));
        }
    }

    #[test]
    fn a_run_carries_the_command_and_its_project() {
        let line = br#"{"t":"run","v":1,"id":"7","root":"/work/a","cwd":"/work/a/src","text":"npm test"}"#;
        assert_eq!(
            run(inbound(line)),
            Some(RunRequest {
                id: "7".to_owned(),
                root: "/work/a".to_owned(),
                directory: Some("/work/a/src".to_owned()),
                text: "npm test".to_owned(),
            })
        );
    }

    /// A `cd` names a DIRECTORY and the host writes the command line, so the shell quoting has one
    /// tested home instead of a second copy in JavaScript.
    #[test]
    fn a_change_directory_line_is_built_host_side_and_quoted() {
        let line = br#"{"t":"cd","v":1,"id":"8","root":"/work/a","path":"/work/a/it's here"}"#;
        assert_eq!(
            run(inbound(line)),
            Some(RunRequest {
                id: "8".to_owned(),
                root: "/work/a".to_owned(),
                directory: None,
                text: r"cd '/work/a/it'\''s here'".to_owned(),
            })
        );
    }

    /// A relative `cwd` is dropped rather than passed through — it only RANKS, so losing it costs
    /// nothing, while believing it could rank on nonsense.
    #[test]
    fn a_relative_working_directory_is_dropped_not_believed() {
        let line = br#"{"t":"run","id":"9","root":"/work","cwd":"src","text":"ls"}"#;
        assert_eq!(
            run(inbound(line)),
            Some(RunRequest {
                id: "9".to_owned(),
                root: "/work".to_owned(),
                directory: None,
                text: "ls".to_owned(),
            })
        );
    }

    /// Validate-then-drop, and the stakes are higher here than anywhere else in this module: what
    /// survives gets TYPED at a live shell prompt.
    #[test]
    fn a_run_that_must_not_be_typed_is_refused() {
        // The two control characters are spelled as JSON escapes, so what the parser hands the rule
        // is a real ESC and a real NUL, which is how the extension would carry one.
        let escaped = format!(
            r#"{{"t":"run","id":"1","root":"/work","text":"ls{}[A"}}"#,
            "\\u001b"
        );
        let truncating = format!(
            r#"{{"t":"run","id":"1","root":"/work","text":"ls{}rm -rf /"}}"#,
            "\\u0000"
        );
        let cases: [&[u8]; 8] = [
            escaped.as_bytes(),
            truncating.as_bytes(),
            br#"{"t":"run","id":"1","root":"/work","text":""}"#,
            br#"{"t":"run","id":"","root":"/work","text":"ls"}"#,
            br#"{"t":"run","id":"1","root":"relative","text":"ls"}"#,
            br#"{"t":"run","id":"1","root":"/work"}"#,
            br#"{"t":"run","id":1,"root":"/work","text":"ls"}"#,
            br#"{"t":"cd","id":"1","root":"/work","path":"relative"}"#,
        ];
        for line in cases {
            assert_eq!(inbound(line), None, "rejected: {}", String::from_utf8_lossy(line));
        }
    }

    /// The id comes back out in the reply line, so an unbounded one would let a request name the
    /// size of its own answer.
    #[test]
    fn an_oversized_correlation_id_is_refused() {
        let id = "x".repeat(MAX_RUN_ID_BYTES + 1);
        let line = format!(r#"{{"t":"run","id":"{id}","root":"/work","text":"ls"}}"#);
        assert_eq!(inbound(line.as_bytes()), None);

        let at_cap = "x".repeat(MAX_RUN_ID_BYTES);
        let line = format!(r#"{{"t":"run","id":"{at_cap}","root":"/work","text":"ls"}}"#);
        assert!(inbound(line.as_bytes()).is_some(), "the cap itself is allowed");
    }

    /// Newline and tab DO survive: a multi-line selection is exactly what "run selection" means.
    #[test]
    fn a_multi_line_selection_is_typeable_and_an_enormous_one_is_not() {
        assert!(is_typeable("cd /tmp\n\tls -la\n"));
        assert!(!is_typeable(""));
        assert!(!is_typeable(&"x".repeat(MAX_RUN_TEXT_BYTES + 1)));
        assert!(is_typeable(&"x".repeat(MAX_RUN_TEXT_BYTES)));
    }

    /// A multi-byte scalar is not a control character, and scanning bytes must not decide otherwise
    /// — every continuation byte is `>= 0x80`, which is the whole argument for the byte scan.
    #[test]
    fn multi_byte_text_survives_the_byte_scan() {
        assert!(is_typeable("echo 'héllo — ✓'"));
        assert!(!is_typeable("echo \u{7f}"));
    }

    #[test]
    fn the_result_names_the_pane_it_landed_in() {
        assert_eq!(
            result_line("7", true, Some("zsh — alpha"), None),
            "{\"id\":\"7\",\"ok\":true,\"pane\":\"zsh — alpha\",\"t\":\"result\"}\n"
        );
    }

    #[test]
    fn a_refusal_carries_the_sentence_the_editor_shows() {
        assert_eq!(
            result_line("7", false, None, Some("no pane")),
            "{\"id\":\"7\",\"message\":\"no pane\",\"ok\":false,\"t\":\"result\"}\n"
        );
    }
}
