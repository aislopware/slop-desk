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
//! ## The paths are repo-RELATIVE
//! The shell fed `shasum` absolute paths, so the digest was a property of WHERE the tree was
//! checked out. Two checkouts of one commit stamped differently and each paid the eighty-five
//! seconds; a moved checkout invalidated a cache nothing about the code had touched.

use std::fs;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

/// The file extensions the two typecheck gates compile or read.
const COMPILED: &[&str] = &["swift", "yml", "plist", "metal", "h"];

/// The trees walked for [`COMPILED`] files.
const TREES: &[&str] = &["Sources", "Apps"];

/// The C surface, whose module maps have no extension worth matching on.
const FFI_TREE: &str = "ThirdParty/slopdesk-ffi";

/// The two files that decide WHICH sources the graph compiles.
const GRAPH: &[&str] = &["Package.swift", "Package.resolved"];

/// This gate's own source — the port's answer to the shell's `${SELF}`.
///
/// The gate's own logic is an input to its verdict: a stamp that survived an edit to the selection
/// rules would cache a verdict the new rules never reached. It is the `gates/` module tree and the
/// binary over it, not the whole crate — the release pipeline shares this crate and cannot change
/// what type-checks.
const SELF_TREES: &[&str] = &["rust/slopdesk-devtools/src/gates"];

/// This gate's own entry point.
const SELF_FILES: &[&str] = &["rust/slopdesk-devtools/src/bin/gate.rs"];

/// Every input path, repo-relative and sorted, exactly as the digest consumes them.
///
/// # Errors
/// When a tree in the set cannot be walked.
pub fn inputs(root: &Path) -> Result<Vec<String>, String> {
    let mut found: Vec<String> = Vec::new();
    for tree in TREES {
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
    for tree in SELF_TREES {
        walk(root, &root.join(tree), &mut found, &|path| {
            path.extension().and_then(|value| value.to_str()) == Some("rs")
        })?;
    }
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
    let mut outer = Sha256::new();
    for path in inputs(root)? {
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

/// Collect every file under `dir` that `keep` accepts, as a repo-relative path.
fn walk(root: &Path, dir: &Path, into: &mut Vec<String>, keep: &dyn Fn(&Path) -> bool) -> Result<(), String> {
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

    use super::{current, inputs, is_warm, record};

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
