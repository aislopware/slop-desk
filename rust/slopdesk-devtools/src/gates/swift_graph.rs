//! The `SwiftPM` dependency graph, and the attribution of a change set to test targets.
//!
//! `swift package describe --type json` is the only description of this package that is not
//! `Package.swift` itself, and reading it is what lets the inner loop run three test targets
//! instead of twenty-six. The selection used to be a `python3 -c` heredoc inside a `$( … )`, which
//! meant the one part with real logic in it — which paths escalate, which reach nothing, which
//! reach everything — could only be exercised by running a build and watching what happened.
//!
//! ## Fail toward SLOW, never toward green
//! Every uncertainty in here resolves to the full suite: a path under `Sources/` or `Tests/` that
//! belongs to no target, a change to the graph itself, a change to the golden corpus. A selection
//! that guessed low would be a gate reporting green over tests it never ran, which is worse than a
//! gate that is sometimes slow.
//!
//! ## The two edges the graph cannot see
//! A dependency graph knows about imports. It does not know that `SubprocessE2ETests` SPAWNS the
//! built `slopdesk-hostd` and `slopdesk-client` binaries, nor that `LaunchRestoreGateContractTests`
//! OPENS `scripts/fixtures/*.json` off disk at run time. Both are hand-mapped in [`attribute`], and
//! a new test that spawns a binary or reads a repo path outside its own target directory must add
//! its edge there or go silently unselected.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

/// The suite that reads `scripts/` off disk at run time.
///
/// It was TWO, and both read gate SCRIPTS as text — the only way to pin a contract a shell script
/// carries. The four GUI gates are Rust now, so those contracts are `cargo test`s where they
/// belong, and what is left here is the half Rust cannot check: that `scripts/fixtures/*.json`
/// still decodes through the shipping Swift types the gate will hand it to.
///
/// Naming a target that no longer exists would make a scripts-only edit attribute to NOTHING and
/// run clean, which is why this is a constant and not a literal at the call site.
const SCRIPT_READERS: &[&str] = &["SlopDeskWorkspaceCoreTests"];

/// The two products `SubprocessE2ETests` spawns, and the suite that spawns them.
const SPAWNED: &[&str] = &["slopdesk-hostd", "slopdesk-client"];

/// The suite that spawns them.
const SPAWNER: &str = "SlopDeskClientTests";

/// What the change set selects.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Selection {
    /// Something the attribution cannot bound — run everything.
    Full,
    /// These test targets, sorted.
    Targets(Vec<String>),
    /// No `SwiftPM` test target reaches the change set; the incremental build was the gate.
    None,
}

impl Selection {
    /// The one word or the space-joined list, as the gate prints and the `--filter` consumes.
    #[must_use]
    pub fn printed(&self) -> String {
        match self {
            Self::Full => "FULL".to_owned(),
            Self::None => "NONE".to_owned(),
            Self::Targets(names) => names.join(" "),
        }
    }
}

/// One target as the description describes it.
#[derive(Debug, Clone)]
struct Target {
    name: String,
    kind: String,
    path: String,
    dependencies: Vec<String>,
}

/// The package description, reduced to what attribution needs.
#[derive(Debug, Clone)]
pub struct Graph {
    targets: Vec<Target>,
    /// Product name → the targets it vends, for the callers that start from a PRODUCT: an Xcode app
    /// spec names products, never targets.
    products: BTreeMap<String, Vec<String>>,
}

