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
        report.fail(format!(
            "a directory under Tests/ or Sources/ has no target in Package.swift — SwiftPM ignores it \
             silently: {}",
            undeclared.join(", ")
        ));
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
                lines
                    .iter()
                    .skip(index + 1)
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
        let listed: Vec<String> = unbuilt
            .iter()
            .map(|(artifact, why)| format!("{artifact} ({why})"))
            .collect();
        report.fail(format!(
            "a linked binaryTarget is never built by {RELEASE_WORKFLOW} — SwiftPM cannot resolve the graph \
             on a fresh runner (docs/49): {}",
            listed.join(", ")
        ));
    }
    report
}

/// Every `CSlopDeskFFI` dependent carries `linkerSettings: ffiCLibraries`.
///
/// `docs/55` §4: the Rust staticlib is ONE object, so any target that calls any `slopdesk_*` door
/// pulls libgit2's members in and needs `iconv`, `Security` and `CoreFoundation` at link time.
/// `Package.swift` spells those once as `ffiCLibraries`, and the promise beside it is that every
/// dependent repeats the name. A dependent that forgets it links today only because SOME other
/// target in the same executable's graph remembered — and fails, with an undefined-symbol list
/// naming nothing it wrote, on the first product that links it alone.
///
/// The manifest is Swift, not a table, so this reads it the way a reader does: one block per
/// `.target(`/`.testTarget(`/`.executableTarget(`, ending where the next begins. A block whose
/// `dependencies:` list quotes `"CSlopDeskFFI"` must also say `linkerSettings: ffiCLibraries`.
/// The list is FLOORED — a manifest with no dependent at all is a renamed module, not a pass.
#[must_use]
pub fn every_ffi_dependent_links_the_frameworks(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(manifest) = report.source(tree, "Package.swift", "it declares every FFI dependent") else {
        return report;
    };
    report.fail_if(
        !manifest.text.contains("let ffiCLibraries: [LinkerSetting]"),
        "Package.swift no longer defines `ffiCLibraries` — the one spelling of the FFI link line (docs/55 \
         §4)",
    );

    let mut dependents = 0_usize;
    let mut forgot: Vec<String> = Vec::new();
    for block in target_blocks(&manifest.text) {
        let Some(name) = text::capture_first(block, r#"name:\s*"([A-Za-z0-9_]+)""#) else {
            continue;
        };
        let dependencies = text::capture_first(block, r"(?s)dependencies:\s*\[(.*?)\]").unwrap_or_default();
        if !dependencies.contains("\"CSlopDeskFFI\"") {
            continue;
        }
        dependents += 1;
        if !block.contains("linkerSettings: ffiCLibraries") {
            forgot.push(name);
        }
    }
    report.fail_if(
        dependents == 0,
        "no target in Package.swift depends on CSlopDeskFFI — the rule would pass on a renamed module \
         (docs/55 §4b)",
    );
    report.fail_if(
        !forgot.is_empty(),
        format!(
            "a CSlopDeskFFI dependent does not carry `linkerSettings: ffiCLibraries` ({}) — it links today \
             on another target's flags and fails alone (docs/55 §4b)",
            forgot.join(", ")
        ),
    );
    report
}

