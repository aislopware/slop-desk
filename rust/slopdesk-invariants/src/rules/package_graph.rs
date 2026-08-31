//! What `Package.swift` declares, and what a fresh runner would find missing.
//!
//! Two rules, both about the shape of the graph rather than about any line inside it, and both
//! failing in the direction that reads as health: an undeclared directory is silently ignored, and
//! a binary target nothing builds fails on a machine that has never built this repo — never on the
//! one that is asking.

use std::collections::{BTreeMap, BTreeSet};

use crate::report::Report;
use crate::text;
use crate::tree::Tree;

/// The release workflow, which is what a fresh runner actually executes.
///
/// Outside the tree's walked roots, so it is read through the escape hatch — and its absence is a
/// finding, not a pass.
const RELEASE_WORKFLOW: &str = ".github/workflows/release.yml";

/// Every directory under `Sources/` and `Tests/` has a target in `Package.swift`.
///
/// `SwiftPM` builds the test targets `Package.swift` DECLARES; a directory under `Tests/` that
/// nobody declared is not an error, it is simply ignored — no warning, no empty suite, nothing.
///
/// `Sources/` is the worse half: an undeclared source directory is never COMPILED, yet
/// `swiftformat`/`swiftlint` still walk it, so it keeps passing lint and reads as maintained code
/// while nothing links it.
#[must_use]
pub fn every_source_directory_is_a_target(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(manifest) = report.source(tree, "Package.swift", "it declares every target") else {
        return report;
    };

    let mut undeclared: Vec<String> = Vec::new();
    for root in ["Sources", "Tests"] {
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        for (path, _) in tree.under(root) {
            let Some(name) = path
                .components()
                .nth(1)
                .and_then(|part| part.as_os_str().to_str())
            else {
                continue;
            };
            if !seen.insert(name) {
                continue;
            }
            if !manifest.text.contains(&format!("name: \"{name}\"")) {
                undeclared.push(format!("{root}/{name}/"));
            }
        }
        if seen.is_empty() {
            report.fail(format!(
                "{root}/ holds no directory at all — the check above would accept every missing target"
            ));
        }
    }
    if !undeclared.is_empty() {
        for site in &undeclared {
            eprintln!("{site}");
        }
        report.fail(
            "a directory under Tests/ or Sources/ has no target in Package.swift — SwiftPM ignores it \
             silently",
        );
    }
    report
}

/// Every linked xcframework the graph declares, from both places that declare one.
///
/// `Package.swift` spells its `binaryTarget` path from the repo root; the Xcode specs spell theirs
/// relative to the app directory. Two spellings, one set.
#[must_use]
pub fn linked_artifacts(tree: &Tree) -> BTreeSet<String> {
    let mut found: BTreeSet<String> = BTreeSet::new();
    if let Some(manifest) = tree.get("Package.swift") {
        found.extend(text::capture_set(
            &manifest.text,
            r#"path: "(ThirdParty/[A-Za-z0-9_./-]+\.xcframework)""#,
        ));
    }
    let specs: Vec<String> = tree
        .paths()
        .filter(|path| path.file_name().is_some_and(|name| name == "project.yml"))
        .filter_map(|path| path.to_str().map(str::to_owned))
        .collect();
    for spec in specs {
        let text = tree.read(&spec).unwrap_or_default();
        found.extend(text::capture_set(
            &text,
            r"framework: \.\./\.\./(ThirdParty/[A-Za-z0-9_./-]+\.xcframework)",
        ));
    }
    found
}

/// The recipe a justfile line declares, or `None` for anything else in the file.
///
/// A name at column zero, then `:` or a parameter list before one. The `:=` test is what keeps a
/// VARIABLE — `VERSION := ""`, `set shell := […]` — from reading as a recipe called `VERSION`.
fn recipe_name(line: &str) -> Option<&str> {
    if line.starts_with(char::is_whitespace) || line.starts_with('#') || line.contains(":=") {
        return None;
    }
    let end = line.find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))?;
    let rest = line.get(end..)?;
    if end == 0 || !rest.contains(':') || !(rest.starts_with(':') || rest.starts_with(' ')) {
        return None;
    }
    line.get(..end)
}

