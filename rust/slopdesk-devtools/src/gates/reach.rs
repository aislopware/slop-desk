//! The four questions about the justfile that only the justfile can answer.
//!
//! Every rule in `slopdesk-invariants` is decided by READING the tree. These four are not: each
//! asks what a `just` recipe would RUN, which means expanding it — and the recipe derives
//! its crate list from the filesystem, so there is no per-crate line left to grep. "What would you
//! do" is the question that survives however the recipe is written next, and `just --dry-run` costs
//! 30 ms to ask.
//!
//! ## Two things the move off make changed, and both are load-bearing
//! `make -n` printed its plan on STDOUT; `just --dry-run` prints it on STDERR, which is why the
//! plans come through [`proc::ask_err`] rather than `proc::ask`.
//!
//! And `just --dry-run` does not RUN a command substitution — it prints the backtick expression
//! verbatim, where `make -n` had already expanded `$(shell …)` into the list. So the plan arrives
//! with `` `grep -l '^[workspace]' …` `` where the crate paths belong, and [`expand_backticks`]
//! runs each substitution the way the shell would have. That is why `RUST_WORKSPACES` in the
//! justfile is a BACKTICK and not `shell(…)`: a `shell(…)` prints as its own source text, which
//! this could not honestly re-run.
//!
//! ## And a plan is not source text, except where it is
//! Every question here is POSITIVE — the plan must NAME something — which is the shape a comment
//! can answer for. `slopdesk-invariants` closed that class over the tree by reading `statements()`;
//! the same class reaches a plan because `just --dry-run` ECHOES a comment inside a recipe body
//! verbatim. [`commands_only`] is this module's half of the answer, and it runs before the
//! substitutions for a reason of its own.
//!
//! ## Why the answer matters more than it looks
//! Almost every crate under `rust/` is its own cargo workspace, and cargo will not cross a
//! workspace boundary for you. A crate that no `fmt`/`lint`/`test` recipe enters is not a warning —
//! it is silence. Formatting is the quietest of the three, since nothing looks different until
//! someone runs the writer and gets a diff they did not make; a suite that never executes is the
//! loudest, because it reports green about code nobody exercised.
//!
//! The Miri question is the same shape asked of the ONE suite `CLAUDE.md` names as the price of an
//! `unsafe` crate. The third of the three was bought with "a differential suite that runs under
//! Miri", and for years nothing ran it: `just miri` existed, `just check` did not depend on it,
//! `just test` did not, the prek hooks did not, the disabled CI did not — so the sentence in the
//! document was the entire enforcement.
//!
//! ## Three ways a crate stayed out of the questions above
//! Each was found by RUNNING the gate over a seeded tree rather than by reading it, and each is the
//! same shape: the question was asked of a narrower set than the sentence that motivates it.
//!
//! * The reach questions were asked of the WORKSPACE ROOTS only. A crate that declares no
//!   `[workspace]` and is not a member of `rust/Cargo.toml` is adopted by nothing — `cargo fmt
//!   --all` from the root does not see it and no recipe enters it — and it was not in the set the
//!   questions were asked of, so a seeded one came back green. [`adopted_by_nothing`] is that half.
//! * `rust` ITSELF was never asked. `RUST_WORKSPACES` carries a bare `rust` in front of the derived
//!   list, and that entry is what covers the root workspace's six members; nothing checked it was
//!   still there, because the check iterated a list `rust` is not in.
//! * The Miri arm asked whether the plan runs Miri, never over WHAT. Retargeting the recipe to
//!   another crate left the gate green while the obligation it names — `rust/slopdesk-gfsimd`'s
//!   `unsafe` — went unexercised. [`runs_miri_for`] asks the whole question.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use crate::proc;

/// The recipes that must reach every workspace crate, and what each one would leave unchecked.
///
/// Three, not one, because a crate present in one and missing from another has an unchecked half.
const REACHING: [&str; 4] = ["fmt-rust", "lint-rust", "lint-rust-clippy", "test-rust"];

