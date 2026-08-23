//! Re-sync `rust/slopdesk-screend/manifests/*.toml` from a herdr checkout.
//!
//! screend carries herdr's bundled agent-detection manifests VERBATIM, as the TOML files they
//! already are — `include_str!`d into the binary by `src/detect.rs`, so the daemon has no resource
//! bundle and no deployment surface. This is the only sanctioned writer: it copies
//! `src/detect/manifests/*.toml` across under the label each manifest is addressed by, so an
//! upstream sync is `slopdesk-herdr manifests && git diff` instead of hand-pasting.
//!
//! (It used to GENERATE a Swift file of raw-string literals, because the rule ladder was in Swift
//! and TOML had to become source. The ladder moved to screend — `docs/52-screen-engine.md` — and
//! the manifests went back to being files.)

use std::fs;
use std::path::Path;

/// (upstream manifest filename stem, the agent LABEL we file it under).
///
/// The two differ for exactly the agents whose canonical label is not their upstream filename;
/// everything else is the identity. Order is herdr's bundled-manifest ordering.
pub const AGENTS: [(&str, &str); 19] = [
    ("pi", "pi"),
    ("claude", "claude"),
    ("codex", "codex"),
    ("gemini", "gemini"),
    ("cursor", "cursor"),
    ("devin", "devin"),
    ("antigravity", "agy"),
    ("cline", "cline"),
    ("opencode", "opencode"),
    ("github-copilot", "copilot"),
    ("kimi", "kimi"),
    ("kiro", "kiro"),
    ("droid", "droid"),
    ("amp", "amp"),
    ("grok", "grok"),
    ("hermes", "hermes"),
    ("kilo", "kilo"),
    ("qodercli", "qodercli"),
    ("maki", "maki"),
];

/// The in-file mark a deliberately-improved manifest carries.
///
/// Keyed on the FILE rather than on a list here, so the reason and the exemption cannot drift
/// apart: the comment that earns the exemption is the one a reader finds at the rule.
const DIVERGENCE_MARKER: &str = "DIVERGES FROM herdr";

/// Where the checked-in copies live, relative to the tree root.
pub const OUTPUT_DIR: &str = "rust/slopdesk-screend/manifests";

/// What a sync did, separated from how it says so.
#[derive(Debug, Default)]
pub struct Outcome {
    /// Lines for the operator, in order.
    pub notes: Vec<String>,
    /// True when a checked-in manifest differs from upstream and `--check` refused to write it.
    pub drift: bool,
}

/// Copy every upstream manifest across, or report which ones would change.
///
/// # Errors
/// When the checkout is missing manifests, when the manifest SET has drifted from `AGENTS`, or
/// when a file cannot be read or written.
pub fn sync(repo_root: &Path, herdr_dir: &Path, check_only: bool) -> Result<Outcome, String> {
    let manifests_dir = herdr_dir.join("src/detect/manifests");
    let output_dir = repo_root.join(OUTPUT_DIR);

    let mut on_disk: Vec<String> = fs::read_dir(&manifests_dir)
        .map_err(|error| format!("cannot read {}: {error}", manifests_dir.display()))?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "toml"))
        .filter_map(|path| path.file_stem().map(|stem| stem.to_string_lossy().into_owned()))
        .collect();
    on_disk.sort();
    let mut expected: Vec<String> = AGENTS.iter().map(|(stem, _)| (*stem).to_owned()).collect();
    expected.sort();
    if on_disk != expected {
        let extra = difference(&on_disk, &expected);
        let missing = difference(&expected, &on_disk);
        return Err(format!(
            "manifest set drift vs upstream — update AGENTS in `src/manifests.rs`, `BUNDLED` \
             +\n`KNOWN_AGENTS` in rust/slopdesk-screend/src/detect.rs, AND AgentKind:\n  new upstream \
             manifests: {extra}\n  removed upstream manifests: {missing}"
        ));
    }

    let mut drifted: Vec<&str> = Vec::new();
    let mut diverged: Vec<(&str, &str)> = Vec::new();
    for (stem, label) in AGENTS {
        let upstream_path = manifests_dir.join(format!("{stem}.toml"));
        let upstream = fs::read_to_string(&upstream_path)
            .map_err(|error| format!("cannot read {}: {error}", upstream_path.display()))?;
        let target = output_dir.join(format!("{label}.toml"));
        let current = fs::read_to_string(&target).unwrap_or_default();
        if current == upstream {
            continue;
        }
        // A manifest we deliberately made BETTER than upstream is never overwritten. `herdr-sync`
        // runs this writer unattended, and a blind copy would silently delete the divergence —
        // after which the differential would report perfect parity, because both engines would
        // again be running upstream's rule. Merge those by hand (`DIVERGED_RULES` in
        // `src/differential.rs` names them, and the manifest itself says why, inline).
        if current.contains(DIVERGENCE_MARKER) {
            diverged.push((stem, label));
            continue;
        }
        drifted.push(label);
        if !check_only {
            fs::write(&target, &upstream)
                .map_err(|error| format!("cannot write {}: {error}", target.display()))?;
        }
    }

    let mut outcome = Outcome::default();
    for (stem, label) in diverged {
        let upstream_path = manifests_dir.join(format!("{stem}.toml"));
        let ours = output_dir.join(format!("{label}.toml"));
        outcome.notes.push(format!(
            "HELD: {OUTPUT_DIR}/{label}.toml carries a deliberate divergence — not overwritten.\n      \
             Re-apply upstream by hand: diff -u {} {}",
            upstream_path.display(),
            ours.display()
        ));
    }
    if drifted.is_empty() {
        outcome.notes.push(format!(
            "OK: {OUTPUT_DIR}/ is in sync with {}",
            herdr_dir.display()
        ));
        return Ok(outcome);
    }
    let named = drifted.join(", ");
    if check_only {
        outcome.drift = true;
        outcome
            .notes
            .push(format!("DRIFT: {OUTPUT_DIR}/ differs from upstream — {named}"));
    } else {
        outcome.notes.push(format!(
            "wrote {} manifest(s) under {OUTPUT_DIR}/: {named}",
            drifted.len()
        ));
    }
    Ok(outcome)
}

