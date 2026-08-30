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

/// The near end of the client control socket — Swift, because it reaches the `@MainActor` store.
const SWIFT_CONTROL_FACE: &str = "Sources/SlopDeskClientCore/Control/ClientControlHost.swift";
/// The seam it drives, which holds the two index-valued enums.
const SWIFT_CONTROL_SEAM: &str = "Sources/SlopDeskWorkspaceCore/Control/ClientControlBackend.swift";
/// The ONE spelling: the method names, the three token vocabularies and the NDJSON framing.
const RUST_CLIENTCTL: &str = "rust/slopdesk-clientctl/src/lib.rs";
/// The doors the Swift face runs that socket through.
const RUST_CLIENTCTL_DOORS: &str = "rust/slopdesk-ffi/src/client_ctl.rs";
/// Where the same codes are declared for the near side to compile against.
const FFI_HEADER: &str = "rust/slopdesk-ffi/include/slopdesk_ffi.h";
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
/// IT USED TO HAVE TWO. A module inside `slopdesk-cli` held the method names and the three token
/// vocabularies; `ClientControlProtocol.swift` held a second spelling of every one of them; and
/// this rule compared one file's regexes against the other's, because no compiler crossed the
/// boundary and no `.xcframework` could link a module of the CLI's own library.
///
/// Then the SOCKET moved too. `slopdesk-clientctl` is the listener, the framing, the decode, the
/// validation, the refusal sentences and the reply encoder — both ends link the one crate — and the
/// Swift that remains is a FACE that reaches the `@MainActor` store and nothing else. So the words
/// no longer cross at all: what crosses is a verb INDEX with typed params, and a typed outcome
/// back.
///
/// The clock argument that made this a gate rather than a test is unchanged and is now carried by
/// the crate's own goldens: the app is long-running and installed from a `.app`, the CLI arrives by
/// `brew upgrade` and is typed seconds later, so a renamed method must be a WIRE change. What is
/// left here is the part no suite can fail on — a literal reappearing in Swift, and a number
/// reappearing in a third place.
///
/// Four claims:
/// * the crate still declares the one table of each vocabulary, so the doors have something to
///   read;
/// * the doors exist, and the face names every one that decides something — a face that stopped
///   calling one would have gone back to holding the answer itself;
/// * no method name or token is spelled as a literal in the face or the seam;
/// * every `SLOPDESK_CTL_*` code is declared in exactly TWO places with the same value — the shim
///   that matches on it and the header the face compiles against — and the shim's own suite pins
///   those against the crate's tables. A third spelling with a different number is a face
///   dispatching a neighbour's verb, which is the one failure a door answering an index cannot
///   catch for itself.
#[must_use]
pub fn the_client_control_socket_has_one_vocabulary(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(rust) = report.source(tree, RUST_CLIENTCTL, "the socket's one vocabulary lives there") else {
        return report;
    };
    let Some(face) = report.source(tree, SWIFT_CONTROL_FACE, "the face lives there") else {
        return report;
    };

    // The crate still holds the tables. Read through `METHODS` rather than off every `&str` const —
    // `DEFAULT_PLACEMENT` is a `&str` const too, and grepping the shape would file it as a method.
    let methods = method_constants(&rust.text);
    let placements = list_tokens(&rust.text, "PLACEMENTS");
    let scopes = list_tokens(&rust.text, "FONT_SCOPES");
    let badges = badge_table(&rust.text);
    for (what, read, floor) in [
        ("method", methods.len(), METHOD_FLOOR),
        ("placement token", placements.len(), PLACEMENT_FLOOR),
        ("font-scope token", scopes.len(), 2),
        ("settable badge token", badges.len(), BADGE_FLOOR),
    ] {
        report.fail_if(
            read < floor,
            format!(
                "{RUST_CLIENTCTL}: the {what} extraction read {read} (floor {floor}) — the vocabulary has \
                 been reshaped or emptied, and every claim below is comparing against nothing"
            ),
        );
    }

    // Each door exists and the face names it. These seven are the ones that DECIDE something: the
    // socket itself, its path, the dispatch index, the three param readers and the refusal. A face
    // that stopped calling one grew that decision back in Swift, which is the whole regression.
    let doors = report.source(tree, RUST_CLIENTCTL_DOORS, "the face's doors live there");
    for door in DOORS {
        report.fail_if(
            !doors.is_some_and(|source| source.text.contains(door)),
            format!("{RUST_CLIENTCTL_DOORS} no longer exports {door} — the face has nothing to call"),
        );
        report.fail_if(
            !face.text.contains(door),
            format!(
                "{SWIFT_CONTROL_FACE} no longer calls {door} — a decision it does not ask for is one it is \
                 making itself"
            ),
        );
    }

    // No literal, in either Swift file. This is the ban that replaces the whole two-way comparison:
    // there is nothing left to hold together as long as nobody writes the words down again.
    literal_ban(tree, &mut report, SWIFT_CONTROL_FACE);
    literal_ban(tree, &mut report, SWIFT_CONTROL_SEAM);

    // The byte contract. A token crosses as its POSITION, so a vocabulary that grows in Rust while
    // the Swift enum does not makes the new token parse to a `rawValue` no case answers — silently
    // unreachable rather than wrong, and still a change nobody meant to make.
    if let Some(seam) = report.source(tree, SWIFT_CONTROL_SEAM, "the index-valued enums live there") {
        byte_contract(
            &mut report,
            &seam.text,
            "ClientControlPlacement",
            placements.len(),
        );
        byte_contract(&mut report, &seam.text, "ClientControlFontScope", scopes.len());
    }

    codes_agree(tree, &mut report);
    report
}

