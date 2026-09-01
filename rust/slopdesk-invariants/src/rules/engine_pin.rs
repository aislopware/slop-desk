//! The terminal engine's source is pinned once, and read at that pin.
//!
//! `libghostty-vt-sys`'s `build.rs` compiles ghostty with Zig at build time and, left to itself,
//! CLONES it from the network to do so. `docs/68` §3 V2 rules that out — a build-time fetch is
//! incompatible with the content-stamped gates and with a reproducible release — so the fetch was
//! taken away from it: `ThirdParty/tools/tools.lock` pins the commit, `just provision` materialises
//! the tree, and `rust/.cargo/config.toml` exports `GHOSTTY_SOURCE_DIR` at it, which `build.rs`
//! honours by short-circuiting its own clone entirely.
//!
//! ## Why that needs a ratchet
//!
//! The arrangement works only while the two files AGREE, and nothing else makes them. Bump the lock
//! and the config still points at the old directory: `just provision` fetches the new tree, the old
//! one is still on disk from the previous run, and every build keeps compiling the OLD ghostty with
//! the NEW bindings. Nothing fails — the directory exists, `build.zig` is in it, the link succeeds
//! — and the symptom is a Rust surface calling into a library that was generated from different
//! sources. That is the same failure shape `slopdesk-gate ffi --check` exists for, one layer down,
//! and it is invisible to every other gate here.
//!
//! The other direction is louder but not loud enough: a config pointing at a version the lock does
//! not name is a directory `just provision` will never create, so the build fails with a Zig error
//! about a missing `build.zig` rather than with the one sentence that explains it.

use std::fs;
use std::path::Path;

use crate::report::Report;
use crate::tree::Tree;

/// The lock record this rule is about.
const PIN: &str = "ghostty";

/// The variable `libghostty-vt-sys`'s `build.rs` reads to skip its own clone.
const VAR: &str = "GHOSTTY_SOURCE_DIR";

/// The committed config that exports it.
const CONFIG: &str = "rust/.cargo/config.toml";

/// The pin file.
const LOCK: &str = "ThirdParty/tools/tools.lock";

/// The engine source pin and the path the build reads it from name the same version
///
/// See the module note: they are two files nothing else keeps in step, and the failure when they
/// drift is a successful build of the wrong sources.
#[must_use]
pub fn the_engine_source_is_read_at_its_pin(tree: &Tree) -> Report {
    let mut report = Report::new();
    let root = tree.root();

    let Some(pinned) = locked_version(root) else {
        report.fail(format!(
            "{LOCK} has no `{PIN}` record — the terminal engine's source is what `GHOSTTY_SOURCE_DIR` \
             points at, and an unpinned one is a build-time clone from the network (docs/68 §3 V2)"
        ));
        return report;
    };

    let Ok(config) = fs::read_to_string(root.join(CONFIG)) else {
        report.fail(format!(
            "{CONFIG} is not readable — {VAR} cannot be checked against {LOCK}"
        ));
        return report;
    };
    let Some(exported) = exported_version(&config) else {
        report.fail(format!(
            "{CONFIG} does not export {VAR} under `.prefix/{PIN}/<version>` — without it \
             `libghostty-vt-sys`'s build.rs clones ghostty at build time, which the content stamps cannot \
             see (docs/68 §3 V2)"
        ));
        return report;
    };

    if exported != pinned {
        report.fail(format!(
            "{CONFIG} exports {VAR} at `{exported}` but {LOCK} pins {PIN} at `{pinned}` — the build would \
             compile the version still on disk from an earlier provision while the bindings were generated \
             against the pinned one, and nothing else fails when it does (docs/68 §3 V2)"
        ));
    }
    report
}