/// Every producer this repo declares, as the command the workflow would have to run.
///
/// ONE shape, and it used to be two. A producer is a `just` RECIPE whose DOC names the artifact —
/// the `# Build ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework (…)` line directly above `ffi:`.
/// That doc is what `just --list` prints, so it is the declaration a reader already uses, and it is
/// the one this reads. A recipe header that names the artifact on its own line counts too.
///
/// The second shape was "a shell script under `ThirdParty/` that names it outside a comment",
/// because the terminal fork's builder was carried close to upstream's shape and stayed shell. That
/// script is gone with the fork (docs/68), `ThirdParty` is not a walked root any more, and the
/// branch that read it could only ever return an empty set — so it is deleted rather than left as a
/// shape somebody might build for.
///
/// Comment lines were STRIPPED on that script side, and the reason is worth keeping even though the
/// side is not: `slopdesk-gate ffi` discussed a gitignore in prose, which is how it came to be
/// nominated as an artifact's builder. The justfile side cannot use the same trick, because there
/// the doc IS a comment — so ASSOCIATION stands in for it: only a comment whose block runs
/// uninterrupted into a recipe header is that recipe's declaration, exactly as just itself decides.
#[must_use]
pub fn producers(tree: &Tree, artifact: &str) -> BTreeSet<String> {
    let basename = artifact.rsplit('/').next().unwrap_or(artifact);
    let mut found: BTreeSet<String> = BTreeSet::new();

    if let Some(justfile) = tree.get("justfile") {
        let lines: Vec<&str> = justfile.text.lines().collect();
        for (index, line) in lines.iter().enumerate() {
            if !line.contains(basename) {
                continue;
            }
            let named = recipe_name(line).or_else(|| {
                if !line.starts_with('#') {
                    return None;
                }
                lines[index + 1..]
                    .iter()
                    .find(|below| !below.starts_with('#'))
                    .and_then(|below| recipe_name(below))
            });
            if let Some(name) = named {
                found.insert(format!("just {name}"));
            }
        }
    }

    found
}

/// Every linked xcframework the release cannot check out, the release must build.
///
/// `Package.swift` declares a `binaryTarget` path, and `SwiftPM` cannot resolve the graph without
/// the FILE — so on a fresh runner a path nothing produces is not a missing optimisation, it is a
/// release that fails before it compiles a line. When this rule was written there were TWO declared
/// artifacts: the terminal fork's had a workflow job, `SlopDeskFFI.xcframework` had nothing, and
/// the only reason that never bit is that the whole FFI port was still uncommitted — the window in
/// which to notice rather than the reason not to. There is one artifact now (docs/68), which makes
/// this rule narrower and not weaker: the last one standing is the one that must never lose its
/// step.
///
/// Asked of EVERY declared artifact rather than only the gitignored ones, which is where this
/// differs from the shell it replaces. `git check-ignore` is a process, and this crate spawns none;
/// more to the point the condition bought nothing, since a 110 MB build output is not going to be
/// committed and building one that WAS checked out is harmless. Demanding the build unconditionally
/// is the stricter rule and the one with no external dependency.
///
/// The workflow must RUN the producer, and the first draft of this only asked whether the workflow
/// MENTIONED the artifact — which a comment satisfies. A negative test that deleted the whole build
/// step still passed, because the comment above it named the file. A gate a comment can satisfy is
/// a gate about prose.
#[must_use]
pub fn every_linked_artifact_is_built_by_the_release(tree: &Tree) -> Report {
    let mut report = Report::new();
    let artifacts = linked_artifacts(tree);
    if artifacts.is_empty() {
        report.fail(
            "no linked xcframework was found in Package.swift or Apps/*/project.yml — the extraction in \
             this gate has gone stale",
        );
        return report;
    }
    let Ok(workflow) = tree.read(RELEASE_WORKFLOW) else {
        report.fail(format!(
            "{RELEASE_WORKFLOW} could not be read — nothing would be checked to build any artifact"
        ));
        return report;
    };
    let code: String = workflow
        .lines()
        .filter(|line| !line.trim_start().starts_with('#'))
        .collect::<Vec<_>>()
        .join("\n");
    if code.trim().is_empty() {
        report.fail(format!(
            "{RELEASE_WORKFLOW} has no non-comment line — the check below would accept every artifact"
        ));
        return report;
    }

    let mut unbuilt: BTreeMap<String, String> = BTreeMap::new();
    for artifact in &artifacts {
        let found = producers(tree, artifact);
        if found.is_empty() {
            unbuilt.insert(
                artifact.clone(),
                "no just recipe or script in the repo writes it".to_owned(),
            );
            continue;
        }
        // ANY of them, not the first one found. Several files know an artifact without producing
        // it, and the question that has one right answer is whether the workflow runs one
        // that does.
        if !found.iter().any(|producer| code.contains(producer.as_str())) {
            unbuilt.insert(
                artifact.clone(),
                format!(
                    "none of: {} is run by the workflow",
                    found.iter().cloned().collect::<Vec<_>>().join(", ")
                ),
            );
        }
    }
    if !unbuilt.is_empty() {
        for (artifact, why) in &unbuilt {
            eprintln!("{artifact} ({why})");
        }
        report.fail(format!(
            "a linked binaryTarget is never built by {RELEASE_WORKFLOW} — SwiftPM cannot resolve the graph \
             on a fresh runner (docs/49)"
        ));
    }
    report
}

