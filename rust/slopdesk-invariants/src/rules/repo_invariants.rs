//! The repo-wide ratchets `CLAUDE.md` states and nothing else enforced.
//!
//! Ported from the `check-invariants.py` that used to sit in `scripts/`, itself a port out of
//! shell. That file
//! opened with an argument for why it was Python and its neighbours were bash, and the argument is
//! worth keeping because it is the reason this module reads [`Source::statements`] rather than
//! grepping: every gate here is "this token must not appear in CODE", and three separate silent
//! failures came out of writing that as a `grep`.
//!
//! * `repo_files … | xargs grep -ln` PRINTS the offender and still exits non-zero, because `xargs`
//!   splits the paths into batches and reports the LAST batch's status. The surrounding `if
//!   hit=$(…)` is then false exactly when there is something to report.
//! * A `grep` for `pkill` matched the gate's own failure MESSAGE, so the check reported itself and
//!   could never be made to pass.
//! * Stripping comments with `sed -E 's,//.*,,'` also mangles `https://…` inside a string literal.
//!
//! None of the three is a shell-scripting mistake so much as the shape of the tool: a pipeline
//! hides status, and a regex has no idea what a comment is. Both failures look exactly like
//! success. The Python answered with a tokenizer; here that tokenizer is [`Source::statements`],
//! which every gate below reads and which keeps string literals and line numbering intact.
//!
//! What the port BUYS, beyond deleting a language: the gates ran in a background subprocess whose
//! only channel back was a log file and an exit code, so a failure arrived as fourteen lines of
//! someone else's stdout. Here each is a [`Rule`](crate::Rule) with a name, a break-test, and a
//! `--only` handle, and it reads the same in-memory tree as the other 280 rather than re-walking
//! the repository with `git ls-files`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use crate::claim::{Claim, check_all};
use crate::report::Report;
use crate::text;
use crate::tree::{Source, Tree};

/// Every `path:line: text` where `pattern` matches real code rather than a comment.
fn hits(files: &[(&Path, &Source)], pattern: &str) -> Vec<String> {
    let regex = text::cached(pattern);
    let mut found = Vec::new();
    for (path, source) in files {
        for (number, line) in source.statements().lines().enumerate() {
            if !line.trim().is_empty() && regex.is_match(line) {
                found.push(format!("{}:{}: {}", path.display(), number + 1, line.trim()));
            }
        }
    }
    found
}

/// Records one violation naming every site, or nothing when the gate holds.
fn sites(report: &mut Report, message: &str, found: &[String]) {
    if !found.is_empty() {
        report.fail(format!("{message} — {}", found.join("; ")));
    }
}

/// The Swift the product ships, plus the tests, which is what a token ban reads.
const SWIFT_ROOTS: [&str; 3] = ["Sources", "Tests", "Apps"];

// ------------------------------------------------------------------------------------------- //
// Token bans
// ------------------------------------------------------------------------------------------- //

/// Files allowed to import a crypto framework, each with the reason it is not what the rule bans.
///
/// An allowlist rather than excluding `Tests/` wholesale: a hash over a PINNED ARTIFACT is
/// supply-chain integrity and always will be, while a hash over a credential is the thing the rule
/// exists to stop — and both would live under `Tests/`.
///
/// EMPTY since `docs/60` F.9, and that is the correct state rather than a gap. Its one entry was
/// the vendored-tools SHA-256, and the tools pin is `rust/slopdesk-provision`'s now — a Rust crate
/// this rule does not read, because the ban is on Swift reaching for a crypto framework at all.
/// The staleness check below is what keeps an empty list honest: an entry naming a file that has
/// gone is a hole in the ban, not a comment.
const CRYPTO_ALLOWED: [(&str, &str); 0] = [];

/// `CLAUDE.md`: "No app-layer crypto or auth — security is the `WireGuard` mesh."
///
/// The way that rule dies is one import, for one hash, in one file, six months before anyone reads
/// the sentence that forbids it.
#[must_use]
pub fn no_app_layer_crypto(tree: &Tree) -> Report {
    let mut report = Report::new();
    let stale: Vec<String> = CRYPTO_ALLOWED
        .iter()
        .filter(|(name, _)| !tree.has(name))
        .map(|(name, _)| (*name).to_owned())
        .collect();
    sites(
        &mut report,
        "a crypto allowlist entry names a file that does not exist",
        &stale,
    );

    let swift = report.corpus(tree, &SWIFT_ROOTS, &["swift"]);
    let found: Vec<String> = hits(&swift, r"^\s*import\s+(CryptoKit|CommonCrypto)\b")
        .into_iter()
        .filter(|line| {
            let file = line.split(':').next().unwrap_or_default();
            !CRYPTO_ALLOWED.iter().any(|(allowed, _)| *allowed == file)
        })
        .collect();
    sites(
        &mut report,
        "app-layer crypto reached the tree — security here is the WireGuard mesh",
        &found,
    );
    report
}

/// `CLAUDE.md`: "cargo never runs inside `swift build`."
///
/// A `SwiftPM` `.plugin`/`buildTool` in the manifest is exactly the shape that rule forbids, and it
/// would arrive looking like a convenience.
#[must_use]
pub fn no_swiftpm_build_plugin(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(manifest) = report.source(tree, "Package.swift", "the SwiftPM manifest is the gate") else {
        return report;
    };
    let found = hits(
        &[(Path::new("Package.swift"), manifest)],
        r"\.plugin\(|buildTool\(|\.buildTool\b",
    );
    sites(
        &mut report,
        "Package.swift declares a build plugin — the FFI artifact is built by 'just ffi'",
        &found,
    );
    report
}

/// `CLAUDE.md`: keep `a * b + c` as two roundings — the golden corpus pins the bit patterns.
///
/// The METHOD form only. `gf256`'s and `slopdesk-gfsimd`'s fused ops are Galois-field region ops
/// over `u8` with nothing to do with float rounding; a path call is never a float fusion.
///
/// This crate is INSIDE the corpus it scans, which the Python was not — so the break-tests below
/// spell the banned tokens in halves that only a `concat!` joins. An exemption would have been the
/// other answer and a worse one: the gate would stop watching the one crate whose whole job is to
/// watch, and this crate does arithmetic of its own.
#[must_use]
pub fn no_fused_multiply_add(tree: &Tree) -> Report {
    let mut report = Report::new();
    let swift = report.corpus(tree, &SWIFT_ROOTS, &["swift"]);
    let rust = report.corpus(tree, &["rust"], &["rs"]);
    // `(?:^|[^\w.])` is the negative lookbehind the Python spelled `(?<![\w.])`: a bare `fma(` is a
    // fusion and `path.fma(` or `wfma(` is not.
    let mut found = hits(&swift, r"\.addingProduct\(|(?:^|[^\w.])fma\(");
    found.extend(hits(&rust, r"\.mul_add\("));
    sites(
        &mut report,
        "a fused multiply-add reached the tree — FMA rounds once, the wire rounds twice",
        &found,
    );
    report
}

/// `CLAUDE.md`: "Never `pkill` the host — `just host-restart` replays hostd's recorded launch."
///
/// A harness that kills a host it STARTED is fine, and several do: each spawns its own on a private
/// port and reaps it. What is banned is the UNQUALIFIED form, which reaches the developer's running
/// hostd as readily as the harness's own. So the question is not "does this say pkill" but "does a
/// pkill naming hostd carry the qualifier that scopes it to a host this recipe started".
///
/// This rule had already stopped asserting half of what it claimed, and the reason is the whole
/// point of [`Report::corpus`]. The corpus was `scripts/**/*.sh` plus the justfile; the last `.sh`
/// left `scripts/` when the harnesses were ported, the walk returned nothing, and the shell half
/// sat green for as long as it took anybody to notice. The tempting repair — narrow to the
/// justfile, which is where a gate is invoked from — is the SAME bug one step on: the justfile
/// spells `pkill` nowhere, so the ban would still be asking nobody anything. The subject did not
/// disappear, it MOVED, and a rule that does not follow its subject is vacuous however loudly it is
/// written.
///
/// So the corpus is `rust/**/*.rs` — where every harness that kills anything now lives — plus the
/// justfile, which is still allowed to shell out. Two spellings reach the syscall: the one wrapper,
/// `gui::kill_matching`, and a raw `Command::new("/usr/bin/pkill")`. In Rust the verb and its
/// target land on different lines, so a site is the matching line joined with the [`WINDOW`] after
/// it: that is what makes `.args(["-f", …])` two lines below a `Command::new` readable at all. A
/// window can pull in an unrelated `slopdesk-hostd` three lines down and report a site that is not
/// one — a false alarm, never a false pass, which is the direction a ban is allowed to be wrong in.
///
/// The window closes the gap between a verb and a pattern WRITTEN NEXT TO IT, and nothing further.
/// A `kill_matching(app_pattern)` whose pattern was built somewhere else is invisible here, and
/// several sites are spelled that way. That is the standing reach of a token ban rather than a hole
/// to fill: following a `String` to where it was made is dataflow analysis, and this crate reads
/// text.
///
/// `rust/slopdesk-invariants` is the one exclusion, and the module header above says why: a grep
/// for `pkill` matching the gate's OWN failure message is one of the three silent failures this
/// file was ported to stop. The break-test fixtures below spell the banned form as string literals,
/// and [`Source::statements`] keeps string literals on purpose, so the crate that states the ban
/// would convict itself for stating it.
#[must_use]
pub fn pkill_never_reaches_the_developers_host(tree: &Tree) -> Report {
    let mut report = Report::new();
    let mut corpus: Vec<(&Path, &Source)> = report
        .corpus(tree, &["rust"], &["rs"])
        .into_iter()
        .filter(|(path, _)| !path.starts_with(STATES_THE_BAN))
        .collect();
    if let Some(justfile) = report.source(tree, "justfile", "a recipe may still shell out to one") {
        corpus.push((Path::new("justfile"), justfile));
    }
    let a_kill = text::cached(r"pkill|kill_matching\s*\(");
    let mut found = Vec::new();
    for (path, source) in &corpus {
        let lines: Vec<&str> = source.statements().lines().collect();
        for (number, line) in lines.iter().enumerate() {
            if !a_kill.is_match(line) {
                continue;
            }
            let end = lines.len().min(number + WINDOW);
            let site = lines.get(number..end).unwrap_or_default().join(" ");
            if site.contains("slopdesk-hostd") && !site.contains("--port") && !site.contains("DerivedData") {
                found.push(format!("{}:{}: {}", path.display(), number + 1, line.trim()));
            }
        }
    }
    sites(
        &mut report,
        "an unqualified pkill names slopdesk-hostd — it would reap the running host",
        &found,
    );
    report
}

/// The crate whose failure message quotes the ban it enforces, and so cannot be in its own corpus.
const STATES_THE_BAN: &str = "rust/slopdesk-invariants";

/// How many lines a kill and its pattern may be apart — `Command::new`, `.args`, and slack for one.
const WINDOW: usize = 4;

/// The prek config, which is not under [`ROOTS`](crate::tree) and so is read rather than walked.
const HOOKS: &str = ".pre-commit-config.yaml";

/// Every nightly this tree asks for is the LATEST one — never a `nightly-YYYY-MM-DD`.
///
/// Two toolchains here are nightly, for two unrelated reasons: rustfmt, because `rust/rustfmt.toml`
/// turns on thirteen unstable options, and Miri. Neither is pinned, and the pressure to pin comes
/// from the formatter, so the argument is worth writing down where the ban lives.
///
/// `wrap_comments` decides where a comment BREAKS. That is rustfmt's own judgement and it changes
/// between nightlies, so the day rustup fetches a new one the tree is red on files nobody touched —
/// on 2026-08-30, 3123 lines across 215 files, with no code change behind them. A date pin makes
/// that stop, and buys a worse thing: the formatter, the linter and the commit hook all agreeing
/// with each other about a rustfmt from months ago, with the bump deferred until it is a thousand-
/// file commit nobody wants to review. The standing decision is the other way — take the reformat
/// when it arrives, as its own commit, and stay current. `just install-tools` installs-or-updates
/// the floating channel with the one verb, so "have the tools" and "be on the latest" are one step.
///
/// So the rule is a ban, not a requirement, and it reads both places a toolchain can be named: the
/// justfile, and the prek hooks. The hooks half is the easiest to lose — `.pre-commit-config`'s
/// `rustfmt (apply)` enters `just fmt-rust` rather than cargo, precisely so the commit path cannot
/// disagree with the gate — and that file is outside the walked roots, so it arrives through
/// [`Tree::read`] rather than the tree.
///
/// A missing one IS a violation, and the sentence here used to say the opposite: "this rule is
/// about what a config says, not about whether hooks are installed". That reasoning confused two
/// files. The hooks are installed under `.git/`, which nothing here reads;
/// `.pre-commit-config.yaml` is TRACKED, so its absence is a rename or a deletion rather than a
/// machine that never ran `prek install` — and swallowing it left half this ban asserting nothing
/// on a tree that still had a nightly pinned in the other half's blind spot.
#[must_use]
pub fn nightly_is_never_pinned_to_a_date(tree: &Tree) -> Report {
    let mut report = Report::new();
    let mut dated = Vec::new();
    if let Some(justfile) = report.source(tree, "justfile", "every toolchain this tree asks for is in it") {
        dated.extend(hits(
            &[(Path::new("justfile"), justfile)],
            r"nightly-\d{4}-\d{2}-\d{2}",
        ));
    }
    match tree.read(HOOKS) {
        Ok(hooks) => {
            let a_date = text::cached(r"nightly-\d{4}-\d{2}-\d{2}");
            dated.extend(
                hooks
                    .lines()
                    .enumerate()
                    .filter(|(_, line)| !line.trim_start().starts_with('#') && a_date.is_match(line))
                    .map(|(number, line)| format!("{HOOKS}:{}: {}", number + 1, line.trim())),
            );
        },
        Err(error) => {
            report.fail(format!(
                "{HOOKS}: {error} — the commit path's half of this ban was not read, and an unread half is \
                 a half that passes"
            ));
        },
    }
    sites(
        &mut report,
        "a nightly toolchain is pinned to a date — every one of them tracks the latest, and a rustfmt \
         reformat is a commit to take rather than a bump to defer",
        &dated,
    );
    report
}

