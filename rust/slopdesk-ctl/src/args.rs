//! Global flag + subcommand parsing. Pure: no I/O, no environment, no exit.
//!
//! Kept separate from the socket work for the same reason the Swift original kept
//! `SlopDeskCtlCore` apart from `main.swift` — the parse is the part worth unit-testing, and a
//! unit test must never open an `AF_UNIX` socket.

/// The global flags and the subcommand, as read off `argv`.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct GlobalArgs {
    /// Explicit `--socket PATH` override; empty when the flag was not given.
    pub socket_path: String,
    /// The first non-flag positional argument. Empty when `argv` carried none.
    pub subcommand: String,
    /// Every argument after the subcommand, in order.
    pub rest: Vec<String>,
}

/// Why [`parse_global`] refused the argument vector.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    /// A `-`-prefixed argument appeared before any subcommand and is not a known global flag.
    UnknownFlag(String),
    /// A global flag that takes a value was the last argument.
    MissingValue(String),
}

/// Parses the global flags and the subcommand out of `args`, whose first element is the program
/// name and is skipped.
///
/// Accepted anywhere in the vector:
/// - `--socket PATH`
/// - `--help` / `-h`, which set the subcommand to `help` so the caller can gate on it
///
/// A `-`-prefixed argument that is neither, and that arrives *before* a subcommand, is an error;
/// once a subcommand is known every remaining argument (flag-shaped or not) goes to `rest`
/// verbatim, because it belongs to the subcommand's own parser.
///
/// # Errors
/// [`ParseError::UnknownFlag`] for an unrecognised leading flag, [`ParseError::MissingValue`] when
/// a value-taking flag ends the vector.
pub fn parse_global(args: &[String]) -> Result<GlobalArgs, ParseError> {
    let mut result = GlobalArgs::default();
    let mut idx = 1; // skip argv[0]
    while let Some(arg) = args.get(idx) {
        match arg.as_str() {
            "--socket" => {
                let Some(value) = args.get(idx + 1) else {
                    return Err(ParseError::MissingValue("--socket".to_owned()));
                };
                idx += 1;
                result.socket_path.clone_from(value);
            },
            "--help" | "-h" => "help".clone_into(&mut result.subcommand),
            _ => {
                if arg.starts_with('-') && result.subcommand.is_empty() {
                    return Err(ParseError::UnknownFlag(arg.clone()));
                }
                if result.subcommand.is_empty() {
                    result.subcommand.clone_from(arg);
                } else {
                    result.rest.push(arg.clone());
                }
            },
        }
        idx += 1;
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{GlobalArgs, ParseError, parse_global};

    fn argv(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| (*s).to_owned()).collect()
    }

    fn ok(items: &[&str]) -> GlobalArgs {
        parse_global(&argv(items)).expect("these argv vectors all parse")
    }

    #[test]
    fn a_bare_subcommand_carries_no_socket_and_no_rest() {
        let g = ok(&["slopdesk-ctl", "list-panes"]);
        assert_eq!(g.subcommand, "list-panes");
        assert_eq!(g.socket_path, "");
        assert!(g.rest.is_empty());
    }

    #[test]
    fn the_socket_flag_is_consumed_with_its_value_and_leaves_the_subcommand_alone() {
        let g = ok(&["slopdesk-ctl", "--socket", "/tmp/test.sock", "read", "some-uuid"]);
        assert_eq!(g.socket_path, "/tmp/test.sock");
        assert_eq!(g.subcommand, "read");
        assert_eq!(g.rest, vec!["some-uuid".to_owned()]);
    }

    #[test]
    fn both_spellings_of_help_become_the_help_subcommand() {
        assert_eq!(ok(&["slopdesk-ctl", "-h"]).subcommand, "help");
        assert_eq!(ok(&["slopdesk-ctl", "--help"]).subcommand, "help");
    }

    #[test]
    fn help_after_a_subcommand_still_wins() {
        // Faithful to the Swift original: `--help` overwrites whatever subcommand was read, so
        // `slopdesk-ctl read some-uuid --help` prints usage instead of dialling the socket.
        assert_eq!(ok(&["slopdesk-ctl", "read", "--help"]).subcommand, "help");
    }

    #[test]
    fn an_unknown_flag_before_the_subcommand_is_refused() {
        assert_eq!(
            parse_global(&argv(&["slopdesk-ctl", "--bogus"])),
            Err(ParseError::UnknownFlag("--bogus".to_owned()))
        );
    }

    #[test]
    fn a_value_taking_flag_at_the_end_is_refused() {
        assert_eq!(
            parse_global(&argv(&["slopdesk-ctl", "--socket"])),
            Err(ParseError::MissingValue("--socket".to_owned()))
        );
    }

    #[test]
    fn everything_after_the_subcommand_reaches_rest_verbatim_including_flags() {
        let g = ok(&["slopdesk-ctl", "run", "foo-uuid", "--cmd", "ls"]);
        assert_eq!(g.subcommand, "run");
        assert_eq!(g.rest, argv(&["foo-uuid", "--cmd", "ls"]));
    }

    #[test]
    fn an_empty_argv_parses_to_an_empty_subcommand_rather_than_an_error() {
        let g = ok(&["slopdesk-ctl"]);
        assert_eq!(g.subcommand, "");
        assert!(g.rest.is_empty());
    }
}