impl Graph {
    /// Read `swift package describe --type json` output.
    ///
    /// # Errors
    /// When the document is not JSON, or carries no `targets` array.
    pub fn parse(json: &str) -> Result<Self, String> {
        let document: Value = serde_json::from_str(json).map_err(|error| format!("describe: {error}"))?;
        let listed = document
            .get("targets")
            .and_then(Value::as_array)
            .ok_or_else(|| "describe: no `targets` array".to_owned())?;
        let targets = listed
            .iter()
            .map(|target| {
                Target {
                    name: string(target, "name"),
                    kind: string(target, "type"),
                    path: string(target, "path"),
                    dependencies: target
                        .get("target_dependencies")
                        .and_then(Value::as_array)
                        .map(|values| {
                            values
                                .iter()
                                .filter_map(|v| v.as_str().map(str::to_owned))
                                .collect()
                        })
                        .unwrap_or_default(),
                }
            })
            .collect();
        let products = document
            .get("products")
            .and_then(Value::as_array)
            .map(|listed| {
                listed
                    .iter()
                    .map(|product| {
                        let targets = product
                            .get("targets")
                            .and_then(Value::as_array)
                            .map(|values| {
                                values
                                    .iter()
                                    .filter_map(|value| value.as_str().map(str::to_owned))
                                    .collect()
                            })
                            .unwrap_or_default();
                        (string(product, "name"), targets)
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(Self { targets, products })
    }

    /// Every source PATH that compiling `products` reaches, transitively.
    ///
    /// A name this package does not vend is SKIPPED rather than fatal: an app spec also names
    /// products of the packages it depends on (`SFSafeSymbols`), whose sources live in
    /// `.build/checkouts` and can never be a path under `Sources/`. A LOCAL product renamed out
    /// from under a spec is not a hole either — `Package.swift` is in the digest that this
    /// scopes, so the rename moves every stamp, and the app it broke fails to build on the next
    /// run.
    ///
    /// `None` when NOTHING resolved, which is a description this cannot read: the caller then falls
    /// back to the whole source tree, because a scope it could not bound must not skip work.
    #[must_use]
    pub fn paths_for_products(&self, products: &[String]) -> Option<Vec<String>> {
        let by_name: BTreeMap<&str, &Target> = self
            .targets
            .iter()
            .map(|target| (target.name.as_str(), target))
            .collect();
        let mut wanted: BTreeSet<String> = BTreeSet::new();
        for product in products {
            let Some(vended) = self.products.get(product) else {
                continue;
            };
            for target in vended {
                wanted.extend(std::iter::once(target.clone()));
                wanted.extend(self.closure(target));
            }
        }
        let mut paths: Vec<String> = wanted
            .iter()
            .filter_map(|name| by_name.get(name.as_str()).map(|target| target.path.clone()))
            .collect();
        paths.sort_unstable();
        paths.dedup();
        if paths.is_empty() { None } else { Some(paths) }
    }

    /// Every test target's name.
    fn tests(&self) -> BTreeSet<String> {
        self.targets
            .iter()
            .filter(|target| target.kind == "test")
            .map(|target| target.name.clone())
            .collect()
    }

    /// Every target a test target transitively depends on.
    fn closure(&self, name: &str) -> BTreeSet<String> {
        let by_name: BTreeMap<&str, &Target> = self
            .targets
            .iter()
            .map(|target| (target.name.as_str(), target))
            .collect();
        let mut seen = BTreeSet::new();
        let mut stack = vec![name.to_owned()];
        while let Some(current) = stack.pop() {
            let Some(target) = by_name.get(current.as_str()) else {
                continue;
            };
            for dependency in &target.dependencies {
                if seen.insert(dependency.clone()) {
                    stack.push(dependency.clone());
                }
            }
        }
        seen
    }

    /// The target owning `path`, LONGEST path first so a nested target wins over its parent.
    fn owner(&self, path: &str) -> Option<&Target> {
        let mut candidates: Vec<&Target> = self.targets.iter().collect();
        candidates.sort_by_key(|target| std::cmp::Reverse(target.path.len()));
        candidates
            .into_iter()
            .find(|target| path.starts_with(&format!("{}/", target.path)))
    }
}

/// Read a string field, or an empty string.
fn string(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

/// Which test targets the changed paths reach.
///
/// `picked == every test target` collapses to [`Selection::Full`]: running the whole suite through
/// a `--filter` regex naming all of it is slower than running it, and the two are the same run.
#[must_use]
pub fn attribute(graph: &Graph, changed: &[String]) -> Selection {
    let tests = graph.tests();
    let reach: BTreeMap<String, BTreeSet<String>> = tests
        .iter()
        .map(|test| (test.clone(), graph.closure(test)))
        .collect();

    let mut picked: BTreeSet<String> = BTreeSet::new();
    let mut full = false;

    for path in changed {
        if path == "Package.swift" || path == "Package.resolved" || path.starts_with("golden/") {
            full = true;
            continue;
        }
        if path.starts_with("scripts/") {
            picked.extend(SCRIPT_READERS.iter().map(|name| (*name).to_owned()));
            continue;
        }
        let Some(owner) = graph.owner(path) else {
            // A `Sources/`/`Tests/` file that belongs to no target — attribution failed, be safe.
            full = true;
            continue;
        };
        if owner.kind == "test" {
            picked.insert(owner.name.clone());
            continue;
        }
        picked.extend(
            reach
                .iter()
                .filter(|(_, closure)| closure.contains(&owner.name))
                .map(|(test, _)| test.clone()),
        );
        if SPAWNED.contains(&owner.name.as_str()) {
            picked.insert(SPAWNER.to_owned());
        }
    }

    if full || (!tests.is_empty() && picked == tests) {
        Selection::Full
    } else if picked.is_empty() {
        Selection::None
    } else {
        Selection::Targets(picked.into_iter().collect())
    }
}

#[cfg(test)]
mod tests {
    use super::{Graph, Selection, attribute};

    const DESCRIBE: &str = r#"{
      "targets": [
        {"name": "Core", "type": "library", "path": "Sources/Core", "target_dependencies": []},
        {"name": "UI", "type": "library", "path": "Sources/UI", "target_dependencies": ["Core"]},
        {"name": "slopdesk-hostd", "type": "executable", "path": "Sources/slopdesk-hostd",
         "target_dependencies": ["Core"]},
        {"name": "CoreTests", "type": "test", "path": "Tests/CoreTests",
         "target_dependencies": ["Core"]},
        {"name": "UITests", "type": "test", "path": "Tests/UITests", "target_dependencies": ["UI"]},
        {"name": "SlopDeskClientTests", "type": "test", "path": "Tests/SlopDeskClientTests",
         "target_dependencies": []},
        {"name": "SlopDeskClientCoreTests", "type": "test", "path": "Tests/SlopDeskClientCoreTests",
         "target_dependencies": []},
        {"name": "SlopDeskWorkspaceCoreTests", "type": "test",
         "path": "Tests/SlopDeskWorkspaceCoreTests", "target_dependencies": []}
      ],
      "products": [
        {"name": "UI", "targets": ["UI"]},
        {"name": "Core", "targets": ["Core"]}
      ]
    }"#;

    fn graph() -> Graph {
        Graph::parse(DESCRIBE).unwrap()
    }

    /// A product's scope is its own path plus everything it links, and NOTHING else — which is what
    /// lets one triple's stamp ignore the other's sources.
    #[test]
    fn a_products_scope_is_its_closure() {
        let paths = graph()
            .paths_for_products(&["UI".to_owned()])
            .expect("UI is a product");
        assert_eq!(paths, ["Sources/Core", "Sources/UI"]);
        assert!(
            !paths.iter().any(|path| path.contains("hostd")),
            "an executable nothing vends is not in a product's closure: {paths:?}"
        );
    }

    /// A name this package does not vend is another package's, and contributes no local path. When
    /// that is ALL there was, the scope refuses to narrow rather than covering nothing.
    #[test]
    fn a_foreign_product_contributes_nothing_and_alone_refuses_to_narrow() {
        assert_eq!(
            graph().paths_for_products(&["UI".to_owned(), "SFSafeSymbols".to_owned()]),
            Some(vec!["Sources/Core".to_owned(), "Sources/UI".to_owned()]),
            "the foreign name is skipped, the local one still scopes"
        );
        assert!(
            graph()
                .paths_for_products(&["SFSafeSymbols".to_owned()])
                .is_none()
        );
    }

    fn select(paths: &[&str]) -> Selection {
        let changed: Vec<String> = paths.iter().map(|path| (*path).to_owned()).collect();
        attribute(&graph(), &changed)
    }

    /// A library edit selects every test whose closure contains it, and nothing else.
    #[test]
    fn a_library_edit_selects_its_dependents() {
        assert_eq!(
            select(&["Sources/UI/View.swift"]),
            Selection::Targets(vec!["UITests".to_owned()])
        );
        assert_eq!(
            select(&["Sources/Core/Model.swift"]),
            Selection::Targets(vec!["CoreTests".to_owned(), "UITests".to_owned()])
        );
    }

    #[test]
    fn a_test_edit_selects_only_that_suite() {
        assert_eq!(
            select(&["Tests/CoreTests/ModelTests.swift"]),
            Selection::Targets(vec!["CoreTests".to_owned()])
        );
    }

    /// The graph cannot see a subprocess spawn, so the edge is hand-mapped.
    #[test]
    fn a_spawned_binary_pulls_in_the_suite_that_spawns_it() {
        let picked = select(&["Sources/slopdesk-hostd/main.swift"]);
        let Selection::Targets(names) = picked else {
            panic!("expected targets, got {picked:?}");
        };
        assert!(names.contains(&"SlopDeskClientTests".to_owned()), "{names:?}");
    }

    #[test]
    fn a_scripts_edit_selects_the_suite_that_reads_them() {
        assert_eq!(
            select(&["scripts/fixtures/launch-restore-workspace.json"]),
            Selection::Targets(vec!["SlopDeskWorkspaceCoreTests".to_owned()])
        );
    }

    #[test]
    fn the_graph_itself_and_the_corpus_escalate() {
        assert_eq!(select(&["Package.swift"]), Selection::Full);
        assert_eq!(select(&["Package.resolved"]), Selection::Full);
        assert_eq!(select(&["golden/golden_vectors.json"]), Selection::Full);
    }

    /// The failure this exists to avoid: an unattributable source path running clean.
    #[test]
    fn a_path_belonging_to_no_target_escalates() {
        assert_eq!(select(&["Sources/Orphan/Thing.swift"]), Selection::Full);
    }

    /// An empty change set is the only way to reach NONE: every path that gets this far came
    /// through the caller's pathspec, and one that came through and attributes to nothing is the
    /// escalation above, not a pass.
    #[test]
    fn an_empty_change_set_selects_nothing() {
        assert_eq!(select(&[]), Selection::None);
    }

    /// Selecting everything IS the full suite; a `--filter` naming all of it is only slower.
    #[test]
    fn selecting_every_suite_collapses_to_full() {
        assert_eq!(
            select(&[
                "Sources/Core/Model.swift",
                "Tests/SlopDeskClientTests/A.swift",
                "Tests/SlopDeskClientCoreTests/A.swift",
                "scripts/fixtures/launch-restore-workspace.json",
            ]),
            Selection::Full
        );
    }

    #[test]
    fn a_nested_target_wins_over_its_parent() {
        let json = r#"{"targets": [
          {"name": "Outer", "type": "library", "path": "Sources", "target_dependencies": []},
          {"name": "Inner", "type": "library", "path": "Sources/Inner", "target_dependencies": []},
          {"name": "InnerTests", "type": "test", "path": "Tests/InnerTests",
           "target_dependencies": ["Inner"]},
          {"name": "OuterTests", "type": "test", "path": "Tests/OuterTests",
           "target_dependencies": ["Outer"]}
        ]}"#;
        let graph = Graph::parse(json).unwrap();
        assert_eq!(
            attribute(&graph, &["Sources/Inner/Thing.swift".to_owned()]),
            Selection::Targets(vec!["InnerTests".to_owned()])
        );
    }

    #[test]
    fn the_printed_form_is_what_the_filter_consumes() {
        assert_eq!(Selection::Full.printed(), "FULL");
        assert_eq!(Selection::None.printed(), "NONE");
        assert_eq!(
            Selection::Targets(vec!["A".to_owned(), "B".to_owned()]).printed(),
            "A B"
        );
    }
}
