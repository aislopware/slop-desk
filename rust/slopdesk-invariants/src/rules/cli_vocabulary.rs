//! The `slopdesk` CLI offers exactly the verbs it can run, and the docs describe that CLI.
//!
//! Ported from the deleted `check-supervisor.sh` sections 1–8, which were the largest single block
//! left in the shell. The subject is one table — `SUBCOMMANDS` in
//! `rust/slopdesk-cli/src/vocabulary.rs` — and the four other places that used to hold a copy of
//! it: the Swift face's flag parser, the completion scripts, the dispatch switch in `main.swift`,
//! and two `ui-shell` markdown sections that describe the surface in prose.
//!
//! ## What the block is actually for
//! The reported bug was six unimplemented verbs offered by all five shells, because
//! `completions.rs` held a flat `SUBCOMMANDS` array with no notion of availability. Pressing Tab
//! found them; running one exited 2. The fix made availability a FIELD, and this is the gate that
//! keeps it one field: a verb is `Ready` and dispatches, or it is `Planned` and no shell offers it,
//! and there is no third state a second list can invent.
//!
//! ## The doc half, and why it needs a gate at all
//! `docs/55 §8`'s closing lesson, verbatim: "A row in this table is a claim with no gate behind it
//! … and it decayed the same way: the port moved and the row did not." The two `## E20` sections
//! had decayed exactly that way and it was found by READING. There is nothing to compile: a
//! markdown sentence is not reachable from any target, so no suite in either language can be made
//! to fail on it. Sections 1–6 already refuse to let the CLI's four spellings drift; the doc was
//! the fifth spelling, and the only one nothing read.
//!
//! ## What is deliberately NOT covered
//! * `docs/ui-shell/spec/` is not read. Those pages are the design TARGET and specify verbs that
//!   were never built, on purpose. Gating a spec against the code would demand the spec be
//!   rewritten every time a feature is deferred, which is the opposite of what a spec is for.
//! * `COVERAGE.md`'s prose is only spot-checked. Its CLI claims are §D/§E rows in English, and the
//!   checkable part of each is "this verb had better not be Ready", which is what the last rule
//!   asserts. The reasons are not mechanically checkable and are not claimed to be.
//! * BEHAVIOUR, which is the same limit `docs/55 §8` names for the whole gate. This compares NAMES
//!   and NUMBERS. A verb that exists, dispatches, is spelled right and does the wrong thing passes
//!   here exactly as it does everywhere else.
//! * A malformed verb with a dangling family colon — the literal `state:` a BACKLOG line once wrote
//!   — is dropped by the tokeniser rather than reported, because it matches no verb SHAPE.

use std::collections::BTreeSet;

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::text;
use crate::tree::Tree;

/// The face over the flag grammar.
const SWIFT_CLI_ARGS: &str = "Sources/SlopDeskCLICore/CLIArgs.swift";
/// The face over the completion scripts.
const SWIFT_CLI_COMPLETIONS: &str = "Sources/SlopDeskCLICore/CLICompletions.swift";
/// The face over the config-file rules.
const SWIFT_CLI_CONFIG: &str = "Sources/SlopDeskCLICore/CLIConfig.swift";
/// The face over the output tables.
const SWIFT_CLI_FORMATTING: &str = "Sources/SlopDeskCLICore/CLIFormatting.swift";
/// The face over the version banner.
const SWIFT_CLI_VERSION: &str = "Sources/SlopDeskCLICore/CLIVersion.swift";
/// The face over the help page and the planned list.
const SWIFT_CLI_USAGE: &str = "Sources/SlopDeskCLICore/CLIUsage.swift";
/// The executable: a dispatch switch and nothing else.
const SWIFT_CLI_MAIN: &str = "Sources/slopdesk/main.swift";

/// The one table.
const RUST_CLI_VOCAB: &str = "rust/slopdesk-cli/src/vocabulary.rs";
/// Where the flag grammar and its help sit together.
const RUST_CLI_ARGS: &str = "rust/slopdesk-cli/src/args.rs";
/// The module that must own no list.
const RUST_CLI_COMPLETIONS: &str = "rust/slopdesk-cli/src/completions.rs";
/// Where `watch:claude`'s documented exit codes actually live.
const RUST_WATCH: &str = "rust/slopdesk-agent/src/watch.rs";

/// The two `ui-shell` docs that describe the CLI in prose.
const UI_SHELL_DOCS: [&str; 2] = ["docs/ui-shell/BACKLOG.md", "docs/ui-shell/USER-STORIES.md"];
/// The shipped-vs-not ledger.
const UI_SHELL_COVERAGE: &str = "docs/ui-shell/COVERAGE.md";
/// The one heading both docs spell.
const E20_HEADING: &str = "## E20 — CLI parity + watch + first-launch";
/// The marker a line must carry to name an unbuilt verb. One literal, so a doc cannot half-say it.
const E20_UNBUILT: &str = "NOT YET IMPLEMENTED";

