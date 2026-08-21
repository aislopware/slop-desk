//! The global-flag parser for `slopdesk`.
//!
//! A pure value transform: no I/O, no `exit`, so every flag combination is testable without opening
//! a socket or launching a GUI. The thin shell adds the socket, the GUI launch and the
//! per-subcommand dispatch, and is the only place that exits.

/// Output format for the list and inspect subcommands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum OutputFormat {
    /// Aligned column tables, honouring `--no-headers`.
    #[default]
    Text,
    /// Compact, key-sorted JSON, for scripting.
    Json,
}

/// The default IPC wait, in milliseconds.
pub const DEFAULT_TIMEOUT_MS: i64 = 3000;

/// One global flag as the help text describes it, and as [`parse`] accepts it.
///
/// The `spellings` field is not decoration: it is what lets a test feed every documented flag back
/// through the parser, so a flag that is renamed in the `match` below but not here fails the build
/// rather than quietly documenting a flag that no longer exists.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct GlobalFlag {
    /// How the help text prints it, alternatives and metavariable included.
    pub display: &'static str,
    /// Every token [`parse`] matches for this flag.
    pub spellings: &'static [&'static str],
    /// One sentence. `{timeout}` is substituted with [`DEFAULT_TIMEOUT_MS`] by the help renderer,
    /// so the documented default cannot drift from the constant the parser uses.
    pub summary: &'static str,
}

/// Every global flag, in the order the help text prints them.
///
/// This sits beside the grammar rather than in the help renderer for the same reason the subcommand
/// vocabulary sits in one table: the flag STRING and the sentence describing it are one fact, and
/// two copies of a fact is a CLI that documents a flag it does not accept.
pub const GLOBAL_FLAGS: &[GlobalFlag] = &[
    GlobalFlag {
        display: "--json / --format json",
        spellings: &["--json", "--format"],
        summary: "Emit structured JSON for list/inspect output.",
    },
    GlobalFlag {
        display: "--no-headers",
        spellings: &["--no-headers"],
        summary: "Strip table header rows from text output.",
    },
    GlobalFlag {
        display: "--socket PATH",
        spellings: &["--socket"],
        summary: "Override the client control socket path.",
    },
    GlobalFlag {
        display: "--config-file PATH",
        spellings: &["--config-file"],
        summary: "Override the config file location.",
    },
    GlobalFlag {
        display: "--timeout MS",
        spellings: &["--timeout"],
        summary: "Per-request IPC wait for the running app (default {timeout}). Bounds each socket \
                  recv/send — NOT the watch:claude block (see --block-timeout).",
    },
    GlobalFlag {
        display: "-e <cmd> [args...]",
        spellings: &["-e"],
        summary: "Launch the GUI and run <cmd> in its first pane. Terminal, per xterm: every token after it \
                  belongs to <cmd>.",
    },
    GlobalFlag {
        display: "-y / --yes",
        spellings: &["-y", "--yes"],
        summary: "Skip destructive-action confirmation prompts.",
    },
    GlobalFlag {
        display: "-h / --help",
        spellings: &["-h", "--help"],
        summary: "Show this help.",
    },
];

/// A fully-parsed `slopdesk` invocation.
#[expect(
    clippy::struct_excessive_bools,
    reason = "a record of independent CLI switches; folding them into enums would invent a relationship \
              between flags the command line does not have"
)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invocation {
    /// The first non-flag token. Empty means a bare invocation, which launches the GUI the way bare
    /// `xterm`/`alacritty`/`ghostty` do.
    pub subcommand: String,
    /// Tokens after the subcommand that are NOT recognised global flags — passed through verbatim
    /// to the per-subcommand parser.
    pub rest: Vec<String>,
    /// `--json` / `--format json`.
    pub format: OutputFormat,
    /// `--no-headers`: strip table header rows, for piping.
    pub no_headers: bool,
    /// `--socket PATH`, overriding the client control socket. `None` auto-detects.
    pub socket_path: Option<String>,
    /// `--config-file PATH`. `None` auto-detects.
    pub config_file: Option<String>,
    /// `--timeout <ms>`: how long to wait for one IPC response from the running app.
    pub timeout_ms: i64,
    /// `-y` / `--yes`: skip destructive-action confirmation prompts.
    pub assume_yes: bool,
    /// `-h` / `--help`: show usage instead of dispatching.
    pub wants_help: bool,
    /// True when this invocation should launch the client GUI: a bare invocation, or an `-e` one.
    pub launch_gui: bool,
    /// The command captured after `-e <cmd> [args…]`.
    ///
    /// `-e` does NOT local-exec — a slopdesk pane is a remote PTY — so the command is forwarded to
    /// the first pane of the freshly-launched GUI.
    pub exec_command: Option<Vec<String>>,
}

