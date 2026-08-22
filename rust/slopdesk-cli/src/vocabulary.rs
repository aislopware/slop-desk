//! The `slopdesk` subcommand vocabulary: which verbs exist, which of them actually run, and what
//! each one is for.
//!
//! ## Why one table and not five lists
//! This surface used to be written down four times — the completion list here, the `printUsage()`
//! prose in `Sources/slopdesk/main.swift`, the dispatch `switch` a few hundred lines below it, and
//! an "independently authored" golden in the Swift test suite. Nothing tied them together, and the
//! failure that produced was not hypothetical: `open`, `import`, `export`, `features`,
//! `state:claude` and `ipc` tab-completed in all five shells and then exited 2 with "not available
//! yet". A completion is a promise that a verb exists; offering one that cannot run is worse than
//! offering nothing, because the user reads it as a feature and files the exit code as a bug.
//!
//! So [`SUBCOMMANDS`] carries the availability beside the name, and every consumer derives:
//! [`ready_names`] is what the shells offer, [`planned_names`] is what the dispatcher may still
//! recognise well enough to say "planned, not implemented", and [`usage`] is the help text. A verb
//! that is added, renamed or shipped moves in exactly one place, and a verb that is offered but not
//! implemented is not expressible.
//!
//! CLAUDE-ONLY: the only per-agent forms are `watch:claude` and `state:claude`. `codex` and
//! `opencode` are deliberately absent, and a test holds them out.

use crate::args::{DEFAULT_TIMEOUT_MS, GLOBAL_FLAGS};

/// Whether a verb can actually be run today.
///
/// The distinction is the whole point of the table: [`Availability::Planned`] verbs are documented
/// (a user who types one gets told it is coming rather than that it is a typo) but are never
/// offered for completion.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Availability {
    /// Implemented and dispatched. Offered for completion.
    Ready,
    /// Designed, documented, not implemented. NEVER offered for completion.
    Planned,
}

/// Which section of the help text a form belongs to, which is also what it needs to run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Group {
    /// Needs nothing running: reads a file, prints a string, resolves a path.
    Local,
    /// Dials the running app's control socket.
    App,
    /// Runs inside a pane and writes terminal escapes; no client socket.
    InPane,
}

impl Group {
    /// Every group, in the order the help text prints them.
    pub const ALL: [Self; 3] = [Self::Local, Self::App, Self::InPane];

    /// The section heading this group prints under.
    #[must_use]
    pub const fn heading(self) -> &'static str {
        match self {
            Self::Local => "Local subcommands (no running app required):",
            Self::App => "App-driving subcommands (require a running SlopDesk app):",
            Self::InPane => "In-pane subcommands (run inside a pane; no client socket required):",
        }
    }
}

/// One documented way to invoke a subcommand, with the one-line summary that follows it.
///
/// A subcommand may have several: `config` is three local forms and five app-driving ones, and they
/// print in different sections because they need different things to be running.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Form {
    /// Where this form prints, and what it needs.
    pub group: Group,
    /// The invocation as a user types it, with metavariables.
    pub invocation: &'static str,
    /// One sentence — or several, for `sidecars`, whose whole point is what it does NOT do.
    pub summary: &'static str,
}

/// One top-level verb.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Subcommand {
    /// The token a user types, and the `case` label the dispatcher matches.
    pub name: &'static str,
    /// Whether it runs today.
    pub availability: Availability,
    /// Its documented forms. EMPTY means "a dispatchable alias documented under another verb" —
    /// `windows` is `window list`, and printing both spellings twice would read as two features.
    pub forms: &'static [Form],
}

