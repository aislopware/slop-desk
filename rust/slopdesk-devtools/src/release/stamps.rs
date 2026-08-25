//! The content stamp of every shipped cargo tool, and the pin that records it.
//!
//! ## Why a stamp exists at all
//! Every sidecar in this tree runs as its own process with its own lifetime, and the expensive
//! ones outlive the release that installed them: superd holds the master fd of every live pane, so
//! restarting it costs the user every running agent (`docs/51`). Under one product version that
//! price was paid on EVERY upgrade — a one-line fix in the Android bridge and superd came down
//! with it, because nothing could tell that superd had not changed.
//!
//! This is what can tell. It hashes each tool's own sources, so "did this daemon change" is a
//! question with an answer, and [`super::bump`] turns that answer into a per-tool version that
//! only moves when the tool did. `MANIFEST.json` in the release tarball carries those versions,
//! and the install side restarts the daemons whose version moved and leaves the rest running.
//!
//! ## What is in a stamp, and why each part
//! * the crate's own `*.rs`, `Cargo.toml` and `Cargo.lock` — the code and the dependency pins;
//! * the same, transitively, for every LOCAL path dependency: a fix in `slopdesk-sanitize` is a
//!   change to screend and to superd, both of which link it, and to nothing else;
//! * for a ROOT-WORKSPACE tool, `rust/Cargo.toml` and `rust/Cargo.lock` on top — the release
//!   profile and the lint set live in the workspace, not in the member, and `opt-level = "z"`
//!   decides what the binary IS.
//!
//! Derived from the cargo graph rather than a hand-kept list, for the reason `slopdesk-gate ffi`
//! gives at length: a list beside the code is a second list to forget, and forgetting THIS one does
//! not fail loudly — it reports a changed daemon as unchanged, which is the one wrong answer that
//! silently skips the restart the change needed.
//!
//! ## What is deliberately NOT in a stamp
//! THIS CODE. `slopdesk-gate ffi` hashes itself because editing it changes the artifact it
//! produces; editing this changes no binary at all. Self-inclusion would make every tool look
//! changed on the day someone fixes a comment here, and every daemon would be restarted to ship
//! nothing. The toolchain version is absent for a weaker reason: it genuinely does change the
//! binary, but it changes EVERY binary at once, which is a product-version event and not a per-tool
//! one.
//!
//! ## One difference from the shell this replaces, on purpose
//! The shell fed `shasum` ABSOLUTE paths, and `shasum` prints the path beside the digest — so the
//! stamp depended on where the tree was checked out. Two machines with the same bytes computed
//! different stamps, which is precisely the "changed daemon reported unchanged" failure with the
//! sign flipped: a CI checkout at a different prefix would report every tool as changed, forever.
//! The digest here is over REPO-RELATIVE paths, so it is a property of the tree and nothing else.
//! `scripts/tool-stamps.pin` was re-seeded under the new digest in the same change; no version
//! moved, because no source did.

use std::collections::{BTreeSet, VecDeque};
use std::fmt::Write as _;
use std::fs;
use std::path::Path;

use sha2::{Digest, Sha256};

use super::tools;

/// The pin's path, repo-relative.
pub const PIN: &str = "scripts/tool-stamps.pin";

/// One tool's line in the pin, or one line of a fresh scan.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// The tool's binary name, which is the pin's key.
    pub tool: String,
    /// The version its crate declares — the source of truth, which the pin only records.
    pub version: String,
    /// The digest of its source closure.
    pub stamp: String,
}

/// Hex `SHA-256` of a byte string.
fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut hex = String::with_capacity(64);
    for byte in digest {
        let _ = write!(hex, "{byte:02x}");
    }
    hex
}

/// Every crate whose sources decide whether `tool`'s crate is stale.
///
/// The crate itself and, transitively, its local path dependencies — returned as `rust/<crate>`,
/// each at most once, in breadth-first discovery order.
///
/// The `path = "../x"` form is the only one this tree uses for a local dependency, and the scan
/// anchors on it. A dependency written any other way (a `[dependencies.x]` table, a registry
/// version) would go unseen — so a crate whose manifest cannot be read at all fails here rather
/// than hashing a partial closure.
///
/// # Errors
/// When a declared path dependency has no `Cargo.toml`, which means the cargo graph is broken.
pub fn crate_closure(root: &Path, crate_name: &str) -> Result<Vec<String>, String> {
    let mut seen: Vec<String> = Vec::new();
    let mut queue: VecDeque<String> = VecDeque::from([crate_name.to_owned()]);

    while let Some(name) = queue.pop_front() {
        if seen.contains(&name) {
            continue;
        }
        let manifest = root.join("rust").join(&name).join("Cargo.toml");
        let text = fs::read_to_string(&manifest).map_err(|_| {
            format!("{name} is a path dependency with no Cargo.toml — the cargo graph is broken")
        })?;
        seen.push(name);
        for dependency in path_dependencies(&text) {
            queue.push_back(dependency);
        }
    }

    Ok(seen.iter().map(|name| format!("rust/{name}")).collect())
}

