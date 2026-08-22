//! Which agent is holding a pane's foreground process group — over a whole job, not one name.
//!
//! A 1:1 port of herdr's `identify_agent_in_job` + `normalized_process_name` + the runtime-argv
//! unwrap family, by way of `AgentJobIdentifier.swift`. The one filesystem touch — resolving a
//! multi-component path token through symlinks — is injected, so tests stay hermetic and the
//! default only runs on the host probe path.

use crate::kind::{AgentKind, path_basename};

/// One process inside a pane's foreground process group (herdr `ForegroundProcess`).
///
/// The host's OS probe fills these in; everything below is pure and testable.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ForegroundJobProcess {
    /// The process id.
    pub pid: i32,
    /// The BSD comm name — bounded, and possibly truncated by the kernel.
    pub name: String,
    /// `argv[0]` when recoverable (handles `process.title =` rewrites and the login-shell `-`
    /// prefix).
    pub argv0: Option<String>,
    /// The full argv when recoverable.
    pub argv: Option<Vec<String>>,
    /// A flat command line, when structured argv is not recoverable.
    pub cmdline: Option<String>,
}

impl ForegroundJobProcess {
    /// A process known only by its pid and comm name — the shape the probe produces when it cannot
    /// read argv at all.
    #[must_use]
    pub fn named(pid: i32, name: &str) -> Self {
        Self {
            pid,
            name: name.to_owned(),
            ..Self::default()
        }
    }
}

/// A pane's foreground job: the group id plus every process in it (herdr `ForegroundJob`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ForegroundJob {
    /// The foreground process group id, as `tcgetpgrp` reported it.
    pub process_group_id: i32,
    /// Every process in the group.
    pub processes: Vec<ForegroundJobProcess>,
}

/// Resolves a path to its symlink target's basename.
///
/// Injected rather than called directly because identification runs in tests, in replays and on
/// machines where the path does not exist — and because a probe that touches the filesystem once
/// per process per poll is a probe that can be made to hang by a stale mount. Any
/// `Fn(&str) -> Option<String>` is one, so a test resolver is a closure and nothing else.
pub trait SymlinkResolver {
    /// The basename of `token`'s fully resolved target, or `None` when it does not resolve.
    fn resolve(&self, token: &str) -> Option<String>;
}

impl<F: Fn(&str) -> Option<String>> SymlinkResolver for F {
    fn resolve(&self, token: &str) -> Option<String> {
        self(token)
    }
}

/// The host probe's resolver: the real filesystem, through `canonicalize`.
///
/// Never fails loudly — a token that does not exist, a permission error, a symlink loop and a
/// non-UTF-8 target all answer `None`, which is exactly the "this token names nothing I know" the
/// caller already handles.
#[must_use]
pub fn realpath_basename(token: &str) -> Option<String> {
    let resolved = std::fs::canonicalize(token).ok()?;
    let base = resolved.file_name()?.to_str()?.to_owned();
    if base.is_empty() { None } else { Some(base) }
}

/// herdr `identify_agent_in_job`.
///
/// Prefers the group LEADER; failing that, scans every process, keeps the recognised agents and
/// picks the highest [`process_priority`] (strict `>`, so the first wins a tie). Returns the agent
/// plus the normalized name that identified it.
#[must_use]
pub fn identify(job: &ForegroundJob, resolver: &impl SymlinkResolver) -> Option<(AgentKind, String)> {
    if let Some(leader) = job
        .processes
        .iter()
        .find(|process| process.pid == job.process_group_id)
    {
        let name = normalized_process_name(leader, resolver);
        if let Some(agent) = AgentKind::identify(&name) {
            return Some((agent, name));
        }
    }

    let mut best: Option<(AgentKind, String, u8)> = None;
    for process in &job.processes {
        let name = normalized_process_name(process, resolver);
        let Some(agent) = AgentKind::identify(&name) else {
            continue;
        };
        let priority = process_priority(process, &name);
        if best.as_ref().is_some_and(|(_, _, current)| *current >= priority) {
            continue;
        }
        best = Some((agent, name, priority));
    }
    best.map(|(agent, name, _)| (agent, name))
}