/// The CLI's core is `rust/slopdesk-cli`, and each face still calls it
///
/// `rust/slopdesk-cli` was written for this port and then left unlinked on a rule — "a port ships
/// over a socket, never FFI" — that `CLAUDE.md` has since replaced with "or as a linked library,
/// pick by lifetime". A CLI starts, does one thing and exits, so it is in-process by necessity: the
/// crate is linked and `SlopDeskCLICore` is the face over it.
///
/// The FLAG GRAMMAR, the completion SCRIPTS, the CONFIG-file rules, the output TABLES and the
/// version BANNER. Each is a place a second parser grows back one convenience at a time, so each is
/// checked from both sides: the door is still called, AND the face does not respell what the door
/// answers. A door-only check passes a face that calls the crate and then ignores it.
///
/// `--config-file` is named among the banned strings because the flag STRING is the parser's, not
/// the face's; the XDG path and the feature line because a second copy of either is a CLI that
/// disagrees with the file the app actually reads.
#[must_use]
pub fn the_cli_core_is_one_law(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Doors {
            path: SWIFT_CLI_ARGS,
            entries: &["slopdesk_cli_default_timeout_ms", "slopdesk_cli_parse"],
            message: "CLIArgs.swift no longer calls {entry} — the CLI's core is rust/slopdesk-cli",
        },
        Claim::Doors {
            path: SWIFT_CLI_COMPLETIONS,
            entries: &[
                "slopdesk_cli_shell",
                "slopdesk_cli_subcommands",
                "slopdesk_cli_completion_script",
            ],
            message: "CLICompletions.swift no longer calls {entry} — the CLI's core is rust/slopdesk-cli",
        },
        Claim::Doors {
            path: SWIFT_CLI_CONFIG,
            entries: &[
                "slopdesk_cli_config_env_key",
                "slopdesk_cli_config_path",
                "slopdesk_cli_config_default_path",
                "slopdesk_cli_config_validate",
            ],
            message: "CLIConfig.swift no longer calls {entry} — the CLI's core is rust/slopdesk-cli",
        },
        Claim::Doors {
            path: SWIFT_CLI_FORMATTING,
            entries: &[
                "slopdesk_cli_table",
                "slopdesk_cli_render_table",
                "slopdesk_cli_render_json",
            ],
            message: "CLIFormatting.swift no longer calls {entry} — the CLI's core is rust/slopdesk-cli",
        },
        Claim::Doors {
            path: SWIFT_CLI_VERSION,
            entries: &["slopdesk_cli_build_hash_env_key", "slopdesk_cli_version_summary"],
            message: "CLIVersion.swift no longer calls {entry} — the CLI's core is rust/slopdesk-cli",
        },
        Claim::Lacks {
            path: SWIFT_CLI_ARGS,
            pattern: r#"case "--(socket|timeout|format|no-headers|config-file)"|"-e""#,
            view: View::Statements,
            message: "CLIArgs.swift matches flag strings again — the grammar lives in args.rs",
        },
        Claim::Lacks {
            path: SWIFT_CLI_COMPLETIONS,
            pattern: r#""(bash|zsh|fish|elvish|powershell|pwsh)"|complete -F|compdef"#,
            view: View::Statements,
            message: "CLICompletions.swift spells a shell name or a script again — those live in \
                      completions.rs",
        },
        Claim::Lacks {
            path: SWIFT_CLI_CONFIG,
            pattern: r"\.config/slopdesk|config\.toml|keybind = ",
            view: View::Statements,
            message: "CLIConfig.swift spells the XDG path or the keybind grammar again — those live in \
                      config.rs",
        },
        Claim::Lacks {
            path: SWIFT_CLI_FORMATTING,
            pattern: r#"padding|repeating: " "|widths\[|joined\(separator: "  "\)"#,
            view: View::Statements,
            message: "CLIFormatting.swift pads a column again — the table renderer is formatting.rs",
        },
        Claim::Lacks {
            path: SWIFT_CLI_VERSION,
            pattern: r"remote-terminal|gui-video|read-only-inspector|terminal protocol v",
            view: View::Statements,
            message: "CLIVersion.swift spells the banner again — its shape lives in version.rs",
        },
    ])
}

