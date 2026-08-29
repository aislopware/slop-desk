//! The command line, parsed.
//!
//! A module of its own so the parse is reachable from a test without a process: the Swift version
//! was a `while let` inside `main.swift`'s top level, which is the one shape no test can enter.

use slopdesk_ids::identity::parse_uuid;

/// What the process was asked to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Args<'a> {
    /// The host running `slopdesk-hostd`.
    pub host: &'a str,
    /// The TCP port it listens on.
    pub port: u16,
    /// Stay in cooked mode even on a tty. What a pipe-driven caller wants, and what the E2E
    /// harness passes.
    pub no_raw: bool,
    /// The session to present on connect, for a reattach or a scrollback restore. `None` means the
    /// driver mints one, which is a fresh shell.
    pub session_id: Option<[u8; 16]>,
}

/// Why a command line did not parse. Each carries the text that has to appear in the message, so
/// the caller formats one sentence rather than choosing one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArgsError<'a> {
    /// `--help`. Not a failure, but it ends the process the same way a usage error does.
    HelpRequested,
    /// A flag this program does not know.
    UnknownFlag(&'a str),
    /// A flag that takes a value was last on the line.
    MissingValue(&'a str),
    /// A value that is the right shape for no `--port` / `--session-id`.
    BadValue {
        /// The flag whose value did not parse.
        flag: &'a str,
        /// What was written after it.
        value: &'a str,
    },
    /// Neither `--host` nor `--port` may be defaulted: a client that guesses which host to reach is
    /// a client that reaches the wrong one silently.
    MissingRequired(&'a str),
}

impl core::fmt::Display for ArgsError<'_> {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match *self {
            Self::HelpRequested => formatter.write_str("help requested"),
            Self::UnknownFlag(flag) => write!(formatter, "unknown option {flag}"),
            Self::MissingValue(flag) => write!(formatter, "{flag} needs a value"),
            Self::BadValue { flag, value } => write!(formatter, "{flag}: cannot read {value:?}"),
            Self::MissingRequired(flag) => write!(formatter, "{flag} is required"),
        }
    }
}

impl core::error::Error for ArgsError<'_> {}

/// Reads `argv` past its zeroth element.
///
/// # Errors
/// [`ArgsError`], including [`ArgsError::HelpRequested`] for `--help` — the caller prints the same
/// usage block either way and differs only in the exit code.
pub fn parse(argv: &[String]) -> Result<Args<'_>, ArgsError<'_>> {
    let mut host: Option<&str> = None;
    let mut port: Option<u16> = None;
    let mut no_raw = false;
    let mut session_id: Option<[u8; 16]> = None;

    let mut rest = argv.iter().skip(1);
    while let Some(argument) = rest.next() {
        let flag = argument.as_str();
        match flag {
            "--host" | "-h" => {
                host = Some(rest.next().ok_or(ArgsError::MissingValue(flag))?.as_str());
            },
            "--port" | "-p" => {
                let value = rest.next().ok_or(ArgsError::MissingValue(flag))?.as_str();
                port = Some(
                    value
                        .parse()
                        .map_err(|_bad| ArgsError::BadValue { flag, value })?,
                );
            },
            "--no-raw" => no_raw = true,
            "--session-id" => {
                let value = rest.next().ok_or(ArgsError::MissingValue(flag))?.as_str();
                session_id = Some(parse_uuid(value).ok_or(ArgsError::BadValue { flag, value })?);
            },
            "--help" => return Err(ArgsError::HelpRequested),
            other => return Err(ArgsError::UnknownFlag(other)),
        }
    }

    Ok(Args {
        host: host.ok_or(ArgsError::MissingRequired("--host"))?,
        port: port.ok_or(ArgsError::MissingRequired("--port"))?,
        no_raw,
        session_id,
    })
}

