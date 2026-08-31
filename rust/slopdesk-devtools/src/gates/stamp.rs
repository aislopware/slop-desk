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
//! part of `Apps/`), the C surface the Swift side imports — every `.h` in the walked trees and
//! every `module.modulemap` in ANY of them, not the FFI tree's alone — and this gate's own source.
//!
//! That last distinction was a hole for as long as the sentence above claimed otherwise. The map
//! lookup was a second walk pinned to `ThirdParty/slopdesk-ffi`, so a module map anywhere ELSE was
//! in no scope's input set while the headers it exports were in all three. A map decides whether an
//! `import` of its module resolves at all — so renaming the module, dropping its `export *` or
//! pointing `header` at a different file left a warm stamp over a change nothing but a compile can
//! find. The map that made this visible belonged to the deleted libghostty fork, and the rule it
//! bought outlives it: the lookup is a NAME match in every tree walked, not a second walk.
//!
//! The Rust SOURCES are deliberately absent. A crate's body cannot change what type-checks on the
//! far side of a C header, and the one Rust change that CAN — deleting or re-signing an exported
//! door — changes the header, which IS in the set, and breaks the macOS link first anyway.
//!
//! ## Each triple stamps only what IT compiles
//! The set above is the union; a [`Scope`] narrows it to the `SwiftPM` products one app actually
//! links, read out of the app's own spec and expanded through the package graph. `SlopDeskMacUI` is
//! in no iOS app's closure, so a desktop-chrome edit no longer costs an iOS typecheck, and the
//! phone UI is in no macOS app's, so a phone edit no longer costs a macOS build. Anything the
//! narrowing cannot bound — a spec it cannot open or cannot read whole, a description that will not
//! parse, a product list nothing in the graph vends — falls back to the WHOLE source tree, because
//! a scope that guessed low would be a green over code it never compiled.
//!
//! That fallback is also how this section spent months describing something that never happened. A
//! scope's app list holds the shells AND `Apps/Shared`, which is an asset catalog with no
//! `project.yml`, and demanding a spec of it answered "cannot read" on every call — so every scope
//! widened to the union and both claims above were false. What the fix bought is a union some
//! ninety-odd inputs wider than either triple, and the difference is exactly `SlopDeskMacUI` /
//! `SlopDeskVideoClientMac` on one side and `SlopDeskPhoneUI` / `SlopDeskVideoClientPhone` on the
//! other, with no shared module in either. A fallback safe enough to take every time is a fallback
//! nobody notices taking. The three exact counts are in `docs/DECISIONS.md`, dated — this file
//! grows an input whenever the walk learns a new kind, and a number spelled in a living doc is
//! stated once and then wrong in silence.
//!
//! ## Source is hashed as CODE, not as bytes
//! A `.swift` or a `.h` in the set is digested through [`super::code_text`] — comments removed,
//! inter-token whitespace normalised — so a doc-comment edit leaves the stamp exactly where it was.
//! That is not a loosening: a comment is discarded by the lexer before one declaration is parsed,
//! so two files that differ only in comments compile to the same thing and a rebuild between them
//! asserts nothing. It is measured rather than assumed — a one-word doc edit in
//! `Sources/SlopDeskVideoProtocol`, which sits deep in both app graphs, cost fifteen minutes across
//! the two triples. Everything else in the set is still hashed byte-for-byte.
//!
//! ## The paths are repo-RELATIVE
//! The shell fed `shasum` absolute paths, so the digest was a property of WHERE the tree was
//! checked out. Two checkouts of one commit stamped differently and each paid the eighty-five
//! seconds; a moved checkout invalidated a cache nothing about the code had touched.

use std::fs;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use super::code_text;

/// The file extensions the two typecheck gates compile or read.
const COMPILED: &[&str] = &["swift", "yml", "plist", "metal", "h"];

/// The one input with no extension to match on — matched by NAME, in every tree walked.
const MODULE_MAP: &str = "module.modulemap";

/// The C surface the Swift side imports — headers, module maps and the slice manifest.
///
/// The one tree outside `Sources`/`Apps` that is walked. There used to be a second,
/// `ThirdParty/ghostty/integration`, because both app specs listed the libghostty embedder as a
/// source path and those files were members of no `Package.swift` target — so nothing else in this
/// set covered them and an edit there left a warm stamp. The fork is gone (`docs/68` §10) and its
/// successor is an ordinary package source under `Sources/`, which the walk above already reaches:
/// a tree outside the graph is a hole to plug, and not having one is better than plugging it.
const FFI_TREE: &str = "ThirdParty/slopdesk-ffi";

/// The two files that decide WHICH sources the graph compiles.
const GRAPH: &[&str] = &["Package.swift", "Package.resolved"];