/// The help page, the completion list and the flag help each live in exactly one place
///
/// Four claims that were sections 1, 2, 5 and 6 of the shell gate.
///
/// **The face calls the door.** If `CLIUsage.swift` stops calling `slopdesk_cli_usage` or
/// `slopdesk_cli_planned_subcommands`, it has grown its own help renderer or its own planned list,
/// which is a second table by another name.
///
/// **`main.swift` PRINTS the crate's help; it does not write one.** Catches someone re-adding a
/// `printUsage()` heredoc, which is where the help text drifted from the completions the first
/// time. The section HEADINGS are the fingerprint of that block — they can only appear in a file
/// rendering the page itself — and they are matched WITH their parentheticals, so the
/// `// MARK: - Local subcommands` divider cannot be mistaken for the page.
///
/// **The completions module owns no list of its own.** This is the exact regression the whole
/// change undoes: a flat `SUBCOMMANDS` array in `completions.rs` with no notion of availability.
///
/// **The flag help sits beside the grammar.** A help page that documents a flag the parser rejects
/// is the same drift from the other end. The flag STRINGS live in `args.rs` next to the `match`
/// that consumes them, and a test there feeds every documented spelling back through `parse`; a
/// `GLOBAL_FLAGS` table anywhere else is a second copy of that fact.
#[must_use]
pub fn the_cli_help_has_one_author(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Doors {
            path: SWIFT_CLI_USAGE,
            entries: &["slopdesk_cli_usage", "slopdesk_cli_planned_subcommands"],
            message: "CLIUsage.swift no longer calls {entry} — the CLI's vocabulary is rust/slopdesk-cli's",
        },
        Claim::Names {
            path: SWIFT_CLI_MAIN,
            needle: "CLIUsage.text(",
            message: "main.swift no longer prints CLIUsage.text — the help text lives in vocabulary.rs",
        },
        Claim::Lacks {
            path: SWIFT_CLI_MAIN,
            pattern: r"Local subcommands \(no running app|App-driving subcommands \(require|In-pane \
                      subcommands \(run inside|^ *Global flags:",
            view: View::Statements,
            message: "main.swift spells a help-page section again — the whole page is rendered by \
                      vocabulary.rs",
        },
        Claim::Lacks {
            path: RUST_CLI_COMPLETIONS,
            pattern: r"const SUBCOMMANDS",
            view: View::Code,
            message: "completions.rs holds a subcommand array again — the list, its availability and its \
                      help text are one table in vocabulary.rs",
        },
        Claim::Names {
            path: RUST_CLI_ARGS,
            needle: "GLOBAL_FLAGS",
            message: "args.rs no longer carries GLOBAL_FLAGS — the flag help must sit beside the grammar it \
                      describes",
        },
        Claim::Lacks {
            path: SWIFT_CLI_MAIN,
            pattern: r#""--no-headers"|"--config-file"|"--socket PATH""#,
            view: View::Statements,
            message: "main.swift spells a global flag again — the grammar and its help are args.rs's",
        },
    ])
}

