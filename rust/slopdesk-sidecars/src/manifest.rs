//! What an upgrade changed, tool by tool, from two `MANIFEST.json` files and no processes at all.
//!
//! ## Why files and not a process tree
//! The runtime audit next door ([`crate::Report`]) asks a live daemon what it is running. That is
//! the right question at hostd's start and the wrong one at install time: `brew upgrade` runs while
//! the daemons are still serving the OLD binaries, so every one of them would read "stale" and the
//! answer would be identical whether one tool changed or ten.
//!
//! The question an install can actually answer is about FILES: the manifest that just landed, and
//! the one recorded after the previous install. Their difference is exactly the set of tools this
//! upgrade touched, and it is known before anything is restarted, dialled or even started.
//!
//! ## The version is the identity, not the SHA
//! `slopdesk-release package` signs every binary with `--timestamp`, so an unchanged tool rebuilt
//! and re-signed has different bytes every single time. Diffing `sha256` across two releases would
//! report every tool as changed, forever, which is the behaviour this whole mechanism exists to
//! end. So the diff is on `version`, which only moves when `slopdesk-release stamps` says the
//! tool's source closure moved — and `sha256` stays what its name says in
//! `scripts/tool-stamps.pin`: integrity for the file that shipped, not identity across releases.

use std::collections::{BTreeMap, BTreeSet};

use crate::{RestartPolicy, launch_agent_label, policy};

/// What to tell a user about a changed tool only they may restart.
///
/// The launchd label is looked UP, never derived from the tool's name. Only two of the twelve are
/// launch agents, and a line telling someone to kickstart a job launchd has never heard of is worse
/// than no line: they will run it, see no error, and believe it worked.
fn operator_note(tool: &str) -> String {
    if let Some(label) = launch_agent_label(tool) {
        return format!(
            "restart it when convenient: `launchctl kickstart -k gui/$UID/{label}` — it will take every \
             live pane"
        );
    }
    if tool == "slopdesk-hostd" {
        // The sentence that joins the two halves of this mechanism: the install side reports, and
        // hostd's own audit is what actually restarts the three daemons it owns (`crate::Report`).
        return "restart its launch agent when convenient (`just host-restart` in a checkout); its own \
                audit then restarts the sidecars it owns"
            .to_owned();
    }
    "restart it when convenient".to_owned()
}

/// One binary as `MANIFEST.json` describes it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Tool {
    /// The binary's name, which is also [`policy`]'s key.
    pub name: String,
    /// Its OWN version — the crate's for a cargo tool, the product's for the `SwiftPM` pair.
    pub version: String,
}

/// A release's `MANIFEST.json`, reduced to the two fields a diff needs.
///
/// `sha256` and `stamp` are deliberately dropped on the way in. They are real fields with real
/// jobs — integrity, and the evidence that let a version move — but neither is an input to "what
/// changed", and a struct that carries them invites the SHA comparison the module doc rules out.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Manifest {
    /// The product version this release shipped under.
    pub product: String,
    /// Every binary in the tarball, in the order the manifest lists them.
    pub tools: Vec<Tool>,
}

/// Why a manifest would not parse.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ManifestError {
    /// The bytes are not JSON.
    NotJson(String),
    /// The JSON is well-formed but is not a manifest: no `tools` array, or an entry missing its
    /// `name` or `version`. Named separately from [`ManifestError::NotJson`] because the two have
    /// different causes — a truncated download versus a manifest from a future this build predates.
    NotAManifest(&'static str),
}

impl core::fmt::Display for ManifestError {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match *self {
            Self::NotJson(ref detail) => write!(formatter, "not JSON: {detail}"),
            Self::NotAManifest(detail) => write!(formatter, "not a manifest: {detail}"),
        }
    }
}

impl core::error::Error for ManifestError {}

/// Reads a `MANIFEST.json`.
///
/// Unknown keys are ignored rather than refused, at both levels. A manifest is written by a release
/// and read by an install that may be OLDER than it — someone who upgrades two versions at once
/// reads the newer file with the older reader — so a field added later must not turn a readable
/// manifest into an unreadable one.
///
/// # Errors
/// [`ManifestError`] when the bytes are not JSON, or are JSON that carries no usable `tools` array.
pub fn parse(text: &str) -> Result<Manifest, ManifestError> {
    let value: serde_json::Value =
        serde_json::from_str(text).map_err(|error| ManifestError::NotJson(error.to_string()))?;
    let product = value
        .get("product")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let entries = value
        .get("tools")
        .and_then(serde_json::Value::as_array)
        .ok_or(ManifestError::NotAManifest("no `tools` array"))?;

    let mut tools = Vec::with_capacity(entries.len());
    for entry in entries {
        let name = entry
            .get("name")
            .and_then(serde_json::Value::as_str)
            .ok_or(ManifestError::NotAManifest("a tool entry has no `name`"))?;
        let version = entry
            .get("version")
            .and_then(serde_json::Value::as_str)
            .ok_or(ManifestError::NotAManifest("a tool entry has no `version`"))?;
        tools.push(Tool {
            name: name.to_owned(),
            version: version.to_owned(),
        });
    }
    Ok(Manifest { product, tools })
}