/// The `SLOPDESK_CTL_*` codes are declared in two places and hold the same numbers.
///
/// The shim MATCHES on them; the header is what the face compiles against. Neither can be dropped —
/// a `#define` is not a Rust `const` and a Rust `const` exports no symbol — so the one thing worth
/// gating is that the two sets are identical. The shim's own suite already pins its half against
/// `METHODS` and `Refusal::code`, so agreement here means all three agree.
fn codes_agree(tree: &Tree, report: &mut Report) {
    let (Some(doors), Some(header)) = (
        report.source(tree, RUST_CLIENTCTL_DOORS, "the shim declares its half"),
        report.source(tree, FFI_HEADER, "the header declares the other half"),
    ) else {
        return;
    };
    let declared = numbered(
        &doors.text,
        r"^pub const (SLOPDESK_CTL_[A-Z0-9_]+): [iu][0-9]+ = ([0-9]+);",
    );
    let defined = numbered(&header.text, r"^#define (SLOPDESK_CTL_[A-Z0-9_]+) ([0-9]+)");
    report.fail_if(
        declared.len() < CODE_FLOOR,
        format!(
            "{RUST_CLIENTCTL_DOORS}: the code extraction read {} (floor {CODE_FLOOR}) — the constants have \
             been reshaped, and the comparison below is against nothing",
            declared.len()
        ),
    );
    for (name, value) in &declared {
        match defined.get(name) {
            None => {
                report.fail(format!(
                    "{FFI_HEADER} does not define {name} — the shim matches on a code the face cannot name"
                ));
            },
            Some(other) if other != value => {
                report.fail(format!(
                    "{name} is {value} in {RUST_CLIENTCTL_DOORS} and {other} in {FFI_HEADER} — the face \
                     would ask for one thing and be answered another"
                ));
            },
            Some(_) => {},
        }
    }
    for name in defined.keys() {
        report.fail_if(
            !declared.contains_key(name),
            format!(
                "{FFI_HEADER} defines {name}, which {RUST_CLIENTCTL_DOORS} does not declare — a code no \
                 door answers to"
            ),
        );
    }
}