impl Default for Invocation {
    fn default() -> Self {
        Self {
            subcommand: String::new(),
            rest: Vec::new(),
            format: OutputFormat::Text,
            no_headers: false,
            socket_path: None,
            config_file: None,
            timeout_ms: DEFAULT_TIMEOUT_MS,
            assume_yes: false,
            wants_help: false,
            launch_gui: false,
            exec_command: None,
        }
    }
}

/// Why a parse failed. Returned rather than exiting, so the failures are testable too.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    /// A flag the parser does not know, seen before any subcommand.
    UnknownFlag(String),
    /// A flag that takes a value, with nothing after it.
    MissingValue(String),
    /// A flag whose value did not parse.
    InvalidValue {
        /// The flag.
        flag: String,
        /// What followed it.
        value: String,
    },
}

/// Parses the global flags and the subcommand out of `args`, including `args[0]`, which is skipped.
///
/// - The first non-flag token is the subcommand; later non-flag tokens go to `rest`.
/// - Recognised global flags are consumed wherever they appear, before OR after the subcommand.
/// - An UNRECOGNISED flag before the subcommand is an error; after it, it is a subcommand-specific
///   flag and passes through.
/// - `-e <cmd> [args…]`, only before a subcommand, is the xterm terminal-emulator flag: it launches
///   the GUI and captures the remainder verbatim. Per xterm semantics `-e` is terminal, so option
///   parsing stops after it — even for leading-dash tokens.
/// - A bare `--`, only valid after a subcommand, ends option parsing: it and everything after it
///   pass through verbatim, which is what protects literal `send-keys` text.
///
/// # Errors
/// Returns [`ParseError`] for an unknown leading flag, a flag missing its value, or a value that
/// does not parse.
pub fn parse(args: &[String]) -> Result<Invocation, ParseError> {
    let mut inv = Invocation::default();
    let mut end_of_options = false;
    let mut idx = 1; // skip argv[0]

    // A flag's value, or the error naming the flag that lacked one.
    let value_at = |idx: usize, flag: &str| -> Result<&String, ParseError> {
        args.get(idx)
            .ok_or_else(|| ParseError::MissingValue(flag.to_owned()))
    };

    while let Some(arg) = args.get(idx) {
        // After a bare `--` everything is a literal operand.
        if end_of_options {
            inv.rest.push(arg.clone());
            idx += 1;
            continue;
        }

        match arg.as_str() {
            "--json" => inv.format = OutputFormat::Json,
            "--format" => {
                idx += 1;
                let raw = value_at(idx, "--format")?;
                inv.format = match raw.as_str() {
                    "json" => OutputFormat::Json,
                    "text" | "plain" => OutputFormat::Text,
                    _ => {
                        return Err(ParseError::InvalidValue {
                            flag: "--format".to_owned(),
                            value: raw.clone(),
                        });
                    },
                };
            },
            "--no-headers" => inv.no_headers = true,
            "--socket" => {
                idx += 1;
                inv.socket_path = Some(value_at(idx, "--socket")?.clone());
            },
            "--config-file" => {
                idx += 1;
                inv.config_file = Some(value_at(idx, "--config-file")?.clone());
            },
            "--timeout" => {
                idx += 1;
                let raw = value_at(idx, "--timeout")?;
                inv.timeout_ms = match raw.parse::<i64>() {
                    Ok(ms) if ms > 0 => ms,
                    _ => {
                        return Err(ParseError::InvalidValue {
                            flag: "--timeout".to_owned(),
                            value: raw.clone(),
                        });
                    },
                };
            },
            "-y" | "--yes" => inv.assume_yes = true,
            "-e" => {
                // A launch flag only at top level; after a subcommand it is that subcommand's token.
                if inv.subcommand.is_empty() {
                    let _first = value_at(idx + 1, "-e")?;
                    // `-e` is terminal: capture every remaining token verbatim and stop parsing.
                    inv.exec_command = Some(args.get(idx + 1..).unwrap_or_default().to_vec());
                    idx = args.len();
                    continue;
                }
                inv.rest.push(arg.clone());
            },
            "-h" | "--help" => inv.wants_help = true,
            "--" => {
                // End-of-options only means something once a subcommand is known: it separates that
                // subcommand's flags from its literal operands.
                if inv.subcommand.is_empty() {
                    return Err(ParseError::UnknownFlag("--".to_owned()));
                }
                inv.rest.push(arg.clone());
                end_of_options = true;
            },
            other => {
                if other.starts_with('-') {
                    // Unrecognised: a hard error before the subcommand, a pass-through after it.
                    if inv.subcommand.is_empty() {
                        return Err(ParseError::UnknownFlag(other.to_owned()));
                    }
                    inv.rest.push(other.to_owned());
                } else if inv.subcommand.is_empty() {
                    other.clone_into(&mut inv.subcommand);
                } else {
                    inv.rest.push(other.to_owned());
                }
            },
        }
        idx += 1;
    }

    // A bare invocation, or one that stopped at `-e`, routes to the GUI.
    inv.launch_gui = inv.subcommand.is_empty() && !inv.wants_help;
    Ok(inv)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{DEFAULT_TIMEOUT_MS, GLOBAL_FLAGS, Invocation, OutputFormat, ParseError, parse};

    fn run(tokens: &[&str]) -> Result<Invocation, ParseError> {
        let mut args = vec!["slopdesk".to_owned()];
        args.extend(tokens.iter().map(|token| (*token).to_owned()));
        parse(&args)
    }

    fn ok(tokens: &[&str]) -> Invocation {
        run(tokens).expect("parses")
    }

    #[test]
    fn a_bare_invocation_launches_the_gui_the_way_a_bare_terminal_does() {
        let inv = ok(&[]);
        assert!(inv.subcommand.is_empty());
        assert!(inv.launch_gui);
        assert_eq!(inv.timeout_ms, DEFAULT_TIMEOUT_MS);
        assert_eq!(inv.format, OutputFormat::Text);
    }

    #[test]
    fn help_alone_does_not_launch_the_gui() {
        assert!(!ok(&["--help"]).launch_gui);
        assert!(ok(&["-h"]).wants_help);
    }

    #[test]
    fn the_first_non_flag_token_is_the_subcommand_and_the_rest_pass_through() {
        let inv = ok(&["panes", "list", "--wide"]);
        assert_eq!(inv.subcommand, "panes");
        assert_eq!(inv.rest, ["list", "--wide"]);
        assert!(!inv.launch_gui);
    }

    #[test]
    fn global_flags_are_consumed_before_or_after_the_subcommand() {
        let before = ok(&["--json", "panes"]);
        let after = ok(&["panes", "--json"]);
        assert_eq!(before.format, OutputFormat::Json);
        assert_eq!(after.format, OutputFormat::Json);
        assert!(after.rest.is_empty());
    }

    #[test]
    fn the_format_flag_accepts_its_three_spellings_and_rejects_the_rest() {
        assert_eq!(ok(&["--format", "json", "panes"]).format, OutputFormat::Json);
        assert_eq!(ok(&["--format", "text", "panes"]).format, OutputFormat::Text);
        assert_eq!(ok(&["--format", "plain", "panes"]).format, OutputFormat::Text);
        assert_eq!(
            run(&["--format", "yaml", "panes"]),
            Err(ParseError::InvalidValue {
                flag: "--format".to_owned(),
                value: "yaml".to_owned()
            })
        );
    }

    #[test]
    fn a_value_flag_at_the_very_end_reports_the_flag_that_lacked_one() {
        for flag in ["--format", "--socket", "--config-file", "--timeout", "-e"] {
            assert_eq!(
                run(&[flag]),
                Err(ParseError::MissingValue(flag.to_owned())),
                "{flag}"
            );
        }
    }

    #[test]
    fn the_timeout_must_be_a_positive_integer() {
        assert_eq!(ok(&["--timeout", "50", "panes"]).timeout_ms, 50);
        for bad in ["0", "-1", "soon", ""] {
            assert_eq!(
                run(&["--timeout", bad, "panes"]),
                Err(ParseError::InvalidValue {
                    flag: "--timeout".to_owned(),
                    value: bad.to_owned()
                }),
                "{bad}"
            );
        }
    }

    #[test]
    fn an_unknown_flag_is_fatal_before_the_subcommand_and_passes_through_after_it() {
        assert_eq!(
            run(&["--nope", "panes"]),
            Err(ParseError::UnknownFlag("--nope".to_owned()))
        );
        assert_eq!(ok(&["panes", "--nope"]).rest, ["--nope"]);
    }

    #[test]
    fn exec_is_terminal_and_captures_even_leading_dash_tokens() {
        let inv = ok(&["-e", "vim", "-u", "NONE", "--json"]);
        assert_eq!(
            inv.exec_command.as_deref(),
            Some(["vim", "-u", "NONE", "--json"].map(str::to_owned).as_slice())
        );
        // Option parsing stopped, so the trailing `--json` was captured, not honoured.
        assert_eq!(inv.format, OutputFormat::Text);
        assert!(inv.launch_gui);
    }

    #[test]
    fn exec_after_a_subcommand_is_that_subcommands_own_token() {
        let inv = ok(&["send-keys", "-e", "literal"]);
        assert_eq!(inv.subcommand, "send-keys");
        assert_eq!(inv.rest, ["-e", "literal"]);
        assert_eq!(inv.exec_command, None);
    }

    #[test]
    fn end_of_options_protects_literal_text_but_only_after_a_subcommand() {
        let inv = ok(&["send-keys", "--", "--json", "-y", "--"]);
        assert_eq!(inv.rest, ["--", "--json", "-y", "--"]);
        // The flags after `--` were captured, not honoured.
        assert_eq!(inv.format, OutputFormat::Text);
        assert!(!inv.assume_yes);
        assert_eq!(run(&["--"]), Err(ParseError::UnknownFlag("--".to_owned())));
    }

    #[test]
    fn the_remaining_globals_land_where_they_are_expected() {
        let inv = ok(&[
            "--no-headers",
            "--socket",
            "/tmp/sock",
            "--config-file",
            "/tmp/conf",
            "-y",
            "panes",
        ]);
        assert!(inv.no_headers);
        assert_eq!(inv.socket_path.as_deref(), Some("/tmp/sock"));
        assert_eq!(inv.config_file.as_deref(), Some("/tmp/conf"));
        assert!(inv.assume_yes);
        assert_eq!(inv.subcommand, "panes");
    }

    #[test]
    fn a_flag_value_that_looks_like_a_flag_is_still_taken_as_the_value() {
        // `--socket --json` names a (silly) socket; it does not silently enable JSON.
        let inv = ok(&["--socket", "--json", "panes"]);
        assert_eq!(inv.socket_path.as_deref(), Some("--json"));
        assert_eq!(inv.format, OutputFormat::Text);
    }

    #[test]
    fn an_empty_argv_does_not_index_past_the_program_name() {
        assert!(parse(&[]).expect("parses").launch_gui);
    }

    #[test]
    fn every_documented_global_flag_is_one_this_parser_accepts() {
        // The help text is generated from `GLOBAL_FLAGS`, so a flag renamed in the `match` above but
        // not here would leave the CLI documenting a flag it rejects with "unknown flag". Feeding
        // each spelling back through the parser is what makes that impossible rather than unlikely.
        for flag in GLOBAL_FLAGS {
            assert!(!flag.spellings.is_empty(), "{} spells nothing", flag.display);
            for spelling in flag.spellings {
                // Every value-taking flag is given one; the point is only that the token is KNOWN,
                // so an `UnknownFlag` for it is the failure and anything else is fine.
                let outcome = run(&[spelling, "value", "panes"]);
                assert_ne!(
                    outcome,
                    Err(ParseError::UnknownFlag((*spelling).to_owned())),
                    "{spelling} is documented but not accepted"
                );
            }
        }
    }

    #[test]
    fn no_global_flag_is_documented_twice() {
        let mut spellings: Vec<&str> = GLOBAL_FLAGS
            .iter()
            .flat_map(|flag| flag.spellings.iter().copied())
            .collect();
        let before = spellings.len();
        spellings.sort_unstable();
        spellings.dedup();
        assert_eq!(spellings.len(), before, "a flag spelling appears on two rows");
    }
}