/// The whole vocabulary, in the order the help text walks it.
///
/// Order matters twice: the help prints group-major, so a verb's position decides where its forms
/// land inside each section. The plural list shortcuts (`windows`/`tabs`/`panes`) sit beside their
/// singular nouns so that a reordering cannot separate them.
pub const SUBCOMMANDS: &[Subcommand] = &[
    Subcommand {
        name: "version",
        availability: Availability::Ready,
        forms: &[Form {
            group: Group::Local,
            invocation: "version",
            summary: "Print version, build hash, and a protocol/feature summary.",
        }],
    },
    Subcommand {
        name: "completions",
        availability: Availability::Ready,
        forms: &[Form {
            group: Group::Local,
            invocation: "completions <shell>",
            summary: "Print a completion script (bash, zsh, fish, elvish, powershell).",
        }],
    },
    Subcommand {
        name: "sidecars",
        availability: Availability::Ready,
        forms: &[Form {
            group: Group::Local,
            invocation: "sidecars [--record]",
            summary: "What the last upgrade changed, per shipped binary, and what each change means. Reads \
                      MANIFEST.json against the copy recorded by the previous install; --record writes that \
                      copy (a formula's post_install runs it). Restarts nothing: hostd restarts the \
                      sidecars it owns at its next start, screend retires itself, superd is yours to \
                      restart. --manifest/--previous point at either file explicitly.",
        }],
    },
    Subcommand {
        name: "help",
        availability: Availability::Ready,
        forms: &[Form {
            group: Group::Local,
            invocation: "help",
            summary: "Print this help (the same text as -h/--help).",
        }],
    },
    Subcommand {
        name: "window",
        availability: Availability::Ready,
        forms: &[Form {
            group: Group::App,
            invocation: "windows | window list",
            summary: "List windows.",
        }],
    },
    // A dispatchable alias: `windows` is documented on the `window` row above.
    Subcommand {
        name: "windows",
        availability: Availability::Ready,
        forms: &[],
    },
    Subcommand {
        name: "tab",
        availability: Availability::Ready,
        forms: &[
            Form {
                group: Group::App,
                invocation: "tabs | tab list [--window <id>]",
                summary: "List tabs.",
            },
            Form {
                group: Group::App,
                invocation: "tab badge --kind <kind> [--tab <id>]",
                summary: "Set a tab status badge.",
            },
        ],
    },
    Subcommand {
        name: "tabs",
        availability: Availability::Ready,
        forms: &[],
    },
    Subcommand {
        name: "pane",
        availability: Availability::Ready,
        forms: &[
            Form {
                group: Group::App,
                invocation: "panes | pane list [--tab <id>]",
                summary: "List panes.",
            },
            Form {
                group: Group::App,
                invocation: "pane capture [--pane <id>] [--lines N]",
                summary: "Capture the last N lines of a pane.",
            },
            Form {
                group: Group::App,
                invocation: "pane send-keys [--pane <id>] -- \"text\" key:Enter",
                summary: "Send literal text + named keys.",
            },
        ],
    },
    Subcommand {
        name: "panes",
        availability: Availability::Ready,
        forms: &[],
    },
    Subcommand {
        name: "config",
        availability: Availability::Ready,
        forms: &[
            Form {
                group: Group::Local,
                invocation: "config path",
                summary: "Print the resolved keybind config-file path.",
            },
            Form {
                group: Group::Local,
                invocation: "config edit",
                summary: "Open the keybind config file in $EDITOR.",
            },
            Form {
                group: Group::Local,
                invocation: "config validate",
                summary: "Check the keybind config file's syntax.",
            },
            Form {
                group: Group::App,
                invocation: "config get <key>",
                summary: "Read a config key (running app).",
            },
            Form {
                group: Group::App,
                invocation: "config set <key> <value> [--reload]",
                summary: "Write a config key (live + persisted).",
            },
            Form {
                group: Group::App,
                invocation: "config unset <key>",
                summary: "Remove a config key (-y to confirm).",
            },
            Form {
                group: Group::App,
                invocation: "config show | config reload",
                summary: "Dump / broadcast-reload the running config.",
            },
        ],
    },
    Subcommand {
        name: "font",
        availability: Availability::Ready,
        forms: &[
            Form {
                group: Group::App,
                invocation: "font list [--monospace] [--family <s>] [--system|--user]",
                summary: "List fonts.",
            },
            Form {
                group: Group::App,
                invocation: "font apply \"<name>\"",
                summary: "Set the terminal font family (running app).",
            },
            Form {
                group: Group::App,
                invocation: "font import <path> [--apply]",
                summary: "Install a font into ~/Library/Fonts (optionally apply).",
            },
        ],
    },
    Subcommand {
        name: "keybind",
        availability: Availability::Ready,
        forms: &[Form {
            group: Group::App,
            invocation: "keybind list [--action <s>]",
            summary: "List keybindings.",
        }],
    },
    Subcommand {
        name: "jump",
        availability: Availability::Ready,
        forms: &[Form {
            group: Group::App,
            invocation: "jump [query] [--no-cd]",
            summary: "cd the focused pane to a frecency-ranked dir.",
        }],
    },
    Subcommand {
        name: "learn",
        availability: Availability::Ready,
        forms: &[Form {
            group: Group::App,
            invocation: "learn [path]",
            summary: "Record a directory visit (no path = focused pane cwd).",
        }],
    },
    Subcommand {
        name: "ignore",
        availability: Availability::Ready,
        forms: &[Form {
            group: Group::App,
            invocation: "ignore <path>",
            summary: "Remove a directory from the frecency database.",
        }],
    },
    Subcommand {
        name: "watch:claude",
        availability: Availability::Ready,
        forms: &[Form {
            group: Group::App,
            invocation: "watch:claude <id> [--block-timeout <ms>]",
            summary: "Block until the Claude session <id> reaches idle/closed (blocks indefinitely by \
                      default; --block-timeout bounds it). --timeout is the per-poll IPC wait, NOT the \
                      block. Exit 0 (idle/closed) · 4 (id never seen) · 9 (block timed out).",
        }],
    },
    Subcommand {
        name: "view",
        availability: Availability::Ready,
        forms: &[Form {
            group: Group::App,
            invocation: "view <path|url> [placement]",
            summary: "Read-only shim (less <path> / open <url>) in a new pane. placement: --new-tab \
                      (default) | --new-window | --left | --right | --top | --bottom.",
        }],
    },
    Subcommand {
        name: "edit",
        availability: Availability::Ready,
        forms: &[Form {
            group: Group::App,
            invocation: "edit <path|url> [placement]",
            summary: "Editor shim ($EDITOR <path>) in a new pane; same placement flags as view.",
        }],
    },
    Subcommand {
        name: "watch",
        availability: Availability::Ready,
        forms: &[Form {
            group: Group::InPane,
            invocation: "watch [-q] <cmd> [args...]",
            summary: "Run <cmd> showing a spinner→success/error badge, then notify on finish (unless \
                      -q/--quiet). Put a bare `--` before <cmd> if it contains --json/--socket/etc.",
        }],
    },
    // Everything below is DESIGNED and NOT IMPLEMENTED. Each is documented so a user who types one
    // is told it is coming, and none of them is ever offered for completion.
    Subcommand {
        name: "open",
        availability: Availability::Planned,
        forms: &[Form {
            group: Group::App,
            invocation: "open <recipe>",
            summary: "Open a .slopdeskrecipe file, or a saved recipe by name.",
        }],
    },
    Subcommand {
        name: "import",
        availability: Availability::Planned,
        forms: &[Form {
            group: Group::App,
            invocation: "import <path>",
            summary: "Import a ghostty/kitty/alacritty config.",
        }],
    },
    Subcommand {
        name: "export",
        availability: Availability::Planned,
        forms: &[Form {
            group: Group::App,
            invocation: "export <path>",
            summary: "Write the running config out in a foreign terminal's format.",
        }],
    },
    Subcommand {
        name: "features",
        availability: Availability::Planned,
        forms: &[Form {
            group: Group::Local,
            invocation: "features",
            summary: "Feature-showcase demo. Until it lands, `version` prints the feature summary.",
        }],
    },
    Subcommand {
        name: "state:claude",
        availability: Availability::Planned,
        forms: &[Form {
            group: Group::App,
            invocation: "state:claude [id]",
            summary: "Print the rolled-up Claude session state without blocking (watch:claude blocks).",
        }],
    },
    Subcommand {
        name: "ipc",
        availability: Availability::Planned,
        forms: &[Form {
            group: Group::App,
            invocation: "ipc <method> [params-json]",
            summary: "Send one raw control-protocol request and print the reply.",
        }],
    },
    // `theme` was the one verb `spec/reference__cli.md` designs and this table forgot, so it exited 2
    // as MISSPELLED while its five siblings above exited 2 as PLANNED. The distinction is the whole
    // point of `Availability`, and a designed verb reported as a typo is the worst of the three
    // answers. Switching the ACTIVE theme is not here on purpose, and the reason CHANGED under this
    // comment: it used to be `config set theme <name>`, which shipped. The theme picker, the `theme`
    // config key and the built-in catalogue were all deleted 2026-08-08 by user ruling — the app has
    // ONE appearance now (`docs/DECISIONS.md`, "the theme picker is deleted, not defaulted"). So the
    // verb stays PLANNED against a surface that would have to come back first.
    Subcommand {
        name: "theme",
        availability: Availability::Planned,
        forms: &[
            Form {
                group: Group::App,
                invocation: "theme list [--color <dark|light|all>]",
                summary: "List the themes the client can activate.",
            },
            Form {
                group: Group::App,
                invocation: "theme import <path-or-url> [--activate] [--overwrite]",
                summary: "Import a SlopDesk/iTerm2/kitty/alacritty/ghostty theme.",
            },
        ],
    },
];