/// The usage block, without a trailing program name — the caller owns that, because the name it
/// prints is `argv[0]`'s basename and this module does not read the process.
pub const USAGE_BODY: &str = "\
  --host, -h <host>   host running slopdesk-hostd
  --port, -p <port>   TCP port slopdesk-hostd listens on
  --no-raw            do not put the local terminal in raw mode (pipe/scripting)
  --session-id <uuid> present this session UUID on connect (reattach to a detached
                      shell / restore the disk-journaled scrollback; E2E harness)

Disconnect key (interactive mode): Ctrl-] cleanly disconnects and exits 0.
";

/// The basename of `argv[0]`, or the shipped name when there is none.
#[must_use]
pub fn program_name(argv0: Option<&str>) -> &str {
    argv0
        .and_then(|path| path.rsplit('/').next())
        .filter(|name| !name.is_empty())
        .unwrap_or("slopdesk-client")
}

#[cfg(test)]
mod tests {
    use super::{Args, ArgsError, parse, program_name};

    fn argv(parts: &[&str]) -> Vec<String> {
        core::iter::once("slopdesk-client")
            .chain(parts.iter().copied())
            .map(ToOwned::to_owned)
            .collect()
    }

    #[test]
    fn the_short_and_long_spellings_are_the_same_flag() {
        let long = argv(&["--host", "mac-studio", "--port", "7777"]);
        let short = argv(&["-h", "mac-studio", "-p", "7777"]);
        assert_eq!(parse(&long), parse(&short));
        assert_eq!(
            parse(&long),
            Ok(Args {
                host: "mac-studio",
                port: 7777,
                no_raw: false,
                session_id: None,
            })
        );
    }

    #[test]
    fn a_session_id_is_read_as_sixteen_bytes() {
        let line = argv(&[
            "-h",
            "h",
            "-p",
            "1",
            "--session-id",
            "01020304-0506-0708-090a-0b0c0d0e0f10",
        ]);
        let parsed = parse(&line);
        assert_eq!(
            parsed.map(|args| args.session_id),
            Ok(Some([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]))
        );
    }

    #[test]
    fn a_malformed_session_id_is_refused_rather_than_replaced_by_a_fresh_one() {
        // The failure mode this excludes is the expensive one: a typo that silently became "no
        // session" would spawn a SECOND shell beside the one the caller meant to reattach to.
        let line = argv(&["-h", "h", "-p", "1", "--session-id", "not-a-uuid"]);
        assert_eq!(
            parse(&line),
            Err(ArgsError::BadValue {
                flag: "--session-id",
                value: "not-a-uuid",
            })
        );
    }

    #[test]
    fn a_port_outside_sixteen_bits_is_a_bad_value_not_a_wrap() {
        let line = argv(&["-h", "h", "-p", "70000"]);
        assert_eq!(
            parse(&line),
            Err(ArgsError::BadValue {
                flag: "-p",
                value: "70000",
            })
        );
    }

    #[test]
    fn a_flag_last_on_the_line_names_itself() {
        assert_eq!(parse(&argv(&["--host"])), Err(ArgsError::MissingValue("--host")));
    }

    #[test]
    fn neither_endpoint_half_may_be_defaulted() {
        assert_eq!(
            parse(&argv(&["-p", "1"])),
            Err(ArgsError::MissingRequired("--host"))
        );
        assert_eq!(
            parse(&argv(&["-h", "h"])),
            Err(ArgsError::MissingRequired("--port"))
        );
    }

    #[test]
    fn an_unknown_flag_is_named_rather_than_ignored() {
        assert_eq!(
            parse(&argv(&["-h", "h", "-p", "1", "--colour"])),
            Err(ArgsError::UnknownFlag("--colour"))
        );
    }

    #[test]
    fn help_is_its_own_outcome() {
        assert_eq!(parse(&argv(&["--help"])), Err(ArgsError::HelpRequested));
    }

    #[test]
    fn the_program_name_is_the_basename_and_never_empty() {
        assert_eq!(
            program_name(Some("/usr/local/bin/slopdesk-client")),
            "slopdesk-client"
        );
        assert_eq!(program_name(Some("")), "slopdesk-client");
        assert_eq!(program_name(None), "slopdesk-client");
    }
}