/// The manifest split at each target DECLARATION; the text before the first is dropped.
///
/// `SwiftPM` spells a dependency the same way it spells a declaration — `.target(name: "X")` is
/// legal inside a `dependencies: [` list, and this manifest uses that form. A splitter that cut at
/// every `.target(` would end a declaration mid-list, lose its `dependencies:` to the regex, and
/// read the dependent as a non-dependent. So a `.target(` is a declaration only when it does not
/// sit inside a `dependencies:` list, which the scan tracks by bracket depth; `//` comments and
/// string literals are skipped so a parenthesis in prose, or the `//` of a package URL, cannot
/// unbalance the count.
fn target_blocks(manifest: &str) -> Vec<&str> {
    const OPENERS: [&str; 4] = [".target(", ".testTarget(", ".executableTarget(", ".binaryTarget("];
    let bytes = manifest.as_bytes();
    let mut starts: Vec<usize> = Vec::new();
    // One entry per open bracket: whether it opened a `dependencies:` list.
    let mut stack: Vec<bool> = Vec::new();
    let mut in_dependencies = 0_usize;
    let mut index = 0_usize;
    while index < bytes.len() {
        let rest = manifest.get(index..).unwrap_or_default();
        if rest.starts_with("//") {
            index += rest.find('\n').unwrap_or(rest.len());
            continue;
        }
        if rest.starts_with('"') {
            // A string literal: a package URL holds `//`, and a flag may hold a bracket. Skip to
            // its close, honouring a backslash escape.
            let mut close = 1_usize;
            while let Some(byte) = rest.as_bytes().get(close) {
                match byte {
                    b'\\' => close += 2,
                    b'"' => break,
                    _ => close += 1,
                }
            }
            index += close.saturating_add(1).min(rest.len());
            continue;
        }
        if in_dependencies == 0 && OPENERS.iter().any(|opener| rest.starts_with(opener)) {
            starts.push(index);
        }
        match bytes.get(index) {
            Some(b'[') => {
                let opens_dependencies = manifest
                    .get(..index)
                    .is_some_and(|before| before.trim_end().ends_with("dependencies:"));
                stack.push(opens_dependencies);
                in_dependencies += usize::from(opens_dependencies);
            },
            Some(b'(') => stack.push(false),
            Some(b']' | b')') => {
                let closed_dependencies = stack.pop() == Some(true);
                in_dependencies = in_dependencies.saturating_sub(usize::from(closed_dependencies));
            },
            _ => {},
        }
        index += 1;
    }
    starts
        .iter()
        .enumerate()
        .filter_map(|(position, &start)| {
            let end = starts.get(position + 1).copied().unwrap_or(manifest.len());
            manifest.get(start..end)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{
        every_ffi_dependent_links_the_frameworks, every_linked_artifact_is_built_by_the_release,
        every_source_directory_is_a_target, producers,
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

    const FFI_MANIFEST: &str =
        "let ffiCLibraries: [LinkerSetting] = [.linkedLibrary(\"iconv\")]\n.target(name: \"Core\", \
         dependencies: [\"Wire\", \"CSlopDeskFFI\"], linkerSettings: ffiCLibraries),\n.target(name: \
         \"Wire\", dependencies: [\"Other\"]),\n.binaryTarget(name: \"CSlopDeskFFI\", path: \
         \"ThirdParty/x.xcframework\"),\n";

    #[test]
    fn every_dependent_carrying_the_link_line_is_clean() {
        let fixture = Fixture::new("ffi-link-clean");
        fixture.write("Package.swift", FFI_MANIFEST);
        assert!(every_ffi_dependent_links_the_frameworks(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_dependent_that_forgot_the_link_line_is_red() {
        let fixture = Fixture::new("ffi-link-forgot");
        fixture.write(
            "Package.swift",
            &FFI_MANIFEST.replace(", linkerSettings: ffiCLibraries", ""),
        );
        let violations = every_ffi_dependent_links_the_frameworks(&fixture.tree())
            .violations()
            .to_vec();
        assert!(violations.iter().any(|v| v.contains("Core")), "{violations:?}");
    }

    /// A one-line target with the dependency last in its list is the shape `SlopDeskClient` had
    /// when it was found without the line — the block must reach past the `]`.
    #[test]
    fn a_dependent_whose_dependency_is_last_still_needs_the_line() {
        let fixture = Fixture::new("ffi-link-last");
        fixture.write(
            "Package.swift",
            "let ffiCLibraries: [LinkerSetting] = []\n.target(name: \"Client\", dependencies: [\"Wire\", \
             \"CSlopDeskFFI\"]),\n.target(name: \"Wire\"),\n",
        );
        assert!(!every_ffi_dependent_links_the_frameworks(&fixture.tree()).is_clean());
    }

    /// `.target(name: "X")` is ALSO how a dependency is spelled, and this manifest uses that form
    /// inside `dependencies:` lists. A splitter that cut there would end `Core`'s block before its
    /// dependency list closed and read it as a non-dependent.
    #[test]
    fn a_dependency_spelled_as_target_does_not_split_the_declaration() {
        let fixture = Fixture::new("ffi-link-dependency-form");
        fixture.write(
            "Package.swift",
            "let ffiCLibraries: [LinkerSetting] = [] // (flags)\n.package(url: \"https://example.invalid/x.git\", \
             from: \"1.0.0\"),\n.target(\nname: \"Core\",\ndependencies: \
             [\n.target(name: \"Arena\"),\n\"CSlopDeskFFI\",\n],\n),\n.target(name: \"Arena\"),\n",
        );
        let violations = every_ffi_dependent_links_the_frameworks(&fixture.tree())
            .violations()
            .to_vec();
        assert!(violations.iter().any(|v| v.contains("Core")), "{violations:?}");
        assert!(
            !violations.iter().any(|v| v.contains("no target")),
            "{violations:?}"
        );
    }

    #[test]
    fn a_manifest_with_no_dependent_at_all_is_red() {
        let fixture = Fixture::new("ffi-link-none");
        fixture.write(
            "Package.swift",
            "let ffiCLibraries: [LinkerSetting] = []\n.target(name: \"Wire\", dependencies: [\"Other\"]),\n",
        );
        assert!(!every_ffi_dependent_links_the_frameworks(&fixture.tree()).is_clean());
    }
}