/// The dispatch switch covers exactly the verbs the shells offer — no more, no fewer
///
/// THE ONE THAT WOULD HAVE CAUGHT THE BUG, in both directions:
///
/// * a verb marked `Ready` in the table with no `case` in `main.swift` ⇒ a completion that exits 2,
///   which is the reported drift;
/// * a `case` in `main.swift` for a verb the table calls `Planned` or does not list ⇒ a command
///   that works but that no shell will ever complete, so nobody finds it.
///
/// `help` is excluded from the set comparison and asserted separately: it is handled ABOVE the
/// switch, because `--help` has to win over the GUI launch, so it is matched by a
/// `subcommand == "help"` guard rather than a `case` label. Excluding it without checking the guard
/// would make it silently exempt.
///
/// Only the TOP-LEVEL switch's labels count — `case "x":` in column 0, which is what a `switch` in
/// a `main.swift` script file produces. Nested per-subcommand switches are indented, so they cannot
/// be picked up here.
#[must_use]
pub fn the_dispatch_switch_matches_availability(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(vocabulary) = report.source(tree, RUST_CLI_VOCAB, "the one CLI table lives there") else {
        return report;
    };
    let Some(main) = report.source(tree, SWIFT_CLI_MAIN, "the dispatch switch lives there") else {
        return report;
    };

    let ready = availability(&vocabulary.text, Availability::Ready);
    let planned = availability(&vocabulary.text, Availability::Planned);
    // A GATE WHOSE HAYSTACK IS EMPTY PASSES EVERY BAN AT ONCE. Both extractions are the kind that go
    // quiet when `vocabulary.rs` is reformatted, and every rule below reads one of them.
    if ready.is_empty() || planned.is_empty() {
        report.fail(format!(
            "{RUST_CLI_VOCAB}: one availability list read as EMPTY ({} Ready, {} Planned) — the checks \
             below would pass by having nothing to check",
            ready.len(),
            planned.len()
        ));
        return report;
    }

    let dispatchable: BTreeSet<&str> = ready
        .iter()
        .map(String::as_str)
        .filter(|name| *name != "help")
        .collect();
    let dispatched = text::capture_set(main.code(), r#"^case "([^"]+)""#);
    let dispatched: BTreeSet<&str> = dispatched.iter().map(String::as_str).collect();
    if dispatchable != dispatched {
        let undispatched: Vec<&str> = dispatchable.difference(&dispatched).copied().collect();
        let unlisted: Vec<&str> = dispatched.difference(&dispatchable).copied().collect();
        report.fail(format!(
            "{SWIFT_CLI_MAIN} dispatches a different set than vocabulary.rs calls Ready — Ready with no \
             case (a completion that exits 2): [{}]; dispatched but not Ready (a verb no shell will ever \
             offer): [{}]",
            undispatched.join(", "),
            unlisted.join(", ")
        ));
    }
    report.fail_if(
        !text::matches(main.code(), r#"invocation\.subcommand == "help""#),
        format!("{SWIFT_CLI_MAIN} no longer routes 'help' — it is Ready in vocabulary.rs and must dispatch"),
    );

    // No planned verb may be reachable by pressing Tab, or by typing it.
    for verb in &planned {
        if text::matches(main.code(), &format!(r#"^case "{}""#, regex::escape(verb))) {
            report.fail(format!(
                "{SWIFT_CLI_MAIN} dispatches '{verb}', which vocabulary.rs still calls Planned — move it to \
                 Availability::Ready in the same change, or the shells will never offer it"
            ));
        }
    }
    report
}

/// The `ui-shell` docs describe the CLI the crate actually ships
///
/// `docs/ui-shell/BACKLOG.md` and `docs/ui-shell/USER-STORIES.md` each carry an
/// `## E20 — CLI parity + watch + first-launch` section naming the shipped surface in prose: which
/// verbs there are, which of them run, which flags they take, and what `watch:claude` exits with.
/// All four are written down for real in `vocabulary.rs` (`SUBCOMMANDS`, each `Subcommand`'s
/// `availability`, each `Form`'s `invocation`), in `args.rs` (`GLOBAL_FLAGS`) and in `watch.rs`
/// (`WatchExit`). This compares the prose against those, both ways.
///
/// The three decayed claims it was written for: a `theme` verb that does not exist in ANY
/// availability, so a user who types it is told it is a typo rather than told it is coming; `open`
/// presented as driving the running app when it is `Planned` and exits 2; and a Scope line ending
/// "`state:`/`ipc` (done)" about two verbs that have never dispatched.
///
/// ## The two halves take different units, and the asymmetry is the rule
/// The "is the reader WARNED?" half asks per BULLET, because both docs wrap a story entry across
/// several lines and the marker can only be written once — judging line-by-line failed seven times
/// on one honest entry whose continuation lines each name a Planned verb while the marker sits
/// above them. That is a doc EXPLAINING the verb is Planned, wrapped at 110 columns.
///
/// The "is a SHIPPED verb wrongly filed as unbuilt?" half stays per LINE. Widening it to the bullet
/// would break it: a legitimate entry saying "X is not implemented, but Y ships" puts the marker
/// and the shipped verb in one bullet. The filing is done by the line that does it.
#[must_use]
pub fn the_ui_shell_docs_describe_the_shipped_cli(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(vocabulary) = report.source(tree, RUST_CLI_VOCAB, "the one CLI table lives there") else {
        return report;
    };

    let vocab_words = vocabulary_words(&vocabulary.text);
    // The allowlist the unknown-word rule compares against. An empty one makes every correct token
    // in both docs a finding, which is the failure that matters most here.
    if vocab_words.len() < 20 {
        report.fail(format!(
            "{RUST_CLI_VOCAB}: read fewer than 20 vocabulary words ({}) — the extraction has gone stale, so \
             the unknown-word rule is comparing the ui-shell docs against nothing",
            vocab_words.len()
        ));
        return report;
    }
    let ready = availability(&vocabulary.text, Availability::Ready);
    let planned = availability(&vocabulary.text, Availability::Planned);
    if ready.is_empty() || planned.is_empty() {
        report.fail(format!(
            "{RUST_CLI_VOCAB}: one availability list read as EMPTY — the doc rules would pass by having \
             nothing to check"
        ));
        return report;
    }

    let cli_flags = flag_spellings(tree, &mut report, &vocabulary.text);
    let watch_codes = exit_codes(tree, &mut report);

    for doc in UI_SHELL_DOCS {
        let Some(source) = report.source(tree, doc, "one of the two E20 sections lives there") else {
            continue;
        };
        let Some(section) = e20_section(&source.text) else {
            // Named, not assumed: the heading is a literal in a file this rule does not own, and a
            // doc that renames or drops it would empty the corpus and pass every rule in silence.
            report.fail(format!(
                "{doc} has no '{E20_HEADING}' section — the four rules below read an empty corpus and pass"
            ));
            continue;
        };

        // A verb the docs name is a verb the vocabulary knows. CATCHES the `theme` bug: a doc naming
        // a subcommand that is in no availability at all, so it is not merely unbuilt.
        let unknown: Vec<&str> = cli_tokens(&section)
            .into_iter()
            .filter(|token| !vocab_words.contains(token.as_str()))
            .collect::<Vec<_>>()
            .iter()
            .map(|owned| text::intern(owned.clone()))
            .collect();
        if !unknown.is_empty() {
            report.fail(format!(
                "{doc} §E20 names CLI words {RUST_CLI_VOCAB} does not know: {}",
                unknown.join(", ")
            ));
        }

        // A SHIPPED verb filed under the unbuilt marker — per LINE. This is the direction that goes
        // stale on the day a verb ships: a `Planned` entry promoted to `Ready` leaves a doc line
        // still filing it under "not yet".
        for line in section.lines().filter(|line| line.contains(E20_UNBUILT)) {
            let shipped: Vec<String> = cli_tokens(line)
                .into_iter()
                .filter(|token| ready.contains(token))
                .collect();
            if !shipped.is_empty() {
                report.fail(format!(
                    "{doc} §E20 files verbs under {E20_UNBUILT} that dispatch today: {} — on: {}",
                    shipped.join(", "),
                    truncated(line)
                ));
            }
        }

        // A PLANNED verb presented as working — per BULLET.
        for bullet in bullets(&section).iter().filter(|b| !b.contains(E20_UNBUILT)) {
            let promised: Vec<String> = cli_tokens(bullet)
                .into_iter()
                .filter(|token| planned.contains(token))
                .collect();
            if !promised.is_empty() {
                report.fail(format!(
                    "{doc} §E20 presents Planned verbs as working (no \"{E20_UNBUILT}\" in the entry): {} — \
                     on: {}",
                    promised.join(", "),
                    truncated(bullet)
                ));
            }
        }

        // A flag the docs name is a flag the CLI parses. CATCHES a doc promising `--colour` or a
        // renamed `--kind`. A bare `--` end-of-options marker is not a flag and matches nothing.
        if let Some(known) = cli_flags.as_ref() {
            let stray: Vec<String> = doc_flags(&section)
                .into_iter()
                .filter(|flag| !known.contains(flag))
                .collect();
            if !stray.is_empty() {
                report.fail(format!(
                    "{doc} §E20 names flags the CLI does not parse: {}",
                    stray.join(", ")
                ));
            }
        }

        // The exit codes the docs quote are the ones the state machine produces. `watch:claude` is
        // the only verb in the tree with a documented exit-code contract, both docs quote it as
        // `0/4/9`, and a renumbering is invisible to every caller — a script testing `$? == 4`
        // simply stops branching.
        if let (Some(rust), Some(quoted)) = (watch_codes.as_ref(), doc_exit_codes(&section)) {
            report.fail_if(
                &quoted != rust,
                format!("{doc} §E20 quotes watch:claude exit codes {quoted}; WatchExit is {rust}"),
            );
        }
    }

    coverage_ledger(tree, &mut report, &ready, &planned);
    report
}

/// Which half of the table a name was filed under.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Availability {
    /// It dispatches today.
    Ready,
    /// It is carried so a user is told it is coming, and exits 2.
    Planned,
}

/// Every `Subcommand.name` filed under one availability.
///
/// STATE, not a pattern, and that is why it is written out rather than being an [`Extract`]: the
/// `name:` line and the `availability:` line are different lines, so a stateless match can read the
/// names or the availabilities but never the pairing. The walk carries a pending name and the
/// availability line either claims it or clears it, which is exactly what the shell's `awk` did.
///
/// [`Extract`]: crate::claim::Extract
fn availability(vocabulary: &str, wanted: Availability) -> BTreeSet<String> {
    let name = text::cached(r#"^ *name: "([^"]*)",?$"#);
    let mut found = BTreeSet::new();
    let mut pending: Option<String> = None;
    for line in vocabulary.lines() {
        if let Some(caps) = name.captures(line) {
            pending = caps.get(1).map(|matched| matched.as_str().to_owned());
            continue;
        }
        let seen = if line.contains("Availability::Ready") {
            Some(Availability::Ready)
        } else if line.contains("Availability::Planned") {
            Some(Availability::Planned)
        } else {
            None
        };
        let Some(seen) = seen else { continue };
        // The pending name is CLAIMED by whichever availability line reaches it first, whether or
        // not that is the half being collected. Taking it unconditionally is what makes the two
        // calls PARTITION the table: leave it pending on a mismatch and the next entry's
        // availability line would file the previous entry's name under the wrong half.
        let claimed = pending.take();
        if seen == wanted
            && let Some(claimed) = claimed
        {
            found.insert(claimed);
        }
    }
    found
}

/// The words a doc token is allowed to be.
///
/// Every `Subcommand.name`, PLUS every word of every `Form.invocation` — the second half is what
/// makes `config get`, `pane capture` and `font apply` legal without any list in this gate.
fn vocabulary_words(vocabulary: &str) -> BTreeSet<String> {
    let mut words = BTreeSet::new();
    for pattern in [r#"^ *name: "([^"]+)",?$"#, r#"^ *invocation: "([^"]*)""#] {
        for spelling in text::capture_all(vocabulary, pattern) {
            words.extend(verb_shaped(&spelling));
        }
    }
    words
}

/// Every CLI-shaped token inside a backtick span.
///
/// Spans holding a `.` are dropped WHOLE — those are file paths (`spec/reference__cli.md`,
/// `vocabulary.rs`), never invocations — and so is the program's own name in either spelling.
/// What survives is a lowercase word, optionally with one `:family` suffix: `pane`, `send-keys`,
/// `watch:claude`.
fn cli_tokens(text_body: &str) -> BTreeSet<String> {
    let mut tokens = BTreeSet::new();
    for span in backtick_spans(text_body) {
        if span.contains('.') {
            continue;
        }
        tokens.extend(
            verb_shaped(&span)
                .into_iter()
                .filter(|word| word != "slopdesk" && !word.starts_with("slopdesk-")),
        );
    }
    tokens
}

/// Every long flag spelled inside a backtick span, whether or not the span is a path.
///
/// Separate from [`cli_tokens`] because it was a separate pipeline in the shell, and the difference
/// matters: a flag written beside a filename in one span is still a flag the docs promise.
fn doc_flags(text_body: &str) -> BTreeSet<String> {
    let flag = text::cached(r"(--[a-z][a-z-]*)");
    backtick_spans(text_body)
        .iter()
        .flat_map(|span| {
            flag.captures_iter(span)
                .filter_map(|caps| caps.get(1).map(|m| m.as_str().to_owned()))
                .collect::<Vec<_>>()
        })
        .collect()
}

/// The contents of every `` ` ``-delimited span, backticks removed.
fn backtick_spans(text_body: &str) -> Vec<String> {
    let mut spans = Vec::new();
    let mut rest = text_body;
    while let Some(open) = rest.find('`') {
        let after = &rest[open + 1..];
        let Some(close) = after.find('`') else { break };
        spans.push(after[..close].to_owned());
        rest = &after[close + 1..];
    }
    spans
}

/// A phrase split into verb-shaped words: metavariables stripped, `/ | ,` treated as separators.
///
/// The separators are how both docs and the vocabulary write an alternation — `config get/set/
/// reload`, `tab/pane/window` — so splitting on them is what makes a span naming three verbs read
/// as three verbs rather than one unknown word.
fn verb_shaped(phrase: &str) -> Vec<String> {
    let metavariable = text::cached(r"<[^>]*>");
    let shape = text::cached(r"^[a-z][a-z0-9-]*(:[a-z0-9]+)?$");
    metavariable
        .replace_all(phrase, "")
        .split(['/', '|', ',', ' ', '\t'])
        .filter(|word| shape.is_match(word))
        .map(str::to_owned)
        .collect()
}

/// The `## E20` section of one doc: everything after the heading, up to the next `## `.
fn e20_section(doc: &str) -> Option<String> {
    let mut lines = doc.lines().skip_while(|line| *line != E20_HEADING);
    lines.next()?;
    Some(
        lines
            .take_while(|line| !line.starts_with("## "))
            .collect::<Vec<_>>()
            .join("\n"),
    )
}

/// The section's bullets. A bullet starts at `- ` in column 1; anything else continues the one
/// above.
fn bullets(section: &str) -> Vec<String> {
    let mut entries: Vec<String> = Vec::new();
    for line in section.lines() {
        match entries.last_mut() {
            Some(open) if !line.starts_with("- ") => {
                open.push(' ');
                open.push_str(line);
            },
            _ => entries.push(line.to_owned()),
        }
    }
    entries
}

/// Every flag spelling the CLI parses, or `None` when neither side read.
///
/// The universe is `GLOBAL_FLAGS`' spellings — which `args.rs`'s own test feeds back through
/// `parse` — plus every flag spelled in a `Form.invocation`.
fn flag_spellings(tree: &Tree, report: &mut Report, vocabulary: &str) -> Option<BTreeSet<String>> {
    let args = report.source(tree, RUST_CLI_ARGS, "the flag grammar lives there")?;
    let mut flags = text::capture_set(&args.text, r#""(--[a-z][a-z-]*)""#);
    let invocation_flag = text::cached(r"(--[a-z][a-z-]*)");
    for spelling in text::capture_all(vocabulary, r#"^ *invocation: "([^"]*)""#) {
        flags.extend(
            invocation_flag
                .captures_iter(&spelling)
                .filter_map(|caps| caps.get(1).map(|m| m.as_str().to_owned())),
        );
    }
    if flags.is_empty() {
        report.fail(
            "no flag spellings read from rust/slopdesk-cli — the ui-shell flag rule compares the docs \
             against nothing"
                .to_owned(),
        );
        return None;
    }
    Some(flags)
}

/// `WatchExit`'s discriminants, joined the way both docs quote them.
fn exit_codes(tree: &Tree, report: &mut Report) -> Option<String> {
    let watch = report.source(tree, RUST_WATCH, "watch:claude's exit contract lives there")?;
    let codes: BTreeSet<String> = text::capture_set(&watch.text, r"^ *[A-Z][A-Za-z]* = ([0-9]+),$");
    if codes.is_empty() {
        report.fail(format!(
            "{RUST_WATCH}: no WatchExit discriminants read — the exit-code rule compares nothing"
        ));
        return None;
    }
    Some(codes.into_iter().collect::<Vec<_>>().join("/"))
}

/// The exit codes a section quotes, or `None` when it quotes none.
fn doc_exit_codes(section: &str) -> Option<String> {
    let phrase = text::cached(r"exit[- ]codes? ([0-9](?:/[0-9])+)|exit ([0-9](?:/[0-9])+)");
    let quoted: BTreeSet<String> = phrase
        .captures_iter(section)
        .filter_map(|caps| caps.get(1).or_else(|| caps.get(2)))
        .flat_map(|matched| matched.as_str().split('/').map(str::to_owned).collect::<Vec<_>>())
        .collect();
    if quoted.is_empty() {
        return None;
    }
    Some(quoted.into_iter().collect::<Vec<_>>().join("/"))
}

/// `COVERAGE.md`'s non-build rows may not name a verb that ships.
///
/// §D files `ipc` and `state:<agent>` as "deferred in source"; §E files `slopdesk import`/`export`
/// under "INTENTIONALLY NOT BUILT — do NOT implement". Both are the deferral record the rest of the
/// repo reads before deciding something is a gap, so the day one of them ships they stop being a
/// record and become an instruction to un-build it.
///
/// Only the checkable half is asserted — "not Ready". `state:claude` is spelled here rather than
/// §D's `state:<agent>`: the vocabulary is Claude-only by design, and the last ban re-states that
/// from this side so a doc that is right today cannot be made wrong by a verb.
fn coverage_ledger(tree: &Tree, report: &mut Report, ready: &BTreeSet<String>, planned: &BTreeSet<String>) {
    /// The four rows, each spelled as the vocabulary would spell the verb.
    const DEFERRED: [&str; 4] = ["ipc", "import", "export", "state:claude"];

    let Some(coverage) = report.source(tree, UI_SHELL_COVERAGE, "the deferral record lives there") else {
        return;
    };
    for deferred in DEFERRED {
        report.fail_if(
            ready.contains(deferred),
            format!(
                "{UI_SHELL_COVERAGE} files '{deferred}' as deferred/not-built, but {RUST_CLI_VOCAB} now \
                 calls it Ready — the coverage ledger is what a future session reads before deciding it is \
                 a gap"
            ),
        );
        let row = deferred.split(':').next().unwrap_or(deferred);
        report.fail_if(
            !coverage.text.contains(row),
            format!("{UI_SHELL_COVERAGE} no longer mentions '{row}' — the row this gate reads is gone"),
        );
    }
    let per_agent: Vec<&str> = ready
        .iter()
        .chain(planned)
        .map(String::as_str)
        .filter(|name| name.contains("codex") || name.contains("opencode"))
        .collect();
    report.fail_if(
        !per_agent.is_empty(),
        format!(
            "{RUST_CLI_VOCAB} grew a codex/opencode verb ({}) — {UI_SHELL_COVERAGE} §D scopes agents to \
             Claude Code, and a per-agent verb is the one thing that would silently make that row false",
            per_agent.join(", ")
        ),
    );
}

/// A doc line cut to the width the shell printed, so one wrapped bullet cannot fill the log.
fn truncated(line: &str) -> String {
    line.chars().take(120).collect()
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A vocabulary in the shape the real one has: `invocation:` on its own line, so the word floor
    /// reads what a reformat would take away.
    const VOCABULARY: &str = r#"
pub const SUBCOMMANDS: &[Subcommand] = &[
    Subcommand {
        name: "pane",
        availability: Availability::Ready,
        forms: &[
            Form {
                invocation: "panes | pane list [--tab <id>]",
            },
            Form {
                invocation: "pane capture --lines <N>",
            },
        ],
    },
    Subcommand {
        name: "watch:claude",
        availability: Availability::Ready,
        forms: &[
            Form {
                invocation: "watch:claude --block-timeout <MS>",
            },
        ],
    },
    Subcommand {
        name: "help",
        availability: Availability::Ready,
        forms: &[
            Form {
                invocation: "help",
            },
        ],
    },
    Subcommand {
        name: "ipc",
        availability: Availability::Planned,
        forms: &[
            Form {
                invocation: "ipc send/recv <MSG>",
            },
        ],
    },
    Subcommand {
        name: "export",
        availability: Availability::Planned,
        forms: &[
            Form {
                invocation: "export <PATH>",
            },
        ],
    },
    Subcommand {
        name: "config",
        availability: Availability::Ready,
        forms: &[
            Form {
                invocation: "config get/set/reload <KEY>",
            },
        ],
    },
    Subcommand {
        name: "jump",
        availability: Availability::Ready,
        forms: &[
            Form {
                invocation: "jump --no-cd <NAME>",
            },
        ],
    },
    Subcommand {
        name: "font",
        availability: Availability::Ready,
        forms: &[
            Form {
                invocation: "font apply/list --family <NAME>",
            },
        ],
    },
    Subcommand {
        name: "tab",
        availability: Availability::Ready,
        forms: &[
            Form {
                invocation: "tab new/close/select <N>",
            },
        ],
    },
];
"#;

    const MAIN: &str = r#"
if invocation.subcommand == "help" { print(CLIUsage.text()) }
switch invocation.subcommand {
case "pane": runPane()
case "watch:claude": runWatch()
case "config": runConfig()
case "jump": runJump()
case "font": runFont()
case "tab": runTab()
default: exit(2)
}
"#;

    fn crate_side(fixture: &Fixture) {
        fixture
            .write(super::RUST_CLI_VOCAB, VOCABULARY)
            .write(super::SWIFT_CLI_MAIN, MAIN)
            .write(
                super::RUST_CLI_ARGS,
                "pub const GLOBAL_FLAGS: &[GlobalFlag] = &[];\nmatch flag { \"--json\" => {}, \"--socket\" \
                 => {} }\n",
            )
            .write(
                super::RUST_WATCH,
                "enum WatchExit {\n    Settled = 0,\n    NeverSeen = 4,\n    TimedOut = 9,\n}\n",
            );
    }

    /// A section both docs can carry, describing exactly the fixture vocabulary.
    fn section(extra: &str) -> String {
        format!(
            "# Doc\n\n{}\n\n- `pane capture` and `config get/set/reload` ship; exit codes 0/4/9 for \
             `watch:claude`.\n- `ipc` — NOT YET IMPLEMENTED.\n- `jump --no-cd` and `font apply` \
             ship.\n{extra}\n\n## E21 — next\n\nafter\n",
            super::E20_HEADING
        )
    }

    fn docs(fixture: &Fixture, extra: &str) {
        for doc in super::UI_SHELL_DOCS {
            fixture.write(doc, &section(extra));
        }
        fixture.write(
            super::UI_SHELL_COVERAGE,
            "§D ipc, state:<agent> deferred in source.\n§E import / export INTENTIONALLY NOT BUILT.\n",
        );
    }

    #[test]
    fn the_dispatch_switch_and_the_table_agree() {
        let fixture = Fixture::new("cli-vocabulary-dispatch");
        crate_side(&fixture);
        assert!(super::the_dispatch_switch_matches_availability(&fixture.tree()).is_clean());

        // A Ready verb with no case — the reported bug: a completion that exits 2.
        fixture.write(
            super::SWIFT_CLI_MAIN,
            &MAIN.replace("case \"font\": runFont()\n", ""),
        );
        let report = super::the_dispatch_switch_matches_availability(&fixture.tree());
        assert!(!report.is_clean());
        assert!(
            report.violations()[0].contains("font"),
            "{:?}",
            report.violations()
        );

        // A Planned verb that dispatches — the same drift from the other end.
        fixture.write(
            super::SWIFT_CLI_MAIN,
            &MAIN.replace("default: exit(2)", "case \"ipc\": runIpc()\ndefault: exit(2)"),
        );
        let report = super::the_dispatch_switch_matches_availability(&fixture.tree());
        assert!(!report.is_clean());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("still calls Planned")),
            "{:?}",
            report.violations()
        );

        // `help` is excluded from the set comparison, so its guard is checked on its own.
        fixture.write(
            super::SWIFT_CLI_MAIN,
            &MAIN.replace("invocation.subcommand == \"help\"", "false"),
        );
        assert!(!super::the_dispatch_switch_matches_availability(&fixture.tree()).is_clean());
    }

    /// A reformatted table reads as no table at all, and every rule downstream passes.
    #[test]
    fn an_unreadable_vocabulary_fails_rather_than_passing() {
        let fixture = Fixture::new("cli-vocabulary-stale");
        crate_side(&fixture);
        fixture.write(super::RUST_CLI_VOCAB, &VOCABULARY.replace("name:", "nom:"));
        assert!(!super::the_dispatch_switch_matches_availability(&fixture.tree()).is_clean());
        assert!(!super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_docs_are_held_against_the_table() {
        let fixture = Fixture::new("cli-vocabulary-docs");
        crate_side(&fixture);
        docs(&fixture, "");
        assert!(
            super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree()).is_clean(),
            "{:?}",
            super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree()).violations()
        );

        // The `theme` bug: a verb in no availability at all, so a user is told it is a typo.
        docs(&fixture, "- `theme list` styles the terminal.");
        let report = super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("does not know")),
            "{:?}",
            report.violations()
        );

        // The `open` bug: a Planned verb presented as working, with no marker in the entry.
        docs(&fixture, "- `ipc` drives the running app.");
        let report = super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("presents Planned verbs as working")),
            "{:?}",
            report.violations()
        );

        // The other direction: a shipped verb filed under the unbuilt marker.
        docs(&fixture, "- `tab` — NOT YET IMPLEMENTED.");
        let report = super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("that dispatch today")),
            "{:?}",
            report.violations()
        );

        // A flag the parser rejects, and a renumbered exit contract.
        docs(&fixture, "- `pane capture --colour` renders in colour.");
        let report = super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("--colour")),
            "{:?}",
            report.violations()
        );
        fixture.write(
            super::RUST_WATCH,
            "enum WatchExit {\n    Settled = 0,\n    NeverSeen = 4,\n    TimedOut = 8,\n}\n",
        );
        docs(&fixture, "");
        let report = super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("WatchExit is 0/4/8")),
            "{:?}",
            report.violations()
        );
    }

    /// A bullet wrapped across lines carries its marker once, and the reader still sees it.
    #[test]
    fn a_wrapped_entry_is_judged_whole() {
        let fixture = Fixture::new("cli-vocabulary-wrapped");
        crate_side(&fixture);
        docs(
            &fixture,
            "- NOT YET IMPLEMENTED — the deferred surface:\n  `ipc` would drive the running app, and\n  the \
             shells would offer it.",
        );
        assert!(
            super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree()).is_clean(),
            "{:?}",
            super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree()).violations()
        );
    }

    /// A renamed heading empties the corpus, which is the one bug the output cannot show.
    #[test]
    fn a_renamed_heading_fails_closed() {
        let fixture = Fixture::new("cli-vocabulary-heading");
        crate_side(&fixture);
        docs(&fixture, "");
        for doc in super::UI_SHELL_DOCS {
            fixture.write(doc, &section("").replace(super::E20_HEADING, "## E20 — CLI"));
        }
        let report = super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("read an empty corpus")),
            "{:?}",
            report.violations()
        );
    }

    #[test]
    fn the_deferral_ledger_is_checked_both_ways() {
        let fixture = Fixture::new("cli-vocabulary-ledger");
        crate_side(&fixture);
        docs(&fixture, "");

        // A deferred verb promoted to Ready without the ledger being told.
        fixture.write(
            super::RUST_CLI_VOCAB,
            &VOCABULARY.replace(
                "name: \"ipc\",\n        availability: Availability::Planned",
                "name: \"ipc\",\n        availability: Availability::Ready",
            ),
        );
        let report = super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("now \ncalls it Ready") || v.contains("calls it Ready")),
            "{:?}",
            report.violations()
        );

        // The ledger row itself deleted.
        crate_side(&fixture);
        fixture.write(
            super::UI_SHELL_COVERAGE,
            "§E import / export INTENTIONALLY NOT BUILT.\n",
        );
        let report = super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no longer mentions 'ipc'")),
            "{:?}",
            report.violations()
        );

        // A per-agent verb, which the Claude-only scope forbids.
        crate_side(&fixture);
        fixture.write(
            super::RUST_CLI_VOCAB,
            &VOCABULARY.replace("\"watch:claude\"", "\"watch:codex\""),
        );
        let report = super::the_ui_shell_docs_describe_the_shipped_cli(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("codex/opencode verb")),
            "{:?}",
            report.violations()
        );
    }
}