/// The verbs that actually run, in table order. This is what the shells offer and what the
/// dispatcher must handle — the two ends of the promise a completion makes.
#[must_use]
pub fn ready_names() -> Vec<&'static str> {
    names_with(Availability::Ready)
}

/// The verbs that are documented but not implemented, in table order. NEVER offered for completion;
/// the dispatcher consults this only to tell "planned" apart from "misspelled".
#[must_use]
pub fn planned_names() -> Vec<&'static str> {
    names_with(Availability::Planned)
}

/// Whether the table knows `name`, and if so whether it runs. `None` is an honest typo.
#[must_use]
pub fn availability(name: &str) -> Option<Availability> {
    SUBCOMMANDS
        .iter()
        .find(|sub| sub.name == name)
        .map(|sub| sub.availability)
}

/// The names carrying one availability, in table order.
fn names_with(wanted: Availability) -> Vec<&'static str> {
    SUBCOMMANDS
        .iter()
        .filter(|sub| sub.availability == wanted)
        .map(|sub| sub.name)
        .collect()
}

/// Total width the help text wraps to. Under 80 would waste the column; over ~100 stops fitting a
/// half-screen terminal, which is where a `--help` is usually read.
const LINE_WIDTH: usize = 100;

/// The column every summary starts in. An invocation too long for it takes a line of its own rather
/// than pushing the whole page right, so one verbose form cannot re-flow the other thirty.
const SUMMARY_COLUMN: usize = 40;