/// The `version` field of the `git` record named [`PIN`], if the lock has one.
///
/// Parsed positionally rather than with the provisioner's own parser: this crate deliberately
/// depends on nothing it checks, so a rule cannot be satisfied by the same bug it is looking for.
fn locked_version(root: &Path) -> Option<String> {
    let text = fs::read_to_string(root.join(LOCK)).ok()?;
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .find_map(|line| {
            let mut fields = line.split('|').map(str::trim);
            (fields.next()? == PIN).then(|| fields.next().map(str::to_owned))?
        })
}

/// The `<version>` segment of the `.prefix/<PIN>/<version>` path the config exports.
///
/// Read out of the path rather than off a separate key, because the path IS the coupling: the
/// build reads a directory, and the directory's name is the version.
fn exported_version(config: &str) -> Option<String> {
    let marker = format!(".prefix/{PIN}/");
    config.lines().find_map(|line| {
        let line = line.trim();
        if !line.starts_with(VAR) {
            return None;
        }
        let tail = line.split_once(&marker)?.1;
        let version: String = tail
            .chars()
            .take_while(|character| {
                character.is_ascii_alphanumeric() || *character == '.' || *character == '-'
            })
            .collect();
        (!version.is_empty()).then_some(version)
    })
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The real arrangement: a `git` record, and a config exporting the same version.
    ///
    /// ⚠️ `name` is the TEST's, not the versions'. These run concurrently against a temp tree keyed
    /// by that name, and three of the cases below want the same pair of versions — sharing a
    /// fixture would let the test that empties the lock do it under the two that read it.
    fn wires(name: &str, version_in_lock: &str, version_in_config: &str) -> Fixture {
        let fixture = Fixture::new(name);
        fixture.write(
            super::LOCK,
            &format!(
                "# prose\n\ncode-server|4.135.0|tar.gz|bin/code-server|https://e.invalid/c.tar.gz|{}\n\
                 ghostty|{version_in_lock}|git|build.zig|https://e.invalid/g.git|{}\n",
                "a".repeat(64),
                "b".repeat(40),
            ),
        );
        fixture.write(
            super::CONFIG,
            &format!(
                "[build]\ntarget-dir = \"../../slopdesk-targets/_workspace\"\n\n[env]\nGHOSTTY_SOURCE_DIR = \
                 {{ value = \"../ThirdParty/tools/.prefix/ghostty/{version_in_config}\", relative = true \
                 }}\n"
            ),
        );
        fixture
    }

    #[test]
    fn a_config_reading_the_pinned_version_is_clean() {
        let fixture = wires("engine-pin-agree", "22d13172", "22d13172");
        let report = super::the_engine_source_is_read_at_its_pin(&fixture.tree());
        assert!(report.is_clean(), "{report:?}");
    }

    /// The silent one: the lock is bumped, the config is not, and the previous provision's tree is
    /// still on disk — so the build succeeds against the WRONG sources.
    #[test]
    fn a_lock_bumped_without_the_config_is_caught() {
        let fixture = wires("engine-pin-drift", "9f00ba11", "22d13172");
        let report = super::the_engine_source_is_read_at_its_pin(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("9f00ba11") && violation.contains("22d13172")),
            "{report:?}"
        );
    }

    /// A config that exports nothing at all lets `build.rs` fall back to its own network clone.
    #[test]
    fn a_config_that_exports_nothing_is_caught() {
        let fixture = wires("engine-pin-no-export", "22d13172", "22d13172");
        fixture.write(
            super::CONFIG,
            "[build]\ntarget-dir = \"../../slopdesk-targets/_workspace\"\n",
        );
        let report = super::the_engine_source_is_read_at_its_pin(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("does not export")),
            "{report:?}"
        );
    }

    /// An unpinned engine is the state this whole arrangement replaced.
    #[test]
    fn a_lock_without_the_record_is_caught() {
        let fixture = wires("engine-pin-no-record", "22d13172", "22d13172");
        fixture.write(super::LOCK, "# nothing but prose\n");
        let report = super::the_engine_source_is_read_at_its_pin(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("no `ghostty` record")),
            "{report:?}"
        );
    }
}