/// What the linked artifact is COMPILED FROM, which no path edge in this set reaches (`docs/68`
/// §10.2).
///
/// Neither file is Swift, neither is under a walked tree, and neither is named by
/// `Package.swift` — yet between them they decide which ghostty tree the terminal engine is built
/// out of: `tools.lock` pins the commit and `rust/.cargo/config.toml` exports the
/// `GHOSTTY_SOURCE_DIR` that selects the materialised copy. Bump either and every source in the
/// walk is byte-identical while the `SlopDeskFFI.xcframework` the apps link is compiled from
/// different Zig sources — today's stamp stays warm over an artifact that is not the one it was
/// computed against, which is the exact silence this gate exists to end.
///
/// By NAME rather than by walk, for the same reason [`SELF_FILES`] is: only the two files that
/// decide the verdict belong here, and `ThirdParty/tools/` also holds a gitignored `.prefix/` of
/// materialised downloads that no stamp may ever descend into.
const ENGINE_PIN: &[&str] = &["ThirdParty/tools/tools.lock", "rust/.cargo/config.toml"];

/// This gate's own source — the port's answer to the shell's `${SELF}`.
///
/// The gate's own logic is an input to its verdict: a stamp that survived an edit to the selection
/// rules would cache a verdict the new rules never reached.
///
/// These SIX files and not the `gates/` tree, for the reason [`super::ffi`]'s own `SELF_FILES`
/// gives: only what decides this verdict belongs here. The input set ([`inputs_for`]), the
/// normaliser each source is hashed through ([`super::code_text`]), the scope expansion
/// ([`super::swift_graph`]), the package description [`Scope::sources`] expands it THROUGH
/// ([`super::touched`]), the two gates that consume them ([`super::xcode`]) and the entry
/// point that dispatches — a sibling gate cannot change what type-checks, and while the whole tree
/// was in the set, editing the golden gate or the FFI producer cost a twelve-minute rebuild of both
/// app triples.
///
/// Anything this list forgets is a stamp that stays warm while the rule that computed it moved. Add
/// a file here the moment a scope decision starts flowing through it.
const SELF_FILES: &[&str] = &[
    "rust/slopdesk-devtools/src/bin/gate.rs",
    // The normaliser decides what a source file HASHES AS, so it decides the verdict as directly as
    // the input set does: a stripper edit that changed one file's digest would otherwise be cached
    // behind a stamp computed under the old rule.
    "rust/slopdesk-devtools/src/gates/code_text.rs",
    "rust/slopdesk-devtools/src/gates/stamp.rs",
    "rust/slopdesk-devtools/src/gates/swift_graph.rs",
    "rust/slopdesk-devtools/src/gates/touched.rs",
    "rust/slopdesk-devtools/src/gates/xcode.rs",
];

/// Which triple's inputs a stamp covers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    /// Everything either triple compiles — the union, and the safe answer.
    Everything,
    /// Only what `Apps/ClientApp-iOS` links.
    Ios,
    /// Only what the macOS app shell links.
    MacosApps,
}