/// The local path dependencies a manifest declares, in the one form this tree writes them.
fn path_dependencies(manifest: &str) -> Vec<String> {
    let mut found = Vec::new();
    for line in manifest.lines() {
        let Some((name, rest)) = line.split_once('=') else {
            continue;
        };
        let name = name.trim();
        if name.is_empty()
            || !name
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
        {
            continue;
        }
        // `{ path = "../x"` — the brace form, with the path FIRST, which is how every local
        // dependency in this tree is spelled.
        let rest = rest.trim_start();
        let Some(brace) = rest.strip_prefix('{') else {
            continue;
        };
        let brace = brace.trim_start();
        let Some(after_key) = brace.strip_prefix("path") else {
            continue;
        };
        let after_key = after_key.trim_start();
        let Some(value) = after_key.strip_prefix('=') else {
            continue;
        };
        let value = value.trim_start();
        let Some(quoted) = value.strip_prefix("\"../") else {
            continue;
        };
        let Some(target) = quoted.split('"').next() else {
            continue;
        };
        if !target.is_empty()
            && target
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
        {
            found.push(target.to_owned());
        }
    }
    found
}

/// Every file under `dir` that belongs in a stamp, repo-relative, unsorted.
///
/// `target` is PRUNED, and that is load-bearing rather than tidiness — `slopdesk-gate ffi` records
/// the whole story: build scripts write real `.rs` under `target/`, and a triple built for the
/// first time MINTS one, so an unpruned stamp would change as a consequence of being checked.
fn walk(root: &Path, dir: &Path, into: &mut Vec<String>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() {
            if name == "target" {
                continue;
            }
            walk(root, &path, into);
        } else if (name.ends_with(".rs") || name == "Cargo.toml" || name == "Cargo.lock")
            && let Ok(relative) = path.strip_prefix(root)
        {
            into.push(relative.to_string_lossy().into_owned());
        }
    }
}

/// The repo-relative files that make up `tool`'s stamp, sorted and de-duplicated.
///
/// # Errors
/// When `tool` is not a cargo tool, or its closure cannot be walked.
pub fn stamp_inputs(root: &Path, tool: &str) -> Result<Vec<String>, String> {
    let crate_name = tools::tool_crate(tool).ok_or_else(|| format!("{tool} is not a cargo tool"))?;
    let mut files = Vec::new();
    for directory in crate_closure(root, crate_name)? {
        walk(root, &root.join(&directory), &mut files);
    }
    // A root-workspace member inherits the profile and the lint set from `rust/Cargo.toml`, and
    // its dependency versions from the SHARED `rust/Cargo.lock` — neither of which sits under the
    // crate directory the walk above covers. A daemon needs no such addition: its workspace IS its
    // crate directory, so its own manifest and lock are already in the walk.
    if tools::is_root_tool(tool) {
        files.push("rust/Cargo.toml".to_owned());
        files.push("rust/Cargo.lock".to_owned());
    }
    files.sort_unstable();
    files.dedup();
    Ok(files)
}

/// The digest of `tool`'s source closure.
///
/// Sorted rather than walk-ordered so the answer is stable across machines and filesystems, and a
/// digest over the whole listing rather than per-file so a DELETED file changes the stamp too. The
/// file NAMES are part of the inner listing, so a rename is a change even when the bytes are not.
///
/// # Errors
/// When the closure cannot be resolved, or a file in it cannot be read.
pub fn stamp_of(root: &Path, tool: &str) -> Result<String, String> {
    let mut listing = String::new();
    for relative in stamp_inputs(root, tool)? {
        let bytes = fs::read(root.join(&relative)).map_err(|error| format!("{relative}: {error}"))?;
        let _ = writeln!(listing, "{}  {relative}", sha256_hex(&bytes));
    }
    Ok(sha256_hex(listing.as_bytes()))
}

/// The version `tool`'s crate declares today.
///
/// Anchored on the `[package]` table, not on the first `version =` in the file: a `[dependencies]`
/// entry three lines down is spelled the same way.
///
/// # Errors
/// When `tool` is not a cargo tool, or its manifest declares no package version.
pub fn declared_version(root: &Path, tool: &str) -> Result<String, String> {
    let crate_name = tools::tool_crate(tool).ok_or_else(|| format!("{tool} is not a cargo tool"))?;
    let manifest = root.join("rust").join(crate_name).join("Cargo.toml");
    let text = fs::read_to_string(&manifest).map_err(|error| format!("{}: {error}", manifest.display()))?;
    package_version(&text)
        .ok_or_else(|| format!("rust/{crate_name}/Cargo.toml declares no [package] version"))
}

