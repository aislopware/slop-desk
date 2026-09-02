//! Every git hook stage `.pre-commit-config.yaml` DECLARES is installed in this clone.
//!
//! ## The failure this exists to make loud
//! `prek install` writes one file per entry in `default_install_hook_types`, and it writes them
//! ONCE — at the moment it is typed. Adding a stage to that list later changes the config and
//! nothing else: the clone keeps the hooks it was given, git keeps calling only those, and the new
//! stage's hooks never run. Nothing is red, nothing is missing from the tree, and every gate that
//! reads the tree agrees the config is correct — because it is. The defect is entirely in the gap
//! between the config and the clone.
//!
//! That is not hypothetical. `commit-msg` was added to the list on 2026-08-11 by `b52e5175`, the
//! commit that also added the `commit-msg-conventional` hook. The clone's hooks had been installed
//! on 2026-06-14 and were never reinstalled, so the subject rule shipped dead: over the 658 commits
//! between that day and 2026-08-31, 97 subjects violated the rule the repo says it enforces — 58
//! past the 72-character ceiling, 39 opening on an article. None of them was rejected, because
//! nothing was asking.
//!
//! ## Why this is a GATE and not a `slopdesk-invariants` rule
//! Every rule in that crate is a pure function of the tree, and the tree is exactly the half that
//! is already correct here. The answer lives in `.git/`, which is not tracked, differs per clone,
//! and can be moved by `core.hooksPath` or by being a worktree — so the question is "what would git
//! RUN", the same shape as [`super::reach`]'s "what would a recipe run". It is on `lint-reach` for
//! that reason.
//!
//! ## The one thing this gate must not do
//! Reach the tree only through a hook. In the state it detects, the hooks are the thing that is not
//! installed, so a gate that ran only from `pre-push` would be silent precisely when it matters.
//! `just check` and `just quick` both reach `lint-reach` by hand, which is the path that survives.

use std::path::{Path, PathBuf};

use crate::proc;

/// The config `prek` reads, and the only place a stage is declared.
const CONFIG: &str = ".pre-commit-config.yaml";

/// The key whose value is the set of hooks `prek install` writes.
const KEY: &str = "default_install_hook_types:";

/// What `prek` installs when the key is absent — its own documented default, and NOT the empty set.
///
/// The distinction is the whole point of pinning it: reading an absent key as "nothing is declared"
/// would make a config that never mentions the key pass vacuously, which is the same silence this
/// gate exists to break.
const IMPLIED: &[&str] = &["pre-commit"];

/// The stages `.pre-commit-config.yaml` declares, in the order it lists them.
///
/// Read line-wise rather than through a YAML crate, the way every other reader in this tree is:
/// the value is a flow sequence on one line, and a parser would be a dependency for one `split`.
/// A commented key is not a declaration — `prek` would not read it either — so the `#` is tested
/// before anything else.
#[must_use]
pub fn declared_stages(config: &str) -> Vec<String> {
    for line in config.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with('#') {
            continue;
        }
        let Some(value) = trimmed.strip_prefix(KEY) else {
            continue;
        };
        let value = value.trim();
        let inner = value.strip_prefix('[').and_then(|rest| rest.strip_suffix(']'));
        let Some(inner) = inner else {
            // A block sequence rather than a flow one. Reading it would mean tracking indentation
            // for a shape this config has never used, and guessing is worse than saying so — the
            // caller reports it rather than accepting an empty list.
            return Vec::new();
        };
        return inner
            .split(',')
            .map(|stage| stage.trim().trim_matches(['"', '\'']).to_owned())
            .filter(|stage| !stage.is_empty())
            .collect();
    }
    IMPLIED.iter().map(|stage| (*stage).to_owned()).collect()
}

/// The declared stages with no installed hook file, in declaration order.
#[must_use]
pub fn missing<'a>(declared: &'a [String], installed: &[String]) -> Vec<&'a String> {
    declared
        .iter()
        .filter(|stage| !installed.iter().any(|present| present == *stage))
        .collect()
}

/// Where git would look for this clone's hooks.
///
/// `core.hooksPath` wins when it is set — git consults nothing else once it is — and only when it
/// is unset does the answer come from `--git-path hooks`, which is also what makes this correct
/// inside a worktree, where `.git` is a FILE and the hooks live in the parent's gitdir.
fn hooks_directory(root: &Path) -> Option<PathBuf> {
    if let Some(configured) = proc::ask("git", &["config", "core.hooksPath"], root)
        && !configured.trim().is_empty()
    {
        let path = PathBuf::from(configured.trim());
        return Some(if path.is_absolute() { path } else { root.join(path) });
    }
    let path = proc::ask("git", &["rev-parse", "--git-path", "hooks"], root)?;
    let path = PathBuf::from(path.trim());
    Some(if path.is_absolute() { path } else { root.join(path) })
}

/// The hook files present in `directory`, by the stage name git calls each one.
fn installed_hooks(directory: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut found: Vec<String> = entries
        .filter_map(Result::ok)
        .filter(|entry| entry.path().is_file())
        .filter_map(|entry| entry.file_name().into_string().ok())
        // git ships every hook twice over as `<name>.sample` and runs none of them.
        .filter(|name| !name.ends_with(".sample"))
        .collect();
    found.sort_unstable();
    found
}