/// The complete `--help` text, terminated by a trailing newline.
///
/// `program` is `argv[0]`'s last component, so a symlinked or renamed binary describes itself by
/// the name the user actually typed.
#[must_use]
pub fn usage(program: &str) -> String {
    let mut out = String::new();
    out.push_str("usage: ");
    out.push_str(program);
    out.push_str(" [global flags] <subcommand> [args...]\n       ");
    out.push_str(program);
    out.push_str("                     launch the client GUI\n       ");
    out.push_str(program);
    out.push_str(" -e <cmd> [args...]  launch the GUI and run <cmd> in the first pane (xterm-style)\n");

    for group in Group::ALL {
        let forms: Vec<&Form> = SUBCOMMANDS
            .iter()
            .filter(|sub| sub.availability == Availability::Ready)
            .flat_map(|sub| sub.forms.iter())
            .filter(|form| form.group == group)
            .collect();
        if forms.is_empty() {
            continue;
        }
        out.push('\n');
        out.push_str(group.heading());
        out.push('\n');
        for form in forms {
            push_entry(&mut out, form.invocation, form.summary);
        }
    }

    let planned: Vec<&Subcommand> = SUBCOMMANDS
        .iter()
        .filter(|sub| sub.availability == Availability::Planned)
        .collect();
    if !planned.is_empty() {
        out.push('\n');
        // Named as what it is. The previous wording — "added by later work items" — was both vaguer
        // and, because these verbs were simultaneously being offered by every shell's completion,
        // read as a description of something that already half-worked.
        out.push_str("Designed, NOT yet implemented (never offered for completion):\n");
        for sub in planned {
            for form in sub.forms {
                push_entry(&mut out, form.invocation, form.summary);
            }
        }
    }

    out.push('\n');
    out.push_str(CONFIG_NOTE);
    out.push_str("\nGlobal flags:\n");
    for flag in GLOBAL_FLAGS {
        let summary = flag.summary.replace("{timeout}", &DEFAULT_TIMEOUT_MS.to_string());
        push_entry(&mut out, flag.display, &summary);
    }
    out
}