/// The one workspace that has MEMBERS, and so the one directory a recipe can enter on their behalf.
const ROOT_WORKSPACE: &str = "rust";

/// The crate whose `unsafe` the Miri suite is the price of.
///
/// Spelled here rather than derived from `slopdesk-invariants`' `HAND_WRITTEN` list, because one
/// string is not worth a dependency edge from the gate runners onto the tree rules — so the
/// duplication is declared instead: `CLAUDE.md`'s bar for a third hand-written-`unsafe` crate is
/// "a differential suite that runs under Miri", and THIS is the crate that cleared it.
const MIRI_CRATE: &str = "slopdesk-gfsimd";

/// What one recipe would run, with every command substitution performed.
///
/// `None` when `just` refused the recipe at all, which every caller reads as "no plan" and reports
/// rather than accepting.
fn dry_run(root: &Path, recipe: &str) -> String {
    let raw = proc::ask_err("just", &["--dry-run", recipe], root).unwrap_or_default();
    plan(&raw, root)
}

/// A raw dry-run plan turned into the text every question below is asked of.
///
/// The two steps are ONE function because their ORDER is the contract, and a caller composing them
/// by hand can get it wrong silently — see [`commands_only`] for what expanding first would run.
#[must_use]
pub fn plan(raw: &str, root: &Path) -> String {
    expand_backticks(&commands_only(raw), root)
}

/// A dry-run plan with the lines `just` would only ECHO removed.
///
/// Every question this module asks is a POSITIVE one — the plan must NAME a crate path, a
/// `cargo test -p`, a `cargo +nightly miri test` — and `just --dry-run` prints a comment inside a
/// recipe body verbatim, exactly like a command. So `# cargo +nightly miri test` in the `check`
/// recipe satisfied the one obligation `CLAUDE.md` names as the price of `rust/slopdesk-gfsimd`'s
/// `unsafe`, and a commented-out `cargo test -p` line answered for a suite nobody runs. The tree is
/// clean today — the only echoed comment in any of the six plans is `check`'s `#!/bin/sh` shebang,
/// which nothing here searches for — so this closes the hole rather than reporting one.
///
/// It runs BEFORE [`expand_backticks`], and that order is the sharper half. A backtick on a
/// commented line is a substitution `just` would never perform, and expanding first would hand it
/// to `sh -c`: the gate executing shell out of a line the recipe does not run.
///
/// A LEADING `#` is the whole test. A `#` inside a command — `sed 's/#.*//'` — is not a comment and
/// the line stays, which is why this is not a strip-to-end-of-line.
#[must_use]
pub fn commands_only(raw: &str) -> String {
    raw.lines()
        .filter(|line| !line.trim_start().starts_with('#'))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Run every `` `…` `` in a dry-run plan and splice its output back in, as the shell would.
///
/// Newlines collapse to spaces because the plan is read a LINE at a time and a substitution that
/// yielded sixty crate paths would otherwise turn one command into sixty.
#[must_use]
pub fn expand_backticks(plan: &str, root: &Path) -> String {
    let mut out = String::new();
    let mut rest = plan;
    while let Some(open) = rest.find('`') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        let Some(close) = after.find('`') else {
            // An UNPAIRED backtick is not a substitution. Copy it through rather than swallowing
            // the remainder of a plan the caller is about to search.
            out.push('`');
            out.push_str(after);
            return out;
        };
        let value = proc::ask("sh", &["-c", &after[..close]], root).unwrap_or_default();
        out.push_str(&value.replace('\n', " "));
        rest = &after[close + 1..];
    }
    out.push_str(rest);
    out
}