/// The `version` of the `[package]` table in a manifest.
#[must_use]
pub fn package_version(manifest: &str) -> Option<String> {
    let mut in_package = false;
    for line in manifest.lines() {
        if line.starts_with("[package]") {
            in_package = true;
            continue;
        }
        if line.starts_with('[') {
            in_package = false;
            continue;
        }
        if in_package && line.starts_with("version") {
            let rest = line.split_once('=')?.1.trim();
            return rest.strip_prefix('"')?.split('"').next().map(str::to_owned);
        }
    }
    None
}

/// A fresh scan of every tool that carries a version of its OWN, in table order.
///
/// The PRODUCT pair is skipped, and `slopdesk` is skipped even though it is a cargo tool with a
/// readable `Cargo.toml` version: that number IS the product's (`docs/49` §"The six version
/// sites"), so pinning it here would make the bumper a second writer of it.
///
/// # Errors
/// When any tool's closure or manifest cannot be read.
pub fn scan(root: &Path) -> Result<Vec<Entry>, String> {
    tools::pinned_tools()
        .into_iter()
        .map(|tool| {
            Ok(Entry {
                tool: tool.to_owned(),
                version: declared_version(root, tool)?,
                stamp: stamp_of(root, tool)?,
            })
        })
        .collect()
}

/// The pin as it stands: its comment header, and one entry per tool.
#[derive(Debug, Clone, Default)]
pub struct Pin {
    /// The leading `#` lines, kept verbatim so a rewrite does not eat the prose.
    pub header: Vec<String>,
    /// What each tool was at the release that last shipped it.
    pub entries: Vec<Entry>,
}

impl Pin {
    /// Read the pin, or explain why it cannot be.
    ///
    /// # Errors
    /// When the file is missing or unreadable — a caller cannot decide what to bump without it.
    pub fn read(root: &Path) -> Result<Self, String> {
        let path = root.join(PIN);
        let text = fs::read_to_string(&path)
            .map_err(|_| format!("no {PIN} — seed it with `slopdesk-release stamps` under its header"))?;
        let mut pin = Self::default();
        let mut in_header = true;
        for line in text.lines() {
            if in_header && line.starts_with('#') {
                pin.header.push(line.to_owned());
                continue;
            }
            in_header = false;
            let mut fields = line.split_whitespace();
            let (Some(tool), Some(version), Some(stamp)) = (fields.next(), fields.next(), fields.next())
            else {
                continue;
            };
            pin.entries.push(Entry {
                tool: tool.to_owned(),
                version: version.to_owned(),
                stamp: stamp.to_owned(),
            });
        }
        Ok(pin)
    }

    /// What the pin recorded for `tool`, or nothing when it has never heard of it — which is how a
    /// NEW tool reads as changed on its first release.
    #[must_use]
    pub fn entry(&self, tool: &str) -> Option<&Entry> {
        self.entries.iter().find(|entry| entry.tool == tool)
    }

    /// Rewrite the pin from a fresh scan, under the header it already carries.
    ///
    /// # Errors
    /// When the file cannot be written.
    pub fn write(root: &Path, header: &[String], entries: &[Entry]) -> Result<(), String> {
        let mut text = String::new();
        for line in header {
            let _ = writeln!(text, "{line}");
        }
        for entry in entries {
            let _ = writeln!(text, "{} {} {}", entry.tool, entry.version, entry.stamp);
        }
        fs::write(root.join(PIN), text).map_err(|error| format!("{PIN}: {error}"))
    }
}

/// Every name the pin lists, for a caller that only needs the keys.
#[must_use]
pub fn pinned_names(pin: &Pin) -> BTreeSet<String> {
    pin.entries.iter().map(|entry| entry.tool.clone()).collect()
}

#[cfg(test)]
mod tests {
    use super::{package_version, path_dependencies, sha256_hex};

    /// The one vector every SHA-256 implementation is checked against.
    #[test]
    fn the_digest_is_sha256() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn a_local_path_dependency_is_seen_and_a_registry_one_is_not() {
        let manifest = "[dependencies]\nslopdesk-sanitize = { path = \"../slopdesk-sanitize\" \
                        }\nslopdesk_wire = { path = \"../slopdesk-wire\", features = [\"a\"] }\nregex = \
                        \"1\"\nserde = { version = \"1\", features = [\"derive\"] }\n";
        assert_eq!(path_dependencies(manifest), vec![
            "slopdesk-sanitize",
            "slopdesk-wire"
        ]);
    }

    /// The failure the `[package]` anchor exists to prevent: a dependency spelled the same way.
    #[test]
    fn the_package_version_is_not_a_dependencys() {
        let manifest =
            "[package]\nname = \"x\"\nversion = \"0.3.1\"\n\n[dependencies]\nversion = \"9.9.9\"\n";
        assert_eq!(package_version(manifest).as_deref(), Some("0.3.1"));
    }

    #[test]
    fn a_manifest_with_no_package_table_has_no_version() {
        assert_eq!(package_version("[workspace]\nmembers = []\n"), None);
    }
}
