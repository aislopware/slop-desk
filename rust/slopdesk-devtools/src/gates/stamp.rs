//! The content stamp that makes an expensive build gate cost nothing when nothing moved.
//!
//! ## Why a stamp at all
//! An `xcodebuild` over this package graph costs ~85 s whether or not a compiled byte changed. That
//! is not a missing cache: with a private `-derivedDataPath`, a second run on an untouched tree
//! emits an EMPTY build-timing summary — no compile task ran — and still spends the time resolving
//! packages and re-creating the build description. Planning IS the cost, and nothing on this side
//! can make Xcode skip it. So the VERDICT is cached against a digest of the gate's inputs.
//!
//! Only a GREEN run writes a stamp, so a red one is never cached, and the stamp is RECOMPUTED after
//! the build rather than reused: xcodegen rewrites the `.xcodeproj` during the run, and a source
//! edited while the build ran must not be recorded as checked.
//!
//! ## What the input set covers, and why that is the whole set
//! Every Swift source these triples compile (`Sources/`, `Apps/`), the package graph that decides
//! which of them they compile (`Package.swift`, `Package.resolved`), the project specs (hashed as
//! part of `Apps/`), the C surface the Swift side imports (`ThirdParty/slopdesk-ffi/**/*.h` and the
//! module maps), and this gate's own source.
//!
//! The Rust SOURCES are deliberately absent. A crate's body cannot change what type-checks on the
//! far side of a C header, and the one Rust change that CAN — deleting or re-signing an exported
//! door — changes the header, which IS in the set, and breaks the macOS link first anyway.
//!
//! ## Each triple stamps only what IT compiles
//! The set above is the union; a [`Scope`] narrows it to the `SwiftPM` products one app actually
//! links, read out of the app's own spec and expanded through the package graph. `SlopDeskHost` is
//! in no iOS app's closure, so a hostd edit no longer costs an iOS typecheck, and the phone UI is
//! in no macOS app's, so a phone edit no longer costs two macOS builds. Anything the narrowing
//! cannot bound — an unreadable spec, a product the graph does not vend, a missing description —
//! falls back to the WHOLE source tree, because a scope that guessed low would be a green over code
//! it never compiled.
//!
//! ## The paths are repo-RELATIVE
//! The shell fed `shasum` absolute paths, so the digest was a property of WHERE the tree was
//! checked out. Two checkouts of one commit stamped differently and each paid the eighty-five
//! seconds; a moved checkout invalidated a cache nothing about the code had touched.

use std::fs;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

/// The file extensions the two typecheck gates compile or read.
const COMPILED: &[&str] = &["swift", "yml", "plist", "metal", "h"];

/// The one tree outside `Sources`/`Apps` that both triples compile.
///
/// It is here because BOTH app specs list
/// `GhosttySurface` as a source path: those files are members of no `Package.swift` target, so
/// nothing else in this set covers them, and an edit there used to leave a warm stamp — the gate
/// reporting green over a file it had not compiled since the change.
const GHOSTTY_TREE: &str = "ThirdParty/ghostty/integration";

/// The C surface, whose module maps have no extension worth matching on.
const FFI_TREE: &str = "ThirdParty/slopdesk-ffi";

/// The two files that decide WHICH sources the graph compiles.
const GRAPH: &[&str] = &["Package.swift", "Package.resolved"];

/// This gate's own source — the port's answer to the shell's `${SELF}`.
///
/// The gate's own logic is an input to its verdict: a stamp that survived an edit to the selection
/// rules would cache a verdict the new rules never reached.
///
/// These FOUR files and not the `gates/` tree, for the reason [`super::ffi`]'s own `SELF_FILES`
/// gives: only what decides this verdict belongs here. The input set ([`inputs_for`]), the scope
/// expansion ([`super::swift_graph`]), the two gates that consume them ([`super::xcode`]) and the
/// entry point that dispatches — a sibling gate cannot change what type-checks, and while the whole
/// tree was in the set, editing the golden gate or the FFI producer cost a twelve-minute rebuild of
/// both app triples.
const SELF_FILES: &[&str] = &[
    "rust/slopdesk-devtools/src/bin/gate.rs",
    "rust/slopdesk-devtools/src/gates/stamp.rs",
    "rust/slopdesk-devtools/src/gates/swift_graph.rs",
    "rust/slopdesk-devtools/src/gates/xcode.rs",
];