/// Run every reachability question and collect the failures.
///
/// # Errors
/// One message per violated contract, joined by newlines — so a single run names everything that is
/// unreachable rather than the first thing.
pub fn run(root: &Path) -> Result<(), String> {
    let mut failures: Vec<String> = Vec::new();
    let workspaces = workspace_crates(root)?;
    let all = every_crate(root)?;
    let members = root_members(root)?;

    let orphans = adopted_by_nothing(&all, &workspaces, &members);
    if !orphans.is_empty() {
        for name in &orphans {
            eprintln!("{name} (adopted by no workspace)");
        }
        failures.push(format!(
            "a crate under rust/ declares no [workspace] and is not a member of {ROOT_WORKSPACE}/Cargo.toml \
             — nothing adopts it, so no recipe can enter it and the reach questions below are never asked \
             of it"
        ));
    }

    for recipe in REACHING {
        let plan = dry_run(root, recipe);
        if plan.trim().is_empty() {
            failures.push(format!(
                "'just --dry-run {recipe}' printed nothing — the check below would accept every crate"
            ));
            continue;
        }
        let unreachable: Vec<&String> = workspaces
            .iter()
            .filter(|name| !plan_enters(&plan, name))
            .collect();
        if !unreachable.is_empty() {
            for name in &unreachable {
                eprintln!("{name} (unreachable from just {recipe})");
            }
            failures.push(
                "a crate is its own cargo workspace and a rust fmt/lint/test recipe never enters it"
                    .to_owned(),
            );
        }
        // The root workspace is not in the list above — it is not a crate under `rust/` — and it is
        // the only entry that covers a MEMBER, since `--all`/`--workspace` reach one only from the
        // directory that adopts it. Drop the bare `rust` from `RUST_WORKSPACES` and six crates go
        // unformatted while every question above still answers yes.
        if !members.is_empty() && !plan_enters_dir(&plan, ROOT_WORKSPACE) {
            failures.push(format!(
                "'just {recipe}' never enters {ROOT_WORKSPACE}/ — its {} members are reached through that \
                 directory and nowhere else",
                members.len()
            ));
        }
    }

    // The same question a second time, about the recipe that RUNS the tests — and asked of a dry
    // run of `test` rather than of its dependency line, because reading the `<short>-test` names
    // off `test:` gets it WRONG: `slopdesk-sanitize` has no recipe of its own, its tests run
    // inside `screend-test`, and the first draft of this check reported it as untested.
    let test_plan: String = dry_run(root, "test")
        .lines()
        .filter(|line| line.contains("cargo test"))
        .collect::<Vec<_>>()
        .join("\n");
    if test_plan.trim().is_empty() {
        failures.push(
            "'just --dry-run test' printed no cargo test command — the check below would accept every crate"
                .to_owned(),
        );
    } else {
        let untested: Vec<&String> = all
            .iter()
            .filter(|name| carries_tests(root, name))
            .filter(|name| !runs_tests_for(&test_plan, name))
            .collect();
        if !untested.is_empty() {
            for name in &untested {
                eprintln!("{name}");
            }
            failures.push(
                "a crate carries tests that 'just test' never runs — a suite nobody executes reports green \
                 about code nobody exercised"
                    .to_owned(),
            );
        }
    }

    let check_plan = dry_run(root, "check");
    if check_plan.trim().is_empty() {
        failures.push(
            "'just --dry-run check' printed nothing — the Miri check below would accept a gate that never \
             runs it"
                .to_owned(),
        );
    } else if !runs_miri_for(&check_plan, MIRI_CRATE) {
        failures.push(format!(
            "'just check' does not reach a Miri run over rust/{MIRI_CRATE} — the differential suite is what \
             pays for that crate's unsafe, and Miri over some OTHER crate answers a different question \
             (CLAUDE.md, docs/DECISIONS.md)"
        ));
    }

    if failures.is_empty() {
        println!(
            "check-reach: every crate under rust/ is adopted by a workspace a recipe enters, formatted, \
             linted and tested, and Miri runs over rust/{MIRI_CRATE}"
        );
        Ok(())
    } else {
        Err(failures
            .iter()
            .map(|why| format!("check-reach: FAIL — {why}"))
            .collect::<Vec<_>>()
            .join("\n"))
    }
}

