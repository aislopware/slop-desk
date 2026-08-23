//! Move each sidecar's OWN version, and only the ones that moved.
//!
//! ## Why this is separate from the product version
//! [`super::sites`] writes ONE number into six places, and those six are the PRODUCT: the CLI
//! banner, the host's `TERM_PROGRAM_VERSION`, and four app-bundle sites. They move together
//! because they describe one thing the user installed.
//!
//! A sidecar is not that. Each runs as its own process with its own lifetime, and the expensive
//! ones outlive the release that installed them — superd holds the master fd of every live pane, so
//! restarting it costs the user every running agent (`docs/51`). Under one shared number there was
//! no way to say "the Android bridge changed and superd did not", so every upgrade restarted
//! everything, and a one-line fix in a panel nobody had open cost a desk full of panes.
//!
//! ## The two questions, and why the stamp answers the first
//! *Did this tool change?* — [`super::stamps`], a digest of the tool's source closure against the
//! value `scripts/tool-stamps.pin` recorded at the last release. Not the commit log: a commit
//! touching `rust/slopdesk-screend/README.md` is in the log and changes no binary, and a commit
//! touching `rust/slopdesk-sanitize` is a change to screend and superd while naming neither.
//!
//! *By how much?* — the commit log, scoped to the same closure, read with the conventional-commit
//! grammar [`super::commitmsg`] already enforces. Same rules the cut applies to the product: `!` or
//! a `BREAKING CHANGE:` trailer is major (below 1.0, the minor), `feat` the minor, and
//! `fix`/`perf`/`refactor` the patch.
//!
//! WHEN THE TWO DISAGREE THE STAMP WINS, in both directions, and neither default is arbitrary:
//!
//! * stamp unchanged, commits present → NO bump. The commits reached a path in the closure without
//!   changing a hashed file (a README, a fixture), so there is nothing to ship and a version that
//!   moved would restart a daemon to install the identical binary.
//! * stamp changed, no bump-worthy commit → PATCH. Something in the closure really is different;
//!   refusing to bump would ship it under the old version and the install side would skip the
//!   restart, leaving the user running code the release did not contain. A patch is the smallest
//!   honest answer.

use std::fs;
use std::path::Path;

use regex::Regex;

use super::stamps::{self, Entry, Pin};
use super::{proc, tools};

/// How far a version moves. Ordered, so a scan can keep the highest it has seen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    /// Nothing in the log asked for a move.
    None,
    /// `fix`, `perf`, `refactor`.
    Patch,
    /// `feat`.
    Minor,
    /// `!` before the colon, or a `BREAKING CHANGE:` trailer.
    Major,
}

impl Kind {
    /// The word the plan prints.
    #[must_use]
    pub const fn word(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Patch => "patch",
            Self::Minor => "minor",
            Self::Major => "major",
        }
    }
}

/// What one commit asks for, read from its subject and body.
///
/// The `!` is the breaking marker the grammar puts BEFORE the colon, so it is matched there rather
/// than anywhere in the subject.
#[must_use]
pub fn kind_of(subject: &str, body: &str) -> Kind {
    let head = subject.split(':').next().unwrap_or_default();
    if is_breaking(head) || body.contains("BREAKING CHANGE:") {
        return Kind::Major;
    }
    match type_of(head) {
        Some("feat") => Kind::Minor,
        Some("fix" | "perf" | "refactor") => Kind::Patch,
        _ => Kind::None,
    }
}

/// The `<type>[(scope)]` before a subject's colon, when it is one.
fn type_of(head: &str) -> Option<&str> {
    let (kind, scope) = head
        .split_once('(')
        .map_or((head, None), |(kind, rest)| (kind, Some(rest)));
    if kind.is_empty() || !kind.bytes().all(|byte| byte.is_ascii_lowercase()) {
        return None;
    }
    // `(…)` and nothing after it — a trailing `!` is stripped by the caller's own test.
    scope.map_or(Some(kind), |rest| {
        rest.strip_suffix(')')
            .filter(|inner| !inner.contains(')'))
            .map(|_| kind)
    })
}

/// `<type>[(scope)]!` — the `!` is the breaking marker the grammar puts BEFORE the colon.
fn is_breaking(head: &str) -> bool {
    head.strip_suffix('!').is_some_and(|rest| type_of(rest).is_some())
}