/// Every `NAME value` pair one pattern finds, keyed by name.
fn numbered(source: &str, pattern: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for line in source.lines() {
        if let Some(caps) = text::cached(pattern).captures(line.trim())
            && let (Some(name), Some(value)) = (caps.get(1), caps.get(2))
        {
            drop(out.insert(name.as_str().to_owned(), value.as_str().to_owned()));
        }
    }
    out
}

/// How many methods the socket has at the floor. A smaller read is a stale extraction.
const METHOD_FLOOR: usize = 10;
/// `new-tab`, `new-window` and the four split sides.
const PLACEMENT_FLOOR: usize = 6;
/// The five settable badges plus `unread`, the many-to-one row.
const BADGE_FLOOR: usize = 5;
/// A floor on the code extraction. Deliberately low, because the load-bearing claim is that the two
/// sides are the SAME set — a reformat that empties one is caught by the other's orphans, and only
/// a reformat of both files, in two languages, at once could empty both.
const CODE_FLOOR: usize = 8;

/// The seven doors that carry a DECISION out of Swift.
const DOORS: [&str; 7] = [
    "slopdesk_client_ctl_socket_path",
    "slopdesk_client_ctl_serve",
    "slopdesk_client_ctl_verb",
    "slopdesk_client_ctl_text",
    "slopdesk_client_ctl_flag",
    "slopdesk_client_ctl_number",
    "slopdesk_client_ctl_refuse",
];

/// The words that may not be typed in Swift again.
///
/// A method name and a placement token look alike — a lowercase hyphenated word in quotes — so the
/// ban is one pattern over the CODE of both files. It is deliberately narrow: `docs/` prose and the
/// doc comments above each declaration may name whatever they describe, since a comment is not
/// something the face reads.
fn literal_ban(tree: &Tree, report: &mut Report, path: &str) {
    let Some(source) = report.source(tree, path, "one half of the face lives there") else {
        return;
    };
    let respelled = text::capture_set(
        source.code(),
        r#"(?:case |= )"(windows|tabs|panes|tab-badge|jump|learn|ignore|view|edit|font-list|keybind-list|pane-capture|pane-send-keys|agent-status|new-tab|new-window|awaiting-input|command-running|command-busy|caffeinate)""#,
    );
    report.fail_if(
        !respelled.is_empty(),
        format!(
            "{path} spells control-socket words as LITERALS ({respelled:?}) — they belong to \
             {RUST_CLIENTCTL} and reach Swift only through {RUST_CLIENTCTL_DOORS}"
        ),
    );
}

/// One `UInt8`-raw-valued enum declares exactly as many cases as its vocabulary has entries.
fn byte_contract(report: &mut Report, seam: &str, name: &str, expected: usize) {
    let Some(body) = text::capture_first(
        seam,
        &format!(
            r"(?s)public enum {}: UInt8[^\n]*\{{(.*?)\n\}}",
            regex::escape(name)
        ),
    ) else {
        report.fail(format!(
            "{SWIFT_CONTROL_SEAM}: no `public enum {name}: UInt8` — the token index a door answers has no \
             case to land on"
        ));
        return;
    };
    let cases = text::capture_set(&body, r"^ *case [a-zA-Z]+ = ([0-9]+)$");
    report.fail_if(
        cases.len() != expected,
        format!(
            "{SWIFT_CONTROL_SEAM}: `{name}` declares {} cases and {RUST_CLIENTCTL} carries {expected} \
             tokens — a token crosses as its POSITION, so the extra one parses to a rawValue no case answers",
            cases.len()
        ),
    );
}

/// Every method `METHODS` collects, resolved through the constants that name them.
///
/// A name in the array with no `pub const` behind it would not compile, so the resolution cannot
/// silently drop one — but a constant left OUT of the array is exactly the drift this reads for,
/// and it comes out as a method the crate's own golden covers and no door delivers.
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