/// True when `needle` occurs in `text` and is not merely the PREFIX of a longer name.
///
/// The one boundary test all three questions below share: `rust/slopdesk-video` must not be
/// satisfied by a plan that only names `rust/slopdesk-videoclient`. A `)` is deliberately not an
/// ending — a plan that wrote `(cd rust/x && …)` would read as unreached, which fails loudly rather
/// than accepting a shape nobody has checked.
fn names_exactly(text: &str, needle: &str) -> bool {
    text.match_indices(needle).any(|(index, _)| {
        let after = text[index + needle.len()..].chars().next();
        matches!(after, None | Some(' ' | ';' | '\n'))
    })
}

/// True when a dry-run plan would enter `dir`, which is a path relative to the repo root.
#[must_use]
pub fn plan_enters_dir(plan: &str, dir: &str) -> bool {
    names_exactly(plan, dir)
}

/// True when a dry-run plan would enter `crate_name`'s directory.
#[must_use]
pub fn plan_enters(plan: &str, crate_name: &str) -> bool {
    plan_enters_dir(plan, &format!("rust/{crate_name}"))
}

/// True when a `cargo test` plan would run `crate_name`'s suite, in either of the two shapes the
/// justfile writes.
#[must_use]
pub fn runs_tests_for(test_plan: &str, crate_name: &str) -> bool {
    test_plan.contains(&format!("cd rust/{crate_name} &&"))
        || names_exactly(test_plan, &format!("cargo test -p {crate_name}"))
}

/// True when a plan runs Miri over `crate_name` SPECIFICALLY.
///
/// Asked of the Miri lines rather than of the whole plan, which is the difference between the two
/// questions: every `check` plan enters `rust/slopdesk-gfsimd` several times over — to format it,
/// to clippy it, to test it — so a plan-wide search for the crate name would be answered by the
/// wrong command, and a plan-wide search for `miri` by the wrong crate.
#[must_use]
pub fn runs_miri_for(plan: &str, crate_name: &str) -> bool {
    plan.lines()
        .filter(|line| line.contains("cargo +nightly miri test"))
        .any(|line| {
            line.contains(&format!("cd rust/{crate_name} &&"))
                || names_exactly(line, &format!("miri test -p {crate_name}"))
        })
}

/// The crates no workspace adopts, which no recipe can enter however it is written.
///
/// A pure function of the three sets so the classification is testable without a tree. A crate is
/// adopted when it is its own workspace root — the reach loop then asks about it directly — or when
/// `rust/Cargo.toml` lists it as a member, which is what makes entering `rust/` cover it. Neither
/// is a matter of what the recipes say, so this is asked ONCE rather than per recipe.
fn adopted_by_nothing<'a>(
    all: &'a [String],
    workspaces: &[String],
    members: &BTreeSet<String>,
) -> Vec<&'a String> {
    all.iter()
        .filter(|name| !workspaces.contains(*name) && !members.contains(*name))
        .collect()
}

/// The member crates `rust/Cargo.toml` adopts.
///
/// # Errors
/// When the manifest cannot be read or declares no `members` key — an empty answer would report
/// every member as an orphan, which is loud about the wrong thing. See
/// [`adopted_by_nothing`] for what the answer decides.
fn root_members(root: &Path) -> Result<BTreeSet<String>, String> {
    let manifest = root.join(ROOT_WORKSPACE).join("Cargo.toml");
    let text = fs::read_to_string(&manifest).map_err(|error| format!("{}: {error}", manifest.display()))?;
    let opened = text.find("members = [").map(|at| &text[at..]).ok_or_else(|| {
        format!(
            "{}: no `members = [` — this gate can no longer tell a member from an orphan",
            manifest.display()
        )
    })?;
    let closed = opened
        .find(']')
        .ok_or_else(|| format!("{}: the `members` array never closes", manifest.display()))?;
    Ok(quoted(&opened[..closed]))
}