/// herdr `normalized_process_name`: argv0-over-comm, runtime unwrap, direct match, then the
/// argv0/cmdline path fallbacks — in that exact order.
#[must_use]
pub fn normalized_process_name(process: &ForegroundJobProcess, resolver: &impl SymlinkResolver) -> String {
    let effective = process.argv0.as_deref().unwrap_or(process.name.as_str());
    let lower_effective = effective.to_lowercase();

    if AgentKind::is_generic_runtime_or_shell(&lower_effective)
        && let Some(wrapped) = wrapped_agent_name(&lower_effective, process.argv.as_deref(), resolver)
    {
        return wrapped;
    }

    if AgentKind::identify(effective).is_some() {
        return effective.to_owned();
    }

    if let Some(wrapped) = process
        .argv
        .as_ref()
        .and_then(|argv| argv.first())
        .and_then(|token| agent_name_from_path_token(token, resolver))
    {
        return wrapped;
    }
    if let Some(first) = process.cmdline.as_deref().unwrap_or("").split_whitespace().next()
        && let Some(wrapped) = agent_name_from_path_token(first, resolver)
    {
        return wrapped;
    }

    effective.to_owned()
}

/// herdr `process_priority`: 3 = unwrapped from a runtime or script, 2 = the literal agent binary,
/// 1 = anything else.
#[must_use]
pub fn process_priority(process: &ForegroundJobProcess, normalized_name: &str) -> u8 {
    let lower_name = normalized_name.to_lowercase();
    if lower_name != process.name.to_lowercase() {
        return 3;
    }
    if AgentKind::is_generic_runtime_or_shell(&lower_name) {
        1
    } else {
        2
    }
}

// MARK: Runtime argv unwrapping (herdr `wrapped_agent_name_from_runtime_argv` family)

fn wrapped_agent_name(
    runtime: &str,
    argv: Option<&[String]>,
    resolver: &impl SymlinkResolver,
) -> Option<String> {
    let argv = argv?;
    match AgentKind::normalized_lookup_name(path_basename(runtime)).as_str() {
        "node" | "bun" => script_arg_agent_name(argv, &["-e", "--eval", "-p", "--print"], &[], resolver),
        "python" | "python3" => script_arg_agent_name(argv, &["-c"], &["-m"], resolver),
        "sh" | "bash" | "zsh" | "fish" => script_arg_agent_name(argv, &["-c"], &[], resolver),
        "cmd" => windows_cmd_arg_agent_name(argv, resolver),
        "powershell" | "pwsh" => powershell_arg_agent_name(argv, resolver),
        _ => None,
    }
}

/// herdr `script_arg_agent_name`: walk argv past option flags to the first positional (script path)
/// token. An eval or module flag bails IMMEDIATELY — a `-c`/`-e` command's trailing args are never
/// trusted as an agent path.
fn script_arg_agent_name(
    argv: &[String],
    eval_flags: &[&str],
    module_flags: &[&str],
    resolver: &impl SymlinkResolver,
) -> Option<String> {
    let mut index = 1;
    while let Some(arg) = argv.get(index) {
        index += 1;
        if arg == "--" {
            return agent_name_from_path_token(argv.get(index)?, resolver);
        }
        if flag_matches(arg, eval_flags) || flag_matches(arg, module_flags) {
            return None;
        }
        if arg.starts_with('-') {
            if option_takes_value(arg) {
                index += 1;
            }
            continue;
        }
        return agent_name_from_path_token(arg, resolver);
    }
    None
}

fn flag_matches(arg: &str, flags: &[&str]) -> bool {
    flags.iter().any(|flag| {
        if arg == *flag {
            return true;
        }
        // Short-flag glued payload (`-eSCRIPT`).
        if flag.starts_with('-') && !flag.starts_with("--") && arg.starts_with(flag) && arg.len() > flag.len()
        {
            return true;
        }
        // Long-flag `=` value (`--eval=…`).
        flag.starts_with("--") && arg.starts_with(&format!("{flag}="))
    })
}

fn option_takes_value(arg: &str) -> bool {
    matches!(
        arg,
        "-r" | "--require"
            | "--loader"
            | "--import"
            | "--experimental-loader"
            | "--inspect-port"
            | "-W"
            | "-X"
            | "-S"
            | "-L"
            | "-o"
    )
}

fn windows_cmd_arg_agent_name(argv: &[String], resolver: &impl SymlinkResolver) -> Option<String> {
    let mut index = 1;
    while let Some(raw) = argv.get(index) {
        let flag = raw.trim_matches('"').to_lowercase();
        index += 1;
        if matches!(flag.as_str(), "/c" | "/k") {
            return command_text_agent_name(argv.get(index)?, resolver);
        }
    }
    None
}