/// What is in `mine` and not in `yours`, rendered the way the drift message reads it.
fn difference(mine: &[String], yours: &[String]) -> String {
    let only: Vec<&str> = mine
        .iter()
        .filter(|name| !yours.contains(name))
        .map(String::as_str)
        .collect();
    if only.is_empty() {
        "none".to_owned()
    } else {
        format!("[{}]", only.join(", "))
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};

    use super::{AGENTS, OUTPUT_DIR, sync};

    /// A throwaway pair of trees: a fake herdr checkout and a fake repo root.
    struct Trees {
        root: PathBuf,
    }

    impl Trees {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!("slopdesk-manifests-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(root.join("herdr/src/detect/manifests")).expect("fixture dirs");
            fs::create_dir_all(root.join("repo").join(OUTPUT_DIR)).expect("fixture dirs");
            let trees = Self { root };
            for (stem, label) in AGENTS {
                trees.upstream(stem, "body\n");
                trees.ours(label, "body\n");
            }
            trees
        }

        fn upstream(&self, stem: &str, body: &str) {
            fs::write(
                self.root
                    .join("herdr/src/detect/manifests")
                    .join(format!("{stem}.toml")),
                body,
            )
            .expect("write upstream");
        }

        fn ours(&self, label: &str, body: &str) {
            fs::write(
                self.root
                    .join("repo")
                    .join(OUTPUT_DIR)
                    .join(format!("{label}.toml")),
                body,
            )
            .expect("write ours");
        }

        fn read_ours(&self, label: &str) -> String {
            fs::read_to_string(
                self.root
                    .join("repo")
                    .join(OUTPUT_DIR)
                    .join(format!("{label}.toml")),
            )
            .expect("read ours")
        }

        fn run(&self, check_only: bool) -> Result<super::Outcome, String> {
            sync(&self.root.join("repo"), &self.root.join("herdr"), check_only)
        }
    }

    impl Drop for Trees {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn an_in_sync_tree_writes_nothing() {
        let trees = Trees::new("in-sync");
        let outcome = trees.run(false).expect("sync");
        assert!(!outcome.drift);
        assert!(outcome.notes.iter().any(|note| note.starts_with("OK: ")));
    }

    #[test]
    fn upstream_drift_is_copied_across_under_the_label() {
        let trees = Trees::new("drift");
        trees.upstream("antigravity", "new upstream\n");
        let checked = trees.run(true).expect("check");
        assert!(checked.drift, "--check must refuse a drifted tree");
        assert_eq!(trees.read_ours("agy"), "body\n", "--check must not write");

        let written = trees.run(false).expect("sync");
        assert!(!written.drift);
        // Filed under the LABEL, not the upstream stem — the whole point of the AGENTS table.
        assert_eq!(trees.read_ours("agy"), "new upstream\n");
        assert!(!Path::new(&trees.root.join("repo").join(OUTPUT_DIR).join("antigravity.toml")).exists());
    }

    /// The failure the writer exists to prevent: an unattended run deleting a deliberate edit.
    #[test]
    fn a_deliberate_divergence_is_held() {
        let trees = Trees::new("held");
        trees.upstream("claude", "upstream rule\n");
        trees.ours(
            "claude",
            "# DIVERGES FROM herdr: ours vetoes on the footer\nours\n",
        );
        let outcome = trees.run(false).expect("sync");
        assert!(
            trees.read_ours("claude").contains("ours"),
            "held file was overwritten"
        );
        assert!(outcome.notes.iter().any(|note| note.starts_with("HELD: ")));
        // Held is not drift: nothing else changed, so the run is clean.
        assert!(!outcome.drift);
    }

    #[test]
    fn a_new_upstream_manifest_stops_the_sync() {
        let trees = Trees::new("set-drift");
        trees.upstream("brand-new-agent", "body\n");
        let error = trees.run(false).expect_err("set drift must fail");
        assert!(error.contains("brand-new-agent"), "{error}");
        assert!(
            error.contains("AgentKind"),
            "the fix names all three sites: {error}"
        );
    }
}