#[cfg(test)]
mod tests {
    use super::{
        every_linked_artifact_is_built_by_the_release, every_source_directory_is_a_target, producers,
    };
    use crate::tests::Fixture;

    #[test]
    fn an_undeclared_source_directory_is_red() {
        let fixture = Fixture::new("package-undeclared");
        fixture.write("Package.swift", ".target(name: \"Declared\")\n");
        fixture.write("Sources/Declared/A.swift", "let a = 1\n");
        fixture.write("Tests/Orphan/B.swift", "let b = 2\n");
        assert!(!every_source_directory_is_a_target(&fixture.tree()).is_clean());

        let clean = Fixture::new("package-declared");
        clean.write(
            "Package.swift",
            ".target(name: \"Declared\"), .testTarget(name: \"DeclaredTests\")\n",
        );
        clean.write("Sources/Declared/A.swift", "let a = 1\n");
        clean.write("Tests/DeclaredTests/B.swift", "let b = 2\n");
        assert!(every_source_directory_is_a_target(&clean.tree()).is_clean());
    }

    /// The DOC line directly above a recipe is that recipe's declaration, which is what
    /// `just --list` prints and what a reader takes the producer off.
    #[test]
    fn a_just_recipe_whose_doc_names_the_artifact_is_a_producer() {
        let fixture = Fixture::new("producer-just");
        fixture.write(
            "justfile",
            "# Build ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework (three slices)\nffi:\n    cargo run\n",
        );
        let found = producers(&fixture.tree(), "ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework");
        assert!(found.contains("just ffi"), "{found:?}");
    }

    /// A blank line ENDS the doc block — just stops reading there and so does this. Prose that
    /// merely mentions the artifact somewhere above a recipe does not nominate it.
    #[test]
    fn a_comment_that_is_not_a_recipes_doc_nominates_nobody() {
        let fixture = Fixture::new("producer-detached");
        fixture.write(
            "justfile",
            "# ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework is linked by the clients\n\n# Run the \
             tests\ntest:\n    cargo test\n",
        );
        let found = producers(&fixture.tree(), "ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework");
        assert!(found.is_empty(), "{found:?}");
    }

    /// A VARIABLE is not a recipe, whatever it names.
    #[test]
    fn a_variable_that_names_the_artifact_is_not_a_producer() {
        let fixture = Fixture::new("producer-variable");
        fixture.write(
            "justfile",
            "ARTIFACT := \"ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework\"\nffi:\n    cargo run\n",
        );
        let found = producers(&fixture.tree(), "ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework");
        assert!(found.is_empty(), "{found:?}");
    }

    /// A gate a COMMENT can satisfy is a gate about prose — on both sides of the question.
    #[test]
    fn a_workflow_that_only_mentions_the_artifact_is_red() {
        let fixture = Fixture::new("artifact-commented");
        fixture.write(
            "Package.swift",
            ".binaryTarget(name: \"X\", path: \"ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework\")\n",
        );
        fixture.write(
            "justfile",
            "# Build ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework\nffi:\n    cargo run\n",
        );
        fixture.write(
            ".github/workflows/release.yml",
            "jobs:\n  # just ffi builds SlopDeskFFI.xcframework here\n  build:\n    run: swift build\n",
        );
        assert!(!every_linked_artifact_is_built_by_the_release(&fixture.tree()).is_clean());

        let built = Fixture::new("artifact-built");
        built.write(
            "Package.swift",
            ".binaryTarget(name: \"X\", path: \"ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework\")\n",
        );
        built.write(
            "justfile",
            "# Build ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework\nffi:\n    cargo run\n",
        );
        built.write(
            ".github/workflows/release.yml",
            "jobs:\n  build:\n    steps:\n      - run: just ffi\n      - run: swift build\n",
        );
        assert!(every_linked_artifact_is_built_by_the_release(&built.tree()).is_clean());
    }

    /// An artifact nothing in the repo writes is the other half of the same finding.
    #[test]
    fn an_artifact_with_no_producer_is_red() {
        let fixture = Fixture::new("artifact-orphan");
        fixture.write(
            "Package.swift",
            ".binaryTarget(name: \"X\", path: \"ThirdParty/nobody/Orphan.xcframework\")\n",
        );
        fixture.write("justfile", "build:\n    swift build\n");
        fixture.write(
            ".github/workflows/release.yml",
            "jobs:\n  build:\n    run: swift build\n",
        );
        assert!(!every_linked_artifact_is_built_by_the_release(&fixture.tree()).is_clean());
    }
}