/// The `config` split, which is the one place in this CLI where two unrelated stores wear the same
/// verb: five forms talk to the running app and three talk to a file on disk. Prose rather than a
/// table row because it is about the RELATIONSHIP between rows.
const CONFIG_NOTE: &str = "\
config: get/set/unset/show/reload target the LIVE running-app store (app keys like
font-size/theme, over the socket). path/edit/validate target the on-disk KEYBIND config
file: the app reads only its `keybind = <chord>:<action>` lines at launch — other keys in
that file are ignored, and `config validate` flags them rather than calling them valid.
";

/// One `  <invocation>    <summary>` entry, wrapped into [`SUMMARY_COLUMN`].
fn push_entry(out: &mut String, invocation: &str, summary: &str) {
    let lead = format!("  {invocation}");
    let lead_width = lead.chars().count();
    let mut wrapped = wrap(summary, LINE_WIDTH.saturating_sub(SUMMARY_COLUMN)).into_iter();
    let Some(first) = wrapped.next() else {
        out.push_str(&lead);
        out.push('\n');
        return;
    };
    out.push_str(&lead);
    if lead_width < SUMMARY_COLUMN {
        for _ in lead_width..SUMMARY_COLUMN {
            out.push(' ');
        }
        out.push_str(&first);
        out.push('\n');
    } else {
        // Too long for the column. Its own line, then the summary in the column — which keeps the
        // page's left edge where every other entry put it.
        out.push('\n');
        push_in_column(out, &first);
    }
    for line in wrapped {
        push_in_column(out, &line);
    }
}

/// One continuation line, indented to [`SUMMARY_COLUMN`].
fn push_in_column(out: &mut String, line: &str) {
    for _ in 0..SUMMARY_COLUMN {
        out.push(' ');
    }
    out.push_str(line);
    out.push('\n');
}