/// The string literals of one `pub const NAME: &[&str] = &[…];` in Rust.
fn list_tokens(source: &str, name: &str) -> BTreeSet<String> {
    let body = text::capture_first(
        source,
        &format!(r"(?s)pub const {}: &\[&str\] = &\[(.*?)\]", regex::escape(name)),
    );
    body.map(|body| text::capture_set(&body, r#""([a-z][a-z-]*)""#))
        .unwrap_or_default()
}

/// The tokens of the badge TABLE — `&[(&str, TabBadge)]`, pairs rather than a flat list.
///
/// Read as its own shape rather than through [`list_tokens`] precisely because it is a table: a
/// reformat back into a bare `&[&str]` beside a `match` would be the mapping spelled twice in one
/// language, which is the same drift the port removed across two.
fn badge_table(source: &str) -> BTreeSet<String> {
    let Some(body) = text::capture_first(
        source,
        r"(?s)pub const SETTABLE_BADGE_TOKENS: &\[\(&str, TabBadge\)\] = &\[(.*?)\n\];",
    ) else {
        return BTreeSet::new();
    };
    text::capture_set(&body, r#"^ *\("([a-z][a-z-]*)", TabBadge::[A-Za-z]+\),$"#)
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

        // A verb the docs name is a verb the vocabulary knows. CATCHES the `theme` bug: a doc
        // naming a subcommand that is in no availability at all, so it is not merely
        // unbuilt.
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

    /// The one vocabulary, in the shape `slopdesk-clientctl`'s `lib.rs` actually has: one `pub
    /// const` per method, a `&[(&str, TabBadge)]` TABLE, and two `&[&str]` token lists.
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

pub const SETTABLE_BADGE_TOKENS: &[(&str, TabBadge)] = &[
    ("running", TabBadge::Running),
    ("completed", TabBadge::Completed),
    ("finished", TabBadge::Finished),
    ("unread", TabBadge::Finished),
    ("error", TabBadge::Error),
    ("awaiting-input", TabBadge::AwaitingInput),
];

pub const PLACEMENTS: &[&str] = &["new-tab", "new-window", "left", "right", "top", "bottom"];

pub const FONT_SCOPES: &[&str] = &["system", "user"];
"#;

    /// The doors the face runs the socket through, plus the codes it matches on. Only the seven
    /// `DOORS` names and the `SLOPDESK_CTL_*` shape matter here; the bodies are elided.
    const DOORS: &str = r#"
pub const SLOPDESK_CTL_VERB_WINDOWS: i32 = 0;
pub const SLOPDESK_CTL_VERB_TABS: i32 = 1;
pub const SLOPDESK_CTL_FIELD_WINDOW_ID: u8 = 0;
pub const SLOPDESK_CTL_FIELD_TAB_ID: u8 = 1;
pub const SLOPDESK_CTL_FLAG_EDITABLE: u8 = 2;
pub const SLOPDESK_CTL_NUMBER_LINES: u8 = 0;
pub const SLOPDESK_CTL_LIST_WINDOWS: u8 = 0;
pub const SLOPDESK_CTL_REFUSAL_PANE_NOT_FOUND: u8 = 16;
pub unsafe extern "C" fn slopdesk_client_ctl_socket_path(c: *const c_uchar, n: usize) -> usize {}
pub unsafe extern "C" fn slopdesk_client_ctl_serve(p: *const c_uchar, n: usize) -> *mut u8 {}
pub unsafe extern "C" fn slopdesk_client_ctl_verb(r: *const SlopDeskCtlRequest) -> i32 {}
pub unsafe extern "C" fn slopdesk_client_ctl_text(r: *const SlopDeskCtlRequest, f: u8) -> usize {}
pub const unsafe extern "C" fn slopdesk_client_ctl_flag(r: *const SlopDeskCtlRequest, f: u8) -> bool {}
pub unsafe extern "C" fn slopdesk_client_ctl_number(r: *const SlopDeskCtlRequest, n: u8) -> i64 {}
pub unsafe extern "C" fn slopdesk_client_ctl_refuse(r: *mut SlopDeskCtlReply, code: u8) {}
"#;

    /// The header's half of the same codes.
    const HEADER: &str = r"
#define SLOPDESK_CTL_VERB_WINDOWS 0
#define SLOPDESK_CTL_VERB_TABS 1
#define SLOPDESK_CTL_FIELD_WINDOW_ID 0
#define SLOPDESK_CTL_FIELD_TAB_ID 1
#define SLOPDESK_CTL_FLAG_EDITABLE 2
#define SLOPDESK_CTL_NUMBER_LINES 0
#define SLOPDESK_CTL_LIST_WINDOWS 0
#define SLOPDESK_CTL_REFUSAL_PANE_NOT_FOUND 16
";

    /// The FACE, in the shape `ClientControlHost.swift` has: a bind, a dispatch on the verb INDEX,
    /// param reads that are door calls, and refusals that are codes.
    const FACE: &str = r"
public final class ClientControlHost {
    public static func resolvedSocketPath() -> String {
        slopdesk_client_ctl_socket_path(bytes, container.utf8.count, out, cap)
    }

    public func start() throws {
        slopdesk_client_ctl_serve(buffer.baseAddress, buffer.count, retained.toOpaque(), runRequest)
    }

    private static func serve(request: OpaquePointer?, reply: OpaquePointer?) {
        switch slopdesk_client_ctl_verb(request) {
        case SLOPDESK_CTL_VERB_WINDOWS:
            slopdesk_client_ctl_answer_list(reply, Kind.windows)
        case SLOPDESK_CTL_VERB_TABS:
            _ = slopdesk_client_ctl_flag(request, Flag.editable)
            _ = slopdesk_client_ctl_number(request, Number.lines)
        default:
            break
        }
    }

    private static func refuse(_ reply: OpaquePointer?, _ code: UInt8) {
        slopdesk_client_ctl_refuse(reply, code, text[0])
    }

    private static func text(_ request: OpaquePointer?, _ field: UInt8) -> String? {
        slopdesk_client_ctl_text(request, field, nil, 0, &present)
    }
}
";

    /// The seam, which holds the two index-valued enums the tokens land on.
    const SEAM: &str = r"
public enum ClientControlPlacement: UInt8, Sendable, Equatable, CaseIterable {
    case newTab = 0
    case newWindow = 1
    case left = 2
    case right = 3
    case top = 4
    case bottom = 5
}

public enum ClientControlFontScope: UInt8, Sendable, Equatable, CaseIterable {
    case system = 0
    case user = 1
}
";

    fn socket(fixture: &Fixture) {
        fixture
            .write(super::RUST_CLIENTCTL, CLIENTCTL)
            .write(super::RUST_CLIENTCTL_DOORS, DOORS)
            .write(super::FFI_HEADER, HEADER)
            .write(super::SWIFT_CONTROL_FACE, FACE)
            .write(super::SWIFT_CONTROL_SEAM, SEAM);
    }

    #[test]
    fn the_socket_has_exactly_one_spelling_of_its_words() {
        let fixture = Fixture::new("clientctl-agree");
        socket(&fixture);
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(report.is_clean(), "{:?}", report.violations());

        // The regression the port removed: a method name typed back into the face.
        fixture.write(
            super::SWIFT_CONTROL_FACE,
            &FACE.replace("case SLOPDESK_CTL_VERB_WINDOWS:", r#"case "windows":"#),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("LITERALS") && v.contains("windows")),
            "{:?}",
            report.violations()
        );

        // The same regression in the SEAM, where a token would be respelled as a case name.
        socket(&fixture);
        fixture.write(
            super::SWIFT_CONTROL_SEAM,
            &SEAM.replace("case newTab = 0", r#"case newTab = "new-tab""#),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("LITERALS")),
            "{:?}",
            report.violations()
        );

        // A face that stopped asking — a param read that answers out of Swift again.
        socket(&fixture);
        fixture.write(
            super::SWIFT_CONTROL_FACE,
            &FACE.replace(
                "slopdesk_client_ctl_number(request, Number.lines)",
                "params[\"lines\"] as? Int",
            ),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no longer calls slopdesk_client_ctl_number")),
            "{:?}",
            report.violations()
        );

        // A door deleted out from under the face.
        socket(&fixture);
        fixture.write(
            super::RUST_CLIENTCTL_DOORS,
            &DOORS.replace("slopdesk_client_ctl_refuse", "removed_door"),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no longer exports slopdesk_client_ctl_refuse")),
            "{:?}",
            report.violations()
        );

        // THE BYTE CONTRACT: a placement added in Rust and not in Swift parses to a rawValue no
        // case answers, which is a token silently unreachable rather than a token spelled wrong.
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
                .any(|v| v.contains("`ClientControlPlacement` declares 6 cases") && v.contains("carries 7")),
            "{:?}",
            report.violations()
        );

        // The badge TABLE flattened back into a list beside a map — the mapping spelled twice, in
        // one language this time.
        socket(&fixture);
        fixture.write(
            super::RUST_CLIENTCTL,
            &CLIENTCTL.replace("&[(&str, TabBadge)]", "&[&str]"),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("settable badge token extraction read 0")),
            "{:?}",
            report.violations()
        );
    }

    /// The codes are declared twice and hold the same numbers, or the face asks for one verb and is
    /// answered another.
    #[test]
    fn a_code_that_disagrees_with_its_header_is_caught() {
        // The same name, a different number — the failure a door answering an index cannot see.
        let fixture = Fixture::new("clientctl-code-drift");
        socket(&fixture);
        fixture.write(
            super::FFI_HEADER,
            &HEADER.replace(
                "#define SLOPDESK_CTL_VERB_TABS 1",
                "#define SLOPDESK_CTL_VERB_TABS 4",
            ),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("SLOPDESK_CTL_VERB_TABS is 1 in") && v.contains("and 4 in")),
            "{:?}",
            report.violations()
        );

        // A code the shim matches on that the header never declares — the face cannot name it.
        let fixture = Fixture::new("clientctl-code-missing");
        socket(&fixture);
        fixture.write(
            super::FFI_HEADER,
            &HEADER.replace("#define SLOPDESK_CTL_REFUSAL_PANE_NOT_FOUND 16\n", ""),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("does not define SLOPDESK_CTL_REFUSAL_PANE_NOT_FOUND")),
            "{:?}",
            report.violations()
        );

        // And the other direction: a header code no door answers to.
        let fixture = Fixture::new("clientctl-code-orphan");
        socket(&fixture);
        fixture.write(
            super::FFI_HEADER,
            &format!("{HEADER}#define SLOPDESK_CTL_VERB_GHOST 99\n"),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("defines SLOPDESK_CTL_VERB_GHOST")),
            "{:?}",
            report.violations()
        );
    }

    /// A reformat that empties an extraction must be RED, not a silent pass.
    #[test]
    fn an_unreadable_vocabulary_fails_closed() {
        let fixture = Fixture::new("clientctl-stale");
        socket(&fixture);
        fixture.write(super::RUST_CLIENTCTL, &CLIENTCTL.replace("pub const", "const"));
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("floor 10")),
            "{:?}",
            report.violations()
        );

        // The far side's enum renamed or restyled: the index a door answers has nowhere to land.
        socket(&fixture);
        fixture.write(
            super::SWIFT_CONTROL_SEAM,
            &SEAM.replace(
                "public enum ClientControlPlacement: UInt8",
                "public enum ClientControlPlacement: String",
            ),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no `public enum ClientControlPlacement: UInt8`")),
            "{:?}",
            report.violations()
        );

        // And the code extraction reformatted out of existence on the shim's side.
        socket(&fixture);
        fixture.write(
            super::RUST_CLIENTCTL_DOORS,
            &DOORS.replace("pub const SLOPDESK_CTL_", "const SLOPDESK_CTL_"),
        );
        let report = super::the_client_control_socket_has_one_vocabulary(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("floor 8")),
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
