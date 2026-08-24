//! `slopdesk-hostd`'s command line.
//!
//! A pure value transform: an argv slice in, a [`HostdArgs`] or a refusal out. No I/O, no `exit`,
//! so every flag combination is testable without spawning a daemon — which is why this was a
//! library type in Swift too, and stayed one across the port.
//!
//! ## Flags
//! - `--port N` / `-p N`: TCP port to bind. Default [`DEFAULT_PORT`]; `0` asks the OS for an
//!   ephemeral one, which is why the daemon records the port it actually BOUND ([`crate::record`]).
//! - `--shell PATH` / `-s PATH`: the shell to spawn. Absent means the user's login shell.
//! - `--inspector`: stand up the read-only structured inspector server on `port + 1`.
//! - `--transcript PATH`: the Claude Code JSONL transcript the inspector tails. Implies
//!   `--inspector`.
//! - `--help` / `-h`: a refusal, so the caller prints [`usage`] and exits non-zero.
//!
//! ## What is NOT a flag any more
//! The curated `claude` launch — `--claude`, and `--xterm256` beside it — is retired as a daemon
//! MODE. A Claude session is a plain terminal pane that runs `claude`, detected by the host and
//! offered client-side as a launch preset, so every channel spawns a login shell and there is no
//! launch mode left to parse. Both spellings are still REFUSED rather than ignored: a script that
//! passes `--claude` is asking for behaviour this daemon no longer has, and silently starting
//! something else would be the worse answer.

/// The port hostd binds when nobody says otherwise, and the ONE spelling of it.
///
/// Not private, and not only hostd's: the client's connect gate prefills the port it expects a host
/// to be on, and the menu-bar app seeds the port it will start one with. All three are the same
/// fact. They disagreed once — the menu-bar app stored `7779` while the client dialled `7420`, so
/// starting a host from the menu bar and pressing Connect dialled a port nothing was listening on —
/// and a default that only one of three halves knows is not a default. The other two ASK for it,
/// through `slopdesk_hostd_default_port`, rather than spelling it again (`docs/55` §8).
pub const DEFAULT_PORT: u16 = 7420;

/// A parsed hostd command line.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HostdArgs {
    /// The port to bind. [`DEFAULT_PORT`] unless `--port`/`-p` said otherwise.
    pub port: u16,
    /// The shell to spawn, or `None` for the user's login shell.
    pub shell: Option<String>,
    /// Whether to stand up the inspector server on `port + 1`. Explicit under `--inspector`, and
    /// implied by `--transcript`, which supplies something for it to tail.
    pub inspector_enabled: bool,
    /// The transcript path the inspector tails, if one was supplied.
    pub transcript_path: Option<String>,
}

/// The usage line printed on `--help` or a parse refusal.
///
/// Rendered from `program` rather than a constant so the message names whatever the caller was
/// invoked as, which is what a person types next.
#[must_use]
pub fn usage(program: &str) -> String {
    format!("usage: {program} [--port N] [--shell /path/to/shell] [--inspector] [--transcript PATH]")
}