fn powershell_arg_agent_name(argv: &[String], resolver: &impl SymlinkResolver) -> Option<String> {
    let mut index = 1;
    while let Some(raw) = argv.get(index) {
        let flag = raw.trim_matches('"').to_lowercase();
        index += 1;
        match flag.as_str() {
            "-file" | "-f" | "/file" => return agent_name_from_path_token(argv.get(index)?, resolver),
            "-command" | "-c" | "/command" | "/c" => {
                return command_text_agent_name(argv.get(index)?, resolver);
            },
            "-encodedcommand" | "-enc" | "/encodedcommand" | "/enc" => return None,
            "-configurationname" | "-executionpolicy" | "-outputformat" | "-psconsolefile" | "-version"
            | "-windowstyle" | "-workingdirectory" => index += 1,
            _ => {
                if flag.starts_with('-') || flag.starts_with('/') {
                    continue;
                }
                return agent_name_from_path_token(raw, resolver);
            },
        }
    }
    None
}

/// herdr `command_text_agent_name`: the first shell-ish token of a command string, skipping the
/// `&` / `.` / `call` invokers.
fn command_text_agent_name(command: &str, resolver: &impl SymlinkResolver) -> Option<String> {
    let mut rest = command;
    while let Some((token, next)) = command_text_token(rest) {
        let trimmed = token.trim();
        if trimmed.eq_ignore_ascii_case("&")
            || trimmed.eq_ignore_ascii_case(".")
            || trimmed.eq_ignore_ascii_case("call")
        {
            rest = next;
            continue;
        }
        return agent_name_from_path_token(trimmed, resolver);
    }
    None
}

/// One token of a command string, plus what is left after it. Honours a single level of quoting; an
/// unterminated quote takes the rest of the string, which is what a shell would have done anyway.
fn command_text_token(input: &str) -> Option<(&str, &str)> {
    let trimmed = input.trim_start();
    let mut characters = trimmed.chars();
    let first = characters.next()?;
    if first == '"' || first == '\'' {
        let body = characters.as_str();
        return match body.find(first) {
            Some(position) => {
                let (token, rest) = body.split_at_checked(position)?;
                Some((token, rest.get(first.len_utf8()..).unwrap_or("")))
            },
            None => Some((body, "")),
        };
    }
    let end = trimmed.find(char::is_whitespace).unwrap_or(trimmed.len());
    trimmed.split_at_checked(end)
}

// MARK: Path token resolution (herdr `agent_name_from_path_token`)

/// A basename match, then the known-package sniff, then symlink resolution — in that order.
fn agent_name_from_path_token(token: &str, resolver: &impl SymlinkResolver) -> Option<String> {
    let trimmed = token.trim_matches(|c| c == '"' || c == '\'');
    if trimmed.is_empty() || trimmed.starts_with('-') {
        return None;
    }

    if let Some(direct) = agent_name_from_basename(path_basename(trimmed)) {
        return Some(direct);
    }
    if let Some(packaged) = agent_name_from_known_package_path(trimmed) {
        return Some(packaged);
    }

    // Symlink resolution only for multi-component paths — a bare word never touches the filesystem.
    let component_count = trimmed.split(['/', '\\']).filter(|part| !part.is_empty()).count();
    let is_absolute = trimmed.starts_with('/') || trimmed.starts_with('\\');
    if component_count < 2 && !(is_absolute && component_count >= 1) {
        return None;
    }
    agent_name_from_basename(&resolver.resolve(trimmed)?)
}

fn agent_name_from_basename(basename: &str) -> Option<String> {
    AgentKind::identify(basename).map(|agent| agent.label().to_owned())
}

