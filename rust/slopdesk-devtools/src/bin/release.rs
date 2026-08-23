//! `slopdesk-release` — the whole release pipeline, from a commit subject to a signed DMG.
//!
//! One binary with one subcommand per job the shell scripts used to be. They are separate verbs
//! rather than one `cut` because each is independently useful: the commit hook runs the grammar on
//! every commit, CI runs the changelog slice on a tag it did not cut, and a correction to a version
//! that shipped wrong is a `bump-product` with no cut around it.
//!
//! ```text
//! slopdesk-release commit-msg <file>              the commit-msg hook's grammar + style rules
//! slopdesk-release changelog render [cliff args]  rewrite CHANGELOG.md from the commit log
//! slopdesk-release changelog section <version>    print one release's notes, fail if absent
//! slopdesk-release stamps [--check]               each tool's source digest, or what drifted
//! slopdesk-release stamps --tool <name>           one tool's line
//! slopdesk-release stamps --paths --tool <name>   the repo paths that tool is made of
//! slopdesk-release stamps --files --tool <name>   every file the digest is over
//! slopdesk-release bump-product <version>         write the version into all six PRODUCT sites
//! slopdesk-release bump-tools [--dry-run]         move the sidecars their stamps say moved
//! slopdesk-release cut [--dry-run] [version]      notes, bumps, commit, tag — never a push
//! slopdesk-release package                        build, sign, notarize, DMG + tarball
//! ```
//!
//! Every verb resolves the repo root itself, so it runs from anywhere; `--repo-root <path>` before
//! the verb overrides that.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use slopdesk_devtools::release::stamps::Pin;
use slopdesk_devtools::release::{bump, changelog, commitmsg, pack, proc, sites, stamps, tools};
use slopdesk_devtools::repo;

/// The usage text, which is also the whole argument grammar.
const USAGE: &str = "\
usage: slopdesk-release [--repo-root <path>] <command> [options]

  commit-msg <file>                the commit-msg hook: conventional grammar + style
  changelog render [cliff args]    rewrite CHANGELOG.md from the commit log
  changelog section <version> [f]  print one release's notes; exit 1 when there are none
  stamps [--check]                 <tool> <version> <stamp> per tool, or what drifted
  stamps --tool <name>             one tool's line
  stamps --paths --tool <name>     the repo paths that tool's stamp is over
  stamps --files --tool <name>     every file that tool's stamp hashes, sorted
  bump-product <version>           write the version into all six PRODUCT sites
  bump-tools [--dry-run]           move the sidecar versions their stamps say moved
  cut [--dry-run] [version]        render, gate, bump, commit, tag. Never pushes
  package                          build, sign, notarize, DMG + CLI tarball
";

fn main() -> ExitCode {
    let mut arguments: Vec<String> = std::env::args().skip(1).collect();

    let mut override_root: Option<PathBuf> = None;
    if arguments.first().is_some_and(|first| first == "--repo-root") {
        if arguments.len() < 2 {
            eprintln!("--repo-root needs a path");
            return ExitCode::from(2);
        }
        override_root = Some(PathBuf::from(arguments.remove(1)));
        arguments.remove(0);
    }

    let root = match repo::root(override_root.as_deref()) {
        Ok(root) => root,
        Err(why) => {
            eprintln!("slopdesk-release: {why}");
            return ExitCode::from(2);
        },
    };

    let Some(command) = arguments.first().cloned() else {
        eprint!("{USAGE}");
        return ExitCode::from(2);
    };
    let rest = &arguments[1..];

    match command.as_str() {
        "commit-msg" => commit_msg(rest),
        "changelog" => changelog_command(&root, rest),
        "stamps" => stamps_command(&root, rest),
        "bump-product" => finish(bump_product(&root, rest)),
        "bump-tools" => finish(bump_tools(&root, rest)),
        "cut" => finish(cut(&root, rest)),
        "package" => finish(package(&root)),
        "--help" | "-h" | "help" => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        },
        other => {
            eprintln!("slopdesk-release: unknown command: {other}\n");
            eprint!("{USAGE}");
            ExitCode::from(2)
        },
    }
}

/// Report a fallible command: its reason on stderr, exit 1.
fn finish(outcome: Result<(), String>) -> ExitCode {
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(why) => {
            eprintln!("{why}");
            ExitCode::FAILURE
        },
    }
}

