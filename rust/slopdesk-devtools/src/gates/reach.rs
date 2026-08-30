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

use std::fs;
use std::path::Path;

use crate::proc;

/// The recipes that must reach every workspace crate, and what each one would leave unchecked.
///
/// Three, not one, because a crate present in one and missing from another has an unchecked half.
const REACHING: [&str; 4] = ["fmt-rust", "lint-rust", "lint-rust-clippy", "test-rust"];

/// What one recipe would run, with every command substitution performed.
///
/// `None` when `just` refused the recipe at all, which every caller reads as "no plan" and reports
/// rather than accepting.
fn dry_run(root: &Path, recipe: &str) -> String {
    let raw = proc::ask_err("just", &["--dry-run", recipe], root).unwrap_or_default();
    expand_backticks(&raw, root)
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
    } else if !check_plan.contains("cargo +nightly miri test") {
        failures.push(
            "'just check' does not reach 'just miri' — the differential suite is what pays for \
             rust/slopdesk-gfsimd's unsafe, and an obligation no recipe reaches is a sentence in a document \
             (CLAUDE.md, docs/DECISIONS.md)"
                .to_owned(),
        );
    }

    if failures.is_empty() {
        println!("check-reach: every workspace crate is formatted, linted and tested by a just recipe");
        Ok(())
    } else {
        Err(failures
            .iter()
            .map(|why| format!("check-reach: FAIL — {why}"))
            .collect::<Vec<_>>()
            .join("\n"))
    }
}

/// True when a dry-run plan would enter `crate_name`'s directory.
///
/// The boundary matters: `rust/slopdesk-video` must not be satisfied by a plan that only names
/// `rust/slopdesk-videoclient`.
#[must_use]
pub fn plan_enters(plan: &str, crate_name: &str) -> bool {
    let needle = format!("rust/{crate_name}");
    plan.match_indices(&needle).any(|(index, _)| {
        let after = plan[index + needle.len()..].chars().next();
        matches!(after, None | Some(' ' | ';' | '\n'))
    })
}

/// True when a `cargo test` plan would run `crate_name`'s suite, in either of the two shapes the
/// justfile writes.
#[must_use]
pub fn runs_tests_for(test_plan: &str, crate_name: &str) -> bool {
    if test_plan.contains(&format!("cd rust/{crate_name} &&")) {
        return true;
    }
    let needle = format!("cargo test -p {crate_name}");
    test_plan.match_indices(&needle).any(|(index, _)| {
        let after = test_plan[index + needle.len()..].chars().next();
        matches!(after, None | Some(' ' | '\n'))
    })
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
    use std::path::Path;

    use super::{expand_backticks, plan_enters, runs_tests_for};

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
