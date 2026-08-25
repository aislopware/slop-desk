//! The `slopdesk` CLI offers exactly the verbs it can run, and the docs describe that CLI.
//!
//! Ported from the deleted `check-supervisor.sh` sections 1–8, which were the largest single block
//! left in the shell. The subject is one table — `SUBCOMMANDS` in
//! `rust/slopdesk-cli/src/vocabulary.rs` — and the other places that used to hold a copy of it.
//!
//! ## Most of this block deleted itself when the CLI stopped being Swift
//! Four of those places were Swift: a flag parser, a completions face, an output formatter and a
//! version banner, each a thin face over a `slopdesk_cli_*` FFI door, plus a dispatch `switch` in
//! the deleted `Sources/slopdesk` target. A gate had to hold those together because no compiler
//! crossed the boundary. The whole CLI process is `rust/slopdesk-cli` now, so there is no boundary
//! and no second spelling: the dispatch-vs-availability check that was the largest rule here is a
//! UNIT TEST in `shell.rs` reading `include_str!("shell.rs")` against `SUBCOMMANDS`, which is
//! strictly better than a text rule — it fails the crate's own suite, not a separate gate.
//!
//! What survives is what no compiler can still decide: two shape bans inside the crate, the ONE
//! cross-language vocabulary left (the client control socket, whose far end is Swift because it
//! dispatches against the `@Observable` store), and the doc half.
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

use std::collections::{BTreeMap, BTreeSet};

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::text;
use crate::tree::Tree;

/// The far end of the client control socket — Swift, because it dispatches against the store.
const SWIFT_CONTROL_PROTOCOL: &str = "Sources/SlopDeskWorkspaceCore/Control/ClientControlProtocol.swift";
/// The `switch` that consumes those method strings.
const SWIFT_CONTROL_DISPATCHER: &str = "Sources/SlopDeskWorkspaceCore/Control/ClientControlDispatcher.swift";
/// The near end: the request builders and the three token vocabularies.
const RUST_CLIENTCTL: &str = "rust/slopdesk-cli/src/clientctl.rs";
/// The process: argv in, dispatch, exit code out.
const RUST_CLI_SHELL: &str = "rust/slopdesk-cli/src/shell.rs";

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

/// The completions module owns no list, and the flag help sits beside the grammar
///
/// What is left of sections 1, 2, 5 and 6 after the CLI stopped being Swift. Both halves that
/// pointed at a Swift face are gone with the face; both halves that point INSIDE the crate stay,
/// because neither is something `rustc` refuses.
///
/// **The completions module owns no list of its own.** This is the exact regression the whole
/// change undoes: a flat `SUBCOMMANDS` array in `completions.rs` with no notion of availability.
/// The compiler is perfectly happy with two arrays; only a reader notices.
///
/// **The flag help sits beside the grammar.** A help page that documents a flag the parser rejects
/// is the same drift from the other end. The flag STRINGS live in `args.rs` next to the `match`
/// that consumes them, and a test there feeds every documented spelling back through `parse`; a
/// `GLOBAL_FLAGS` table anywhere else is a second copy of that fact.
///
/// **The process prints the vocabulary's page.** `shell.rs` calls `vocabulary::usage`; it does not
/// render one. This is the claim that used to read `main.swift`, and it is worth keeping on the
/// Rust side for the reason it was written: the help text drifted from the completions the first
/// time by someone adding a section heading to the dispatcher rather than to the table.
#[must_use]
pub fn the_cli_help_has_one_author(tree: &Tree) -> Report {
    check_all(tree, &[
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
        Claim::Names {
            path: RUST_CLI_SHELL,
            needle: "vocabulary::usage",
            message: "shell.rs no longer prints vocabulary::usage — the help page must have one author",
        },
        Claim::Lacks {
            path: RUST_CLI_SHELL,
            pattern: r"Local subcommands \(no running app|App-driving subcommands \(require|In-pane \
                      subcommands \(run inside|Global flags:",
            view: View::Code,
            message: "shell.rs spells a help-page section again — the whole page is rendered by \
                      vocabulary.rs",
        },
    ])
}