/// `current` moved by `kind`.
///
/// Below 1.0 a breaking change moves the MINOR, which is semver's own rule and the one the cut
/// applies to the product — a 0.x major bump would claim a stability this tree has not promised.
///
/// # Errors
/// When `current` is not a plain `major.minor.patch`.
pub fn next_version(current: &str, kind: Kind) -> Result<String, String> {
    let core = current.split(['-', '+']).next().unwrap_or_default();
    let numbers: Vec<u64> = core
        .split('.')
        .map(|part| {
            part.parse::<u64>()
                .map_err(|_| format!("not a semver in a Cargo.toml: {current}"))
        })
        .collect::<Result<_, _>>()?;
    let [major, minor, patch] = numbers[..] else {
        return Err(format!("not a semver in a Cargo.toml: {current}"));
    };
    Ok(match kind {
        Kind::Major if major == 0 => format!("0.{}.0", minor + 1),
        Kind::Major => format!("{}.0.0", major + 1),
        Kind::Minor => format!("{major}.{}.0", minor + 1),
        Kind::Patch => format!("{major}.{minor}.{}", patch + 1),
        Kind::None => current.to_owned(),
    })
}

/// The release this tree is measured against.
///
/// Commits BEFORE it already shipped, so they cannot be evidence that a tool changed since. A repo
/// with no tag at all measures from the root commit, which is the honest answer for a first release
/// rather than an error.
#[must_use]
pub fn base_range(root: &Path) -> (Option<String>, String) {
    match proc::ask("git", &["describe", "--tags", "--abbrev=0"], root) {
        Some(tag) if !tag.is_empty() => (Some(tag.clone()), format!("{tag}..HEAD")),
        _ => (None, "HEAD".to_owned()),
    }
}

/// The largest bump the commits touching `tool`'s closure ask for.
///
/// Reads subject AND body: a `BREAKING CHANGE:` trailer lives in the body, and the two are kept
/// apart by a unit separator so a body line that merely quotes a subject cannot be parsed as one.
/// A record separator ends each commit, because a body is many lines and `git log` would otherwise
/// run them together.
///
/// # Errors
/// When the tool's path closure is empty or unreadable, or `git log` fails.
pub fn kind_for(root: &Path, tool: &str, range: &str) -> Result<Kind, String> {
    let paths = path_closure(root, tool)?;
    if paths.is_empty() {
        return Err(format!("{tool} has an empty path closure"));
    }
    let mut arguments: Vec<String> = vec![
        "log".to_owned(),
        range.to_owned(),
        "--no-merges".to_owned(),
        "--format=%s%x1f%b%x1e".to_owned(),
        "--".to_owned(),
    ];
    arguments.extend(paths);
    Ok(largest_kind(&proc::capture("git", &arguments, root)?))
}

/// The largest bump asked for by a `%s%x1f%b%x1e` log.
///
/// Split on the RECORD separator first and the UNIT separator second, in that order: a body is
/// many lines, and `git log` runs consecutive commits together without the record mark. The
/// leading newline `git log` puts between records is the only thing trimmed — trimming further
/// would eat a body's own leading blank line, which is where a trailer block starts.
#[must_use]
pub fn largest_kind(log: &str) -> Kind {
    log.split('\u{1e}')
        .filter_map(|record| {
            let record = record.trim_start_matches('\n');
            if record.is_empty() {
                return None;
            }
            let (subject, body) = record.split_once('\u{1f}').unwrap_or((record, ""));
            Some(kind_of(subject, body))
        })
        .max()
        .unwrap_or(Kind::None)
}

/// The repo-relative directories whose commits belong to `tool`.
///
/// Its own crate and every local crate it links, which is the same closure the stamp hashes — so
/// "which commits touched this tool" is asked without a second idea of what a tool is made of.
///
/// # Errors
/// When `tool` is not a cargo tool or its closure cannot be walked.
pub fn path_closure(root: &Path, tool: &str) -> Result<Vec<String>, String> {
    let crate_name = tools::tool_crate(tool).ok_or_else(|| format!("{tool} is not a shipped cargo tool"))?;
    let mut paths = stamps::crate_closure(root, crate_name)?;
    // A root-workspace member's profile and lints live in the workspace manifest, so a commit that
    // touches only `rust/Cargo.toml` is a change to every member. Same reason the stamp adds it.
    if tools::is_root_tool(tool) {
        paths.push("rust/Cargo.toml".to_owned());
        paths.push("rust/Cargo.lock".to_owned());
    }
    Ok(paths)
}

/// One tool's row in the plan.
#[derive(Debug, Clone)]
pub struct Move {
    /// The tool.
    pub tool: String,
    /// The version its crate declares today.
    pub from: String,
    /// The version it will declare after the write — the same string when nothing moved.
    pub to: String,
    /// The stamp measured for the plan. Re-read after the writes before it reaches the pin.
    pub stamp: String,
    /// The line the plan prints for this row.
    pub line: String,
}