/// Greedy word wrap. A single word longer than `width` overflows rather than being split: every
/// over-long token in this table is a path or a flag, and hyphenating one would make it
/// un-pasteable.
fn wrap(text: &str, width: usize) -> Vec<String> {
    let mut lines = Vec::new();
    let mut current = String::new();
    for word in text.split_whitespace() {
        let fits = current.is_empty() || current.chars().count() + 1 + word.chars().count() <= width;
        if fits {
            if !current.is_empty() {
                current.push(' ');
            }
        } else {
            lines.push(std::mem::take(&mut current));
        }
        current.push_str(word);
    }
    if !current.is_empty() {
        lines.push(current);
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::{
        Availability, Group, LINE_WIDTH, SUBCOMMANDS, availability, planned_names, ready_names, usage,
    };
    use crate::completions::{Shell, script};

    #[test]
    fn no_completion_ever_offers_a_verb_that_cannot_run() {
        // THE rule this table exists for. Before it, six planned verbs tab-completed in all five
        // shells and then exited 2; a user was offered a command that could not run.
        for shell in Shell::ALL {
            let text = script(shell);
            for planned in planned_names() {
                assert!(
                    !text.contains(planned),
                    "{} offers the unimplemented `{planned}`",
                    shell.name()
                );
            }
        }
    }

    #[test]
    fn every_shell_offers_every_ready_verb() {
        for shell in Shell::ALL {
            let text = script(shell);
            for ready in ready_names() {
                assert!(text.contains(ready), "{} is missing {ready}", shell.name());
            }
        }
    }

    #[test]
    fn the_two_availabilities_partition_the_table_and_no_name_repeats() {
        let ready = ready_names();
        let planned = planned_names();
        assert_eq!(ready.len() + planned.len(), SUBCOMMANDS.len());
        let mut all: Vec<&str> = ready.iter().chain(planned.iter()).copied().collect();
        all.sort_unstable();
        let before = all.len();
        all.dedup();
        assert_eq!(all.len(), before, "a name is spelled twice");
        for name in all {
            assert!(!name.is_empty());
            assert!(!name.starts_with('-'), "{name} would parse as a flag");
        }
    }

    #[test]
    fn the_six_verbs_that_used_to_be_offered_and_could_not_run_are_planned() {
        // The reported drift, pinned by name so that "implementing" one means moving it to Ready
        // here — which is the same edit that lets the shells offer it.
        for dead in ["open", "import", "export", "features", "state:claude", "ipc"] {
            assert_eq!(
                availability(dead),
                Some(Availability::Planned),
                "{dead} changed availability without the table saying so"
            );
        }
    }

    #[test]
    fn an_unknown_verb_is_neither_ready_nor_planned() {
        assert_eq!(availability("opne"), None);
        assert_eq!(availability(""), None);
        assert_eq!(availability("watch:codex"), None);
    }

    #[test]
    fn the_table_never_names_a_non_claude_agent() {
        for sub in SUBCOMMANDS {
            for excluded in ["codex", "opencode"] {
                assert!(!sub.name.contains(excluded), "{} names {excluded}", sub.name);
            }
        }
    }

    #[test]
    fn only_an_alias_may_have_no_forms_and_every_form_belongs_to_its_verb() {
        for sub in SUBCOMMANDS {
            if sub.forms.is_empty() {
                // The plural list shortcuts are the only formless entries, and each is documented
                // on its singular noun's row.
                assert!(
                    ["windows", "tabs", "panes"].contains(&sub.name),
                    "{} has no documented form",
                    sub.name
                );
                continue;
            }
            for form in sub.forms {
                assert!(
                    form.invocation.contains(sub.name) || sub.name == "window",
                    "{}'s form `{}` never names it",
                    sub.name,
                    form.invocation
                );
                assert!(!form.summary.is_empty(), "{} has an empty summary", sub.name);
            }
        }
    }

    #[test]
    fn the_usage_text_documents_every_ready_verb_and_every_planned_one() {
        let text = usage("slopdesk");
        for sub in SUBCOMMANDS {
            if sub.forms.is_empty() {
                continue;
            }
            for form in sub.forms {
                assert!(
                    text.contains(form.invocation),
                    "usage is missing `{}`",
                    form.invocation
                );
            }
        }
    }

    #[test]
    fn the_usage_text_prints_every_section_and_the_program_name_it_was_given() {
        let text = usage("sd");
        assert!(text.starts_with("usage: sd [global flags]"));
        assert!(!text.contains("slopdesk ["), "the program name is not hardcoded");
        for group in Group::ALL {
            assert!(text.contains(group.heading()), "{group:?} section missing");
        }
        assert!(text.contains("Designed, NOT yet implemented"));
        assert!(text.contains("Global flags:"));
        assert!(text.ends_with('\n'));
    }

    #[test]
    fn the_default_timeout_is_substituted_rather_than_written_down() {
        let text = usage("slopdesk");
        assert!(
            !text.contains("{timeout}"),
            "an unsubstituted placeholder shipped"
        );
        assert!(text.contains(&crate::args::DEFAULT_TIMEOUT_MS.to_string()));
    }

    #[test]
    fn no_help_line_runs_past_the_wrap_width_unless_one_token_does() {
        for line in usage("slopdesk").lines() {
            let width = line.chars().count();
            if width <= LINE_WIDTH {
                continue;
            }
            // The only allowed overflow is a single unsplittable token — a long invocation.
            assert!(
                line.split_whitespace().count() <= 1 || line.trim_start().starts_with("  "),
                "over-wide help line: {line}"
            );
        }
    }
}