fn commit_msg(arguments: &[String]) -> ExitCode {
    let Some(file) = arguments.first() else {
        eprintln!("usage: slopdesk-release commit-msg <path-to-commit-message-file>");
        return ExitCode::from(2);
    };
    let Ok(message) = std::fs::read_to_string(file) else {
        eprintln!("check-commit-msg: no such file: {file}");
        return ExitCode::from(2);
    };
    match commitmsg::check(&message) {
        commitmsg::Verdict::Accepted(None) => ExitCode::SUCCESS,
        commitmsg::Verdict::Accepted(Some(advice)) => {
            eprintln!("{advice}");
            ExitCode::SUCCESS
        },
        commitmsg::Verdict::Rejected(why) => {
            eprintln!("{why}");
            ExitCode::FAILURE
        },
    }
}

fn changelog_command(root: &Path, arguments: &[String]) -> ExitCode {
    match arguments.first().map(String::as_str) {
        Some("render") => finish(changelog::render(root, &arguments[1..])),
        Some("section") => {
            let Some(version) = arguments.get(1) else {
                eprintln!("usage: slopdesk-release changelog section <version> [changelog]");
                return ExitCode::from(2);
            };
            let path = arguments
                .get(2)
                .map_or_else(|| root.join(changelog::CHANGELOG), PathBuf::from);
            let Ok(text) = std::fs::read_to_string(&path) else {
                eprintln!("changelog-section: no {}", path.display());
                return ExitCode::FAILURE;
            };
            let Some(section) = changelog::section(&text, version) else {
                eprintln!("changelog-section: CHANGELOG.md has no entry for {version}.");
                eprintln!("  Regenerate it:  slopdesk-release changelog render");
                eprintln!("  Or cut properly: slopdesk-release cut");
                return ExitCode::FAILURE;
            };
            println!("{section}");
            ExitCode::SUCCESS
        },
        _ => {
            eprintln!("usage: slopdesk-release changelog <render|section> …");
            ExitCode::from(2)
        },
    }
}

/// What `stamps` was asked for. Each mode answers a different question about the same digest.
#[derive(Debug, Default)]
struct StampRequest {
    /// Name what drifted from the pin rather than printing the scan.
    check: bool,
    /// The repo paths a tool's COMMITS are scoped to.
    paths: bool,
    /// Every file the digest is over.
    files: bool,
    /// One tool instead of all of them.
    one: Option<String>,
}

/// Parse `stamps`' flags, or print the usage that names all four modes.
fn stamp_request(arguments: &[String]) -> Result<StampRequest, ()> {
    let mut request = StampRequest::default();
    let mut walk = arguments.iter();
    while let Some(argument) = walk.next() {
        match argument.as_str() {
            "--check" => request.check = true,
            "--paths" => request.paths = true,
            "--files" => request.files = true,
            "--tool" => {
                let Some(name) = walk.next() else {
                    eprintln!("tool-stamps: --tool needs a tool name");
                    return Err(());
                };
                request.one = Some(name.clone());
            },
            other => {
                eprintln!(
                    "tool-stamps: unknown flag: {other}   (--check | --paths --tool <name> | --files --tool \
                     <name> | --tool <name>)"
                );
                return Err(());
            },
        }
    }
    Ok(request)
}

/// Print one list per line, or the reason there is none.
fn print_lines(lines: Result<Vec<String>, String>) -> ExitCode {
    match lines {
        Ok(lines) => {
            for line in lines {
                println!("{line}");
            }
            ExitCode::SUCCESS
        },
        Err(why) => {
            eprintln!("tool-stamps: {why}");
            ExitCode::FAILURE
        },
    }
}