/// Decide what every tool does, before anything is written.
///
/// Computed for all of them first so a dry run and a real run agree, and so a failure halfway
/// leaves no crate bumped against a pin that never learned about it.
///
/// # Errors
/// When a stamp, a manifest or the commit log cannot be read.
pub fn plan(root: &Path, pin: &Pin, range: &str) -> Result<Vec<Move>, String> {
    let mut plan = Vec::new();
    for entry in stamps::scan(root)? {
        let pinned = pin.entry(&entry.tool);
        if pinned.is_some_and(|previous| previous.stamp == entry.stamp) {
            plan.push(Move {
                line: format!("  same     {:<22} {}", entry.tool, entry.version),
                tool: entry.tool,
                from: entry.version.clone(),
                to: entry.version,
                stamp: entry.stamp,
            });
            continue;
        }

        // The stamp is what says a binary changed, so a changed stamp always ships SOMETHING.
        // Refusing the bump here would leave the install side skipping a restart it needed.
        let mut kind = kind_for(root, &entry.tool, range)?;
        if kind == Kind::None {
            kind = Kind::Patch;
        }
        let target = next_version(&entry.version, kind)?;
        let line = match pinned {
            None => format!("  NEW      {:<22} {target} (never released)", entry.tool),
            Some(previous) => {
                format!(
                    "  {:<8} {:<22} {} → {target}",
                    kind.word(),
                    entry.tool,
                    previous.version
                )
            },
        };
        plan.push(Move {
            tool: entry.tool,
            from: entry.version,
            to: target,
            stamp: entry.stamp,
            line,
        });
    }
    Ok(plan)
}