/// What happened to one tool between two releases.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Change {
    /// Same version on both sides. Whatever is running is what is installed, so there is nothing to
    /// do — which is the entire point of shipping a per-tool version.
    Unchanged,
    /// A different version. Not necessarily newer: a downgrade is a change too, and it is the same
    /// restart either way.
    Changed,
    /// In this release and not the previous one. A fresh install reads EVERY tool this way, and so
    /// does a genuinely new daemon — the two are indistinguishable from files alone, and they want
    /// the same non-action, because in both cases nothing of it is running.
    Added,
    /// In the previous release and not this one. The binary is gone; anything still serving from it
    /// is an orphan holding a deleted inode.
    Removed,
}

impl Change {
    /// The name this crosses the FFI door under, and the one the CLI prints.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Unchanged => "unchanged",
            Self::Changed => "changed",
            Self::Added => "added",
            Self::Removed => "removed",
        }
    }
}

/// One tool's line in the upgrade plan.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Step {
    /// The tool's name.
    pub tool: String,
    /// What it was, or `None` when this release added it.
    pub previous: Option<String>,
    /// What it is now, or `None` when this release dropped it.
    pub current: Option<String>,
    /// What happened to it.
    pub change: Change,
    /// What may be done about it, from [`policy`]. Carried even for an unchanged tool, because the
    /// CLI's table has one shape and a column that empties on some rows is a column that is read as
    /// missing rather than as not-applicable.
    pub policy: RestartPolicy,
}

impl Step {
    /// One sentence saying what happens next, in the same voice [`crate::Report::summary`] uses.
    ///
    /// The wording for a CHANGED tool is deliberately about what will happen ON ITS OWN, because on
    /// the install side that is the truth: nothing here ends a daemon. hostd's own audit restarts
    /// the ones it owns the next time it starts, screend retires itself, and superd is the user's
    /// call — so the line says which of those three this is.
    #[must_use]
    pub fn note(&self) -> String {
        match self.change {
            Change::Unchanged => "unchanged; nothing to do".to_owned(),
            Change::Added => "new in this release; nothing of it was running".to_owned(),
            Change::Removed => "no longer shipped; anything still serving from it is an orphan".to_owned(),
            Change::Changed => {
                match self.policy {
                    RestartPolicy::Automatic => "hostd restarts it the next time it starts".to_owned(),
                    RestartPolicy::SelfRetiring => {
                        "it retires itself once idle, and the next verb starts the new one".to_owned()
                    },
                    RestartPolicy::NotResident => {
                        "nothing of it is resident; the next invocation is the new one".to_owned()
                    },
                    RestartPolicy::OperatorChoice => operator_note(&self.tool),
                }
            },
        }
    }
}

/// What an upgrade from `previous` to `current` changed, one line per tool.
///
/// `previous` is `None` on a first install, where every tool reads [`Change::Added`] — which is
/// correct rather than a special case: nothing was running, so nothing needs replacing.
///
/// The order is `current`'s, then whatever `previous` had that `current` does not. A plan whose
/// order shifts between runs is a plan nobody diffs, and the manifest's own order is the tarball's,
/// which is the release binary's tool table — one list, all the way down.
#[must_use]
pub fn plan(previous: Option<&Manifest>, current: &Manifest) -> Vec<Step> {
    let was: BTreeMap<&str, &str> = previous.map_or_else(BTreeMap::new, |manifest| {
        manifest
            .tools
            .iter()
            .map(|tool| (tool.name.as_str(), tool.version.as_str()))
            .collect()
    });

    let mut steps: Vec<Step> = current
        .tools
        .iter()
        .map(|tool| {
            let before = was.get(tool.name.as_str()).map(|&version| version.to_owned());
            let change = match before {
                None => Change::Added,
                Some(ref version) if *version == tool.version => Change::Unchanged,
                Some(_) => Change::Changed,
            };
            Step {
                tool: tool.name.clone(),
                previous: before,
                current: Some(tool.version.clone()),
                change,
                policy: policy(&tool.name),
            }
        })
        .collect();

    let now: BTreeSet<&str> = current.tools.iter().map(|tool| tool.name.as_str()).collect();
    for tool in previous.iter().flat_map(|manifest| &manifest.tools) {
        if !now.contains(tool.name.as_str()) {
            steps.push(Step {
                tool: tool.name.clone(),
                previous: Some(tool.version.clone()),
                current: None,
                change: Change::Removed,
                policy: policy(&tool.name),
            });
        }
    }
    steps
}