/// Which triple's inputs a stamp covers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    /// Everything either triple compiles — the union, and the safe answer.
    Everything,
    /// Only what `Apps/ClientApp-iOS` links.
    Ios,
    /// Only what the two macOS app shells link.
    MacosApps,
}

impl Scope {
    /// The app directories this scope compiles, which carry the specs and the shells themselves.
    const fn apps(self) -> &'static [&'static str] {
        match self {
            Self::Everything => &["Apps"],
            Self::Ios => &["Apps/ClientApp-iOS", "Apps/Shared"],
            Self::MacosApps => &["Apps/ClientApp-macOS", "Apps/HostApp-macOS", "Apps/Shared"],
        }
    }

    /// The source trees this scope compiles: the closure of the products its specs name, or the
    /// whole tree when that cannot be resolved.
    fn sources(self, root: &Path) -> Vec<String> {
        if matches!(self, Self::Everything) {
            return vec!["Sources".to_owned()];
        }
        let mut products: Vec<String> = Vec::new();
        for app in self.apps() {
            products.extend(products_named_in(&root.join(app).join("project.yml")));
        }
        if products.is_empty() {
            return vec!["Sources".to_owned()];
        }
        super::touched::graph(root)
            .ok()
            .and_then(|graph| graph.paths_for_products(&products))
            .unwrap_or_else(|| vec!["Sources".to_owned()])
    }
}

/// Every `product:` an xcodegen spec names, in file order.
///
/// A line scan rather than a YAML parse: the key appears once per dependency, its value is one
/// token, and a spec this cannot read answers nothing — which the caller reads as "widen".
fn products_named_in(spec: &Path) -> Vec<String> {
    let Ok(text) = fs::read_to_string(spec) else {
        return Vec::new();
    };
    text.lines()
        .filter_map(|line| line.trim().strip_prefix("product:"))
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .collect()
}

/// Every input path, repo-relative and sorted, exactly as the digest consumes them.
///
/// # Errors
/// When a tree in the set cannot be walked.
pub fn inputs(root: &Path) -> Result<Vec<String>, String> {
    inputs_for(root, Scope::Everything)
}

/// The same, narrowed to one triple.
///
/// # Errors
/// When a tree in the set cannot be walked.
pub fn inputs_for(root: &Path, scope: Scope) -> Result<Vec<String>, String> {
    let mut found: Vec<String> = Vec::new();
    let mut trees: Vec<String> = scope.sources(root);
    trees.extend(scope.apps().iter().map(|app| (*app).to_owned()));
    trees.push(GHOSTTY_TREE.to_owned());
    for tree in &trees {
        walk(root, &root.join(tree), &mut found, &|path| {
            path.extension()
                .and_then(|value| value.to_str())
                .is_some_and(|value| COMPILED.contains(&value))
        })?;
    }
    walk(root, &root.join(FFI_TREE), &mut found, &|path| {
        let name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or_default();
        name == "module.modulemap" || path.extension().and_then(|value| value.to_str()) == Some("h")
    })?;
    for file in GRAPH.iter().chain(SELF_FILES) {
        found.push((*file).to_owned());
    }
    found.sort_unstable();
    found.dedup();
    Ok(found)
}

/// The digest of every input's contents AND name.
///
/// The name is in the digest, so a rename or a deletion moves the stamp the way a content edit
/// does. A path that does not exist hashes as empty rather than failing: `Package.resolved` is
/// absent on a tree that has never resolved, and that is a state to stamp, not to refuse.
///
/// # Errors
/// When an input tree cannot be walked or a file that exists cannot be read.
pub fn current(root: &Path) -> Result<String, String> {
    current_for(root, Scope::Everything)
}