/// POSIX `'…'` quoting was written eight times; it lives once, behind `slopdesk_ws_shell_quote`.
///
/// This gate existed in `check-supervisor.sh` and could not fail: it piped 742 paths into
/// `xargs grep -ln`, which prints the offender and still exits non-zero when the final batch is
/// clean — so the surrounding `if hit=$(…)` was false exactly when there was something to report.
#[must_use]
pub fn shell_quoting_has_one_owner(tree: &Tree) -> Report {
    let mut report = Report::new();
    let swift = report.corpus(tree, &["Sources"], &["swift"]);
    let found = hits(&swift, r#"replacingOccurrences\(of: "'""#);
    sites(
        &mut report,
        "a site quotes a shell word itself — every one asks slopdesk_ws_shell_quote",
        &found,
    );
    report
}

// ------------------------------------------------------------------------------------------- //
// The scripts themselves
// ------------------------------------------------------------------------------------------- //

/// Nothing under `scripts/` is a program any more.
///
/// The two rules this replaces — every script sets `pipefail`, every shebang carries the mode bit —
/// were true and are now unaskable: the last shell script and the last Python script left the tree
/// in the change that added this. A rule whose corpus is empty PASSES, and a check that cannot fail
/// is worse than one that is missing, because the log says it ran.
///
/// So the corpus becomes the rule. `scripts/` holds pins, fixtures and two Swift probes — data and
/// source, nothing executable — and a `.sh`, `.py`, `.bash`, `.zsh` or `.awk` arriving anywhere
/// this crate walks is the standing decision reversing itself by accident. Scripting is Rust: a
/// `slopdesk-gate` verb, a `slopdesk-ops` harness, or a rule in this crate. That is not a style
/// preference — a shell gate's decidable half cannot be unit-tested, which is how four of the
/// ported ones turned out to have been reading an empty haystack for years.
///
/// There used to be an exception, and it is gone rather than widened. `ThirdParty/ghostty/` held
/// `build-libghostty.sh` — the dependency's own builder, carried close to upstream's shape — so the
/// walk skipped it by prefix. docs/68 deleted the fork, `ThirdParty` is not a `Tree::ROOTS` entry
/// any more, and a filter for a directory the walk cannot reach is a rule about nothing.
/// `ThirdParty/tools/` was NEVER out of scope, and the distinction was authorship rather than
/// directory — `provision.sh` lived there and was ours, and
/// the argument that kept it (a bootstrap installs what a Rust gate would need) was never true of
/// it: it installs the PANEL's runtime deps, and cargo is a prerequisite of this tree either way.
/// It is `rust/slopdesk-provision` now, and this rule is what stops it coming back.
#[must_use]
pub fn scripting_is_rust(tree: &Tree) -> Report {
    let mut report = Report::new();
    let found: Vec<String> = tree
        .paths()
        .filter(|path| {
            path.extension()
                .and_then(|value| value.to_str())
                .is_some_and(|value| matches!(value, "sh" | "bash" | "zsh" | "py" | "awk"))
        })
        .map(|path| path.display().to_string())
        .collect();
    sites(
        &mut report,
        "a shell or Python script is back in the tree — scripting is Rust (a slopdesk-gate verb, a \
         slopdesk-ops harness, or a rule in this crate), because a shell gate's decidable half cannot be \
         unit-tested",
        &found,
    );
    report
}

// ------------------------------------------------------------------------------------------- //
// The release, in three steps
// ------------------------------------------------------------------------------------------- //

/// The one file the tool arrays live in — read by the release binary's own modules and by two
/// rules here.
const SHIPPED_TOOLS: &str = "rust/slopdesk-devtools/src/release/tools.rs";
/// The per-binary version pins `MANIFEST.json` publishes.
const TOOL_PIN: &str = "scripts/tool-stamps.pin";
/// The formula the release workflow copies into the tap, rewriting only `version` and `sha256`.
const FORMULA: &str = "packaging/homebrew/Formula/slopdesk.rb";

/// Every `slopdesk-…` name inside the named tool arrays of the release binary's tool table.
///
/// Reading the ARRAYS rather than the file is the whole gate: a first draft grepped the whole
/// packager, which the commentary around those arrays — it names every daemon — satisfied on its
/// own. A gate a comment can pass is not a gate. The same reason keeps this a TEXT read after the
/// table became Rust: a gate that linked the crate it judges would be judging itself.
fn shipped(tree: &Tree, report: &mut Report, arrays: &str, name_pattern: &str) -> BTreeSet<String> {
    let Some(tools) = report.source(tree, SHIPPED_TOOLS, "the shipped tool arrays live there") else {
        return BTreeSet::new();
    };
    let bodies = text::capture_all(
        &tools.text,
        &format!(r"(?s)^pub const (?:{arrays}): &\[&str\] =(.*?)\]"),
    );
    if bodies.is_empty() {
        report.fail(format!(
            "{SHIPPED_TOOLS}: the release tool arrays are gone — this gate is blind"
        ));
        return BTreeSet::new();
    }
    bodies
        .iter()
        .flat_map(|body| text::capture_set(body, name_pattern))
        .collect()
}

/// A daemon hostd resolves at runtime and the tarball omits is a feature that cannot run.
///
/// This gate exists because the tarball was three binaries — `slopdesk`, `slopdesk-hostd`,
/// `slopdesk-ctl` — while hostd resolved eight more, superd among them. superd forks every PTY
/// master, so a `brew install` produced a host that could not open a single pane, and no gate could
/// see it: the release path is exercised by TAGGING, and a change that moves an implementation out
/// of the Swift graph is invisible to everything that is not a release.
///
/// Derived from the call sites, not from a list: every `RustServicePaths.locate`/`locateBeside`
/// names the binary it wants, so a seventh daemon is covered the day someone writes the lookup. Two
/// names cannot be found that way and are added explicitly rather than left to an approximation
/// that would quietly drop them — `slopdesk-superd`, which hostd reaches by SOCKET and never by
/// path, and `slopdesk-hook`, which `slopdesk-agenthooks` copies from its own directory.
#[must_use]
pub fn the_release_ships_every_sidecar_the_host_needs(tree: &Tree) -> Report {
    let mut report = Report::new();
    let mut wanted: BTreeSet<String> = ["slopdesk-superd", "slopdesk-hook"]
        .iter()
        .map(|name| (*name).to_owned())
        .collect();

    let locate = text::cached(
        r#"RustServicePaths\.locate(?:Beside)?\(\s*(?:"(?P<literal>slopdesk-[a-z]+)"|(?P<symbol>\w+))"#,
    );
    for (_, source) in report.corpus(tree, &["Sources"], &["swift"]) {
        let constants = text::capture_set(source.statements(), r#"\bbinaryName\s*=\s*"(slopdesk-[a-z]+)""#);
        for capture in locate.captures_iter(source.statements()) {
            if let Some(literal) = capture.name("literal") {
                wanted.insert(literal.as_str().to_owned());
            } else if capture
                .name("symbol")
                .is_some_and(|it| it.as_str() == "binaryName")
            {
                wanted.extend(constants.iter().cloned());
            }
        }
    }

    let carried = shipped(
        tree,
        &mut report,
        "RUST_ROOT_TOOLS|RUST_CRATE_TOOLS",
        r"\b(slopdesk-[a-z]+)\b",
    );
    if carried.is_empty() {
        return report;
    }
    let missing: Vec<String> = wanted.difference(&carried).cloned().collect();
    sites(
        &mut report,
        "the host resolves a sidecar the release tarball does not ship",
        &missing,
    );
    report
}

/// A sidecar the pin has never heard of ships at whatever its `Cargo.toml` happened to say.
///
/// `MANIFEST.json` publishes a version per binary, and the install side restarts a daemon when that
/// version moves — so a tool missing from `scripts/tool-stamps.pin` is not a cosmetic gap.
/// `slopdesk-release package` would find no pinned version, and `bump-tools` would treat the tool
/// as new on every single run, bumping it whether or not it changed. Either way the number
/// stops meaning "this daemon is different from the one you have", which is the only thing it is
/// for.
///
/// Only the tools that carry a version of their OWN. `PRODUCT_TOOLS` — `slopdesk` and
/// `slopdesk-hostd` — ARE the product, and their number is the product's (`docs/49` §"The six
/// version sites"). A pin entry for either would be a seventh version site, exactly the thing
/// `slopdesk-release bump-product` exists to prevent.
///
/// The subtraction is spelled out rather than left to the name pattern. It used to be implicit —
/// `slopdesk` was `SwiftPM`'s, so reading the two cargo arrays excluded it by construction. Since
/// the CLI process was ported out of Swift it is a cargo tool AND a product tool, and the only
/// thing still keeping it out of `carried` would be that `slopdesk-[a-z]+` wants a hyphen. A gate
/// that holds because of a hyphen is a gate that stops holding when someone widens a regex.
#[must_use]
pub fn every_shipped_sidecar_carries_its_own_version(tree: &Tree) -> Report {
    let mut report = Report::new();
    let product = shipped(tree, &mut report, "PRODUCT_TOOLS", r"\b(slopdesk(?:-[a-z]+)?)\b");
    let carried: BTreeSet<String> = shipped(
        tree,
        &mut report,
        "RUST_ROOT_TOOLS|RUST_CRATE_TOOLS",
        r"\b(slopdesk(?:-[a-z]+)?)\b",
    )
    .difference(&product)
    .cloned()
    .collect();
    if carried.is_empty() {
        return report;
    }
    let Some(pin) = report.source(tree, TOOL_PIN, "every sidecar would be unversioned without it") else {
        return report;
    };
    let pinned: BTreeSet<String> = pin
        .text
        .lines()
        .filter(|line| !line.trim().is_empty() && !line.starts_with('#'))
        .filter_map(|line| line.split_whitespace().next().map(str::to_owned))
        .collect();

    let mut disagreeing: Vec<String> = carried.difference(&pinned).cloned().collect();
    // A pin entry for a tool nobody ships is the same bug wearing the other hat: it keeps a stale
    // version alive in `MANIFEST.json` for a binary that is not in the tarball.
    disagreeing.extend(pinned.difference(&carried).cloned());
    sites(
        &mut report,
        "scripts/tool-stamps.pin and the shipped cargo tools disagree — run `slopdesk-release bump-tools`",
        &disagreeing,
    );
    report
}

/// A binary the tarball carries and the formula does not name is a feature `brew` cannot run.
///
/// This is the same failure [`the_release_ships_every_sidecar_the_host_needs`] catches one step
/// earlier, at the step nothing was watching. The tarball was fixed to carry all twelve tools; the
/// FORMULA went on installing three of them for four releases, so a `brew install` still produced a
/// host with no superd and therefore no pane. Nothing could see it, for the same reason as before
/// and one repository over: the formula lived in `aislopware/homebrew-tap`, and a file in another
/// repository is checked by nobody. So the formula lives here and the release workflow copies it
/// into the tap — which makes it a file in this tree, which makes it gateable.
///
/// `MANIFEST.json` is checked too, and it is not decoration: `slopdesk sidecars` diffs it against
/// the copy recorded by the previous install to say WHICH binaries an upgrade changed. Without it
/// installed the only honest answer is "all of them", which is the all-or-nothing upgrade the
/// per-tool version exists to end (`docs/49`).
#[must_use]
pub fn the_formula_installs_every_binary_the_release_ships(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(formula) = report.source(tree, FORMULA, "the tap has no other source of truth") else {
        return report;
    };
    let Some(block) = text::capture_first(&formula.text, r"(?s)bin\.install\b(.*?)\n\n") else {
        report.fail(format!(
            "{FORMULA}: the formula has no bin.install — this gate is blind"
        ));
        return report;
    };
    let installed = text::capture_set(&block, r#""(slopdesk(?:-[a-z]+)?)""#);

    let carried = shipped(
        tree,
        &mut report,
        "RUST_ROOT_TOOLS|RUST_CRATE_TOOLS",
        r"\b(slopdesk(?:-[a-z]+)?)\b",
    );
    if carried.is_empty() {
        return report;
    }
    if !formula.text.contains(r#"prefix.install "MANIFEST.json""#) {
        report.fail(format!(
            "{FORMULA}: the formula installs no MANIFEST.json — `slopdesk sidecars` cannot say what changed"
        ));
        return report;
    }

    let mut disagreeing: Vec<String> = carried.difference(&installed).cloned().collect();
    // The other direction is a bug too: a formula naming a binary the tarball does not carry makes
    // `brew install` fail outright on the missing file, which at least is loud — but it is still a
    // claim about the release that the release does not honour.
    disagreeing.extend(installed.difference(&carried).cloned());
    sites(
        &mut report,
        "packaging/homebrew/Formula/slopdesk.rb and the shipped tool set disagree",
        &disagreeing,
    );
    report
}

// ------------------------------------------------------------------------------------------- //
// Ports that stopped one step short
// ------------------------------------------------------------------------------------------- //

/// The modules this gate knows are stranded, each with the Swift that still runs instead.
///
/// They are DEBT, registered so the gate can be green while it shrinks — not exemptions. Removing a
/// name here is the last step of finishing that port; adding one is a change `docs/DECISIONS.md`
/// must record.
///
/// The list is EMPTY, and the liveness loop in the rule below is what keeps it honest. It used to
/// hold `slopdesk-workspace::connection`, registered while `ConnectionTarget.swift` was the copy
/// that should go — and by the time anyone looked, `connect_gate.rs` and `pane_empty.rs` were both
/// spelling `use crate::connection::StatusKind`. The module was reached, the entry excused nothing,
/// and the debt register said the port was unfinished for as long as nobody checked. Debt that has
/// been paid and not struck off is indistinguishable from debt.
///
/// `slopdesk-videohostd::encode`, `::feed`, `::mux_registry` and `::windowgeometry` USED to be
/// here, registered as debt with a known end date: `docs/61` §3 said the capture half was not
/// ported, so with no `SCStream` there were no frames and a `main.rs` that opened the encoder would
/// compose a daemon that ran and served nothing. `Sources/SlopDeskVideoHost` was what actually ran.
///
/// It does not run any more — `docs/61` §1 deleted it — so all four names left in that same commit,
/// because removing a name here is the last step of finishing a port, never a step of its own. If
/// this gate is red on a `slopdesk-videohostd` module, the daemon's composition has not reached it
/// yet and the answer is to WIRE it; putting the name back would re-register debt the deletion
/// already spent.
const STRANDED_RUST_MODULES: [&str; 0] = [];

/// A crate module nothing reaches is a port that stopped one step short of finishing.
///
/// The failure this catches is quiet and expensive: `e6b1ce9b` moved four `slopdesk-workspace`
/// modules to Rust, gave them 47 tests between them, re-exported all four from `lib.rs` — and wired
/// none. `cargo` says nothing, because a `pub` item in a library crate has no unused warning to
/// give; the tests are green; and the Swift the port was meant to delete is what actually runs. Two
/// implementations, which is the one thing `CLAUDE.md` forbids outright.
///
/// A module counts as REACHED when another Rust file names `module::`, or names something `lib.rs`
/// re-exports from it, or when the module exports a `no_mangle` door — that last one is the FFI
/// crate's whole shape, and its caller is Swift, which is not in this tree's `.rs` files. `lib.rs`
/// itself counts as a caller, but its own `pub mod` / `pub use` lines do not: a re-export is what a
/// stranded module has INSTEAD of a caller, so reading it as one would make this gate unable to
/// fail.
///
/// The method names an INHERENT `impl` declares count too, for the same reason a re-exported name
/// does. A module holding nothing but `impl Session` blocks for a `Session` its sibling defines
/// exports no nameable item at all: the type belongs to the other module, the module path leads to
/// nothing a caller could spell, and `lib.rs` has no `pub use` to re-export because there is
/// nothing to re-export. Its methods are reached THROUGH the type — a sibling writes
/// `self.resize_capture` and the effect lands here — so the call site this gate is looking for
/// exists and simply never mentions the module. That is `slopdesk-videohostd::session_actuate` and
/// `::session_resize`, both wired from `session.rs` and both read as stranded until the impl names
/// were evidence.
///
/// Four narrowings keep the gate able to fail, because a method name is far weaker evidence than a
/// type name and would otherwise excuse most of the tree. An impl on a type the module DECLARES is
/// not this shape at all and is skipped: the type is a nameable item, so `module::` and the
/// `pub use` path already answer for it, and counting `as_byte` on a locally declared `StatusKind`
/// as well would buy no reach the gate did not have while handing every `as_byte` in every other
/// crate to whichever module happens to declare one.
///
/// The other three: a TRAIT impl is skipped, because a body satisfying `Display` names the trait's
/// methods and not its own, and those names are spelled in every crate in the tree. Only a method
/// carrying a visibility qualifier counts — a private one cannot be called from a sibling file at
/// all, so its name elsewhere belongs to some other function, and Rust forbids a qualifier on a
/// trait impl's method, which makes this the same narrowing twice over. And the evidence is the
/// CALL shape, the name followed by its open paren, rather than the bare name a re-exported type is
/// matched by: a method is reached by being called, and without the paren a `run` or a `new` named
/// in any comment anywhere would excuse its module. A module of impls whose public methods nobody
/// calls is still red.
#[must_use]
/// The spellings that name THIS module from anywhere in the tree, whatever qualifies them.
///
/// Split out of the loop because the three sources are independent of each other and of the scan
/// that consumes them: the crate-qualified path, whatever `lib.rs` re-exports out of the module,
/// and — for a module of inherent impls, which has no nameable item at all — the CALL shape of each
/// method it hangs on somebody else's type. The relative `crate::`/`super::`/`self::` form and the
/// bare `module::` form are deliberately NOT here: those two are ambiguous across crates, so the
/// caller pairs them with a same-crate flag and a left-context check respectively.
fn unambiguous_reaches(
    module: &str,
    crate_ident: &str,
    body: &str,
    exported: Option<&BTreeSet<String>>,
) -> Vec<String> {
    let mut alternatives = vec![format!(r"\b{crate_ident}::{module}::")];
    if let Some(names) = exported {
        alternatives.extend(names.iter().map(|name| format!(r"\b{name}\b")));
    }
    // What a module of inherent impls has INSTEAD of a nameable item: methods on a type some OTHER
    // module declares. A trait impl is skipped by its `for`, and again by the visibility qualifier
    // the pattern demands — Rust forbids one on a trait method.
    let declared = text::capture_set(
        body,
        r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|union|trait) (\w+)",
    );
    for (header, block) in text::capture_pairs(body, r"(?s)^impl([^\n{]*)\{(.*?)\n\}") {
        let subject = text::capture_first(&header, r"^(?:<[^>]*>)?\s*(\w+)");
        // An impl on a type this module DECLARES is not the stranded shape: the type is a nameable
        // item, so `module::` and the `pub use` path above already speak for it.
        if header.contains(" for ") || subject.is_none_or(|name| declared.contains(&name)) {
            continue;
        }
        alternatives.extend(
            text::capture_all(&block, r"^\s+pub(?:\([^)]*\))?(?: (?:const|async|unsafe|extern))* fn (\w+)")
                .into_iter()
                // The CALL, not the name: a method is reached by being called, and a bare name
                // would let any mention in any comment excuse the module.
                .map(|name| format!(r"\b{name}\s*\(")),
        );
    }
    alternatives
}

/// Every module a `lib.rs` declares is reached from somewhere — by its path, by a name the crate
/// re-exports, or by a call to a method it adds to another module's type.
pub fn no_rust_module_is_written_and_then_never_called(tree: &Tree) -> Report {
    let mut report = Report::new();
    let sources = report.corpus(tree, &["rust"], &["rs"]);
    let mut found = Vec::new();
    let mut spent = Vec::new();

    for (lib, source) in sources.iter().filter(|(path, _)| path.ends_with("lib.rs")) {
        let Some(directory) = lib.parent() else {
            continue;
        };
        let crate_name = directory
            .parent()
            .and_then(Path::file_name)
            .map_or_else(String::new, |name| name.to_string_lossy().into_owned());

        // What `lib.rs` re-exports, per module. A caller naming one of these names reaches the
        // module without ever spelling `module::`, which is the ordinary shape for a crate whose
        // public surface is flat.
        let mut exported: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
        for (module, group) in text::capture_pairs(source.statements(), r"(?s)^pub use (\w+)::\{(.*?)\};") {
            let names = group.replace('\n', " ");
            for name in names.split(',') {
                let name = name.trim().split(" as ").next().unwrap_or_default().trim();
                if !name.is_empty() && name != "self" {
                    exported
                        .entry(module.clone())
                        .or_default()
                        .insert(name.to_owned());
                }
            }
        }
        for (module, name) in text::capture_pairs(source.statements(), r"^pub use (\w+)::(\w+);") {
            exported.entry(module).or_default().insert(name);
        }

        for module in text::capture_all(source.statements(), r"^pub mod (\w+);") {
            let file = directory.join(format!("{module}.rs"));
            let folder = directory.join(&module);
            let inside: Vec<&(&Path, &Source)> = sources
                .iter()
                .filter(|(path, _)| *path == file.as_path() || path.starts_with(&folder))
                .collect();
            let body: String = inside.iter().map(|(_, held)| held.text.as_str()).collect();
            if body.contains("no_mangle") {
                continue; // a door; its caller is Swift
            }

            // THIS crate's module, not a homonym in another one. `slopdesk-video` has a `cursor`
            // and a `capture_region` too, and for as long as the pattern was the bare `cursor::`,
            // one `use slopdesk_video::cursor::CursorChannelMessage;` in a sibling file read as a
            // call into `slopdesk-videohostd`'s own `cursor`. So which spellings count depends on
            // WHERE the file that spells them is, and the split is the whole point:
            //
            // * `crate::`, `super::` and `self::` are RELATIVE, so they name this module only from
            //   inside this crate. From outside, `crate::cursor::` names the other crate's — which
            //   is exactly how slopdesk-video's own uses excused this one.
            // * An UNQUALIFIED `cursor::` counts from anywhere, because `use slopdesk_video::
            //   {cursor, geometry};` and then `cursor::X` is the ordinary cross-crate idiom and
            //   nothing short of resolving imports tells the two apart. What it must not do is
            //   count when something already qualifies it, and that is a left-context check rather
            //   than a pattern — see below.
            // * `slopdesk_videohostd::cursor::`, a re-exported name, and a method call on a type
            //   this module does not declare are all unambiguous, so they count from anywhere too.
            //
            // The bare form stays a PURE LITERAL and its left context is checked in Rust below,
            // rather than being spelled `(?:^|[^\w:])`. That spelling is correct and it costs the
            // whole rule: a leading character class has no literal prefix, the regex crate gives up
            // its prefilter for the entire alternation, and one scan of the tree per module turns
            // twenty seconds of `memchr` into twenty minutes of NFA.
            let crate_ident = crate_name.replace('-', "_");
            let here = text::cached(&format!(r"\b(?:crate|super|self)::{module}::"));
            let alternatives = unambiguous_reaches(&module, &crate_ident, &body, exported.get(&module));
            let anywhere = text::cached(&format!(r"(?:{})", alternatives.join("|")));
            let bare = text::cached(&format!("{module}::"));
            let reaches = |text: &str, same_crate: bool| {
                anywhere.is_match(text)
                    || (same_crate && here.is_match(text))
                    || bare.find_iter(text).any(|hit| {
                        // A segment ANYTHING qualifies is somebody else's: `cursor::` inside
                        // `slopdesk_video::cursor::` names slopdesk-video's module, and the
                        // qualified spellings that DO name this one are the two regexes above.
                        text.get(..hit.start())
                            .and_then(|before| before.chars().next_back())
                            .is_none_or(|char| !char.is_alphanumeric() && char != '_' && char != ':')
                    })
            };
            let wired = sources.iter().any(|(path, held)| {
                if inside.iter().any(|(known, _)| known == path) {
                    return false;
                }
                let same_crate = directory.parent().is_some_and(|root| path.starts_with(root));
                // A CALLER, not a mention. `statements()` blanks every comment, because the
                // alternatives above are exactly the strings a `///` link spells — a sibling
                // writing "the way [`crate::windowgeometry::Poller`] is" would otherwise excuse
                // the whole module, and one did.
                if path.ends_with("lib.rs") || path.ends_with("mod.rs") {
                    // A root counts as a caller, but not through its own declarations — and not
                    // just THIS crate's root. `slopdesk-video/src/lib.rs` says `pub use
                    // cursor::{…}` about its OWN `cursor`, and that line, at
                    // the start of a line and qualified by nothing, is the last
                    // thing that excused `slopdesk-videohostd::cursor`.
                    let stripped =
                        text::cached(r"(?s)^pub (?:mod|use) [^;]*;").replace_all(held.statements(), "");
                    return reaches(&stripped, same_crate);
                }
                reaches(held.statements(), same_crate)
            });
            let named = format!("{crate_name}::{module}");
            let known_debt = STRANDED_RUST_MODULES.contains(&named.as_str());
            if known_debt && wired {
                spent.push(named.clone());
            }
            if !wired && !known_debt {
                found.push(format!("{}: pub mod {module};", lib.display()));
            }
        }
    }
    sites(
        &mut report,
        "a Rust module is written and tested and reached by nothing — finish or drop it",
        &found,
    );
    // The other half of the register: an entry excusing a module that IS reached is debt already
    // paid, and it reads exactly like debt outstanding. This costs no fixture anything while the
    // list is empty, and bites the moment a name goes back in and the port behind it finishes.
    sites(
        &mut report,
        "a stranded-module entry excuses a module that is reached — the port finished and the debt register \
         did not hear about it, so strike the name off",
        &spent,
    );
    report
}

/// `public var onSomething: (…) -> …` — the injected-sink shape this codebase wires its views with.
const SINK_DECLARATION: &str = r"public var (on[A-Z][A-Za-z0-9]*)\s*:\s*\(";

/// A seam a view is supposed to install must be installed by a view, not only by a test.
///
/// The pattern all over this tree is an `@ObservationIgnored public var onX: (() -> Void)?` that
/// the model FIRES and a view BINDS. When that state later grows an observable twin the view can
/// read directly, the sink stops being bound — and nothing says so, because firing an unbound
/// optional is a silent no-op and the tests kept assigning it. Three of them survived that way:
/// declared, documented, fired from four call sites, asserted by six tests, and connected to no
/// pixel on either platform.
///
/// That shape is worse than dead code, because a test that binds the sink PASSES — it proves the
/// model fires, which is true, and says nothing about whether anything listens. It is also the
/// shape the two-headed client makes easy: a sink one half binds and the other does not looks alive
/// from anywhere except the half that is silent.
///
/// Tests are deliberately not counted as binders, which is the whole point of the gate. Assignment
/// anywhere in product code counts, including inside the declaring file — an `init` that takes the
/// closure and stores it to `self` is a binding, made by whoever calls the initialiser.
///
/// [`Report::corpus`] floors the two walks, but the SUBJECTS are an extraction rather than a walk,
/// and an extraction has its own empty. The day `SINK_DECLARATION` stops matching — a spelling
/// change, an attribute rename — this rule finds no sinks, finds nothing unbound, and reports the
/// tree as clean while asserting nothing about it. So the subject count is floored too, and the
/// number is 1 rather than today's: a tree that legitimately has one sink left must not have to
/// re-tune a gate to keep it.
#[must_use]
pub fn every_injected_sink_has_someone_who_binds_it(tree: &Tree) -> Report {
    let mut report = Report::new();
    let mut sinks: BTreeMap<String, String> = BTreeMap::new();
    for (path, source) in report.corpus(tree, &["Sources"], &["swift"]) {
        for name in text::capture_all(source.statements(), SINK_DECLARATION) {
            sinks.entry(name).or_insert_with(|| path.display().to_string());
        }
    }
    report.fail_if(
        sinks.is_empty(),
        "no injected sink was extracted from Sources/ — the declaration pattern stopped matching, and this \
         rule now asks nobody to bind anything",
    );
    let product = report.corpus(tree, &["Sources", "Apps", "ThirdParty"], &["swift"]);
    let found: Vec<String> = sinks
        .iter()
        .filter(|(name, _)| {
            // `(?:^|[^A-Za-z0-9_])` and `(?:$|[^=])` are the two lookarounds the Python spelled
            // directly: an assignment, not a comparison, and not the tail of a longer name.
            let assigned = text::cached(&format!(r"(?:^|[^A-Za-z0-9_]){name}\s*=(?:$|[^=])"));
            !product
                .iter()
                .any(|(_, source)| assigned.is_match(source.statements()))
        })
        .map(|(name, home)| format!("{home}: {name}"))
        .collect();
    sites(
        &mut report,
        "an injected sink is bound by nobody outside the tests — it reaches no view",
        &found,
    );
    report
}

// ------------------------------------------------------------------------------------------- //
// Prose that points at files
// ------------------------------------------------------------------------------------------- //

/// The docs a reader is sent to whose citations are checked by SPAN, plus the two front doors.
///
/// These must not lie. Every OTHER document — `docs/19`, the `27` to `31` handoffs, `docs/40`, and
/// all of `docs/ui-shell/` — is a record of a plan as it stood, and a path that was real then is
/// not a defect now. 476 stale citations live in those; 5 lived here, which is the whole argument
/// for drawing the line where `CLAUDE.md` already draws it.
///
/// It stops at `docs/55` on purpose, and the list is not the read-first table.
/// `doc_citations::every_cited_path_exists` covers `docs/57`–`62` and `DESIGN.md`, and covers them
/// with the two things this rule has no shape for: an EXTENSION requirement and `PATH_TOMBSTONES`.
/// Those documents are port LEDGERS — running this rule's semantics over them reports 74 spans, and
/// they are overwhelmingly `Sources/SlopDeskHost` and `rust/slopdesk-workspace::key_repeat`: a
/// deleted target named as the thing a stage deleted, and a Rust module path that is not a file at
/// all. Adding them here would be the gate arguing with the documents' subject, which is the same
/// answer `DELETION_HEADINGS` gives one scale down.
const LIVE_DOCS: [&str; 16] = [
    "CLAUDE.md",
    "README.md",
    "justfile",
    "docs/00-overview.md",
    "docs/20-wire-protocol.md",
    "docs/45-multi-client-state-sync.md",
    "docs/46-gates-env-paths.md",
    "docs/47-simulator-panel.md",
    "docs/48-android-panel.md",
    "docs/49-release-pipeline.md",
    "docs/50-agent-detection-architecture.md",
    "docs/51-process-supervision.md",
    "docs/52-screen-engine.md",
    "docs/53-file-drop-service.md",
    "docs/54-inspector.md",
    "docs/55-ffi-boundary.md",
];

// The roots a backticked span must start with are read off the filesystem — see
// `doc_citations::top_level_directories`, which this rule's twin already calls.

/// A citation whose whole point is that the file is gone. `docs/51` has a "What this deleted"
/// section; flagging it would be the gate arguing with the document's subject.
const DELETION_HEADINGS: [&str; 3] = ["What this deleted", "Deleted", "Removed"];

/// A doc a reader is SENT to must not name a path that is not there.
///
/// The failure is not tidiness. `docs/45` claimed a mitigation —
/// "`…/HostOutputSnifferGoldenGuardTests.swift` asserts the frozen vector still round-trips" — for
/// a test that had moved to Rust with the sniffer. A reader checking whether the blind spot was
/// covered would grep, find nothing, and conclude it was not.
///
/// The roots come off the filesystem rather than a list. The list this replaced was the SAME one
/// `doc_citations::every_cited_path_exists` had already retired for drifting both ways, and it had
/// drifted the same way again: `hid-bridge` and `packaging` were never in it, so `docs/49`'s two
/// `packaging/homebrew` citations were exempt without anyone deciding they should be. Both happen
/// to resolve today, which is the whole shape of the defect — an exemption nobody chose reports
/// nothing until the day it matters.
#[must_use]
pub fn live_docs_cite_files_that_exist(tree: &Tree) -> Report {
    let mut report = Report::new();
    let mut found = Vec::new();
    let mut examined = 0_usize;
    let Some(roots) = super::doc_citations::top_level_directories(tree) else {
        report.fail("the repository root could not be read — no path citation could be scoped");
        return report;
    };
    let roots: Vec<String> = roots.into_iter().map(|root| format!("{root}/")).collect();
    for name in LIVE_DOCS {
        let Some(source) = tree.get(name) else {
            found.push(format!(
                "{name}: the live-doc list names a file that does not exist"
            ));
            continue;
        };
        let spans = text::cached(r"`([^`\s]+)`");
        let suffix = text::cached(r":[\d,+-]+$");
        let numbered = text::cached(r"^docs/(\d+)$");
        let mut deleting = false;
        for (number, line) in source.text.lines().enumerate() {
            if line.starts_with('#') {
                deleting = DELETION_HEADINGS.iter().any(|heading| line.contains(heading));
            }
            if deleting {
                continue;
            }
            for span in spans.captures_iter(line) {
                let raw = span[1]
                    .trim_matches('(')
                    .trim_end_matches(['.', ',', ':', ';', ')']);
                if !roots.iter().any(|root| raw.starts_with(root)) || raw.contains(['*', '{', '}', '…']) {
                    continue;
                }
                examined += 1;
                let trimmed = suffix.replace(raw, "");
                let cited = trimmed.split('#').next().unwrap_or_default();
                let cited = cited.split('§').next().unwrap_or_default();
                // `docs/51` is how this repo cites doc 51, not a path.
                let resolved = numbered.captures(cited).map_or_else(
                    || tree.root().join(cited).exists(),
                    |digits| {
                        // A STRING prefix, not `Path::starts_with`, which compares whole
                        // components: `docs/51-process-supervision.md` does not start with the
                        // component `docs/51-`, and reading it that way made every `docs/51`
                        // citation in the tree a violation.
                        let prefix = format!("docs/{}-", &digits[1]);
                        tree.under("docs")
                            .any(|(path, _)| path.to_string_lossy().starts_with(&prefix))
                    },
                );
                if !resolved {
                    found.push(format!("{name}:{}: {cited}", number + 1));
                }
            }
        }
    }
    // The list being present is checked above, file by file. This is the other absence: sixteen
    // docs all readable and not one backticked span in them starting with a path root. Every way
    // that can happen is a broken extraction — the span pattern, the derived root set, or a
    // `DELETION_HEADINGS` entry grown general enough to swallow every section — and each of them
    // leaves this rule green over docs it never actually read.
    report.fail_if(
        examined == 0,
        "not one path citation was extracted from the live docs — the spans, the roots or the deletion \
         headings stopped matching, and this rule is reporting on documents it did not read",
    );
    sites(
        &mut report,
        "a doc CLAUDE.md sends readers to cites a path that is not in the tree",
        &found,
    );
    report
}

/// A backticked path is a SOURCE citation only when it ends in one of these — a comment saying "see
/// `Foo/Bar.swift`" is making a checkable claim, whereas `Sources/SlopDeskMacUI/Pane` is a place
/// and `SlopDeskError/badFrame` is a `DocC` symbol link that happens to carry a slash.
const CITED_SUFFIXES: [&str; 9] = [
    ".swift", ".rs", ".py", ".sh", ".h", ".toml", ".json", ".yml", ".awk",
];

/// The roots a source citation may be written against. A comment cites either the full repo path or
/// the tail of one (`SlopDeskPhoneUI/Pane/SplitCanvasView.swift`), and both must resolve.
///
/// The example moved in 2026-08-28, and it moved because THIS RULE CAUGHT ITS OWN HEADER: it used
/// to cite the phone's old terminal leaf, `3f11c6e6` deleted that file, and the rule named its own
/// doc comment as a stale citation. That is the check working exactly as docs/62 §4.8 predicts — a
/// rename campaign reds this rule once per stale citation, and each one is a real dangling
/// reference rather than a false positive. The dead path is deliberately NOT backticked here, since
/// a backticked one would be a citation this rule then has to fail.
const CITED_ROOTS: [&str; 8] = [
    "Sources",
    "Tests",
    "Apps",
    "ThirdParty",
    "rust",
    "scripts",
    "docs",
    "golden",
];

/// The directory names a citation may START with and still be a claim about THIS tree.
///
/// Without this the gate reads every `foo/bar.rs` in a comment as a repo path, and the ones that
/// are not are exactly the ones worth quoting: libghostty upstream (`Helpers/Cursor.swift`), a
/// system header (`Carbon/HIToolbox/Events.h`), a runtime file such as slopdesk/config.toml. None
/// is in the tree and none of them should be — a gate that demanded they were would be demanding
/// the comment lie. So the addressable set is the repo roots plus whatever sits one level inside
/// the three source roots, which is derived, never listed.
///
/// Derived is the safer half of that trade and the quieter one, so it carries a floor. Every module
/// name a comment can cite — `SlopDeskWorkspaceCore/…`, `SlopDeskPhoneUI/…` — enters this set HERE
/// and nowhere else, and the [`Report::corpus`] floor downstream cannot see it: that floor asks
/// whether all eight [`CITED_ROOTS`] came back empty, and `Sources` alone going dark leaves seven
/// standing. The rule would keep reading every comment in the tree and quietly stop recognising a
/// module citation as a citation at all. So each root asserts it contributed a name: three roots
/// that between them hold no directory is a walk that died, not a tree anyone shipped.
fn addressable_first_segments(tree: &Tree, report: &mut Report) -> BTreeSet<String> {
    let mut segments: BTreeSet<String> = CITED_ROOTS.iter().map(|root| (*root).to_owned()).collect();
    for root in ["Sources", "Tests", "Apps"] {
        let mut named = 0_usize;
        for (path, _) in tree.under(root) {
            if let Some(child) = path.components().nth(1) {
                segments.insert(child.as_os_str().to_string_lossy().into_owned());
                named += 1;
            }
        }
        report.fail_if(
            named == 0,
            format!(
                "{root}/ contributed no module name — every citation of one is now unaddressable, and this \
                 rule reads the same comments while recognising fewer of them"
            ),
        );
    }
    segments
}

/// A comment that points at a file must point at a file that is there.
///
/// This is [`live_docs_cite_files_that_exist`] aimed at the OTHER half of the prose. The docs a
/// reader is sent to are gated; the ~40 000 lines of header comment that actually explain this
/// codebase were not, and a rename walks straight through them. Increment 63 folded the shared
/// `SwiftUI` target into `SlopDeskPhoneUI` and left nine live citations of `SlopDeskClientUI/…`
/// behind — each one a sentence telling a reader where the other half of a decision lives, and each
/// one resolving to nothing. A `DocC` link into a deleted module is worse than no link: it renders
/// as prose and reads as a fact.
///
/// The rule is SHAPE, not a name list, which is why it cannot decay: a backticked token with a
/// slash in it and a source suffix on the end IS a path claim, so it must resolve — as a repo path
/// or as the tail of one. Names are not checked at all (a module name is not a path, and history
/// that says "it lived in the old shared target" is honest and stays legal).
#[must_use]
pub fn source_comments_cite_files_that_exist(tree: &Tree) -> Report {
    let mut report = Report::new();
    let known = cited_file_index(tree);
    let addressable = addressable_first_segments(tree, &mut report);
    let citation = text::cached(r"`{1,2}([A-Za-z0-9_./+-]+/[A-Za-z0-9_+.-]+)`{1,2}");

    let mut found = Vec::new();
    for (path, source) in report.corpus(tree, &CITED_ROOTS, &["swift", "rs"]) {
        for (number, line) in source.text.lines().enumerate() {
            for capture in citation.captures_iter(line) {
                let cited = &capture[1];
                if is_dead_citation(cited, &addressable, &known, tree) {
                    found.push(format!("{}:{}: {cited}", path.display(), number + 1));
                }
            }
        }
    }
    sites(
        &mut report,
        "a comment cites a source path that is not in the tree — a rename walked past it",
        &found,
    );
    report
}

/// Every citable file in the tree, indexed by BASE NAME.
///
/// The index is by name rather than by path because a citation is usually a TAIL
/// (`SlopDeskPhoneUI/Pane/SplitCanvasView.swift`) rather than a repo path, and a name lookup turns
/// the tail test into one `ends_with` over the few files that could possibly answer it.
fn cited_file_index(tree: &Tree) -> BTreeMap<String, Vec<String>> {
    let mut known: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for path in tree.paths() {
        let display = path.display().to_string();
        if CITED_SUFFIXES.iter().any(|suffix| display.ends_with(suffix)) {
            let name = path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned();
            known.entry(name).or_default().push(display);
        }
    }
    known
}

/// Whether one captured token is a path claim about THIS tree that nothing answers.
///
/// The three filters are in cost order and each drops a different kind of non-claim: a token with
/// no source suffix is a place or a `DocC` symbol, a token whose head is not an addressable segment
/// is somebody else's tree (upstream libghostty, a system header, a runtime `config.toml`), and
/// only what survives both is asked to resolve.
fn is_dead_citation(
    cited: &str,
    addressable: &BTreeSet<String>,
    known: &BTreeMap<String, Vec<String>>,
    tree: &Tree,
) -> bool {
    if !CITED_SUFFIXES.iter().any(|suffix| cited.ends_with(suffix)) {
        return false;
    }
    let tail = cited.trim_start_matches(['.', '/']);
    if !tail
        .split('/')
        .next()
        .is_some_and(|head| addressable.contains(head))
    {
        return false;
    }
    let name = tail.rsplit('/').next().unwrap_or_default();
    let resolved = known
        .get(name)
        .is_some_and(|paths| paths.iter().any(|real| real.ends_with(tail)));
    // The tree holds the roots a rule reads, which is not quite every file `git` sees: the vendored
    // dependency's own scripts sit outside it and are citable. So a tail the index cannot place is
    // asked of the filesystem before it is called a lie.
    !resolved && !tree.root().join(tail).exists()
}

/// The repo's own configuration, which cites paths and is read by no compiler.
///
/// Every one of these is outside the walk in [`crate::tree::Tree`] — top-level dotfiles are not
/// under a root, and `justfile` is held there but is scanned by neither citation rule, since it has
/// no extension and its sibling reads two. So the whole corpus comes through the `read` escape
/// hatch. `.github/workflows` is enumerated rather than listed — a workflow added tomorrow is
/// covered the day it lands, which is the only way this corpus stays honest without somebody
/// maintaining it.
///
/// `justfile` is the one whose RECIPES are read as well as its comments, and deliberately: a recipe
/// that names a deleted path is a worse failure than a comment that does, and it costs nothing to
/// judge both — the tree's own recipes cite no path that is not there.
const CITING_CONFIGS: [&str; 8] = [
    ".editorconfig",
    ".gitignore",
    ".pre-commit-config.yaml",
    ".shellcheckrc",
    ".swiftformat",
    ".swiftlint.yml",
    "cliff.toml",
    "justfile",
];
/// The workflow directory, walked whole. `.disabled` files included: a dormant workflow whose own
/// header says it is "kept CORRECT because a dormant workflow rots silently" is the one that most
/// needs asking.
const WORKFLOW_DIR: &str = ".github/workflows";

/// The same claim as [`source_comments_cite_files_that_exist`], asked of the CONFIGURATION.
///
/// That rule reads `.swift` and `.rs`, which is where a citation usually rots. It is not where the
/// shell port's citations rotted. When `scripts/` stopped holding programs, four references to the
/// deleted scripts survived — in a `.gitignore` comment, in the live release workflow, and in the
/// dormant one whose own header claims it is "kept CORRECT because a dormant workflow rots
/// silently" — and every one of them was invisible: no compiler parses these files, no formatter
/// rewrites them, and the citation rule's corpus stopped at two extensions.
///
/// TWO differences from its sibling, both forced by what these files are. The corpus is a list of
/// FILES rather than roots, because configuration is where it is rather than under a tree. And a
/// citation here need not be BACKTICKED: `.gitignore` and `.editorconfig` are plain prose with no
/// markup convention at all, so the backticks are stripped and the bare token is what is read.
/// That is only safe because the head test does the real filtering — a URL's `github.com/…`, a
/// glob, a formula path under `packaging/` are all rejected before anything is asked to resolve.
///
/// `.md` is deliberately NOT here, and widening it there would be a mistake rather than an
/// improvement: `docs/DECISIONS.md` is a DATED record, and a 2026-07 entry that names the script
/// which was live in 2026-07 is telling the truth. [`live_docs_cite_files_that_exist`] already
/// covers the docs a reader is actively sent to.
#[must_use]
pub fn config_files_cite_files_that_exist(tree: &Tree) -> Report {
    let mut report = Report::new();
    let known = cited_file_index(tree);
    let addressable = addressable_first_segments(tree, &mut report);
    // No backtick in the pattern: the caller blanks them first, so one spelling reads both a
    // markdown-ish `path` and a bare one. Rust's regex has no lookbehind, so the left boundary is a
    // consumed character class and the path is group 1.
    let citation = text::cached(r"(?:^|[^A-Za-z0-9_./+-])([A-Za-z0-9_.+-]+(?:/[A-Za-z0-9_.+-]+)+)");

    let mut corpus: Vec<(String, String)> = Vec::new();
    for name in CITING_CONFIGS {
        if let Ok(text) = tree.read(name) {
            corpus.push(((*name).to_owned(), text));
        }
    }
    let mut workflows = 0_usize;
    if let Ok(entries) = std::fs::read_dir(tree.root().join(WORKFLOW_DIR)) {
        let mut named: Vec<String> = entries
            .filter_map(Result::ok)
            .filter(|entry| entry.path().is_file())
            .filter_map(|entry| entry.file_name().into_string().ok())
            .collect();
        named.sort();
        for file in named {
            let path = format!("{WORKFLOW_DIR}/{file}");
            if let Ok(text) = tree.read(&path) {
                workflows += 1;
                corpus.push((path, text));
            }
        }
    }
    // The floor [`Report::corpus`] carries, restated for a corpus assembled by hand. A rename of
    // `.github/workflows`, or a dotfile list that has drifted off every real name, leaves this rule
    // reading nothing and reporting green — which is the failure it exists to catch, one level up.
    report.fail_if(
        corpus.len() < 2 || workflows == 0,
        format!(
            "the config corpus came back as {} file(s) and {workflows} workflow(s) — this rule scans almost \
             nothing and passes by asking nobody anything",
            corpus.len()
        ),
    );

    let mut found = Vec::new();
    for (path, text) in &corpus {
        for (number, line) in text.lines().enumerate() {
            let plain = line.replace('`', " ");
            for capture in citation.captures_iter(&plain) {
                let cited = &capture[1];
                if is_dead_citation(cited, &addressable, &known, tree) {
                    found.push(format!("{path}:{}: {cited}", number + 1));
                }
            }
        }
    }
    sites(
        &mut report,
        "a config file cites a source path that is not in the tree — no compiler reads these, so nothing \
         else would have noticed",
        &found,
    );
    report
}

/// Where the operator harnesses live, one module per thing that used to be a shell script.
const OPS: &str = "rust/slopdesk-devtools/src/ops";
/// The module that spells the container, and so is allowed to name it without calling it.
const OPS_CONTAINER: &str = "mod.rs";
/// The build products whose launch lands on a `<App Support>/SlopDesk` unless it is redirected.
const HOST_DAEMONS: [&str; 2] = ["slopdesk-hostd", "slopdesk-videohostd"];
/// The four variables a container is, which is the thing [`OPS_CONTAINER`] must keep naming.
const CONTAINER_VARIABLES: [&str; 4] = [
    "SLOPDESK_APP_SUPPORT_DIR",
    "SLOPDESK_SCROLLBACK_DIR",
    "SLOPDESK_FILE_DROP_DIR",
    "SLOPDESK_WORKSPACE_STATE_DIR",
];
/// A module that names a daemon and must NOT contain it, with the reason written down.
///
/// TWO entries, and a third is a design decision rather than a convenience: an exemption is "this
/// harness acts on the developer's OWN daemon on purpose", which is true of exactly these.
///
/// The second was added by `docs/60` F.9, when the menu-bar app that gave a cold machine its first
/// hostd was deleted and `install hostd` took its place. It is the sharper of the two: `hostd.rs`
/// merely must not move state out from under a running daemon, while the installer writes a
/// `LaunchAgent` that outlives the command — a container there would hand launchd a hostd
/// permanently pointed at a scratch directory, which is the bug this rule exists to prevent,
/// installed rather than run.
const OPS_UNCONTAINED: [(&str, &str); 2] = [
    (
        "hostd.rs",
        "restarts the developer's own live hostd by replaying the environment that daemon RECORDED for \
         itself. Imposing a container would move the state directories out from under the panes it is \
         holding, which is the opposite of restarting it identically.",
    ),
    (
        "launchd.rs",
        "installs the developer's REAL LaunchAgent, whose whole job is to start the daemon they will \
         actually use. A container would be baked into a plist that outlives the command and point every \
         later launch at a scratch directory.",
    ),
];

/// An operator harness that STARTS a daemon gives it a container
///
/// `HOME` moves none of the four directories the daemons write — Core Foundation reads the account
/// record for `NSHomeDirectory()` — so a daemon started without the set lands on the developer's
/// own `<App Support>/SlopDesk`: it sweeps their scrollback journals to the newest 256 on its first
/// loop, rewrites the `workspace-state.json` of the layout they are working in, resolves their
/// `~/Downloads` as its file-drop directory, and (for `slopdesk-videohostd`) reads and then UNLINKS
/// the `parked-windows.json` crash journal belonging to their own running host.
///
/// This is the Rust half of a contract `GuiGateLaunchContractTests` already keeps over `scripts/`,
/// and it is here because the two harnesses that most needed it were the two that did NOT look like
/// a gate — a soak and a manual input harness — and both went without for months. The shell version
/// discovered its subjects by walking a directory rather than reading a list, for exactly that
/// reason, and so does this: the day a new module under `ops/` execs a daemon, it is asked for the
/// container whether or not anybody thought to say so.
#[must_use]
pub fn an_ops_harness_that_starts_a_daemon_contains_it(tree: &Tree) -> Report {
    let mut report = Report::new();
    let files = report.corpus(tree, &[OPS], &["rs"]);
    report.fail_if(
        files.is_empty(),
        format!("{OPS}: the walk found no modules — this rule reads nothing and would pass vacuously"),
    );

    let mut launchers = 0_usize;
    let mut found = Vec::new();
    for (path, source) in &files {
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default();
        let code = source.statements();
        if name == OPS_CONTAINER {
            for variable in CONTAINER_VARIABLES {
                report.fail_if(
                    !code.contains(variable),
                    format!(
                        "{OPS}/{OPS_CONTAINER}: the container no longer names `{variable}` — a harness that \
                         calls it would be uncontained and this rule would still pass"
                    ),
                );
            }
            continue;
        }
        if !HOST_DAEMONS.iter().any(|daemon| code.contains(daemon)) {
            continue;
        }
        launchers += 1;
        if OPS_UNCONTAINED.iter().any(|(exempt, _)| *exempt == name) || code.contains("container(") {
            continue;
        }
        found.push(path.display().to_string());
    }
    report.fail_if(
        launchers == 0,
        format!("{OPS}: no module names a host daemon — the discovery is broken, not the tree"),
    );
    let exempt: Vec<String> = OPS_UNCONTAINED
        .iter()
        .map(|(name, why)| format!("{name} is exempt because it {why}"))
        .collect();
    sites(
        &mut report,
        &format!(
            "an ops harness starts a host daemon with no container — it lands on the DEVELOPER's own state. \
             ({})",
            exempt.join(" ")
        ),
        &found,
    );
    report
}

/// Where the `LaunchAgent` shapes live, and the marker that says one is the guarded kind.
const LAUNCHD: &str = "rust/slopdesk-devtools/src/ops/launchd.rs";
/// Any ONE of these in a daemon's `main.rs` is a deliberate exit 0 — the thing the guarded
/// `KeepAlive` is guarding. Three spellings because the two daemons reach it differently:
/// superd RETURNS `ExitCode::SUCCESS` when the lock is held, hostd computes its code from whether
/// the bind error was `AddrInUse`, and a future one may just call `exit(0)`.
const DELIBERATE_SUCCESS: [&str; 3] = ["ExitCode::SUCCESS", "AddrInUse", "exit(0)"];

/// A `SuccessfulExit: false` agent supervises a daemon that CAN exit 0
///
/// The two halves of this contract sit in crates with no edge between them: the plist text is a
/// string in `slopdesk-devtools`, and the exit code is a branch in the daemon's own `main`. No
/// compiler compares them, and the failure is invisible in both directions — every test passes, the
/// job installs, and launchd respawns the loser every ten seconds for ever.
///
/// `SuccessfulExit: false` says "restart this job unless it exited 0", which is only ever the right
/// shape when losing a race is SPELLED as an exit 0. superd does it for its lock file ("exiting
/// rather than stealing its socket") and hostd for `AddrInUse` (`docs/60` F.9) — and for hostd it
/// is load-bearing twice, because a SIGTERM to a job launchd is still holding races the replayed
/// one for the port. `ops::hostd` boots the job out first so that race is not entered at all
/// ([`the_replay_boots_the_agent_out_first`]) — but the exit 0 stays load-bearing under it, for
/// every other way two hostds can meet: a Homebrew agent, a second checkout, a developer's own
/// second window. The loser must be allowed to stay dead.
///
/// Discovered from the agent list rather than a second list of daemons: the day somebody adds a
/// fourth `Agent` with the guarded `KeepAlive`, it is asked for the exit path whether or not
/// anybody thought to say so.
#[must_use]
pub fn a_guarded_keepalive_supervises_a_daemon_that_exits_zero(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(source) = tree.get(LAUNCHD) else {
        report.fail_if(true, format!("{LAUNCHD}: gone — this rule reads nothing"));
        return report;
    };
    let code = source.statements();

    let mut guarded = 0_usize;
    let mut found = Vec::new();
    for block in code.split("= Agent {").skip(1) {
        let body = block.split("};").next().unwrap_or_default();
        if !body.contains("SuccessfulExit") {
            continue;
        }
        let Some(crate_name) = body
            .split_once("crate_name:")
            .and_then(|(_, rest)| rest.split('"').nth(1))
        else {
            continue;
        };
        guarded += 1;
        let main = format!("rust/{crate_name}/src/main.rs");
        let Some(daemon) = tree.get(&main) else {
            found.push(format!("{main} (no such file)"));
            continue;
        };
        if !DELIBERATE_SUCCESS
            .iter()
            .any(|marker| daemon.statements().contains(marker))
        {
            found.push(main);
        }
    }

    report.fail_if(
        guarded == 0,
        format!("{LAUNCHD}: no agent carries `SuccessfulExit` — the discovery is broken, not the tree"),
    );
    sites(
        &mut report,
        "a `SuccessfulExit: false` agent supervises a daemon with no deliberate exit 0 — losing the race is \
         a non-zero exit, so launchd respawns the loser for ever",
        &found,
    );
    report
}

/// The replay boots the launchd job out BEFORE it signals anything
///
/// `just host-restart` promises to replay the recorded launch EXACTLY. On a machine with
/// `slopdesk-ops install hostd` run once, the promise is breakable in a way nothing reports: the
/// agent's `KeepAlive` relaunches the daemon the signal just killed, from
/// `~/Library/Application Support/SlopDesk/bin/` — a copy taken whenever `install` last ran — and
/// that relaunch races the replayed binary for the port. The loser exits 0 (see
/// [`a_guarded_keepalive_supervises_a_daemon_that_exits_zero`]), which is what converges the race
/// and also what makes the wrong winner SILENT: the listener check finds a listener, the restart
/// reports success, and the developer is now testing whatever was installed last against the diff
/// they just wrote.
///
/// So the bootout is not a tidy-up, it is the step that makes the replay the only bidder, and it is
/// only that step if it comes FIRST. Booting out after the signal has already lost the race. No
/// type holds the order — both calls are `launchctl`/`kill` through the same helper and either
/// order compiles, runs and prints the same lines on the machine that has no agent installed, which
/// is every CI machine and most developer ones. That is exactly the shape this crate exists for.
#[must_use]
pub fn the_replay_boots_the_agent_out_first(tree: &Tree) -> Report {
    /// The module that owns the restart sequence.
    const RESTART: &str = "rust/slopdesk-devtools/src/ops/hostd.rs";

    check_all(tree, &[Claim::Before {
        path: RESTART,
        first: r"launchd::bootout\(",
        second: r#""-TERM""#,
        message: "rust/slopdesk-devtools/src/ops/hostd.rs signals the recorded pid before it boots \
                  com.slopdesk.hostd out of launchd — the agent relaunches the installed binary into a race \
                  with the replay, and the loser exits 0, so `just host-restart` reports success over \
                  whichever hostd won",
    }])
}

#[cfg(test)]
mod tests {
    use super::{
        HOOKS, a_guarded_keepalive_supervises_a_daemon_that_exits_zero,
        an_ops_harness_that_starts_a_daemon_contains_it, config_files_cite_files_that_exist,
        every_injected_sink_has_someone_who_binds_it, live_docs_cite_files_that_exist,
        nightly_is_never_pinned_to_a_date, no_app_layer_crypto, no_fused_multiply_add,
        no_rust_module_is_written_and_then_never_called, no_swiftpm_build_plugin,
        pkill_never_reaches_the_developers_host, scripting_is_rust, source_comments_cite_files_that_exist,
        the_formula_installs_every_binary_the_release_ships, the_replay_boots_the_agent_out_first,
    };
    use crate::tests::Fixture;

    /// Where the restart sequence lives, restated so the fixtures below cannot drift from the rule.
    const RESTART: &str = "rust/slopdesk-devtools/src/ops/hostd.rs";

    /// A restart body, in the two orders, with the rest of the sequence around them so the fixture
    /// fails for the ORDER rather than for being too small to match.
    fn restart(bootout_first: bool) -> String {
        let boot = "        launchd::bootout(&launchd::HOSTD, Duration::from_secs(20))?;\n";
        let term = "        proc::ask(\"/bin/kill\", &[\"-TERM\", &pid], Path::new(\"/\"));\n";
        let (first, second) = if bootout_first { (boot, term) } else { (term, boot) };
        format!("pub fn run() {{\n    if plan.stop {{\n{first}{second}    }}\n}}\n")
    }

    /// The whole point: booting out AFTER the signal has already lost the race the bootout exists
    /// to prevent, and every machine without the agent installed passes either way.
    #[test]
    fn signalling_before_the_bootout_is_red() {
        let fixture = Fixture::new("restart-order-reversed");
        fixture.write(RESTART, &restart(false));
        assert!(
            !the_replay_boots_the_agent_out_first(&fixture.tree()).is_clean(),
            "a SIGTERM under a live agent is the relaunch race, whatever runs afterwards"
        );
    }

    /// The order that ships.
    #[test]
    fn booting_out_before_the_signal_is_green() {
        let fixture = Fixture::new("restart-order-shipped");
        fixture.write(RESTART, &restart(true));
        assert!(the_replay_boots_the_agent_out_first(&fixture.tree()).is_clean());
    }

    /// A restart that stopped booting out at all is the same failure as doing it late, and
    /// `Claim::Before` says so rather than passing over an unmatched pattern.
    #[test]
    fn a_restart_that_never_boots_out_is_red() {
        let fixture = Fixture::new("restart-order-absent");
        fixture.write(
            RESTART,
            "pub fn run() {\n    proc::ask(\"/bin/kill\", &[\"-TERM\", &pid], Path::new(\"/\"));\n}\n",
        );
        assert!(!the_replay_boots_the_agent_out_first(&fixture.tree()).is_clean());
    }

    /// A backtick, held apart from the fixtures that need one.
    ///
    /// [`source_comments_cite_files_that_exist`] reads THIS file too, and a backticked path in a
    /// test fixture is indistinguishable from a claim about the tree — the Python this came from
    /// never had to say so, because it lived in `scripts/` and scanned only Swift and Rust. Joining
    /// the tick at runtime is what keeps the gate inside its own corpus rather than exempt from it.
    const TICK: &str = "\u{60}";

    /// The banned tokens, spelled in halves. This crate is inside the corpus its own gate scans, so
    /// a test that wrote either one whole would make the live tree fail on the gate's break-test.
    const FUSED_SWIFT: &str = concat!(".adding", "Product(b, c)");
    const FUSED_RUST: &str = concat!(".mul_", "add(b, c)");

    /// An `Agent` body carrying the guarded `KeepAlive`, given the daemon's crate and its `main`.
    fn guarded_agent(crate_name: &str) -> String {
        format!(
            "pub const D: Agent = Agent {{\n    crate_name: \"{crate_name}\",\n    keep_alive: \
             \"<key>SuccessfulExit</key><false/>\",\n}};\n"
        )
    }

    /// The whole point: a guarded agent over a daemon whose every exit is a failure is a respawn
    /// loop, and nothing else in the tree can see it.
    #[test]
    fn a_guarded_agent_over_a_daemon_that_never_exits_zero_is_red() {
        let fixture = Fixture::new("keepalive-loop");
        fixture.write(super::LAUNCHD, &guarded_agent("slopdesk-loopd"));
        fixture.write(
            "rust/slopdesk-loopd/src/main.rs",
            "fn main() {\n    std::process::exit(1);\n}\n",
        );
        assert!(
            !a_guarded_keepalive_supervises_a_daemon_that_exits_zero(&fixture.tree()).is_clean(),
            "losing the race non-zero under `SuccessfulExit: false` respawns for ever"
        );
    }

    /// The other half: the shape hostd actually ships passes, and the marker is not `exit(0)` —
    /// hostd computes the code from the error kind, so a rule that only knew the literal would fire
    /// on the code it was written to protect.
    #[test]
    fn a_daemon_that_spells_its_loss_as_addr_in_use_is_green() {
        let fixture = Fixture::new("keepalive-addrinuse");
        fixture.write(super::LAUNCHD, &guarded_agent("slopdesk-hostd"));
        fixture.write(
            "rust/slopdesk-hostd/src/main.rs",
            "fn main() {\n    std::process::exit(i32::from(why.kind() != \
             std::io::ErrorKind::AddrInUse));\n}\n",
        );
        assert!(a_guarded_keepalive_supervises_a_daemon_that_exits_zero(&fixture.tree()).is_clean());
    }

    /// An agent whose `KeepAlive` is the bare `true` makes no such promise, so it is not asked for
    /// one — screend relaunches unconditionally on purpose.
    #[test]
    fn an_unguarded_agent_is_not_asked_for_an_exit_zero() {
        let fixture = Fixture::new("keepalive-bare");
        fixture.write(
            super::LAUNCHD,
            "pub const S: Agent = Agent {\n    crate_name: \"slopdesk-screend\",\n    keep_alive: \"    \
             <true/>\",\n};\npub const D: Agent = Agent {\n    crate_name: \"slopdesk-superd\",\n    \
             keep_alive: \"<key>SuccessfulExit</key>\",\n};\n",
        );
        fixture.write(
            "rust/slopdesk-superd/src/main.rs",
            "fn main() -> ExitCode {\n    return ExitCode::SUCCESS;\n}\n",
        );
        assert!(a_guarded_keepalive_supervises_a_daemon_that_exits_zero(&fixture.tree()).is_clean());
    }

    /// A launchd module that stopped carrying agents fails LOUDLY rather than passing vacuously.
    #[test]
    fn a_launchd_module_with_no_guarded_agent_is_red() {
        let fixture = Fixture::new("keepalive-empty");
        fixture.write(super::LAUNCHD, "pub const NOTHING: usize = 0;\n");
        assert!(!a_guarded_keepalive_supervises_a_daemon_that_exits_zero(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_trailing_comment_does_not_hide_a_fusion() {
        let fixture = Fixture::new("fused-trailing");
        fixture.write(
            "Sources/A/Math.swift",
            &format!("let x = a{FUSED_SWIFT} // two roundings, honest\n"),
        );
        let report = no_fused_multiply_add(&fixture.tree());
        assert!(
            !report.is_clean(),
            "a fusion at the head of a commented line is still a fusion"
        );
    }

    /// The other half of the same claim: the gate must not fire on prose that NAMES the ban, which
    /// is the shape every doc comment above one of these rules has.
    #[test]
    fn prose_naming_the_ban_is_not_a_violation() {
        let fixture = Fixture::new("fused-prose");
        fixture.write(
            "Sources/A/Prose.swift",
            &format!("// never write a{FUSED_SWIFT} here\nlet x = a * b + c\n"),
        );
        fixture.write(
            "rust/x/src/lib.rs",
            &format!("/// not even a{FUSED_RUST}\npub fn f() {{}}\n"),
        );
        assert!(no_fused_multiply_add(&fixture.tree()).is_clean());
    }

    /// The URL bug the tokenizer exists to stop: a `//` inside a string literal is not a comment,
    /// so what follows it on that line is still code.
    #[test]
    fn a_url_in_a_literal_does_not_blank_the_rest_of_the_line() {
        let fixture = Fixture::new("fused-url");
        fixture.write(
            "Sources/A/Link.swift",
            &format!("let url = \"https://example.com\"; let x = a{FUSED_SWIFT}\n"),
        );
        assert!(!no_fused_multiply_add(&fixture.tree()).is_clean());
    }

    #[test]
    fn an_unlisted_crypto_import_is_red_and_the_allowlisted_one_is_not() {
        let fixture = Fixture::new("crypto");
        fixture.write("Sources/A/Hash.swift", "import CryptoKit\n");
        assert!(!no_app_layer_crypto(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_build_plugin_in_the_manifest_is_red() {
        let fixture = Fixture::new("plugin");
        fixture.write("Package.swift", "targets: [.plugin(name: \"cargo\")]\n");
        assert!(!no_swiftpm_build_plugin(&fixture.tree()).is_clean());
    }

    /// The corpus IS the rule now: pins and fixtures are data, a script is a program.
    #[test]
    fn a_script_anywhere_in_the_tree_is_red() {
        let fixture = Fixture::new("scripting-is-rust");
        fixture.write("scripts/tool-stamps.pin", "abc\n");
        fixture.write("scripts/fixtures/probe.swift", "let x = 1\n");
        assert!(scripting_is_rust(&fixture.tree()).is_clean());

        for (name, path) in [
            ("shell", "scripts/gate.sh"),
            ("python", "rust/helper.py"),
            ("awk", "scripts/gate-death.awk"),
        ] {
            let back = Fixture::new(&format!("scripting-back-{name}"));
            back.write(path, "#!/usr/bin/env bash\nset -euo pipefail\n");
            assert!(
                !scripting_is_rust(&back.tree()).is_clean(),
                "{name} at {path} did not fire"
            );
        }
    }

    /// The gate reports the QUALIFIER, not the word: a harness reaping the host it started on its
    /// own port is the legal spelling and the whole reason this is not a token ban.
    #[test]
    fn an_unqualified_pkill_is_red_and_a_scoped_one_is_not() {
        let fixture = Fixture::new("pkill");
        fixture.write("rust/harness/src/lib.rs", "fn reap() {}\n");
        fixture.write("justfile", "soak:\n    pkill -f slopdesk-hostd --port 9999\n");
        assert!(pkill_never_reaches_the_developers_host(&fixture.tree()).is_clean());
        fixture.write(
            "justfile",
            "soak:\n    pkill -f slopdesk-hostd --port 9999\nreap:\n    pkill -f slopdesk-hostd\n",
        );
        assert!(!pkill_never_reaches_the_developers_host(&fixture.tree()).is_clean());
    }

    /// The spelling that actually ships: a Rust harness, with the verb and its pattern on separate
    /// lines. A line-at-a-time read sees `Command::new` and `"-f"` and never sees what is killed.
    #[test]
    fn a_rust_harness_kills_across_lines_and_is_still_read() {
        let fixture = Fixture::new("pkill-rust-window");
        fixture.write("justfile", "soak:\n    cargo run\n");
        fixture.write(
            "rust/harness/src/lib.rs",
            "fn scoped(port: u16) {\n    kill_matching(&format!(\"slopdesk-hostd --port {port}\"));\n}\n",
        );
        assert!(
            pkill_never_reaches_the_developers_host(&fixture.tree()).is_clean(),
            "a kill scoped by --port is the harness reaping its own host"
        );
        fixture.write(
            "rust/harness/src/lib.rs",
            "fn reap() {\n    Command::new(\"/usr/bin/pkill\")\n        .args([\"-f\", \
             \"slopdesk-hostd\"])\n        .status();\n}\n",
        );
        assert!(!pkill_never_reaches_the_developers_host(&fixture.tree()).is_clean());
    }

    /// The corpus is the harnesses plus the justfile, and losing either is losing half the subject.
    #[test]
    fn a_pkill_ban_with_no_corpus_is_red_rather_than_green() {
        let no_rust = Fixture::new("pkill-no-rust");
        no_rust.write("justfile", "soak:\n    cargo run\n");
        assert!(!pkill_never_reaches_the_developers_host(&no_rust.tree()).is_clean());

        let no_justfile = Fixture::new("pkill-no-justfile");
        no_justfile.write("rust/harness/src/lib.rs", "fn reap() {}\n");
        assert!(!pkill_never_reaches_the_developers_host(&no_justfile.tree()).is_clean());
    }

    /// The crate that states the ban quotes it, so it may not be convicted of stating it.
    #[test]
    fn the_crate_that_states_the_ban_is_not_in_its_own_corpus() {
        let fixture = Fixture::new("pkill-self-match");
        fixture.write("justfile", "soak:\n    cargo run\n");
        fixture.write("rust/harness/src/lib.rs", "fn reap() {}\n");
        fixture.write(
            "rust/slopdesk-invariants/src/rules/repo_invariants.rs",
            "fn message() -> &'static str {\n    \"pkill -f slopdesk-hostd is banned\"\n}\n",
        );
        assert!(pkill_never_reaches_the_developers_host(&fixture.tree()).is_clean());
    }

    /// The floating spelling passes; a date fires from either file a toolchain can be named in.
    #[test]
    fn a_dated_nightly_is_red_in_the_justfile_and_in_the_hooks() {
        let floating = "fmt-rust:\n    cargo +nightly fmt --all\nmiri:\n    cargo +nightly miri test\n";
        let fixture = Fixture::new("nightly-floating");
        fixture.write("justfile", floating);
        fixture.write(HOOKS, "repos:\n  - hooks:\n      - entry: just fmt-rust\n");
        assert!(nightly_is_never_pinned_to_a_date(&fixture.tree()).is_clean());

        let pinned = Fixture::new("nightly-dated-justfile");
        pinned.write("justfile", "fmt-rust:\n    cargo +nightly-2026-08-21 fmt --all\n");
        assert!(!nightly_is_never_pinned_to_a_date(&pinned.tree()).is_clean());

        let hook = Fixture::new("nightly-dated-hook");
        hook.write("justfile", floating);
        hook.write(
            HOOKS,
            "repos:\n  - hooks:\n      - entry: cargo +nightly-2026-08-21 fmt --all\n",
        );
        assert!(
            !nightly_is_never_pinned_to_a_date(&hook.tree()).is_clean(),
            "a hook can pin a toolchain the justfile never names"
        );
    }

    /// The hooks file is TRACKED, so its absence is a rename rather than a machine without prek —
    /// and an unread half of a ban is a half that passes.
    #[test]
    fn a_missing_hooks_config_is_red_rather_than_half_a_ban() {
        let fixture = Fixture::new("nightly-no-hooks");
        fixture.write("justfile", "fmt-rust:\n    cargo +nightly fmt --all\n");
        let report = nightly_is_never_pinned_to_a_date(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains(HOOKS)),
            "{report:?}"
        );
    }

    #[test]
    fn a_module_reached_by_nobody_is_red_and_a_reexport_is_not_a_caller() {
        let fixture = Fixture::new("stranded");
        fixture.write(
            "rust/slopdesk-x/src/lib.rs",
            "pub mod solver;\npub use solver::Solver;\n",
        );
        fixture.write("rust/slopdesk-x/src/solver.rs", "pub struct Solver;\n");
        assert!(!no_rust_module_is_written_and_then_never_called(&fixture.tree()).is_clean());

        let wired = Fixture::new("stranded-wired");
        wired.write(
            "rust/slopdesk-x/src/lib.rs",
            "pub mod solver;\npub use solver::Solver;\n",
        );
        wired.write("rust/slopdesk-x/src/solver.rs", "pub struct Solver;\n");
        wired.write(
            "rust/slopdesk-x/src/run.rs",
            "use crate::Solver;\npub fn go(s: Solver) {}\n",
        );
        assert!(no_rust_module_is_written_and_then_never_called(&wired.tree()).is_clean());
    }

    /// A module of inherent impls, which is the shape that has NO name to be reached by.
    ///
    /// `session_actuate` and `session_resize` are both of them: every line is `impl Session`, the
    /// type is `session.rs`'s, and the effect arrives as `self.resize_capture(…)` from a sibling.
    /// Nothing spells the module, nothing is re-exported, and the gate called both stranded while
    /// the daemon ran them. The second half is what keeps it a gate: take the call away and the
    /// same module is red again.
    #[test]
    fn a_module_of_inherent_impls_is_reached_through_its_methods() {
        let module = "use crate::session::Session;\nimpl Session {\n    pub(crate) fn resize_capture(&self, \
                      width: u16) {}\n}\n";
        // `session` is reached by the impl module's own `use crate::session::Session`, so the only
        // verdict either half of this test turns on is `session_resize`'s.
        let manifest = "pub mod session;\npub mod session_resize;\n";
        let wired = Fixture::new("stranded-impl-wired");
        wired.write("rust/slopdesk-x/src/lib.rs", manifest);
        wired.write(
            "rust/slopdesk-x/src/session.rs",
            "pub struct Session;\npub fn pump(s: &Session) {\n    s.resize_capture(8);\n}\n",
        );
        wired.write("rust/slopdesk-x/src/session_resize.rs", module);
        assert!(no_rust_module_is_written_and_then_never_called(&wired.tree()).is_clean());

        let stranded = Fixture::new("stranded-impl-uncalled");
        stranded.write("rust/slopdesk-x/src/lib.rs", manifest);
        stranded.write(
            "rust/slopdesk-x/src/session.rs",
            "pub struct Session;\npub fn pump(s: &Session) {}\n",
        );
        stranded.write("rust/slopdesk-x/src/session_resize.rs", module);
        assert!(!no_rust_module_is_written_and_then_never_called(&stranded.tree()).is_clean());
    }

    /// An impl on the module's OWN type is not evidence, and counting it would strand the gate.
    ///
    /// A method name is far weaker than a type name: `as_byte` on a locally declared `StatusKind`
    /// is spelled by nine files across this tree that have nothing to do with the module holding
    /// it. Reading that as reach buys nothing — a declared type is nameable, so `module::` and the
    /// `pub use` path already answer for it — while handing every `as_byte` anywhere to whichever
    /// module declares one. Here `other.rs` calls a same-named method on an unrelated value, and
    /// `status` must stay red.
    #[test]
    fn an_impl_on_the_modules_own_type_is_not_evidence() {
        let fixture = Fixture::new("stranded-impl-own-type");
        fixture.write("rust/slopdesk-x/src/lib.rs", "pub mod status;\npub mod other;\n");
        fixture.write(
            "rust/slopdesk-x/src/status.rs",
            "pub enum StatusKind {\n    Up,\n}\nimpl StatusKind {\n    \
             pub const fn as_byte(self) -> u8 {\n        0\n    }\n}\n",
        );
        fixture.write(
            "rust/slopdesk-x/src/other.rs",
            "pub fn unrelated(ink: u8) -> u8 {\n    ink.as_byte()\n}\n",
        );
        assert!(!no_rust_module_is_written_and_then_never_called(&fixture.tree()).is_clean());
    }

    /// A `///` link is a MENTION, and the rule's own alternatives are exactly what one spells.
    ///
    /// This is the first of the three holes round 15 found, and it is the nastiest, because the
    /// text that excused the module was written to be helpful: a sibling saying "the way
    /// [`crate::windowgeometry::Poller`] is" spells the qualified path character for character.
    /// `statements()` blanking every comment is what closes it; take that away and a module is
    /// excused by being documented.
    #[test]
    fn a_doc_link_is_not_a_caller() {
        let root = "pub mod windowgeometry;\npub mod pump;\npub fn boot() {\n    pump::start();\n}\n";
        let module = "pub struct Poller;\n";

        let mentioned = Fixture::new("stranded-doc-link");
        mentioned.write("rust/slopdesk-x/src/lib.rs", root);
        mentioned.write("rust/slopdesk-x/src/windowgeometry.rs", module);
        mentioned.write(
            "rust/slopdesk-x/src/pump.rs",
            "/// the way [`crate::windowgeometry::Poller`] is\npub fn start() {}\n",
        );
        let report = no_rust_module_is_written_and_then_never_called(&mentioned.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("pub mod windowgeometry;")),
            "{report:?}"
        );

        // The same link as a STATEMENT is the real thing, and the module goes green — which is what
        // keeps the half above a gate rather than a rule that never passes.
        let used = Fixture::new("stranded-doc-link-used");
        used.write("rust/slopdesk-x/src/lib.rs", root);
        used.write("rust/slopdesk-x/src/windowgeometry.rs", module);
        used.write(
            "rust/slopdesk-x/src/pump.rs",
            "use crate::windowgeometry::Poller;\npub fn start() {\n    let _ = Poller;\n}\n",
        );
        assert!(no_rust_module_is_written_and_then_never_called(&used.tree()).is_clean());
    }

    /// `crate::cursor::` in ANOTHER crate names that crate's `cursor`, and this tree has two.
    ///
    /// The second hole. `slopdesk-video` owns a `cursor` and a `capture_region`; so does
    /// `slopdesk-videohostd`. While the pattern was the bare `cursor::`, one sibling of the OTHER
    /// module writing `crate::cursor::Message` read as reach into this one — a relative path
    /// resolved against the wrong crate root.
    #[test]
    fn a_homonym_module_in_another_crate_is_not_this_ones_caller() {
        let fixture = Fixture::new("stranded-homonym");
        fixture.write("rust/slopdesk-x/src/lib.rs", "pub mod cursor;\n");
        fixture.write("rust/slopdesk-x/src/cursor.rs", "pub struct Sampler;\n");
        // slopdesk-y reaches its OWN `cursor` relatively, which is the ordinary shape and must stay
        // green — the whole verdict this test turns on is slopdesk-x's.
        fixture.write(
            "rust/slopdesk-y/src/lib.rs",
            "pub mod cursor;\nuse crate::cursor::Message;\npub fn go(m: Message) {\n    let _ = m;\n}\n",
        );
        fixture.write("rust/slopdesk-y/src/cursor.rs", "pub struct Message;\n");
        let report = no_rust_module_is_written_and_then_never_called(&fixture.tree());
        assert_eq!(
            report.violations().len(),
            1,
            "only slopdesk-x's cursor is stranded: {report:?}"
        );
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk-x") && v.contains("pub mod cursor;")),
            "{report:?}"
        );
    }

    /// The third hole: a root's own `pub use cursor::{…}` is a DECLARATION, not a call.
    ///
    /// `slopdesk-video/src/lib.rs` re-exports its own `cursor`, at the start of a line and
    /// qualified by nothing — the exact bare shape that counts from anywhere. Stripping every
    /// `pub mod` and `pub use` statement out of a root before reading it is what closes this,
    /// and the rest of the root still counts, so a genuine caller living up there is not lost.
    #[test]
    fn another_roots_reexport_of_its_own_module_is_not_a_caller() {
        let fixture = Fixture::new("stranded-foreign-reexport");
        fixture.write("rust/slopdesk-x/src/lib.rs", "pub mod cursor;\n");
        fixture.write("rust/slopdesk-x/src/cursor.rs", "pub struct Sampler;\n");
        fixture.write(
            "rust/slopdesk-y/src/lib.rs",
            "pub mod cursor;\npub use cursor::{Message, Shape};\npub fn make() -> Message {\n    let _ = \
             Shape;\n    Message\n}\n",
        );
        fixture.write(
            "rust/slopdesk-y/src/cursor.rs",
            "pub struct Message;\npub struct Shape;\n",
        );
        let report = no_rust_module_is_written_and_then_never_called(&fixture.tree());
        assert_eq!(
            report.violations().len(),
            1,
            "only slopdesk-x's cursor is stranded: {report:?}"
        );
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk-x") && v.contains("pub mod cursor;")),
            "{report:?}"
        );
    }

    /// A door's caller is Swift, which is in no `.rs` file — so `no_mangle` is what stands in for
    /// the call site the gate cannot see.
    #[test]
    fn a_no_mangle_door_counts_as_reached() {
        let fixture = Fixture::new("door");
        fixture.write("rust/slopdesk-ffi/src/lib.rs", "pub mod door;\n");
        fixture.write(
            "rust/slopdesk-ffi/src/door.rs",
            "#[no_mangle]\npub extern \"C\" fn slopdesk_open() {}\n",
        );
        assert!(no_rust_module_is_written_and_then_never_called(&fixture.tree()).is_clean());
    }

    /// A test binding the sink is not a binder. That is the entire gate: the three dead sinks it
    /// was written for each had six passing tests assigning them.
    #[test]
    fn a_sink_bound_only_by_a_test_is_red() {
        let fixture = Fixture::new("sinks");
        fixture.write(
            "Sources/A/Model.swift",
            "public var onRequestCopyMode: (() -> Void)?\n",
        );
        fixture.write("Tests/ATests/ModelTests.swift", "model.onRequestCopyMode = {}\n");
        assert!(!every_injected_sink_has_someone_who_binds_it(&fixture.tree()).is_clean());

        let bound = Fixture::new("sinks-bound");
        bound.write(
            "Sources/A/Model.swift",
            "public var onRequestCopyMode: (() -> Void)?\n",
        );
        bound.write(
            "Sources/A/View.swift",
            "model.onRequestCopyMode = { self.copy() }\n",
        );
        assert!(every_injected_sink_has_someone_who_binds_it(&bound.tree()).is_clean());
    }

    /// Swift under `Sources/` that declares no sink at all is the extraction dying, not a tree with
    /// nothing to check — every sink in it would be unbound and none of them would be reported.
    #[test]
    fn a_tree_whose_sink_pattern_matches_nothing_is_red() {
        let fixture = Fixture::new("sinks-none-extracted");
        fixture.write("Sources/A/Model.swift", "public var title: String = \"\"\n");
        fixture.write("Sources/A/View.swift", "model.title = \"hi\"\n");
        let report = every_injected_sink_has_someone_who_binds_it(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("no injected sink was extracted")),
            "{report:?}"
        );
    }

    /// `==` is a comparison and `onXY` is a different name; neither binds `onX`.
    #[test]
    fn a_comparison_and_a_longer_name_are_not_bindings() {
        let fixture = Fixture::new("sinks-near");
        fixture.write("Sources/A/Model.swift", "public var onCopy: (() -> Void)?\n");
        fixture.write(
            "Sources/A/View.swift",
            "if model.onCopy == nil { }\nmodel.onCopyConfirmation = {}\n",
        );
        assert!(!every_injected_sink_has_someone_who_binds_it(&fixture.tree()).is_clean());
    }

    /// Every live doc must be PRESENT before one of them can be asked about, because the list
    /// naming a file that is not there is itself a violation — and it would mask the one the test
    /// is about.
    fn with_live_docs(name: &str) -> Fixture {
        let fixture = Fixture::new(name);
        for doc in super::LIVE_DOCS {
            fixture.write(doc, "");
        }
        fixture
    }

    #[test]
    fn a_live_doc_citing_a_missing_path_is_red_and_a_deletion_section_is_not() {
        let fixture = with_live_docs("live-docs");
        // A live file under `Sources` so the root EXISTS to be derived, and so the extraction floor
        // is satisfied by something — otherwise this fixture goes red for having read nothing, and
        // the assertion below would pass without the citation being scoped at all.
        fixture.write("Sources/A/Here.swift", "// still here\n");
        fixture.write(
            "CLAUDE.md",
            &format!(
                "see {TICK}Sources/A/Here.swift{TICK} and {TICK}Sources/A/Gone.swift{TICK} for the seam\n"
            ),
        );
        assert!(!live_docs_cite_files_that_exist(&fixture.tree()).is_clean());

        let deleting = with_live_docs("live-docs-deleted");
        deleting.write("Sources/A/Here.swift", "// still here\n");
        // The live one above the heading is what keeps the extraction floor satisfied, so this
        // test proves the deletion section is EXEMPT rather than proving the scan died.
        deleting.write(
            "CLAUDE.md",
            &format!(
                "see {TICK}Sources/A/Here.swift{TICK}\n\n## What this deleted\n\n- \
                 {TICK}Sources/A/Gone.swift{TICK}, folded in\n"
            ),
        );
        assert!(live_docs_cite_files_that_exist(&deleting.tree()).is_clean());
    }

    /// A root the hand-written list never named is still a root.
    ///
    /// The list this replaced held eight names and the tree has ten; `hid-bridge` and `packaging`
    /// were exempt because nobody added them, which is the drift
    /// `doc_citations::every_cited_path_exists` had already retired the same list for. The fixture
    /// uses a root name that could not have been in any such list, so it fails on the old shape by
    /// construction rather than by which two names happen to be missing today.
    #[test]
    fn a_root_no_list_would_have_named_is_still_read() {
        let fixture = with_live_docs("live-docs-derived-root");
        fixture.write("packaging/homebrew/here.rb", "# still here\n");
        fixture.write(
            "CLAUDE.md",
            &format!(
                "see {TICK}packaging/homebrew/here.rb{TICK} and {TICK}packaging/homebrew/gone.rb{TICK}\n"
            ),
        );
        assert!(!live_docs_cite_files_that_exist(&fixture.tree()).is_clean());

        let clean = with_live_docs("live-docs-derived-root-clean");
        clean.write("packaging/homebrew/here.rb", "# still here\n");
        clean.write(
            "CLAUDE.md",
            &format!("see {TICK}packaging/homebrew/here.rb{TICK}\n"),
        );
        assert!(live_docs_cite_files_that_exist(&clean.tree()).is_clean());
    }

    /// Sixteen readable docs and no citation extracted from any of them is the scan dying, not the
    /// tree being clean.
    #[test]
    fn live_docs_that_yield_no_citation_at_all_are_red() {
        let fixture = with_live_docs("live-docs-no-citations");
        fixture.write("CLAUDE.md", "prose with no backticked path in it at all\n");
        assert!(!live_docs_cite_files_that_exist(&fixture.tree()).is_clean());
    }

    /// A live doc that has gone missing is the gate's own blindness, and it is reported as one.
    #[test]
    fn a_live_doc_that_is_not_in_the_tree_is_red() {
        let fixture = Fixture::new("live-docs-absent");
        fixture.write("CLAUDE.md", "nothing cited here\n");
        assert!(!live_docs_cite_files_that_exist(&fixture.tree()).is_clean());
    }

    /// Each of the three source roots has to contribute a module name or the addressable set is a
    /// dead walk, so every fixture for this rule seeds all three before it says anything else.
    fn addressable(fixture: &Fixture) {
        fixture.write("Sources/A/Note.swift", "// a module\n");
        fixture.write("Tests/ATests/NoteTests.swift", "// a suite\n");
        fixture.write("Apps/ClientApp-iOS/App.swift", "// an app\n");
    }

    #[test]
    fn a_comment_citing_a_tail_that_resolves_is_green_and_one_that_does_not_is_red() {
        let fixture = Fixture::new("comment-cites");
        addressable(&fixture);
        fixture.write("Sources/SlopDeskPhoneUI/Settings/Pages.swift", "// the page\n");
        fixture.write(
            "Sources/A/Note.swift",
            &format!("/// see {TICK}SlopDeskPhoneUI/Settings/Pages.swift{TICK} for the rest\n"),
        );
        assert!(source_comments_cite_files_that_exist(&fixture.tree()).is_clean());

        let stale = Fixture::new("comment-cites-stale");
        addressable(&stale);
        stale.write("Sources/SlopDeskPhoneUI/Settings/Pages.swift", "// the page\n");
        stale.write(
            "Sources/A/Note.swift",
            &format!("/// see {TICK}Sources/SlopDeskClientUI/Settings/Pages.swift{TICK} now\n"),
        );
        assert!(!source_comments_cite_files_that_exist(&stale.tree()).is_clean());
    }

    /// An upstream path is not a claim about this tree, and a gate demanding it resolve would be
    /// demanding the comment lie.
    #[test]
    fn a_citation_outside_the_addressable_roots_is_ignored() {
        let fixture = Fixture::new("comment-cites-upstream");
        addressable(&fixture);
        fixture.write(
            "Sources/A/Note.swift",
            &format!("/// libghostty's own {TICK}Helpers/Cursor.swift{TICK}\n"),
        );
        assert!(source_comments_cite_files_that_exist(&fixture.tree()).is_clean());
    }

    /// The corpus its sibling cannot reach. The break seeds the EXACT shape the shell port left
    /// behind: a `scripts/` program that stopped existing, still named in a file no compiler,
    /// formatter or other rule reads — and named without backticks, which is the other half of why
    /// nothing caught it.
    #[test]
    fn a_config_citing_a_live_path_is_green_and_a_deleted_one_is_red() {
        let fixture = Fixture::new("config-cites");
        addressable(&fixture);
        fixture.write("rust/slopdesk-devtools/src/lib.rs", "// the tool\n");
        fixture.write(
            ".gitignore",
            "# built by rust/slopdesk-devtools/src/lib.rs\ndist/\n",
        );
        fixture.write("cliff.toml", "[changelog]\n");
        fixture.write(
            ".github/workflows/release.yml",
            &format!("# see {TICK}rust/slopdesk-devtools/src/lib.rs{TICK}\nname: Release\n"),
        );
        assert!(
            config_files_cite_files_that_exist(&fixture.tree()).is_clean(),
            "the fixture must start clean, or the break below proves nothing"
        );

        for (name, file, line) in [
            (
                "gitignore",
                ".gitignore",
                "# built by scripts/build-ffi.sh\ndist/\n",
            ),
            (
                "workflow",
                ".github/workflows/release.yml",
                "# cut by scripts/cut-release.sh\nname: Release\n",
            ),
        ] {
            let stale = Fixture::new(&format!("config-cites-{name}"));
            addressable(&stale);
            stale.write("cliff.toml", "[changelog]\n");
            stale.write(".gitignore", "dist/\n");
            stale.write(".github/workflows/release.yml", "name: Release\n");
            stale.write(file, line);
            assert!(
                !config_files_cite_files_that_exist(&stale.tree()).is_clean(),
                "{name} at {file} did not fire"
            );
        }
    }

    /// The corpus is assembled by hand, so it carries its own floor: a workflow directory that was
    /// renamed leaves this rule reading dotfiles alone and reporting green.
    #[test]
    fn a_config_corpus_with_no_workflow_is_red() {
        let fixture = Fixture::new("config-cites-floor");
        addressable(&fixture);
        fixture.write("cliff.toml", "[changelog]\n");
        fixture.write(".gitignore", "dist/\n");
        let report = config_files_cite_files_that_exist(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("asking nobody anything")),
            "{report:?}"
        );
    }

    /// A module citation is recognised HERE and nowhere else, so a root that went dark is red even
    /// though seven other roots keep the corpus floor satisfied and the comments keep being read.
    #[test]
    fn a_source_root_that_names_no_module_is_red() {
        let fixture = Fixture::new("comment-cites-dead-root");
        fixture.write("Tests/ATests/NoteTests.swift", "// a suite\n");
        fixture.write("Apps/ClientApp-iOS/App.swift", "// an app\n");
        fixture.write("docs/00-overview.md", "the tree\n");
        let report = source_comments_cite_files_that_exist(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("Sources/ contributed no module name")),
            "{report:?}"
        );
    }

    /// The container is what makes a harness safe to run, so a harness without one is RED.
    #[test]
    fn an_ops_module_that_launches_a_daemon_without_a_container_is_red() {
        let fixture = Fixture::new("ops-uncontained");
        fixture.write(
            "rust/slopdesk-devtools/src/ops/mod.rs",
            "pub fn container(state: &Path) -> Vec<(String, String)> {\n    \
             vec![(\"SLOPDESK_APP_SUPPORT_DIR\".into(), state), (\"SLOPDESK_SCROLLBACK_DIR\".into(), \
             state), (\"SLOPDESK_FILE_DROP_DIR\".into(), state), (\"SLOPDESK_WORKSPACE_STATE_DIR\".into(), \
             state)]\n}\n",
        );
        fixture.write(
            "rust/slopdesk-devtools/src/ops/soak.rs",
            "let hostd = root.join(\".build/debug/slopdesk-hostd\");\nCommand::new(&hostd).spawn();\n",
        );
        assert!(!an_ops_harness_that_starts_a_daemon_contains_it(&fixture.tree()).is_clean());
    }

    /// The same module WITH the container passes, and so does the one exemption.
    #[test]
    fn a_contained_launch_and_the_one_exemption_pass() {
        let fixture = Fixture::new("ops-contained");
        fixture.write(
            "rust/slopdesk-devtools/src/ops/mod.rs",
            "pub fn container(state: &Path) -> Vec<(String, String)> {\n    \
             vec![(\"SLOPDESK_APP_SUPPORT_DIR\".into(), state), (\"SLOPDESK_SCROLLBACK_DIR\".into(), \
             state), (\"SLOPDESK_FILE_DROP_DIR\".into(), state), (\"SLOPDESK_WORKSPACE_STATE_DIR\".into(), \
             state)]\n}\n",
        );
        fixture.write(
            "rust/slopdesk-devtools/src/ops/soak.rs",
            "let environment = container(&state)?;\nCommand::new(\".build/debug/slopdesk-hostd\");\n",
        );
        // `hostd.rs` replays the daemon's OWN recorded environment and must not impose one.
        fixture.write(
            "rust/slopdesk-devtools/src/ops/hostd.rs",
            "proc::run(\"swift\", &[\"build\", \"--product\", \"slopdesk-hostd\"], root)?;\n",
        );
        assert!(an_ops_harness_that_starts_a_daemon_contains_it(&fixture.tree()).is_clean());
    }

    /// A container hollowed out to three variables is RED, or the rule would pass over a harness
    /// that calls it and is still uncontained.
    #[test]
    fn a_container_that_stops_naming_all_four_variables_is_red() {
        let fixture = Fixture::new("ops-hollow-container");
        fixture.write(
            "rust/slopdesk-devtools/src/ops/mod.rs",
            "pub fn container() -> Vec<String> {\n    vec![\"SLOPDESK_APP_SUPPORT_DIR\".into(), \
             \"SLOPDESK_SCROLLBACK_DIR\".into(), \"SLOPDESK_FILE_DROP_DIR\".into()]\n}\n",
        );
        fixture.write(
            "rust/slopdesk-devtools/src/ops/soak.rs",
            "let environment = container(&state)?;\nCommand::new(\".build/debug/slopdesk-hostd\");\n",
        );
        assert!(!an_ops_harness_that_starts_a_daemon_contains_it(&fixture.tree()).is_clean());
    }

    /// A walk that finds no harness at all reads nothing, and a rule that reads nothing must not
    /// report health.
    #[test]
    fn an_empty_ops_directory_is_red_rather_than_vacuously_green() {
        let fixture = Fixture::new("ops-empty");
        fixture.write("Sources/A/Note.swift", "// nothing to do with ops\n");
        assert!(!an_ops_harness_that_starts_a_daemon_contains_it(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_formula_that_installs_no_manifest_is_red() {
        let fixture = Fixture::new("formula");
        fixture.write(
            "rust/slopdesk-devtools/src/release/tools.rs",
            "pub const RUST_ROOT_TOOLS: &[&str] = &[\"slopdesk\", \"slopdesk-ctl\"];\npub const \
             RUST_CRATE_TOOLS: &[&str] = &[\"slopdesk-hostd\"];\n",
        );
        fixture.write(
            "packaging/homebrew/Formula/slopdesk.rb",
            "  def install\n    bin.install \"slopdesk\", \"slopdesk-hostd\", \"slopdesk-ctl\"\n\n  end\n",
        );
        assert!(!the_formula_installs_every_binary_the_release_ships(&fixture.tree()).is_clean());
    }
}