/// Parse a full argv, `argv[0]` included and dropped.
///
/// `None` for `--help`/`-h`, a flag whose value is missing, a `--port` that is not a port, or a
/// flag this daemon does not have. The caller prints [`usage`] and exits non-zero; there is no
/// partial parse and no flag is ignored.
#[must_use]
pub fn parse(argv: &[String]) -> Option<HostdArgs> {
    let mut port = DEFAULT_PORT;
    let mut shell = None;
    let mut inspector = false;
    let mut transcript = None;

    let mut rest = argv.iter().skip(1);
    while let Some(argument) = rest.next() {
        match argument.as_str() {
            "--port" | "-p" => port = rest.next()?.parse().ok()?,
            "--shell" | "-s" => shell = Some(rest.next()?.clone()),
            "--transcript" => transcript = Some(rest.next()?.clone()),
            "--inspector" => inspector = true,
            _ => return None,
        }
    }

    Some(HostdArgs {
        port,
        shell,
        // Explicitly, or implied by a transcript to tail.
        inspector_enabled: inspector || transcript.is_some(),
        transcript_path: transcript,
    })
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::{DEFAULT_PORT, HostdArgs, parse, usage};

    /// Build an argv the way a shell hands one over: program name first.
    fn argv(tail: &[&str]) -> Vec<String> {
        std::iter::once("slopdesk-hostd")
            .chain(tail.iter().copied())
            .map(str::to_owned)
            .collect()
    }

    /// A bare invocation is the documented default, top to bottom.
    #[test]
    fn a_bare_invocation_is_the_default_everywhere() {
        assert_eq!(
            parse(&argv(&[])),
            Some(HostdArgs {
                port: DEFAULT_PORT,
                shell: None,
                inspector_enabled: false,
                transcript_path: None,
            })
        );
    }

    /// Both spellings of both value flags, and a port that is a port.
    #[test]
    fn every_flag_is_accepted_in_both_spellings() {
        let long = parse(&argv(&["--port", "9001", "--shell", "/bin/bash"])).expect("a valid line");
        let short = parse(&argv(&["-p", "9001", "-s", "/bin/bash"])).expect("a valid line");
        assert_eq!(long, short);
        assert_eq!(long.port, 9001);
        assert_eq!(long.shell.as_deref(), Some("/bin/bash"));
    }

    /// `--port 0` is a REQUEST, not an error — it asks the OS for an ephemeral port, and the record
    /// is what later says which one it got.
    #[test]
    fn port_zero_is_a_request_rather_than_a_refusal() {
        assert_eq!(parse(&argv(&["--port", "0"])).map(|args| args.port), Some(0));
    }

    /// A transcript implies the inspector; the inspector alone implies no transcript.
    #[test]
    fn a_transcript_stands_the_inspector_up_and_the_inspector_does_not_invent_one() {
        let tailing = parse(&argv(&["--transcript", "/tmp/session.jsonl"])).expect("a valid line");
        assert!(tailing.inspector_enabled);
        assert_eq!(tailing.transcript_path.as_deref(), Some("/tmp/session.jsonl"));

        let bare = parse(&argv(&["--inspector"])).expect("a valid line");
        assert!(bare.inspector_enabled);
        assert_eq!(bare.transcript_path, None);
    }

    /// Help is a refusal, so the shell prints usage and exits non-zero rather than starting.
    #[test]
    fn help_is_a_refusal_in_both_spellings() {
        assert_eq!(parse(&argv(&["--help"])), None);
        assert_eq!(parse(&argv(&["-h"])), None);
    }

    /// The retired launch mode is REFUSED, not ignored. A script still passing `--claude` is asking
    /// for behaviour this daemon does not have, and starting a plain shell instead would be worse.
    #[test]
    fn the_retired_claude_flags_are_refused_rather_than_ignored() {
        assert_eq!(parse(&argv(&["--claude"])), None);
        assert_eq!(parse(&argv(&["--claude", "--xterm256"])), None);
        assert_eq!(parse(&argv(&["--xterm256"])), None);
    }

    /// A missing value is a refusal at every value flag, including the last argument.
    #[test]
    fn a_flag_with_no_value_is_a_refusal() {
        assert_eq!(parse(&argv(&["--port"])), None);
        assert_eq!(parse(&argv(&["--shell"])), None);
        assert_eq!(parse(&argv(&["--transcript"])), None);
    }

    /// A port that is not a port — out of `u16`, negative, or not a number at all.
    #[test]
    fn a_port_that_is_not_a_port_is_a_refusal() {
        for bad in ["65536", "-1", "seven", "", "7420 "] {
            assert_eq!(parse(&argv(&["--port", bad])), None, "{bad} parsed as a port");
        }
    }

    /// A VALUE that looks like a flag is still a value: the flag before it consumed its turn.
    #[test]
    fn a_value_that_looks_like_a_flag_is_still_a_value() {
        let parsed = parse(&argv(&["--shell", "--inspector"])).expect("a valid line");
        assert_eq!(parsed.shell.as_deref(), Some("--inspector"));
        assert!(
            !parsed.inspector_enabled,
            "the value was consumed, not read as a flag"
        );
    }

    /// The usage line names the program it was invoked as, and every flag the parser accepts.
    #[test]
    fn the_usage_line_names_the_program_and_every_flag() {
        let text = usage("hostd");
        assert!(text.starts_with("usage: hostd "));
        for flag in ["--port", "--shell", "--inspector", "--transcript"] {
            assert!(text.contains(flag), "usage does not document {flag}");
        }
    }
}