/// The same digest, over one triple's inputs.
///
/// # Errors
/// When an input tree cannot be walked or a file that exists cannot be read.
pub fn current_for(root: &Path, scope: Scope) -> Result<String, String> {
    let mut outer = Sha256::new();
    for path in inputs_for(root, scope)? {
        let bytes = fs::read(root.join(&path)).unwrap_or_default();
        let mut inner = Sha256::new();
        inner.update(&bytes);
        outer.update(format!("{:x}  {path}\n", inner.finalize()));
    }
    Ok(format!("{:x}", outer.finalize()))
}

/// True when `marker` records exactly `want`.
#[must_use]
pub fn is_warm(marker: &Path, want: &str) -> bool {
    fs::read_to_string(marker).is_ok_and(|recorded| recorded.trim() == want)
}

/// Record `value` in `marker`, creating `.build/` if this is the first gate to run.
///
/// # Errors
/// When the marker's directory cannot be created or the marker cannot be written.
pub fn record(marker: &Path, value: &str) -> Result<(), String> {
    if let Some(parent) = marker.parent() {
        fs::create_dir_all(parent).map_err(|error| format!("{}: {error}", parent.display()))?;
    }
    fs::write(marker, format!("{value}\n")).map_err(|error| format!("{}: {error}", marker.display()))
}

/// Directories no stamp ever descends: build OUTPUT, and git's own object store.
///
/// PRUNED at the directory rather than filtered out of the results, which is the difference between
/// a warm `make ffi` costing 50 s and costing 0.4 s. `rust/slopdesk-ffi/target` alone holds 48 GB
/// across 592 000 files — three iOS/macOS slices of every dependency — and the walk that fed the
/// FFI stamp read every one of their names before discarding them by path component. Nothing under
/// any of these is an input to anything: a stamp asks what the SOURCES say, and an output that
/// could change a stamp would be a gate firing on its own result.
const PRUNED: &[&str] = &["target", ".build", ".git"];