/// Name what left the pin.
///
/// Exits 1 when anything drifted, so a caller can branch on it. That is NOT a failure: a tool whose
/// sources changed since the last release is the normal state of `main`.
fn stamp_drift(root: &Path, scanned: &[stamps::Entry]) -> ExitCode {
    let pin = Pin::read(root).unwrap_or_default();
    let mut drifted = false;
    for entry in scanned {
        match pin.entry(&entry.tool) {
            None => {
                println!("  NEW      {} (no entry in {})", entry.tool, stamps::PIN);
                drifted = true;
            },
            Some(previous) if previous.stamp != entry.stamp => {
                println!("  CHANGED  {} ({} → needs a bump)", entry.tool, previous.version);
                drifted = true;
            },
            Some(previous) => println!("  same     {} {}", entry.tool, previous.version),
        }
    }
    if drifted {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}

fn stamps_command(root: &Path, arguments: &[String]) -> ExitCode {
    let Ok(request) = stamp_request(arguments) else {
        return ExitCode::from(2);
    };

    // The audit trail behind a stamp that moved: the digest is over exactly these files, in exactly
    // this order, so "why did superd bump" is answerable without re-deriving the closure by hand.
    // `--paths` is the coarser question the bumper asks — which COMMITS belong to this tool.
    if request.files || request.paths {
        let Some(tool) = request.one else {
            eprintln!("tool-stamps: --files and --paths each need --tool <name>");
            return ExitCode::from(2);
        };
        return print_lines(if request.files {
            stamps::stamp_inputs(root, &tool)
        } else {
            bump::path_closure(root, &tool)
        });
    }

    if let Some(tool) = request.one {
        if tools::tool_crate(&tool).is_none() {
            eprintln!("tool-stamps: {tool} is not a shipped cargo tool");
            return ExitCode::FAILURE;
        }
        return print_lines(stamps::declared_version(root, &tool).and_then(|version| {
            stamps::stamp_of(root, &tool).map(|stamp| vec![format!("{tool} {version} {stamp}")])
        }));
    }

    let scanned = match stamps::scan(root) {
        Ok(scanned) => scanned,
        Err(why) => {
            eprintln!("tool-stamps: {why}");
            return ExitCode::FAILURE;
        },
    };
    if request.check {
        return stamp_drift(root, &scanned);
    }
    for entry in scanned {
        println!("{} {} {}", entry.tool, entry.version, entry.stamp);
    }
    ExitCode::SUCCESS
}

fn bump_product(root: &Path, arguments: &[String]) -> Result<(), String> {
    let version = arguments.first().ok_or_else(|| {
        "usage: slopdesk-release bump-product <version>   (e.g. 0.2.3, no leading v)".to_owned()
    })?;
    sites::bump(root, version)
}

fn bump_tools(root: &Path, arguments: &[String]) -> Result<(), String> {
    let mut dry_run = false;
    for argument in arguments {
        if argument == "--dry-run" {
            dry_run = true;
        } else {
            return Err(format!(
                "bump-tool-versions: unknown flag: {argument}   (--dry-run)"
            ));
        }
    }
    let pin = Pin::read(root)?;
    let (base, range) = bump::base_range(root);
    let plan = bump::plan(root, &pin, &range)?;
    for step in &plan {
        println!("{}", step.line);
    }
    if plan.iter().all(|step| step.from == step.to) {
        println!(
            "bump-tool-versions: no sidecar changed since {} — nothing to bump",
            base.as_deref().unwrap_or("the root commit")
        );
        return Ok(());
    }
    if dry_run {
        println!("bump-tool-versions: --dry-run, nothing written");
        return Ok(());
    }
    bump::apply(root, &pin, &plan)?;
    println!(
        "bump-tool-versions: crate versions written and {} rewritten",
        stamps::PIN
    );
    Ok(())
}

/// Cut a release: decide the version, write the notes, bump every site, commit, tag.
///
/// This is `lerna version --conventional-commits` for a repo with no package.json. One convention
/// on commit subjects, read twice: once by `git cliff --bumped-version` to turn feat/fix into
/// minor/patch, once by the render to produce what the GitHub Release ships.
///
/// It does NOT push. The tag push is what starts the signing pipeline, and that stays a separate,
/// deliberate keystroke.
fn cut(root: &Path, arguments: &[String]) -> Result<(), String> {
    let mut dry_run = false;
    let mut forced: Option<String> = None;
    for argument in arguments {
        if argument == "--dry-run" {
            dry_run = true;
        } else if argument.starts_with('-') {
            return Err(format!("cut-release: unknown flag: {argument}"));
        } else {
            forced = Some(argument.trim_start_matches('v').to_owned());
        }
    }

    for tool in ["git-cliff", "xcodegen"] {
        if !proc::on_path(tool) {
            return Err(format!("cut-release: {tool} not on PATH (brew install {tool})"));
        }
    }

    // A release is cut FROM a branch, not from a detached checkout, and from main because the tag
    // has to be reachable from the branch the tap and the docs point at.
    let branch = proc::capture("git", &["rev-parse", "--abbrev-ref", "HEAD"], root)?;
    if branch != "main" {
        return Err(format!("cut-release: on {branch}; releases are cut from main"));
    }
    // A dirty tree means the release commit would carry work nobody reviewed as part of it, and
    // the bump would land on top of edits that were never built.
    if !proc::capture("git", &["status", "--porcelain"], root)?.is_empty() {
        return Err("cut-release: working tree is dirty — commit or stash first".to_owned());
    }

    proc::step("Deciding the version");
    let version = if let Some(forced) = forced {
        println!("forced on the command line: {forced}");
        forced
    } else {
        let computed = proc::ask("git-cliff", &["--bumped-version"], root).ok_or_else(|| {
            "cut-release: git cliff could not compute a version (no conventional commits since the last tag?)"
                .to_owned()
        })?;
        let computed = computed.trim_start_matches('v').to_owned();
        println!("computed from the commits since the last tag: {computed}");
        computed
    };
    if !sites::is_semver(&version) {
        return Err(format!("cut-release: not a semver: {version}"));
    }
    if proc::ask(
        "git",
        &["rev-parse", "-q", "--verify", &format!("refs/tags/v{version}")],
        root,
    )
    .is_some()
    {
        return Err(format!(
            "cut-release: v{version} already exists — pass a different version or delete the tag"
        ));
    }

    proc::step("Rendering CHANGELOG.md");
    // `--tag` tells git-cliff to render the unreleased commits UNDER the version about to be
    // tagged, rather than leaving them in an "Unreleased" section the release could not slice.
    changelog::render(root, &["--tag".to_owned(), format!("v{version}")])?;
    let rendered = std::fs::read_to_string(root.join(changelog::CHANGELOG))
        .map_err(|error| format!("cut-release: {}: {error}", changelog::CHANGELOG))?;
    let notes = changelog::section(&rendered, &version)
        .ok_or_else(|| format!("cut-release: the rendered changelog has no {version} section"))?;

    if dry_run {
        proc::step("Dry run — the release body would be");
        println!("{notes}");
        if proc::run("git", &["checkout", "--", changelog::CHANGELOG], root).is_err() {
            let _ = std::fs::remove_file(root.join(changelog::CHANGELOG));
        }
        proc::step("Dry run — the sidecars that would move");
        bump_tools(root, &["--dry-run".to_owned()])?;
        println!();
        println!("cut-release: nothing was written. Re-run without --dry-run to cut v{version}.");
        return Ok(());
    }

    proc::step("Writing the version into every site");
    sites::bump(root, &version)?;

    // The PRODUCT version above moves on every cut; a sidecar's does not. Each one is bumped only
    // when its own source stamp left the pin — so a release that touched nothing but the client app
    // leaves every sidecar version exactly where it was, and the install side has a reason not to
    // restart a single daemon. That is the whole point: restarting superd costs the user every live
    // pane (`docs/51`), and it should cost that only when superd actually changed.
    //
    // AFTER the product sites, and the order matters in one direction only: nothing here reads the
    // product version, but the six-site write ends in a sweep that fails on any version-shaped
    // string in those files that is not the new one, and a crate version is not in them. Kept
    // downstream anyway so a failure in that write stops the cut before any crate is touched.
    proc::step("Bumping the sidecars that changed");
    bump_tools(root, &[])?;

    proc::step("Committing and tagging");
    let mut staged: Vec<&str> = vec![changelog::CHANGELOG];
    staged.extend(sites::all_sites());
    staged.push(stamps::PIN);
    let mut add: Vec<&str> = vec!["add"];
    add.extend(staged);
    proc::run("git", &add, root)?;
    // The crate manifests and lock files the bumper rewrote. `-u` rather than a path list, because
    // which crates moved is exactly what this cannot know in advance — and leaving one out would
    // strand a bumped `Cargo.toml` in the working tree, where the release ships a binary whose
    // version was never committed and the next `make check` finds a dirty tree.
    //
    // `-u` over a whole directory is safe here for ONE reason, checked far above: this refuses to
    // run on a dirty tree. So the only modifications under `rust/` at this point are the ones the
    // bumper just made, and a sweep cannot catch work nobody reviewed as part of the release.
    proc::run("git", &["add", "-u", "rust"], root)?;

    // `chore(release)` is the one subject `cliff.toml` skips, so the release commit never appears
    // in the notes of the release after it.
    proc::run(
        "git",
        &["commit", "-m", &format!("chore(release): v{version}")],
        root,
    )?;
    proc::run(
        "git",
        &["tag", "-a", &format!("v{version}"), "-m", &format!("v{version}")],
        root,
    )?;

    println!(
        "\ncut-release: v{version} is committed and tagged, and nothing has left this machine.\n\n  \
         Review:  git show --stat HEAD\n  \
         Ship:    git push origin main && git push origin v{version}\n  \
         Undo:    git tag -d v{version} && git reset --hard HEAD~1"
    );
    Ok(())
}

fn package(root: &Path) -> Result<(), String> {
    let settings = pack::Settings::from_env()?;
    pack::run(root, &settings)
}
