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

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::text;
use crate::tree::{Source, Tree};

/// Every file under `roots` whose extension is in `extensions`, in path order.
fn collect<'a>(tree: &'a Tree, roots: &[&'a str], extensions: &[&str]) -> Vec<(&'a Path, &'a Source)> {
    let mut out = Vec::new();
    for root in roots {
        for (path, source) in tree.under(root) {
            let wanted = path
                .extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| extensions.contains(&extension));
            if wanted {
                out.push((path, source));
            }
        }
    }
    out
}

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

    let swift = collect(tree, &SWIFT_ROOTS, &["swift"]);
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
    let swift = collect(tree, &SWIFT_ROOTS, &["swift"]);
    let rust = collect(tree, &["rust"], &["rs"]);
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
/// The harnesses under `scripts/` DO kill hosts, and must: each spawns its own on a private port
/// and reaps it. What is banned is the UNQUALIFIED form, which reaches the developer's running
/// hostd as readily as the harness's own. So the question is not "does this script say pkill" but
/// "does a pkill naming hostd carry the qualifier that scopes it to a host this script started".
#[must_use]
pub fn pkill_never_reaches_the_developers_host(tree: &Tree) -> Report {
    let mut report = Report::new();
    let mut shells = collect(tree, &["scripts"], &["sh"]);
    if let Some(justfile) = report.source(tree, "justfile", "every gate is invoked from it") {
        shells.push((Path::new("justfile"), justfile));
    }
    let found: Vec<String> = hits(&shells, r"pkill\s+-f")
        .into_iter()
        .filter(|line| {
            line.contains("slopdesk-hostd") && !line.contains("--port") && !line.contains("DerivedData")
        })
        .collect();
    sites(
        &mut report,
        "an unqualified pkill names slopdesk-hostd — it would reap the running host",
        &found,
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
    let swift = collect(tree, &["Sources"], &["swift"]);
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
/// `ThirdParty/ghostty/` is out of scope and stays out: `build-libghostty.sh` is the dependency's
/// own builder, carried close to upstream's shape. `ThirdParty/tools/` is NOT out of scope, and the
/// distinction is authorship rather than directory — `provision.sh` lived there and was ours, and
/// the argument that kept it (a bootstrap installs what a Rust gate would need) was never true of
/// it: it installs the PANEL's runtime deps, and cargo is a prerequisite of this tree either way.
/// It is `rust/slopdesk-provision` now, and this rule is what stops it coming back.
#[must_use]
pub fn scripting_is_rust(tree: &Tree) -> Report {
    let mut report = Report::new();
    let found: Vec<String> = tree
        .paths()
        .filter(|path| !path.starts_with("ThirdParty/ghostty"))
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
    for (_, source) in collect(tree, &["Sources"], &["swift"]) {
        let constants = text::capture_set(&source.text, r#"\bbinaryName\s*=\s*"(slopdesk-[a-z]+)""#);
        for capture in locate.captures_iter(&source.text) {
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
/// `ConnectionTarget.swift` is a four-field `Codable` value 20 files hold and `SwiftUI` diffs — a
/// vocabulary by `docs/55` §6, so the Rust twin is the copy that should go, not the Swift.
const STRANDED_RUST_MODULES: [&str; 1] = ["slopdesk-workspace::connection"];

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
#[must_use]
pub fn no_rust_module_is_written_and_then_never_called(tree: &Tree) -> Report {
    let mut report = Report::new();
    let sources = collect(tree, &["rust"], &["rs"]);
    let mut found = Vec::new();

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
        for (module, group) in text::capture_pairs(&source.text, r"(?s)^pub use (\w+)::\{(.*?)\};") {
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
        for (module, name) in text::capture_pairs(&source.text, r"^pub use (\w+)::(\w+);") {
            exported.entry(module).or_default().insert(name);
        }

        for module in text::capture_all(&source.text, r"^pub mod (\w+);") {
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

            let mut alternatives = vec![format!("{module}::")];
            if let Some(names) = exported.get(&module) {
                alternatives.extend(names.iter().map(|name| format!(r"{name}\b")));
            }
            let reaches = text::cached(&format!(r"\b(?:{})", alternatives.join("|")));
            let wired = sources.iter().any(|(path, held)| {
                if inside.iter().any(|(known, _)| known == path) {
                    return false;
                }
                if path == lib {
                    // `lib.rs` counts as a caller, but not through its own declarations.
                    let stripped = text::cached(r"(?s)^pub (?:mod|use) [^;]*;").replace_all(&held.text, "");
                    return reaches.is_match(&stripped);
                }
                reaches.is_match(&held.text)
            });
            let known_debt = STRANDED_RUST_MODULES.contains(&format!("{crate_name}::{module}").as_str());
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
#[must_use]
pub fn every_injected_sink_has_someone_who_binds_it(tree: &Tree) -> Report {
    let mut report = Report::new();
    let mut sinks: BTreeMap<String, String> = BTreeMap::new();
    for (path, source) in collect(tree, &["Sources"], &["swift"]) {
        for name in text::capture_all(&source.text, SINK_DECLARATION) {
            sinks.entry(name).or_insert_with(|| path.display().to_string());
        }
    }
    let product = collect(tree, &["Sources", "Apps", "ThirdParty"], &["swift"]);
    let found: Vec<String> = sinks
        .iter()
        .filter(|(name, _)| {
            // `(?:^|[^A-Za-z0-9_])` and `(?:$|[^=])` are the two lookarounds the Python spelled
            // directly: an assignment, not a comparison, and not the tail of a longer name.
            let assigned = text::cached(&format!(r"(?:^|[^A-Za-z0-9_]){name}\s*=(?:$|[^=])"));
            !product.iter().any(|(_, source)| assigned.is_match(&source.text))
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

/// The docs `CLAUDE.md` sends a reader to before touching anything, plus the two front doors.
///
/// These must not lie. Every OTHER document — `docs/19`, the `27` to `31` handoffs, `docs/40`, and
/// all of `docs/ui-shell/` — is a record of a plan as it stood, and a path that was real then is
/// not a defect now. 476 stale citations live in those; 5 lived here, which is the whole argument
/// for drawing the line where `CLAUDE.md` already draws it.
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

/// The roots a backticked span must start with to be read as a claim about this tree.
const PATH_ROOTS: [&str; 8] = [
    "Sources/",
    "Tests/",
    "Apps/",
    "rust/",
    "scripts/",
    "docs/",
    "golden/",
    "ThirdParty/",
];

/// A citation whose whole point is that the file is gone. `docs/51` has a "What this deleted"
/// section; flagging it would be the gate arguing with the document's subject.
const DELETION_HEADINGS: [&str; 3] = ["What this deleted", "Deleted", "Removed"];

/// A doc a reader is SENT to must not name a path that is not there.
///
/// The failure is not tidiness. `docs/45` claimed a mitigation —
/// "`…/HostOutputSnifferGoldenGuardTests.swift` asserts the frozen vector still round-trips" — for
/// a test that had moved to Rust with the sniffer. A reader checking whether the blind spot was
/// covered would grep, find nothing, and conclude it was not.
#[must_use]
pub fn live_docs_cite_files_that_exist(tree: &Tree) -> Report {
    let mut report = Report::new();
    let mut found = Vec::new();
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
                if !PATH_ROOTS.iter().any(|root| raw.starts_with(root)) || raw.contains(['*', '{', '}', '…'])
                {
                    continue;
                }
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
/// the tail of one (`SlopDeskPhoneUI/Pane/TerminalLeafView.swift`), and both must resolve.
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
fn addressable_first_segments(tree: &Tree) -> BTreeSet<String> {
    let mut segments: BTreeSet<String> = CITED_ROOTS.iter().map(|root| (*root).to_owned()).collect();
    for root in ["Sources", "Tests", "Apps"] {
        for (path, _) in tree.under(root) {
            if let Some(child) = path.components().nth(1) {
                segments.insert(child.as_os_str().to_string_lossy().into_owned());
            }
        }
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
    let addressable = addressable_first_segments(tree);
    let citation = text::cached(r"`{1,2}([A-Za-z0-9_./+-]+/[A-Za-z0-9_+.-]+)`{1,2}");

    let mut found = Vec::new();
    for (path, source) in collect(tree, &CITED_ROOTS, &["swift", "rs"]) {
        for (number, line) in source.text.lines().enumerate() {
            for capture in citation.captures_iter(line) {
                let cited = &capture[1];
                if !CITED_SUFFIXES.iter().any(|suffix| cited.ends_with(suffix)) {
                    continue;
                }
                let tail = cited.trim_start_matches(['.', '/']);
                if !tail
                    .split('/')
                    .next()
                    .is_some_and(|head| addressable.contains(head))
                {
                    continue;
                }
                let name = tail.rsplit('/').next().unwrap_or_default();
                let resolved = known
                    .get(name)
                    .is_some_and(|paths| paths.iter().any(|real| real.ends_with(tail)));
                // The tree holds the roots a rule reads, which is not quite every file `git` sees:
                // the vendored dependency's own scripts sit outside it and are citable. So a tail
                // the index cannot place is asked of the filesystem before it is called a lie.
                if !resolved && !tree.root().join(tail).exists() {
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
    let files = collect(tree, &[OPS], &["rs"]);
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
        view: View::Code,
        message: "rust/slopdesk-devtools/src/ops/hostd.rs signals the recorded pid before it boots \
                  com.slopdesk.hostd out of launchd — the agent relaunches the installed binary into a race \
                  with the replay, and the loser exits 0, so `just host-restart` reports success over \
                  whichever hostd won",
    }])
}

#[cfg(test)]
mod tests {
    use super::{
        a_guarded_keepalive_supervises_a_daemon_that_exits_zero,
        an_ops_harness_that_starts_a_daemon_contains_it, every_injected_sink_has_someone_who_binds_it,
        live_docs_cite_files_that_exist, no_app_layer_crypto, no_fused_multiply_add,
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
        fixture.write("justfile", "all:\n    echo hi\n");
        fixture.write("scripts/soak.sh", "pkill -f slopdesk-hostd --port 9999\n");
        assert!(pkill_never_reaches_the_developers_host(&fixture.tree()).is_clean());
        fixture.write("scripts/reap.sh", "pkill -f slopdesk-hostd\n");
        assert!(!pkill_never_reaches_the_developers_host(&fixture.tree()).is_clean());
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
        fixture.write(
            "CLAUDE.md",
            &format!("see {TICK}Sources/A/Gone.swift{TICK} for the seam\n"),
        );
        assert!(!live_docs_cite_files_that_exist(&fixture.tree()).is_clean());

        let deleting = with_live_docs("live-docs-deleted");
        deleting.write(
            "CLAUDE.md",
            &format!("## What this deleted\n\n- {TICK}Sources/A/Gone.swift{TICK}, folded in\n"),
        );
        assert!(live_docs_cite_files_that_exist(&deleting.tree()).is_clean());
    }

    /// A live doc that has gone missing is the gate's own blindness, and it is reported as one.
    #[test]
    fn a_live_doc_that_is_not_in_the_tree_is_red() {
        let fixture = Fixture::new("live-docs-absent");
        fixture.write("CLAUDE.md", "nothing cited here\n");
        assert!(!live_docs_cite_files_that_exist(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_comment_citing_a_tail_that_resolves_is_green_and_one_that_does_not_is_red() {
        let fixture = Fixture::new("comment-cites");
        fixture.write("Sources/SlopDeskPhoneUI/Settings/Pages.swift", "// the page\n");
        fixture.write(
            "Sources/A/Note.swift",
            &format!("/// see {TICK}SlopDeskPhoneUI/Settings/Pages.swift{TICK} for the rest\n"),
        );
        assert!(source_comments_cite_files_that_exist(&fixture.tree()).is_clean());

        let stale = Fixture::new("comment-cites-stale");
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
        fixture.write(
            "Sources/A/Note.swift",
            &format!("/// libghostty's own {TICK}Helpers/Cursor.swift{TICK}\n"),
        );
        assert!(source_comments_cite_files_that_exist(&fixture.tree()).is_clean());
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