/// Collect every file under `dir` that `keep` accepts, as a repo-relative path.
///
/// Shared with [`super::ffi`], whose input set is a different tree with a different filter but the
/// same deterministic sorted walk.
///
/// # Errors
/// When a directory in the tree cannot be read.
pub(crate) fn walk(
    root: &Path,
    dir: &Path,
    into: &mut Vec<String>,
    keep: &dyn Fn(&Path) -> bool,
) -> Result<(), String> {
    if !dir.is_dir() {
        return Ok(());
    }
    let entries = fs::read_dir(dir).map_err(|error| format!("{}: {error}", dir.display()))?;
    let mut paths: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .collect();
    paths.sort_unstable();
    for path in paths {
        if path.is_dir() {
            let name = path
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or_default();
            if PRUNED.contains(&name) {
                continue;
            }
            walk(root, &path, into, keep)?;
        } else if keep(&path) {
            let relative = path.strip_prefix(root).unwrap_or(&path);
            into.push(relative.to_string_lossy().into_owned());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::{Scope, current, inputs, inputs_for, is_warm, products_named_in, record};

    /// A tree just big enough to exercise the walk, the extension filter and the digest.
    fn fixture(name: &str) -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!("slopdesk-stamp-{name}-{}", std::process::id()));
        let _ignored = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("Sources/Deep")).unwrap();
        fs::create_dir_all(root.join("ThirdParty/slopdesk-ffi/include")).unwrap();
        fs::write(root.join("Sources/A.swift"), "let a = 1\n").unwrap();
        fs::write(root.join("Sources/Deep/B.metal"), "kernel\n").unwrap();
        fs::write(root.join("Sources/notes.md"), "not compiled\n").unwrap();
        fs::write(root.join("ThirdParty/slopdesk-ffi/include/door.h"), "void d();\n").unwrap();
        fs::write(
            root.join("ThirdParty/slopdesk-ffi/include/module.modulemap"),
            "m\n",
        )
        .unwrap();
        fs::write(root.join("Package.swift"), "// swift-tools-version:6.0\n").unwrap();
        root
    }

    #[test]
    fn only_the_compiled_extensions_are_inputs() {
        let root = fixture("extensions");
        let found = inputs(&root).unwrap();
        assert!(found.contains(&"Sources/A.swift".to_owned()));
        assert!(found.contains(&"Sources/Deep/B.metal".to_owned()));
        assert!(found.contains(&"ThirdParty/slopdesk-ffi/include/module.modulemap".to_owned()));
        assert!(
            !found.iter().any(|path| path.rsplit('.').next() == Some("md")),
            "a doc reached the stamp: {found:?}"
        );
    }

    /// Build output is not an input, and the walk must not even LOOK: `target/` holds tens of
    /// gigabytes of slices, and reading their names cost fifty seconds a run.
    #[test]
    fn build_output_is_pruned_at_the_directory() {
        let root = fixture("pruned");
        fs::create_dir_all(root.join("Sources/target/deep")).unwrap();
        fs::write(root.join("Sources/target/deep/Built.swift"), "generated\n").unwrap();
        fs::create_dir_all(root.join("Sources/.build")).unwrap();
        fs::write(root.join("Sources/.build/Cached.swift"), "cached\n").unwrap();
        let found = inputs(&root).unwrap();
        assert!(
            !found
                .iter()
                .any(|path| path.contains("target") || path.contains(".build")),
            "an output tree reached the stamp: {found:?}"
        );
        assert!(
            found.contains(&"Sources/A.swift".to_owned()),
            "the source went with it"
        );
    }

    /// The graph files are inputs whether or not they exist — an unresolved tree is a state.
    #[test]
    fn the_package_graph_is_always_an_input() {
        let root = fixture("graph");
        let found = inputs(&root).unwrap();
        assert!(found.contains(&"Package.swift".to_owned()));
        assert!(found.contains(&"Package.resolved".to_owned()));
    }

    #[test]
    fn a_content_edit_moves_the_stamp() {
        let root = fixture("content");
        let before = current(&root).unwrap();
        fs::write(root.join("Sources/A.swift"), "let a = 2\n").unwrap();
        assert_ne!(before, current(&root).unwrap());
    }

    /// The file NAME is in the digest, so a rename is a change even when every byte survives.
    #[test]
    fn a_rename_moves_the_stamp() {
        let root = fixture("rename");
        let before = current(&root).unwrap();
        fs::rename(root.join("Sources/A.swift"), root.join("Sources/Renamed.swift")).unwrap();
        assert_ne!(before, current(&root).unwrap());
    }

    /// The spec's own vocabulary: `product:` under each dependency, one token, order preserved.
    #[test]
    fn a_spec_yields_the_products_it_names() {
        let root = fixture("products");
        let spec = root.join("Apps/ClientApp-iOS/project.yml");
        fs::create_dir_all(spec.parent().unwrap()).unwrap();
        fs::write(
            &spec,
            "targets:\n  App:\n    dependencies:\n      - package: SlopDesk\n        product: \
             SlopDeskClientCore\n      - package: SFSafeSymbols\n        product: SFSafeSymbols\n",
        )
        .unwrap();
        assert_eq!(products_named_in(&spec), ["SlopDeskClientCore", "SFSafeSymbols"]);
        assert!(
            products_named_in(&root.join("Apps/Nowhere/project.yml")).is_empty(),
            "a spec that cannot be read names nothing, which the caller widens on"
        );
    }

    /// A scope that cannot bound itself covers the WHOLE tree — never less than the union.
    #[test]
    fn an_unreadable_spec_widens_to_everything() {
        let root = fixture("widen");
        // No `Apps/` at all, so no spec, no products, no package description to expand them with.
        let narrowed = inputs_for(&root, Scope::Ios).unwrap();
        assert!(
            narrowed.contains(&"Sources/A.swift".to_owned()),
            "the fallback dropped a source: {narrowed:?}"
        );
        assert_eq!(
            narrowed,
            inputs_for(&root, Scope::Everything).unwrap(),
            "a scope that resolved nothing must stamp exactly what the union does"
        );
    }

    #[test]
    fn a_marker_is_warm_only_for_the_value_it_recorded() {
        let root = fixture("marker");
        let marker = root.join(".build/stamp.sha256");
        assert!(!is_warm(&marker, "abc"));
        record(&marker, "abc").unwrap();
        assert!(is_warm(&marker, "abc"));
        assert!(!is_warm(&marker, "abd"));
    }
}