/// The double-quoted words of a TOML array fragment, in order.
fn quoted(fragment: &str) -> BTreeSet<String> {
    fragment
        .split('"')
        .skip(1)
        .step_by(2)
        .map(str::to_owned)
        .collect()
}

/// Every crate under `rust/` that is its own cargo workspace.
fn workspace_crates(root: &Path) -> Result<Vec<String>, String> {
    let mut found = Vec::new();
    for name in every_crate(root)? {
        let manifest = root.join("rust").join(&name).join("Cargo.toml");
        let text = fs::read_to_string(&manifest).unwrap_or_default();
        if text.lines().any(|line| line.trim() == "[workspace]") {
            found.push(name);
        }
    }
    Ok(found)
}

/// Every directory under `rust/` holding a `Cargo.toml`.
fn every_crate(root: &Path) -> Result<Vec<String>, String> {
    let rust = root.join("rust");
    let entries = fs::read_dir(&rust).map_err(|error| format!("{}: {error}", rust.display()))?;
    let mut found: Vec<String> = entries
        .filter_map(Result::ok)
        .filter(|entry| entry.path().join("Cargo.toml").is_file())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .collect();
    found.sort_unstable();
    Ok(found)
}

/// Whether a crate has any `#[test]` at all, reading `src` and `tests` ONLY.
///
/// A bare `rust/<crate>` walk descends into `target/`, which holds ~2 GB per crate of build output
/// that also contains `#[test]` — it found the right answer and took minutes to do it, in a gate
/// that runs on every lint.
fn carries_tests(root: &Path, crate_name: &str) -> bool {
    let mut found = false;
    for sub in ["src", "tests"] {
        let dir = root.join("rust").join(crate_name).join(sub);
        found = found || any_rust_file_matching(&dir, &["#[test]", "#[cfg(test)]"]);
    }
    found
}