/// The plan as the JSON object the FFI door hands to Swift.
#[must_use]
pub fn plan_json(previous: Option<&Manifest>, current: &Manifest) -> String {
    let steps = plan(previous, current);
    let mut root = serde_json::Map::new();
    root.insert(
        "previousProduct".to_owned(),
        previous.map_or(serde_json::Value::Null, |manifest| {
            manifest.product.clone().into()
        }),
    );
    root.insert("product".to_owned(), current.product.clone().into());
    root.insert(
        "changed".to_owned(),
        steps
            .iter()
            .filter(|step| step.change == Change::Changed)
            .count()
            .into(),
    );
    root.insert(
        "tools".to_owned(),
        steps
            .iter()
            .map(|step| {
                let mut object = serde_json::Map::new();
                object.insert("tool".to_owned(), step.tool.clone().into());
                object.insert("change".to_owned(), step.change.name().into());
                object.insert("policy".to_owned(), step.policy.name().into());
                object.insert("note".to_owned(), step.note().into());
                if let Some(ref version) = step.previous {
                    object.insert("previous".to_owned(), version.clone().into());
                }
                if let Some(ref version) = step.current {
                    object.insert("current".to_owned(), version.clone().into());
                }
                serde_json::Value::Object(object)
            })
            .collect::<Vec<_>>()
            .into(),
    );
    serde_json::Value::Object(root).to_string()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::*;

    fn manifest(product: &str, tools: &[(&str, &str)]) -> Manifest {
        Manifest {
            product: product.to_owned(),
            tools: tools
                .iter()
                .map(|&(name, version)| {
                    Tool {
                        name: name.to_owned(),
                        version: version.to_owned(),
                    }
                })
                .collect(),
        }
    }

    /// The shape `slopdesk-release package` writes, verbatim down to the extra fields — the two
    /// this reader ignores are in here on purpose, because ignoring them is the contract.
    const REAL: &str = r#"{
      "product": "0.4.0",
      "arch": "arm64",
      "tools": [
        {"name": "slopdesk", "version": "0.4.0", "sha256": "aa", "stamp": ""},
        {"name": "slopdesk-superd", "version": "0.1.0", "sha256": "bb", "stamp": "d2af"}
      ]
    }"#;

    #[test]
    fn the_manifest_the_release_writes_parses_and_the_unused_fields_are_ignored() {
        let parsed = parse(REAL).expect("the shipped manifest shape parses");
        assert_eq!(parsed.product, "0.4.0");
        assert_eq!(parsed.tools, vec![
            Tool {
                name: "slopdesk".to_owned(),
                version: "0.4.0".to_owned()
            },
            Tool {
                name: "slopdesk-superd".to_owned(),
                version: "0.1.0".to_owned()
            },
        ]);
    }

    /// A field added by a LATER release must not make an older reader refuse the file.
    #[test]
    fn an_unknown_field_is_ignored_rather_than_refused() {
        let parsed = parse(
            r#"{"product":"9.9.9","channel":"beta","tools":[
                 {"name":"slopdesk-dropd","version":"0.3.0","signedBy":"someone"}]}"#,
        )
        .expect("a manifest from the future still parses");
        assert_eq!(parsed.tools.len(), 1);
    }

    #[test]
    fn the_two_ways_a_manifest_can_be_unreadable_are_told_apart() {
        assert!(matches!(parse("not json at all"), Err(ManifestError::NotJson(_))));
        assert_eq!(
            parse(r#"{"product":"0.4.0"}"#),
            Err(ManifestError::NotAManifest("no `tools` array"))
        );
        assert_eq!(
            parse(r#"{"tools":[{"name":"slopdesk-dropd"}]}"#),
            Err(ManifestError::NotAManifest("a tool entry has no `version`"))
        );
    }

    // ── The diff ──────────────────────────────────────────────────────────────────────────

    /// The whole point: one tool moved, and the plan says so about that one and not the others.
    #[test]
    fn only_the_tool_whose_version_moved_reads_as_changed() {
        let before = manifest("0.4.0", &[
            ("slopdesk-superd", "0.1.0"),
            ("slopdesk-dropd", "0.1.0"),
            ("slopdesk-androidd", "0.1.0"),
        ]);
        let after = manifest("0.5.0", &[
            ("slopdesk-superd", "0.1.0"),
            ("slopdesk-dropd", "0.2.0"),
            ("slopdesk-androidd", "0.1.0"),
        ]);
        let steps = plan(Some(&before), &after);
        assert_eq!(steps.iter().map(|step| step.change).collect::<Vec<_>>(), vec![
            Change::Unchanged,
            Change::Changed,
            Change::Unchanged
        ]);
    }

    /// The product version moving on its own changes NOTHING for the daemons — which is the failure
    /// the single product version caused, stated as a test.
    #[test]
    fn a_product_bump_alone_restarts_nothing() {
        let before = manifest("0.4.0", &[("slopdesk-superd", "0.1.0")]);
        let after = manifest("0.5.0", &[("slopdesk-superd", "0.1.0")]);
        let steps = plan(Some(&before), &after);
        assert_eq!(steps[0].change, Change::Unchanged);
        assert!(steps[0].note().contains("nothing to do"), "{}", steps[0].note());
    }

    /// The `SwiftPM` pair DO carry the product version, so they move on every release — and that is
    /// right: they are the program the user just replaced.
    #[test]
    fn the_swiftpm_pair_move_with_the_product() {
        let before = manifest("0.4.0", &[("slopdesk", "0.4.0")]);
        let after = manifest("0.5.0", &[("slopdesk", "0.5.0")]);
        assert_eq!(plan(Some(&before), &after)[0].change, Change::Changed);
    }

    #[test]
    fn a_first_install_adds_everything_and_a_dropped_tool_is_reported() {
        let after = manifest("0.4.0", &[("slopdesk-dropd", "0.1.0")]);
        assert_eq!(plan(None, &after)[0].change, Change::Added);

        let before = manifest("0.4.0", &[
            ("slopdesk-dropd", "0.1.0"),
            ("slopdesk-retired", "0.1.0"),
        ]);
        let steps = plan(Some(&before), &after);
        assert_eq!(steps.len(), 2);
        assert_eq!(steps[1].tool, "slopdesk-retired");
        assert_eq!(steps[1].change, Change::Removed);
        assert_eq!(steps[1].current, None);
    }

    /// A downgrade is a change, for the same reason it is stale next door.
    #[test]
    fn a_downgrade_is_a_change() {
        let before = manifest("0.5.0", &[("slopdesk-dropd", "0.2.0")]);
        let after = manifest("0.4.0", &[("slopdesk-dropd", "0.1.0")]);
        assert_eq!(plan(Some(&before), &after)[0].change, Change::Changed);
    }

    /// The three policies say three different things about the same `changed`, and superd's line
    /// carries the command AND the cost — a line that says only "restart it" gets run blind.
    #[test]
    fn the_note_follows_the_policy_and_superds_names_its_cost() {
        let before = manifest("0.4.0", &[
            ("slopdesk-dropd", "0.1.0"),
            ("slopdesk-screend", "0.1.0"),
            ("slopdesk-superd", "0.1.0"),
        ]);
        let after = manifest("0.5.0", &[
            ("slopdesk-dropd", "0.2.0"),
            ("slopdesk-screend", "0.2.0"),
            ("slopdesk-superd", "0.2.0"),
        ]);
        let steps = plan(Some(&before), &after);
        assert!(
            steps[0].note().contains("hostd restarts it"),
            "{}",
            steps[0].note()
        );
        assert!(steps[1].note().contains("retires itself"), "{}", steps[1].note());
        assert!(
            steps[2].note().contains("com.slopdesk.superd"),
            "{}",
            steps[2].note()
        );
        assert!(steps[2].note().contains("every live pane"), "{}", steps[2].note());
    }

    #[test]
    fn the_json_carries_every_field_the_near_side_decodes() {
        let before = manifest("0.4.0", &[("slopdesk-dropd", "0.1.0")]);
        let after = manifest("0.5.0", &[("slopdesk-dropd", "0.2.0")]);
        let encoded: serde_json::Value =
            serde_json::from_str(&plan_json(Some(&before), &after)).expect("the plan encodes valid JSON");
        assert_eq!(encoded["product"], "0.5.0");
        assert_eq!(encoded["previousProduct"], "0.4.0");
        assert_eq!(encoded["changed"], 1);
        let tool = &encoded["tools"][0];
        assert_eq!(tool["tool"], "slopdesk-dropd");
        assert_eq!(tool["previous"], "0.1.0");
        assert_eq!(tool["current"], "0.2.0");
        assert_eq!(tool["change"], "changed");
        assert_eq!(tool["policy"], "automatic");
        assert!(tool["note"].as_str().is_some_and(|note| note.contains("hostd")));
    }

    /// A first install has no previous product, and the field must be null rather than an empty
    /// string a UI would print as a version.
    #[test]
    fn a_first_install_has_a_null_previous_product() {
        let after = manifest("0.4.0", &[("slopdesk-dropd", "0.1.0")]);
        let encoded: serde_json::Value =
            serde_json::from_str(&plan_json(None, &after)).expect("the plan encodes valid JSON");
        assert!(encoded["previousProduct"].is_null());
        assert!(encoded["tools"][0].get("previous").is_none());
    }
}