/// Write `version` into a crate's `[package]` table, read it back, and refresh its lock entry.
///
/// Anchored on the table, not on the first `version =` in the file: a `[dependencies]` entry three
/// lines down is spelled the same way, and rewriting THAT is a broken build with a
/// plausible-looking diff.
///
/// # Errors
/// When the manifest is missing, the anchor has moved, or cargo cannot refresh the lock.
pub fn write_crate_version(root: &Path, crate_name: &str, version: &str) -> Result<(), String> {
    let manifest = root.join("rust").join(crate_name).join("Cargo.toml");
    let text = fs::read_to_string(&manifest).map_err(|_| format!("missing rust/{crate_name}/Cargo.toml"))?;
    let anchored =
        Regex::new(r#"(?s)(\[package\][^\[]*?\nversion = )"[^"]*""#).map_err(|error| error.to_string())?;
    let rewritten = anchored.replace(&text, format!("${{1}}\"{version}\"").as_str());
    fs::write(&manifest, rewritten.as_ref())
        .map_err(|error| format!("rust/{crate_name}/Cargo.toml: {error}"))?;

    let readback = stamps::package_version(rewritten.as_ref());
    if readback.as_deref() != Some(version) {
        return Err(format!(
            "rust/{crate_name}/Cargo.toml still reads {} after the write — the anchor moved",
            readback.as_deref().unwrap_or("<nothing>")
        ));
    }

    // THE LOCK CARRIES THE PACKAGE'S OWN VERSION TOO, and leaving it stale is not cosmetic: the
    // next `cargo build` rewrites it, and that build is the packager — running AFTER the cut
    // committed and tagged. The result is a tag whose tree does not build clean and a lock file
    // dirtied by the release itself.
    //
    // `cargo update -p <crate> --offline` and nothing broader. `generate-lockfile` would re-resolve
    // every dependency, which is a version bump nobody asked for riding in on a release commit;
    // `--offline` means it cannot reach a registry to find one even if the resolver wanted to.
    //
    // A root-workspace member's lock is the SHARED `rust/Cargo.lock`, so the update runs from
    // there. `rust/Cargo.toml` excludes the daemons, so the same invocation from `rust/` could not
    // see one.
    let own = root.join("rust").join(crate_name);
    let workspace = if own.join("Cargo.lock").is_file() {
        own
    } else {
        root.join("rust")
    };
    proc::run(
        "cargo",
        &["update", "--offline", "--quiet", "-p", crate_name],
        &workspace,
    )
    .map_err(|error| format!("could not update the lock for {crate_name}: {error}"))
}

/// Apply a plan: write every crate version that moved, then rewrite the pin from a fresh scan.
///
/// One crate may back two tools, so the same version is written twice. That is idempotent and
/// deliberate: they are one crate's two binaries.
///
/// The stamps are RE-READ rather than reused from the plan, because the writes above changed a
/// `Cargo.toml` inside every bumped tool's own closure — the plan's values describe the tree as it
/// was a moment ago, and pinning those would report every bumped tool as changed again tomorrow.
///
/// # Errors
/// When a write, a lock refresh, a re-scan or the pin rewrite fails.
pub fn apply(root: &Path, pin: &Pin, plan: &[Move]) -> Result<Vec<Entry>, String> {
    for step in plan.iter().filter(|step| step.from != step.to) {
        let crate_name =
            tools::tool_crate(&step.tool).ok_or_else(|| format!("{} is not a cargo tool", step.tool))?;
        write_crate_version(root, crate_name, &step.to)?;
    }
    let fresh = stamps::scan(root)?;
    Pin::write(root, &pin.header, &fresh)?;
    Ok(fresh)
}

#[cfg(test)]
mod tests {
    use super::{Kind, kind_of, next_version};

    #[test]
    fn the_breaking_marker_sits_before_the_colon() {
        assert_eq!(kind_of("feat(rail)!: key the pane id", ""), Kind::Major);
        assert_eq!(kind_of("fix!: drop the frame", ""), Kind::Major);
        // A bang in the TEXT is not a marker.
        assert_eq!(kind_of("fix(rail): drop the frame!", ""), Kind::Patch);
    }

    #[test]
    fn a_breaking_change_trailer_lives_in_the_body() {
        assert_eq!(
            kind_of("fix(rail): drop the frame", "BREAKING CHANGE: the wire moved"),
            Kind::Major
        );
    }

    #[test]
    fn the_types_map_to_the_three_moves() {
        assert_eq!(kind_of("feat: add a pane", ""), Kind::Minor);
        assert_eq!(kind_of("feat(rail): add a pane", ""), Kind::Minor);
        assert_eq!(kind_of("fix: drop it", ""), Kind::Patch);
        assert_eq!(kind_of("perf: drop it", ""), Kind::Patch);
        assert_eq!(kind_of("refactor: drop it", ""), Kind::Patch);
        assert_eq!(kind_of("docs: explain it", ""), Kind::None);
        assert_eq!(kind_of("chore(release): v0.4.0", ""), Kind::None);
    }

    /// The one place a `feature:` prefix must not be read as `feat`.
    #[test]
    fn a_type_is_the_whole_word() {
        assert_eq!(kind_of("feature: add a pane", ""), Kind::None);
        assert_eq!(kind_of("fixture: add a case", ""), Kind::None);
    }

    /// Below 1.0 a breaking change moves the MINOR — semver's own rule.
    #[test]
    fn a_zero_major_does_not_reach_one() {
        assert_eq!(next_version("0.1.0", Kind::Major).unwrap(), "0.2.0");
        assert_eq!(next_version("1.4.2", Kind::Major).unwrap(), "2.0.0");
    }

    #[test]
    fn the_smaller_moves_are_the_obvious_ones() {
        assert_eq!(next_version("0.1.3", Kind::Minor).unwrap(), "0.2.0");
        assert_eq!(next_version("0.1.3", Kind::Patch).unwrap(), "0.1.4");
        assert_eq!(next_version("0.1.3", Kind::None).unwrap(), "0.1.3");
    }

    #[test]
    fn a_version_that_is_not_three_numbers_is_refused() {
        assert!(next_version("0.1", Kind::Patch).is_err());
        assert!(next_version("0.1.x", Kind::Patch).is_err());
    }

    /// A body is many lines, and the highest kind across the whole log is the answer.
    #[test]
    fn a_log_of_many_records_answers_with_its_largest() {
        let log = concat!(
            "docs: explain it\u{1f}\u{1e}",
            "\nfix(a): drop it\u{1f}a body\nover two lines\n\u{1e}",
            "\nfeat(b): add it\u{1f}\u{1e}",
        );
        assert_eq!(super::largest_kind(log), Kind::Minor);
    }

    /// The trailer lives in the BODY, and a body that merely quotes a subject is not one.
    #[test]
    fn a_trailer_in_a_multi_line_body_is_still_found() {
        let log = "fix(a): drop it\u{1f}why it changed\n\nBREAKING CHANGE: the wire moved\n\u{1e}";
        assert_eq!(super::largest_kind(log), Kind::Major);
        let quoted = "docs: explain it\u{1f}the rule is `feat!: x` for a break\n\u{1e}";
        assert_eq!(super::largest_kind(quoted), Kind::None);
    }

    #[test]
    fn an_empty_log_asks_for_nothing() {
        assert_eq!(super::largest_kind(""), Kind::None);
        assert_eq!(super::largest_kind("\n"), Kind::None);
    }

    /// `major` > `minor` > `patch` > `none`, which is how a scan keeps the highest it has seen.
    #[test]
    fn the_kinds_order() {
        assert!(Kind::Major > Kind::Minor);
        assert!(Kind::Minor > Kind::Patch);
        assert!(Kind::Patch > Kind::None);
    }
}