/// herdr `agent_name_from_known_package_path`: the pi coding agent's npm dist layout.
fn agent_name_from_known_package_path(path: &str) -> Option<String> {
    const NEEDLE: [&str; 5] = [
        "node_modules",
        "@earendil-works",
        "pi-coding-agent",
        "dist",
        "cli",
    ];
    let components: Vec<String> = path
        .split(['/', '\\'])
        .filter(|part| !part.is_empty())
        .map(AgentKind::normalized_lookup_name)
        .collect();
    if components.windows(NEEDLE.len()).any(|window| window == NEEDLE) {
        return Some(AgentKind::Pi.label().to_owned());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::{ForegroundJob, ForegroundJobProcess, identify, normalized_process_name, process_priority};
    use crate::kind::AgentKind;

    /// A resolver that resolves nothing. TEST-ONLY: production never wants it — the door's
    /// `Resolver::resolve` states that a null Swift callback is NOT "resolve nothing" and falls
    /// back to [`super::realpath_basename`], so a `pub` version of this would be a third spelling
    /// of a rule that has one.
    const fn no_symlinks(_token: &str) -> Option<String> {
        None
    }

    fn wrapped(pid: i32, name: &str, argv: &[&str]) -> ForegroundJobProcess {
        ForegroundJobProcess {
            pid,
            name: name.to_owned(),
            argv0: None,
            argv: Some(argv.iter().map(|arg| (*arg).to_owned()).collect()),
            cmdline: None,
        }
    }

    fn name_of(process: &ForegroundJobProcess) -> String {
        normalized_process_name(process, &no_symlinks)
    }

    #[test]
    fn the_group_leader_wins_before_anything_else_is_looked_at() {
        let job = ForegroundJob {
            process_group_id: 10,
            processes: vec![
                ForegroundJobProcess::named(9, "codex"),
                ForegroundJobProcess::named(10, "claude"),
            ],
        };
        assert_eq!(
            identify(&job, &no_symlinks),
            Some((AgentKind::Claude, "claude".to_owned()))
        );
    }

    #[test]
    fn a_leader_that_names_nobody_falls_back_to_the_highest_priority_process() {
        let job = ForegroundJob {
            process_group_id: 1,
            processes: vec![
                ForegroundJobProcess::named(1, "zsh"),
                ForegroundJobProcess::named(2, "claude"),
            ],
        };
        assert_eq!(
            identify(&job, &no_symlinks),
            Some((AgentKind::Claude, "claude".to_owned()))
        );
    }

    #[test]
    fn an_agent_unwrapped_from_a_runtime_outranks_the_literal_binary() {
        let job = ForegroundJob {
            process_group_id: 1,
            processes: vec![
                ForegroundJobProcess::named(1, "sh"),
                ForegroundJobProcess::named(2, "codex"),
                wrapped(3, "node", &["node", "/opt/bin/claude"]),
            ],
        };
        // The `node` process resolves to `claude` at priority 3; `codex` is a literal binary at 2.
        assert_eq!(
            identify(&job, &no_symlinks),
            Some((AgentKind::Claude, "claude".to_owned()))
        );
    }

    #[test]
    fn the_first_of_equal_priority_wins_the_tie() {
        let job = ForegroundJob {
            process_group_id: 1,
            processes: vec![
                ForegroundJobProcess::named(1, "zsh"),
                ForegroundJobProcess::named(2, "codex"),
                ForegroundJobProcess::named(3, "gemini"),
            ],
        };
        assert_eq!(
            identify(&job, &no_symlinks),
            Some((AgentKind::Codex, "codex".to_owned()))
        );
    }

    #[test]
    fn a_job_of_shells_names_nobody() {
        let job = ForegroundJob {
            process_group_id: 1,
            processes: vec![
                ForegroundJobProcess::named(1, "zsh"),
                ForegroundJobProcess::named(2, "make"),
                ForegroundJobProcess::named(3, "node"),
            ],
        };
        assert_eq!(identify(&job, &no_symlinks), None);
        assert_eq!(identify(&ForegroundJob::default(), &no_symlinks), None);
    }

    #[test]
    fn a_node_shebang_wrapper_resolves_to_the_script_it_runs() {
        assert_eq!(
            name_of(&wrapped(1, "node", &["node", "/usr/local/bin/claude"])),
            "claude"
        );
        assert_eq!(name_of(&wrapped(1, "bun", &["bun", "/opt/bin/codex"])), "codex");
        // The FIRST positional wins and is taken whole: `bun run codex` names the script `run`,
        // which is nobody, and the walk does not keep going looking for a better token.
        assert_eq!(name_of(&wrapped(1, "bun", &["bun", "run", "codex"])), "bun");
        assert_eq!(
            name_of(&wrapped(1, "node", &[
                "node",
                "--enable-source-maps",
                "/opt/gemini"
            ])),
            "gemini"
        );
        assert_eq!(
            name_of(&wrapped(1, "node", &["node", "--require", "hook", "/opt/amp"])),
            "amp"
        );
    }

    #[test]
    fn an_eval_command_is_never_trusted_as_a_path() {
        // `-e` / `-c` bail immediately: the trailing token is source text, not an executable.
        assert_eq!(name_of(&wrapped(1, "node", &["node", "-e", "claude"])), "node");
        assert_eq!(name_of(&wrapped(1, "node", &["node", "--eval=claude"])), "node");
        assert_eq!(name_of(&wrapped(1, "node", &["node", "-eclaude"])), "node");
        assert_eq!(
            name_of(&wrapped(1, "python3", &["python3", "-c", "claude"])),
            "python3"
        );
        assert_eq!(
            name_of(&wrapped(1, "python3", &["python3", "-m", "claude"])),
            "python3"
        );
        assert_eq!(name_of(&wrapped(1, "bash", &["bash", "-c", "claude"])), "bash");
    }

    #[test]
    fn a_double_dash_hands_the_next_token_over_whole() {
        assert_eq!(name_of(&wrapped(1, "node", &["node", "--", "/opt/kilo"])), "kilo");
        assert_eq!(name_of(&wrapped(1, "node", &["node", "--"])), "node");
    }

    #[test]
    fn the_windows_shells_unwrap_their_command_forms() {
        assert_eq!(
            name_of(&wrapped(1, "cmd", &["cmd", "/c", "claude --resume"])),
            "claude"
        );
        assert_eq!(
            name_of(&wrapped(1, "cmd", &["cmd", "/d", "/s", "/c", "call codex"])),
            "codex"
        );
        assert_eq!(
            name_of(&wrapped(1, "pwsh", &["pwsh", "-File", "C:\\bin\\gemini.exe"])),
            "gemini"
        );
        assert_eq!(
            name_of(&wrapped(1, "pwsh", &["pwsh", "-Command", "& 'droid'"])),
            "droid"
        );
        // An encoded command is opaque — never guessed at.
        assert_eq!(
            name_of(&wrapped(1, "pwsh", &["pwsh", "-EncodedCommand", "Y2xhdWRl"])),
            "pwsh"
        );
    }

    #[test]
    fn the_pi_package_layout_is_recognised_without_touching_the_filesystem() {
        assert_eq!(
            name_of(&wrapped(1, "node", &[
                "node",
                "/w/node_modules/@earendil-works/pi-coding-agent/dist/cli.js",
            ])),
            "pi"
        );
    }

    #[test]
    fn a_bare_word_never_reaches_the_resolver() {
        // `no_symlinks` resolves nothing, so a bare unknown word stays the runtime's own name
        // — and the point is that a single-component token is not even offered to a resolver.
        assert_eq!(name_of(&wrapped(1, "node", &["node", "mystery"])), "node");
    }

    #[test]
    fn a_resolver_answer_identifies_a_multi_component_path() {
        let resolve = |token: &str| (token == "/opt/shim/agent").then(|| "claude".to_owned());
        let process = wrapped(1, "node", &["node", "/opt/shim/agent"]);
        assert_eq!(normalized_process_name(&process, &resolve), "claude");
    }

    #[test]
    fn the_priority_ladder_is_unwrapped_then_literal_then_everything_else() {
        let unwrapped = wrapped(1, "node", &["node", "/opt/claude"]);
        assert_eq!(process_priority(&unwrapped, &name_of(&unwrapped)), 3);
        let literal = ForegroundJobProcess::named(1, "claude");
        assert_eq!(process_priority(&literal, &name_of(&literal)), 2);
        let shell = ForegroundJobProcess::named(1, "zsh");
        assert_eq!(process_priority(&shell, &name_of(&shell)), 1);
    }

    #[test]
    fn argv0_beats_the_kernels_truncated_comm_name() {
        let process = ForegroundJobProcess {
            pid: 1,
            name: "claude-cod".to_owned(),
            argv0: Some("claude".to_owned()),
            argv: None,
            cmdline: None,
        };
        assert_eq!(name_of(&process), "claude");
    }

    #[test]
    fn a_flat_cmdline_is_the_last_fallback() {
        let process = ForegroundJobProcess {
            pid: 1,
            name: "mystery".to_owned(),
            argv0: None,
            argv: None,
            cmdline: Some("/usr/local/bin/hermes --serve".to_owned()),
        };
        assert_eq!(name_of(&process), "hermes");
    }

    #[test]
    fn nothing_recognisable_leaves_the_name_exactly_as_it_arrived() {
        let process = ForegroundJobProcess {
            pid: 1,
            name: "some-daemon".to_owned(),
            argv0: None,
            argv: Some(vec!["/opt/some-daemon".to_owned()]),
            cmdline: None,
        };
        assert_eq!(name_of(&process), "some-daemon");
    }
}