/// True when some `.rs` file under `dir` contains any of `needles`.
fn any_rust_file_matching(dir: &Path, needles: &[&str]) -> bool {
    let Ok(entries) = fs::read_dir(dir) else {
        return false;
    };
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        if path.is_dir() {
            if any_rust_file_matching(&path, needles) {
                return true;
            }
        } else if path.extension().and_then(|value| value.to_str()) == Some("rs") {
            let text = fs::read_to_string(&path).unwrap_or_default();
            if needles.iter().any(|needle| text.contains(needle)) {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::path::Path;

    use super::{
        adopted_by_nothing, commands_only, expand_backticks, plan, plan_enters, plan_enters_dir,
        runs_miri_for, runs_tests_for,
    };

    /// One of each kind, so a classifier that answered by position rather than by set would show.
    fn crates() -> (Vec<String>, Vec<String>, BTreeSet<String>) {
        let all = ["slopdesk-cli", "slopdesk-wire", "slopdesk-zzprobe"].map(str::to_owned);
        let workspaces = vec!["slopdesk-wire".to_owned()];
        let members = BTreeSet::from(["slopdesk-cli".to_owned()]);
        (all.to_vec(), workspaces, members)
    }

    /// A crate that is neither a workspace root nor a member is reached by nothing — the shape a
    /// seeded `rust/slopdesk-zzprobe` proved the gate used to call green.
    #[test]
    fn a_crate_no_workspace_adopts_is_named() {
        let (all, workspaces, members) = crates();
        assert_eq!(adopted_by_nothing(&all, &workspaces, &members), vec![
            &"slopdesk-zzprobe".to_owned()
        ]);

        // And the two adopted kinds are not: a member is covered from `rust/`, a root on its own.
        let adopted = ["slopdesk-cli".to_owned(), "slopdesk-wire".to_owned()];
        assert!(adopted_by_nothing(&adopted, &workspaces, &members).is_empty());
    }

    /// The membership the orphan question is decided by, and the loud failure when it cannot be
    /// read — an empty answer would report all six members as orphans, naming the wrong defect.
    #[test]
    fn a_manifest_with_no_members_blinds_the_orphan_question() {
        let root = std::env::temp_dir().join("slopdesk-reach-members");
        let rust = root.join("rust");
        std::fs::create_dir_all(&rust).expect("temp tree");

        std::fs::write(
            rust.join("Cargo.toml"),
            "[workspace]\nmembers = [\n  \"slopdesk-hook\",\n  \"slopdesk-ctl\",\n]\nresolver = \"3\"\n",
        )
        .expect("manifest");
        assert_eq!(
            super::root_members(&root).expect("members"),
            BTreeSet::from(["slopdesk-hook".to_owned(), "slopdesk-ctl".to_owned()])
        );

        std::fs::write(rust.join("Cargo.toml"), "[workspace]\nresolver = \"3\"\n").expect("manifest");
        let blind = super::root_members(&root).expect_err("a missing members key must be loud");
        assert!(blind.contains("member from an orphan"), "{blind}");
    }

    /// The root workspace's own entry, which covers every member and is in no list of crates.
    #[test]
    fn the_root_workspace_is_a_directory_a_plan_can_miss() {
        let with_root = "for ws in rust rust/slopdesk-wire; do cd $ws; done";
        assert!(plan_enters_dir(with_root, "rust"));

        // The bare `rust` dropped from `RUST_WORKSPACES`: every crate question still answers yes,
        // and the six members are formatted by nothing.
        let without = "for ws in rust/slopdesk-wire rust/slopdesk-superd; do cd $ws; done";
        assert!(!plan_enters_dir(without, "rust"));
        assert!(plan_enters(without, "slopdesk-wire"));
    }

    /// Miri over the WRONG crate answers a different question, and the plan names the right one on
    /// lines that have nothing to do with Miri.
    #[test]
    fn miri_must_name_the_crate_that_pays_for_it() {
        let real = "cd rust/slopdesk-gfsimd && cargo +nightly fmt --all\ncd rust/slopdesk-gfsimd && cargo \
                    +nightly miri test\n";
        assert!(runs_miri_for(real, "slopdesk-gfsimd"));

        // Retargeted: Miri still runs, the crate is still entered — by the formatter one line up.
        let retargeted = "cd rust/slopdesk-gfsimd && cargo +nightly fmt --all\ncd rust/slopdesk-wire && \
                          cargo +nightly miri test\n";
        assert!(!runs_miri_for(retargeted, "slopdesk-gfsimd"));
        assert!(runs_miri_for(retargeted, "slopdesk-wire"));

        // The other shape, and not satisfied by a longer name.
        assert!(runs_miri_for(
            "cargo +nightly miri test -p slopdesk-gfsimd --quiet",
            "slopdesk-gfsimd"
        ));
        assert!(!runs_miri_for(
            "cargo +nightly miri test -p slopdesk-gfsimdx",
            "slopdesk-gfsimd"
        ));
    }

    /// A commented recipe line answers none of the four questions, in all three of their spellings.
    #[test]
    fn a_comment_in_a_plan_is_not_a_command() {
        let plan = "    # cd rust/slopdesk-ghost && cargo test\n# cargo test -p slopdesk-ghost\n\t#cargo \
                    +nightly miri test\ncd rust/slopdesk-wire && cargo test\n";
        let kept = commands_only(plan);
        assert!(!plan_enters(&kept, "slopdesk-ghost"), "{kept}");
        assert!(!runs_tests_for(&kept, "slopdesk-ghost"), "{kept}");
        assert!(!kept.contains("miri"), "{kept}");

        // The live line beside them survives, so the filter is reading the `#` rather than the
        // plan.
        assert!(plan_enters(&kept, "slopdesk-wire"), "{kept}");
    }

    /// A `#` INSIDE a command is not a comment, and the line stays.
    #[test]
    fn a_hash_inside_a_command_does_not_delete_the_line() {
        let plan = "cd rust/slopdesk-wire && sed 's/#.*//' x && cargo test\n";
        assert_eq!(commands_only(plan), plan.trim_end());
    }

    /// The order that closes the sharper half: a substitution on a commented line is never run.
    ///
    /// The command would create the file if it ever reached `sh -c`, so the assertion is about the
    /// filesystem rather than about the returned string — a plan that merely LOOKS empty would pass
    /// a string comparison while the side effect had already happened. It goes through [`plan`],
    /// which is the composition `dry_run` uses, so a reordering there has to break this test.
    #[test]
    fn a_backtick_on_a_commented_line_is_never_executed() {
        let witness = std::env::temp_dir().join("slopdesk-reach-commented-backtick");
        let _ = std::fs::remove_file(&witness);
        let raw = format!("# echo `touch {} && echo ran`\n", witness.display());
        let expanded = plan(&raw, Path::new("/"));
        assert!(expanded.trim().is_empty(), "{expanded}");
        assert!(!witness.exists(), "the gate ran a command the recipe would not");

        // And the live half still expands, so the assertion above is not passing because `plan`
        // stopped substituting altogether.
        assert_eq!(plan("echo `printf x`\n", Path::new("/")), "echo x");
    }

    /// The whole reason this module still answers the question it did under make: a dry run hands
    /// back the SUBSTITUTION, and the crate paths only exist once it has been run.
    #[test]
    fn a_substitution_is_run_and_spliced_where_it_stood() {
        let plan = expand_backticks(
            "for ws in rust `printf 'rust/a\\nrust/b\\n'`; do cd $ws; done",
            Path::new("/"),
        );
        assert_eq!(plan, "for ws in rust rust/a rust/b; do cd $ws; done");
        assert!(plan_enters(&plan, "a"));
        assert!(plan_enters(&plan, "b"));
    }

    /// A plan with nothing to substitute comes back byte for byte, and an unpaired backtick — which
    /// is text, not a substitution — never swallows the rest of the plan.
    #[test]
    fn a_plan_without_a_pair_is_untouched() {
        let plain = "cd rust/slopdesk-wire && cargo test";
        assert_eq!(expand_backticks(plain, Path::new("/")), plain);
        let odd = "echo `printf x` and a lone ` here";
        assert_eq!(expand_backticks(odd, Path::new("/")), "echo x and a lone ` here");
    }

    /// A crate name that is a PREFIX of another does not satisfy the longer one's question.
    #[test]
    fn a_prefix_is_not_a_crate() {
        let plan = "cd rust/slopdesk-videoclient && cargo clippy\n";
        assert!(plan_enters(plan, "slopdesk-videoclient"));
        assert!(!plan_enters(plan, "slopdesk-video"));
    }

    #[test]
    fn a_plan_that_enters_the_directory_counts() {
        let plan = "cd rust/slopdesk-superd && cargo fmt --all\ncd rust/slopdesk-screend; cargo fmt\n";
        assert!(plan_enters(plan, "slopdesk-superd"));
        assert!(plan_enters(plan, "slopdesk-screend"));
        assert!(!plan_enters(plan, "slopdesk-dropd"));
    }

    /// Both shapes the justfile writes, and neither satisfied by a longer name.
    #[test]
    fn a_suite_runs_in_either_shape() {
        assert!(runs_tests_for(
            "cd rust/slopdesk-agent && cargo test --quiet",
            "slopdesk-agent"
        ));
        assert!(runs_tests_for(
            "cargo test -p slopdesk-agent --quiet",
            "slopdesk-agent"
        ));
        assert!(!runs_tests_for(
            "cargo test -p slopdesk-agenthooks",
            "slopdesk-agent"
        ));
        assert!(!runs_tests_for(
            "cd rust/slopdesk-agenthooks && cargo test",
            "slopdesk-agent"
        ));
    }
}