impl Scope {
    /// The app directories this scope compiles, which carry the specs and the shells themselves.
    const fn apps(self) -> &'static [&'static str] {
        match self {
            Self::Everything => &["Apps"],
            Self::Ios => &["Apps/ClientApp-iOS", "Apps/Shared"],
            Self::MacosApps => &["Apps/ClientApp-macOS", "Apps/Shared"],
        }
    }

    /// The source trees this scope compiles: the closure of the products its specs name, or the
    /// whole tree when that cannot be resolved.
    ///
    /// A directory with NO spec vends no product and is skipped. `Apps/Shared` is one — it carries
    /// the assets and entitlements both shells include, and it is in [`Self::apps`] so those files
    /// reach the digest, not because it names a target. Demanding a spec of it made
    /// [`products_named_in`] answer `None` on every call, so the widening below fired every time
    /// and the narrowing this whole section describes had never once run.
    ///
    /// The boundary that keeps the skip safe: each scope has exactly ONE spec-bearing app today. A
    /// scope holding two would narrow to the survivor if one spec were deleted, so the day a second
    /// arrives, "absent" has to become an answer rather than a silence.
    fn sources(self, root: &Path) -> Vec<String> {
        if matches!(self, Self::Everything) {
            return vec!["Sources".to_owned()];
        }
        let mut products: Vec<String> = Vec::new();
        for app in self.apps() {
            let spec = root.join(app).join("project.yml");
            if !spec.is_file() {
                continue;
            }
            let Some(named) = products_named_in(&spec) else {
                return vec!["Sources".to_owned()];
            };
            products.extend(named);
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

/// Every `product:` an xcodegen spec names, in file order, or `None` when the spec cannot be read
/// as a complete list.
///
/// A line scan rather than a YAML parse: the key appears once per dependency and its value is one
/// token. What the scan must NOT do is answer confidently when it did not understand — xcodegen
/// also accepts a bare `- package: X` with no `product:` under it, meaning "link everything that
/// package vends". Every spec here spells the product out today, and a productless dependency would
/// otherwise return a short list that narrowed the scope silently: a warm green over code the app
/// does compile. So an unpaired `package:` answers `None`, and so does a spec that cannot be
/// opened.
fn products_named_in(spec: &Path) -> Option<Vec<String>> {
    let text = fs::read_to_string(spec).ok()?;
    let mut found: Vec<String> = Vec::new();
    let mut awaiting = false;
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(value) = trimmed.strip_prefix("product:") {
            let value = value.trim();
            if value.is_empty() {
                return None;
            }
            found.push(value.to_owned());
            awaiting = false;
        } else if trimmed.starts_with("- package:") || trimmed.starts_with("package:") {
            if awaiting {
                return None;
            }
            awaiting = true;
        }
    }
    if awaiting { None } else { Some(found) }
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
    // The xcframework is a binaryTarget in the graph, so a narrowed scope's product closure NAMES
    // it and walks it under this filter, while `Everything` — whose closure is the literal string
    // `Sources` — did not. That made the union smaller than the thing it is the fallback FOR, by
    // one file: `SlopDeskFFI.xcframework/Info.plist`, which records the slices the Swift side
    // links. Unobservable while the narrowing never ran, and a fallback that covers less than
    // the scope it replaces is the one direction this gate may not be wrong in.
    trees.push(FFI_TREE.to_owned());
    // A module map has no extension to match on, and it is an input to EVERY tree walked here
    // rather than to the FFI one alone — which is what a second walk scoped to `FFI_TREE` used to
    // say. A map is what says which header its module exports, and an app spec can point
    // `SWIFT_INCLUDE_PATHS` at any directory holding one, so a map outside the FFI tree decides
    // whether a triple type-checks at all. Headers were in the set the whole time — `h` is a
    // `COMPILED` extension — and the maps naming them were not, so renaming a module, dropping its
    // `export *` or pointing `header` somewhere else left a warm stamp over a change that can only
    // be found by compiling.
    for tree in &trees {
        walk(root, &root.join(tree), &mut found, &|path| {
            if path.file_name().and_then(|value| value.to_str()) == Some(MODULE_MAP) {
                return true;
            }
            path.extension()
                .and_then(|value| value.to_str())
                .is_some_and(|value| COMPILED.contains(&value))
        })?;
    }
    for file in GRAPH.iter().chain(SELF_FILES).chain(ENGINE_PIN) {
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
        let file = PathBuf::from(&path);
        let bytes = fs::read(root.join(&file)).unwrap_or_default();
        let mut inner = Sha256::new();
        // Source is hashed as CODE, everything else as bytes. See [`code_text`] for the
        // measurement: a doc-comment edit under `Sources/` used to cost fifteen minutes of
        // `xcodebuild` for a change the lexer discards before it parses a declaration.
        match code_text::Dialect::of(&file) {
            Some(dialect) => inner.update(code_text::code_only(&bytes, dialect)),
            None => inner.update(&bytes),
        }
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
/// a warm `just ffi` costing 50 s and costing 0.4 s. `rust/slopdesk-ffi/target` alone holds 48 GB
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
        // A module map OUTSIDE the FFI tree, which is the case the walk exists to cover.
        fs::write(
            root.join("Sources/Deep/module.modulemap"),
            "module CDeep { header \"deep.h\" export * }\n",
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

    /// A module map is an input wherever it sits, not only under the FFI tree.
    ///
    /// The lookup used to be a second walk pinned to `ThirdParty/slopdesk-ffi`, which left every
    /// map outside that one tree out of every scope's input set while the headers they export were
    /// inside all of them.
    #[test]
    fn a_module_map_outside_the_ffi_tree_is_an_input() {
        let root = fixture("modulemap-anywhere");
        let found = inputs(&root).unwrap();
        assert!(
            found.contains(&"Sources/Deep/module.modulemap".to_owned()),
            "the map that decides what an import sees is not stamped: {found:?}"
        );
    }

    /// And editing it moves the stamp, which is the property the gate's verdict rests on.
    #[test]
    fn editing_a_module_map_moves_the_stamp() {
        let root = fixture("modulemap-edit");
        let before = current(&root).unwrap();
        fs::write(
            root.join("Sources/Deep/module.modulemap"),
            "module CDeep { header \"somewhere-else.h\" }\n",
        )
        .unwrap();
        assert_ne!(before, current(&root).unwrap());
    }

    /// The engine pin is an input by NAME: bump it and the stamp moves, though every walked source
    /// is byte-identical.
    ///
    /// The failure it forecloses is the one `docs/68` §10.2 names — a warm stamp over an
    /// xcframework compiled from a different ghostty tree — and it can only be caught here, since
    /// neither file is under a walked tree and no path edge in this set reaches either.
    #[test]
    fn the_engine_pin_is_an_input_by_name() {
        let root = fixture("engine-pin");
        let found = inputs(&root).unwrap();
        assert!(found.contains(&"ThirdParty/tools/tools.lock".to_owned()));
        assert!(found.contains(&"rust/.cargo/config.toml".to_owned()));

        let before = current(&root).unwrap();
        fs::create_dir_all(root.join("ThirdParty/tools")).unwrap();
        fs::write(root.join("ThirdParty/tools/tools.lock"), "ghostty|deadbeef|git\n").unwrap();
        assert_ne!(
            before,
            current(&root).unwrap(),
            "the engine commit moved and the stamp did not"
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
        assert_eq!(products_named_in(&spec).unwrap(), [
            "SlopDeskClientCore",
            "SFSafeSymbols"
        ]);
        assert!(
            products_named_in(&root.join("Apps/Nowhere/project.yml")).is_none(),
            "a spec that cannot be read is not a spec that names nothing"
        );
    }

    /// `- package: X` with no `product:` under it links EVERYTHING that package vends. A scan that
    /// answered the short list would narrow the scope silently — green over code the app compiles.
    #[test]
    fn a_dependency_without_a_product_refuses_to_answer() {
        let root = fixture("productless");
        let spec = root.join("Apps/ClientApp-iOS/project.yml");
        fs::create_dir_all(spec.parent().unwrap()).unwrap();
        fs::write(
            &spec,
            "targets:\n  App:\n    dependencies:\n      - package: SlopDesk\n        product: \
             SlopDeskClientCore\n      - package: Everything\n",
        )
        .unwrap();
        assert!(products_named_in(&spec).is_none());
        assert_eq!(
            inputs_for(&root, Scope::Ios).unwrap(),
            inputs_for(&root, Scope::Everything).unwrap(),
            "a spec it could not read whole must stamp the union"
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

    /// A sibling directory with no spec vends no product, and must not widen the whole scope.
    ///
    /// `Apps/Shared` is that directory in the real tree — an asset catalog both shells include —
    /// and demanding a `project.yml` of it made every narrowing fall back to the union, silently,
    /// for as long as the narrowing existed. This is the test that reds on that shape: it asserts
    /// the scope both NARROWS and drops the module the app does not link, which a fallback to
    /// `Sources` fails on the second count.
    #[test]
    fn a_spec_less_app_directory_does_not_widen_the_scope() {
        let root = fixture("spec-less-sibling");
        fs::create_dir_all(root.join("Apps/Shared")).unwrap();
        fs::write(root.join("Apps/Shared/Contents.json"), "{}\n").unwrap();
        let spec = root.join("Apps/ClientApp-iOS/project.yml");
        fs::create_dir_all(spec.parent().unwrap()).unwrap();
        fs::write(
            &spec,
            "targets:\n  App:\n    dependencies:\n      - package: SlopDesk\n        product: Phone\n",
        )
        .unwrap();
        fs::create_dir_all(root.join("Sources/Phone")).unwrap();
        fs::create_dir_all(root.join("Sources/Desktop")).unwrap();
        fs::write(root.join("Sources/Phone/P.swift"), "let p = 1\n").unwrap();
        fs::write(root.join("Sources/Desktop/D.swift"), "let d = 1\n").unwrap();
        // The describe cache, seeded rather than produced: `touched::graph` reads it whenever it is
        // no older than `Package.swift`, so this test asserts the SCOPE without spending a SwiftPM
        // manifest compile on a two-target fixture.
        fs::create_dir_all(root.join(".build")).unwrap();
        fs::write(
            root.join(".build/pkg-describe.json"),
            "{\"targets\": [{\"name\": \"Phone\", \"type\": \"library\", \"path\": \"Sources/Phone\", \
             \"target_dependencies\": []}, {\"name\": \"Desktop\", \"type\": \"library\", \"path\": \
             \"Sources/Desktop\", \"target_dependencies\": []}], \"products\": [{\"name\": \"Phone\", \
             \"targets\": [\"Phone\"]}, {\"name\": \"Desktop\", \"targets\": [\"Desktop\"]}]}",
        )
        .unwrap();

        let narrowed = inputs_for(&root, Scope::Ios).unwrap();
        assert!(
            narrowed.contains(&"Sources/Phone/P.swift".to_owned()),
            "the scope dropped what the app links: {narrowed:?}"
        );
        assert!(
            !narrowed.contains(&"Sources/Desktop/D.swift".to_owned()),
            "the spec-less sibling widened the scope back to the whole tree: {narrowed:?}"
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