/// The client control socket has one vocabulary
///
/// THE LAST CROSS-LANGUAGE VOCABULARY THE CLI HAS. Everything else the `slopdesk` process knows is
/// its own crate's now; this one cannot be, because the far end dispatches against the
/// `@Observable` workspace store, which is `SwiftUI`'s and stays Swift.
///
/// The two ends ship on different clocks and that is the whole reason this is a gate rather than a
/// test: the app is long-running and installed from a `.app`, the CLI arrives by `brew upgrade` and
/// is typed seconds later. A renamed method moves both ends in one commit, passes both suites
/// green, and then meets a peer that is still the version the user launched this morning.
///
/// Three vocabularies, because all three are parsed by string on the far side and each fails the
/// same silent way — an unknown token becomes an error response, never a compile failure:
/// * the METHOD names, which is the `switch` itself;
/// * the PLACEMENT tokens `view`/`edit` take;
/// * the FONT SCOPE tokens `font list` takes.
///
/// The badge tokens are deliberately NOT compared as a set. Swift's map is `token → TabBadgeKind`
/// and carries `unread ↦ finished`, a many-to-one row Rust's flat list cannot express; what is
/// checked is that every token Rust offers is one Swift maps, which is the direction a user feels.
#[must_use]
pub fn the_client_control_socket_has_one_vocabulary(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(rust) = report.source(tree, RUST_CLIENTCTL, "the CLI's end of the socket lives there") else {
        return report;
    };
    let Some(swift) = report.source(tree, SWIFT_CONTROL_PROTOCOL, "the far end's spellings live there")
    else {
        return report;
    };

    // Rust spells each method as a `pub const NAME: &str = "…";` and then COLLECTS them into
    // `METHODS`, so the set is read through that array rather than off every `&str` const in the
    // file — `DEFAULT_PLACEMENT` is a `&str` const too, and grepping the shape would file it as a
    // method the app has never heard of. Reading `METHODS` also catches the other half: a method
    // constant defined, spelled right, and left out of the array the far end is held against.
    let rust_methods = method_constants(&rust.text);
    let swift_methods = method_block(&swift.text)
        .map(|block| text::capture_set(&block, r#"^ *public static let [a-zA-Z]+ = "([a-z][a-z-]*)"$"#))
        .unwrap_or_default();
    compare(&mut report, "method", &rust_methods, &swift_methods, METHOD_FLOOR);

    let rust_placements = list_tokens(&rust.text, "PLACEMENTS");
    let swift_placements = raw_values(&swift.text, "Placement");
    compare(
        &mut report,
        "placement token",
        &rust_placements,
        &swift_placements,
        PLACEMENT_FLOOR,
    );

    let rust_scopes = list_tokens(&rust.text, "FONT_SCOPES");
    let swift_scopes = raw_values(&swift.text, "FontScope");
    compare(&mut report, "font-scope token", &rust_scopes, &swift_scopes, 2);

    // One direction only, for the reason in the doc comment above.
    let rust_badges = list_tokens(&rust.text, "SETTABLE_BADGE_TOKENS");
    let swift_badges = text::capture_set(&swift.text, r#"^ *"([a-z][a-z-]*)": \.[a-zA-Z]+,$"#);
    if rust_badges.len() < 5 || swift_badges.len() < 5 {
        report.fail(format!(
            "{RUST_CLIENTCTL}/{SWIFT_CONTROL_PROTOCOL}: the badge-token extraction read {} and {} — the \
             comparison below would pass by having nothing to compare",
            rust_badges.len(),
            swift_badges.len()
        ));
    } else {
        let unmapped: Vec<&String> = rust_badges.difference(&swift_badges).collect();
        report.fail_if(
            !unmapped.is_empty(),
            format!(
                "`tab badge --kind` offers tokens ClientControlProtocol maps to no TabBadgeKind: \
                 {unmapped:?} — the CLI would accept them and the app would answer 'unknown'"
            ),
        );
    }

    // The `switch` is where a method name is actually consumed, and it reads the constants rather
    // than respelling them. A `case "windows":` there is a literal the gate above cannot see.
    if let Some(dispatcher) = report.source(tree, SWIFT_CONTROL_DISPATCHER, "the switch lives there") {
        let respelled = text::capture_set(dispatcher.code(), r#"^ *case "([a-z][a-z-]*)":"#);
        report.fail_if(
            !respelled.is_empty(),
            format!(
                "{SWIFT_CONTROL_DISPATCHER} switches on method LITERALS ({respelled:?}) — it must switch on \
                 ClientControlProtocol.Method, which is what {RUST_CLIENTCTL} is held against"
            ),
        );
    }
    report
}

/// How many methods the socket has at the floor. A smaller read is a stale extraction.
const METHOD_FLOOR: usize = 10;
/// `new-tab`, `new-window` and the four split sides.
const PLACEMENT_FLOOR: usize = 6;

/// Both sides of one vocabulary, or a named failure when either read too little to be believed.
fn compare(report: &mut Report, what: &str, rust: &BTreeSet<String>, swift: &BTreeSet<String>, floor: usize) {
    if rust.len() < floor || swift.len() < floor {
        report.fail(format!(
            "the {what} extraction read {} from {RUST_CLIENTCTL} and {} from {SWIFT_CONTROL_PROTOCOL} \
             (floor {floor}) — a comparison against an empty set passes in silence",
            rust.len(),
            swift.len()
        ));
        return;
    }
    if rust == swift {
        return;
    }
    let cli_only: Vec<&String> = rust.difference(swift).collect();
    let app_only: Vec<&String> = swift.difference(rust).collect();
    report.fail(format!(
        "the {what}s disagree across the client control socket — the CLI sends and the app does not know: \
         {cli_only:?}; the app answers and no CLI verb reaches: {app_only:?}"
    ));
}

/// Every method `METHODS` collects, resolved through the constants that name them.
///
/// A name in the array with no `pub const` behind it would not compile, so the resolution cannot
/// silently drop one — but a constant left OUT of the array is exactly the drift this reads for,
/// and it comes out as a method Swift knows and no CLI verb reaches.
fn method_constants(clientctl: &str) -> BTreeSet<String> {
    let mut spellings = BTreeMap::new();
    for line in clientctl.lines() {
        if let Some(caps) = text::cached(r#"^pub const ([A-Z_]+): &str = "([a-z][a-z-]*)";$"#).captures(line)
            && let (Some(name), Some(value)) = (caps.get(1), caps.get(2))
        {
            drop(spellings.insert(name.as_str().to_owned(), value.as_str().to_owned()));
        }
    }
    let Some(body) = text::capture_first(clientctl, r"(?s)pub const METHODS: &\[&str\] = &\[(.*?)\]") else {
        return BTreeSet::new();
    };
    text::capture_set(&body, r"^ *([A-Z_]+),$")
        .iter()
        .filter_map(|name| spellings.get(name).cloned())
        .collect()
}

/// The body of Swift's `enum Method`, up to its closing `all` set.
fn method_block(protocol: &str) -> Option<String> {
    let mut lines = protocol
        .lines()
        .skip_while(|line| !line.contains("public enum Method {"));
    lines.next()?;
    Some(
        lines
            .take_while(|line| !line.contains("public static let all"))
            .collect::<Vec<_>>()
            .join("\n"),
    )
}

/// The string literals of one `pub const NAME: &[&str] = &[…];` in Rust.
fn list_tokens(source: &str, name: &str) -> BTreeSet<String> {
    let body = text::capture_first(
        source,
        &format!(r"(?s)pub const {}: &\[&str\] = &\[(.*?)\]", regex::escape(name)),
    );
    body.map(|body| text::capture_set(&body, r#""([a-z][a-z-]*)""#))
        .unwrap_or_default()
}

/// A Swift `String`-raw-valued enum's tokens: the explicit `= "…"` ones and the implicit ones,
/// which Swift spells as the case name itself.
fn raw_values(protocol: &str, name: &str) -> BTreeSet<String> {
    let Some(body) = text::capture_first(
        protocol,
        &format!(
            r"(?s)public enum {}: String[^\n]*\{{(.*?)\n    \}}",
            regex::escape(name)
        ),
    ) else {
        return BTreeSet::new();
    };
    let explicit = text::cached(r#"^ *case [a-zA-Z]+ = "([a-z][a-z-]*)"$"#);
    let implicit = text::cached(r"^ *case ([a-z][a-zA-Z]*)$");
    body.lines()
        .filter_map(|line| {
            explicit
                .captures(line)
                .or_else(|| implicit.captures(line))
                .and_then(|caps| caps.get(1))
                .map(|matched| matched.as_str().to_owned())
        })
        .collect()
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

    fn crate_side(fixture: &Fixture) {
        fixture
            .write(super::RUST_CLI_VOCAB, VOCABULARY)
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

    /// A reformatted table reads as no table at all, and every rule downstream passes.
    #[test]
    fn an_unreadable_vocabulary_fails_rather_than_passing() {
        let fixture = Fixture::new("cli-vocabulary-stale");
        crate_side(&fixture);
        fixture.write(super::RUST_CLI_VOCAB, &VOCABULARY.replace("name:", "nom:"));
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

    // ------------------------------------------------------------------------------------- //
    // The client control socket
    // ------------------------------------------------------------------------------------- //

    /// The near end, in the shape `clientctl.rs` actually has: one `pub const` per method, then
    /// three `&[&str]` token lists.
    const CLIENTCTL: &str = r#"
pub const WINDOWS: &str = "windows";
pub const TABS: &str = "tabs";
pub const PANES: &str = "panes";
pub const TAB_BADGE: &str = "tab-badge";
pub const JUMP: &str = "jump";
pub const LEARN: &str = "learn";
pub const IGNORE: &str = "ignore";
pub const VIEW: &str = "view";
pub const EDIT: &str = "edit";
pub const FONT_LIST: &str = "font-list";
pub const KEYBIND_LIST: &str = "keybind-list";

pub const METHODS: &[&str] = &[
    WINDOWS,
    TABS,
    PANES,
    TAB_BADGE,
    JUMP,
    LEARN,
    IGNORE,
    VIEW,
    EDIT,
    FONT_LIST,
    KEYBIND_LIST,
];

/// A `&str` const that is NOT a method — the shape the extraction must not mistake for one.
pub const DEFAULT_PLACEMENT: &str = "new-tab";

pub const SETTABLE_BADGE_TOKENS: &[&str] = &[
    "running",
    "completed",
    "finished",
    "unread",
    "error",
    "awaiting-input",
];

pub const PLACEMENTS: &[&str] = &["new-tab", "new-window", "left", "right", "top", "bottom"];

pub const FONT_SCOPES: &[&str] = &["system", "user"];
"#;

    /// The far end, in the shape `ClientControlProtocol.swift` has: a `Method` enum of static
    /// lets closed by `all`, a badge map, and two `String`-raw-valued enums — one with explicit
    /// raw values and four implicit ones, which is the case `raw_values` exists for.
    const PROTOCOL: &str = r#"
public enum ClientControlProtocol {
    public enum Method {
        public static let windows = "windows"
        public static let tabs = "tabs"
        public static let panes = "panes"
        public static let tabBadge = "tab-badge"
        public static let jump = "jump"
        public static let learn = "learn"
        public static let ignore = "ignore"
        public static let view = "view"
        public static let edit = "edit"
        public static let fontList = "font-list"
        public static let keybindList = "keybind-list"

        public static let all: Set<String> = [windows, tabs]
    }

    public static let settableBadgeTokens: [String: TabBadgeKind] = [
        "running": .running,
        "completed": .completed,
        "finished": .finished,
        "unread": .finished,
        "error": .error,
        "awaiting-input": .awaitingInput,
    ]

    public enum Placement: String, Sendable, Equatable, CaseIterable {
        case newTab = "new-tab"
        case newWindow = "new-window"
        case left
        case right
        case top
        case bottom
    }

    public enum FontScope: String, Sendable, Equatable, CaseIterable {
        case system
        case user
    }
}
"#;

    const DISPATCHER: &str = r#"
switch method {
case ClientControlProtocol.Method.windows: windows(id: id)
default: Self.error(id: id, message: "unknown method: \(method)")
}
"#;

    fn socket(fixture: &Fixture) {
        fixture
            .write(super::RUST_CLIENTCTL, CLIENTCTL)
            .write(super::SWIFT_CONTROL_PROTOCOL, PROTOCOL)
            .write(super::SWIFT_CONTROL_DISPATCHER, DISPATCHER);
    }

    #[test]
    fn the_two_ends_of_the_socket_are_held_together() {
        let fixture = Fixture::new("clientctl-agree");
        socket(&fixture);
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(report.is_clean(), "{:?}", report.violations());

        // A method renamed on ONE side — the drift that ships green and meets last morning's app.
        fixture.write(
            super::SWIFT_CONTROL_PROTOCOL,
            &PROTOCOL.replace(r#"keybindList = "keybind-list""#, r#"keybindList = "keybinds""#),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("methods disagree")),
            "{:?}",
            report.violations()
        );

        // A method constant defined, spelled right, and never collected into `METHODS` — so the
        // far end dispatches a verb the near end can no longer send.
        socket(&fixture);
        fixture.write(
            super::RUST_CLIENTCTL,
            &CLIENTCTL.replace("    KEYBIND_LIST,\n", ""),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no CLI verb reaches") && v.contains("keybind-list")),
            "{:?}",
            report.violations()
        );

        // A placement the CLI offers and the app cannot parse.
        socket(&fixture);
        fixture.write(
            super::RUST_CLIENTCTL,
            &CLIENTCTL.replace(r#""bottom"]"#, r#""bottom", "centre"]"#),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("placement tokens disagree") && v.contains("centre")),
            "{:?}",
            report.violations()
        );

        // A badge token with no TabBadgeKind behind it — the one-directional half.
        socket(&fixture);
        fixture.write(
            super::RUST_CLIENTCTL,
            &CLIENTCTL.replace(r#"    "error","#, "    \"error\",\n    \"stalled\","),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("stalled")),
            "{:?}",
            report.violations()
        );

        // The switch respelling a method as a literal, which the set comparison cannot see.
        socket(&fixture);
        fixture.write(
            super::SWIFT_CONTROL_DISPATCHER,
            &DISPATCHER.replace("case ClientControlProtocol.Method.windows:", r#"case "windows":"#),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("method LITERALS")),
            "{:?}",
            report.violations()
        );
    }

    /// A reformat that empties either extraction must be RED, not a silent pass.
    #[test]
    fn an_unreadable_vocabulary_on_either_side_fails_closed() {
        let fixture = Fixture::new("clientctl-stale");
        socket(&fixture);
        fixture.write(
            super::SWIFT_CONTROL_PROTOCOL,
            &PROTOCOL.replace("public static let", "static let"),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("floor 10")),
            "{:?}",
            report.violations()
        );
    }

    /// The two bans that survived the port both fire on the shape they ban.
    #[test]
    fn the_crate_may_not_grow_a_second_list_or_a_second_help_page() {
        let fixture = Fixture::new("cli-help-author");
        fixture
            .write(
                super::RUST_CLI_COMPLETIONS,
                "fn script() -> String { String::new() }\n",
            )
            .write(
                super::RUST_CLI_ARGS,
                "pub const GLOBAL_FLAGS: &[GlobalFlag] = &[];\n",
            )
            .write(
                super::RUST_CLI_SHELL,
                "print(io.out, &vocabulary::usage(&program))?;\n",
            );
        assert!(super::the_cli_help_has_one_author(&fixture.tree()).is_clean());

        fixture.write(
            super::RUST_CLI_COMPLETIONS,
            "const SUBCOMMANDS: &[&str] = &[\"pane\"];\n",
        );
        assert!(!super::the_cli_help_has_one_author(&fixture.tree()).is_clean());

        fixture
            .write(
                super::RUST_CLI_COMPLETIONS,
                "fn script() -> String { String::new() }\n",
            )
            .write(
                super::RUST_CLI_SHELL,
                "print(io.out, \"Global flags:\\n  --json\")?;\n",
            );
        assert!(!super::the_cli_help_has_one_author(&fixture.tree()).is_clean());
    }
}