/// Check that every declared stage is installed.
///
/// # Errors
/// One message naming every missing stage and the command that fixes all of them at once, because
/// `prek install` is idempotent and there is never a reason to install one stage alone.
#[expect(clippy::print_stdout, reason = "the hook census is this gate's report")]
pub fn run(root: &Path) -> Result<(), String> {
    let config_path = root.join(CONFIG);
    let config = std::fs::read_to_string(&config_path)
        .map_err(|error| format!("check-hooks: FAIL — {CONFIG} is not readable: {error}"))?;

    let declared = declared_stages(&config);
    if declared.is_empty() {
        return Err(format!(
            "check-hooks: FAIL — {CONFIG} declares `{KEY}` in a shape this gate cannot read (a block \
             sequence rather than a `[a, b]` list). Write it inline, or teach this gate the other shape — \
             an unreadable declaration must not pass as an empty one"
        ));
    }

    let Some(directory) = hooks_directory(root) else {
        // Not a git checkout at all — an export, a vendored copy. There is nothing to install into
        // and nothing to be wrong about.
        println!("check-hooks: not a git checkout — no hooks to install");
        return Ok(());
    };

    let installed = installed_hooks(&directory);
    let absent = missing(&declared, &installed);
    if absent.is_empty() {
        let count = declared.len();
        println!(
            "check-hooks: all {count} declared hook stages are installed in {}",
            directory.display()
        );
        return Ok(());
    }

    let names: Vec<&str> = absent.iter().map(|stage| stage.as_str()).collect();
    let names = names.join(", ");
    Err(format!(
        "check-hooks: FAIL — {CONFIG} declares the hook stage(s) `{names}`, and {} holds no file for them. \
         `prek install` writes these files ONCE, when it is typed: adding a stage to `{KEY}` later changes \
         the config and not the clone, so every hook on the new stage is dead and nothing says so. Run \
         `prek install` — it is idempotent and rewrites all of them",
        directory.display()
    ))
}

#[cfg(test)]
mod tests {
    use super::{declared_stages, missing};

    fn owned(stages: &[&str]) -> Vec<String> {
        stages.iter().map(|stage| (*stage).to_owned()).collect()
    }

    #[test]
    fn the_flow_sequence_this_config_writes_is_read_in_order() {
        let config = "minimum_pre_commit_version: \"3.5.0\"\ndefault_install_hook_types: [pre-commit, \
                      commit-msg, pre-push]\ndefault_stages: [pre-commit]\n";
        assert_eq!(
            declared_stages(config),
            owned(&["pre-commit", "commit-msg", "pre-push"])
        );
    }

    /// Quoting is a taste, not a different declaration.
    #[test]
    fn quoted_entries_are_the_same_stages() {
        let config = "default_install_hook_types: [ \"pre-commit\" , 'commit-msg' ]\n";
        assert_eq!(declared_stages(config), owned(&["pre-commit", "commit-msg"]));
    }

    /// An ABSENT key is prek's documented default, not the empty set — an empty set would make a
    /// config that never names the key pass vacuously.
    #[test]
    fn an_absent_key_reads_as_preks_own_default() {
        assert_eq!(declared_stages("repos: []\n"), owned(&["pre-commit"]));
    }

    /// A commented key is not a declaration, and the live one below it still is.
    #[test]
    fn a_commented_key_is_not_a_declaration() {
        let config = "# default_install_hook_types: [pre-commit, commit-msg, \
                      pre-push]\ndefault_install_hook_types: [pre-commit]\n";
        assert_eq!(declared_stages(config), owned(&["pre-commit"]));
    }

    /// A block sequence comes back EMPTY, which `run` reports rather than accepting.
    #[test]
    fn a_block_sequence_is_not_silently_read_as_nothing_declared() {
        let config = "default_install_hook_types:\n  - pre-commit\n  - commit-msg\n";
        assert!(declared_stages(config).is_empty());
    }

    /// The break-test: the exact state this clone was in — `commit-msg` declared on 2026-08-11,
    /// installed never.
    #[test]
    fn a_declared_stage_with_no_file_is_caught() {
        let declared = owned(&["pre-commit", "commit-msg", "pre-push"]);
        let installed = owned(&["pre-commit", "pre-push"]);
        assert!(
            missing(&declared, &owned(&["pre-commit", "commit-msg", "pre-push"])).is_empty(),
            "the fixture must start clean, or this proves nothing"
        );
        let absent = missing(&declared, &installed);
        assert_eq!(absent, vec![&"commit-msg".to_owned()]);
    }

    /// An EXTRA installed hook is not this gate's business: a hand-written hook nobody declared is
    /// a choice, and demanding its removal would be a rule about someone's own clone.
    #[test]
    fn an_undeclared_installed_hook_is_left_alone() {
        let declared = owned(&["pre-commit"]);
        let installed = owned(&["post-checkout", "pre-commit", "prepare-commit-msg"]);
        assert!(missing(&declared, &installed).is_empty());
    }
}
