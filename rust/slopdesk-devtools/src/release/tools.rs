//! The shipped tool set, and the crate each tool is built from.
//!
//! ## Why this is one table and not four lists
//! These arrays used to be `shipped-tools.sh`, a file that existed only to be `source`d, because
//! four readers needed the same set: the packager to build and stage, the stamper to hash each
//! tool's sources, the bumper to decide which versions may move, and `slopdesk-invariants` to
//! prove the host resolves no sidecar the release omits. Four readers of one list is three
//! chances for a seventh daemon to be added to some of them.
//!
//! Three of those readers are now this crate's own modules and reach the table directly. The
//! fourth reads it as TEXT — a gate cannot link a crate it judges — so the arrays below are
//! written in one flat shape it can parse, and the commentary stays outside them.
//!
//! ## The tarball used to be three binaries
//! …and that was a host that could not open a pane. superd forks and owns every PTY master
//! (`docs/51`), and `HostServiceSupervisor.connected()` puts the consequence in one line: "hostd
//! does not fork, so there is no fallback to have". The other five daemons each cost a feature
//! outright — no screen engine, no file drop, no inspector, no Android panel, no profile seed.
//! None of them shipped, because the release path is exercised by tagging and no gate is a
//! release.

/// Built by `SwiftPM`, versioned by the PRODUCT version (`docs/49` §"The six version sites").
///
/// These two are the app the user installed; they do not carry a version of their own and must
/// not. A pin entry for either would be a seventh version site.
pub const SPM_TOOLS: &[&str] = &["slopdesk", "slopdesk-hostd"];

/// `rust/Cargo.toml`'s workspace members: ONE shared `rust/target/`, built with `-p` from `rust/`.
pub const RUST_ROOT_PACKAGES: &[&str] = &["slopdesk-ctl", "slopdesk-probe", "slopdesk-hook"];

/// The binaries those members produce.
///
/// `slopdesk-hook` is a package producing TWO of them — the relay and the installer that puts it
/// in place — and the installer finds the relay at `executable.parent()/slopdesk-hook`, so the two
/// must land in the same directory or the hook install silently has nothing to copy.
pub const RUST_ROOT_TOOLS: &[&str] = &[
    "slopdesk-ctl",
    "slopdesk-probe",
    "slopdesk-hook",
    "slopdesk-agenthooks",
];

/// The daemons.
///
/// Each is `exclude`d from the root workspace and carries its own, so each builds from its own
/// directory into its own `rust/<crate>/target/` — the same seam `RustServicePaths.locate` walks.
/// Building these with `-p` from `rust/` fails: cargo cannot see a package it excluded.
pub const RUST_CRATE_TOOLS: &[&str] = &[
    "slopdesk-superd",
    "slopdesk-screend",
    "slopdesk-dropd",
    "slopdesk-inspectord",
    "slopdesk-androidd",
    "slopdesk-codeseed",
];

/// Every cargo-built tool, root members first, in declaration order.
#[must_use]
pub fn rust_tools() -> Vec<&'static str> {
    let mut all = RUST_ROOT_TOOLS.to_vec();
    all.extend_from_slice(RUST_CRATE_TOOLS);
    all
}

/// Everything the CLI tarball ships, `SwiftPM` half first.
#[must_use]
pub fn cli_tools() -> Vec<&'static str> {
    let mut all = SPM_TOOLS.to_vec();
    all.extend(rust_tools());
    all
}

/// True when `tool` is one of the two the product version covers.
#[must_use]
pub fn is_spm(tool: &str) -> bool {
    SPM_TOOLS.contains(&tool)
}

/// True when `tool` builds into the shared `rust/target/`.
#[must_use]
pub fn is_root_tool(tool: &str) -> bool {
    RUST_ROOT_TOOLS.contains(&tool)
}

/// True when `tool` is a daemon with its own workspace and its own `target/`.
#[must_use]
pub fn is_crate_tool(tool: &str) -> bool {
    RUST_CRATE_TOOLS.contains(&tool)
}

/// The crate directory under `rust/` that builds `tool`, or `None` when it is not a cargo tool.
///
/// Every name is its own crate EXCEPT the hook installer, which rides the relay's package — so the
/// two share a version and a source stamp, and that is correct rather than a rounding error: they
/// are one crate's two binaries and they ship or go stale together.
#[must_use]
pub fn tool_crate(tool: &str) -> Option<&'static str> {
    if tool == "slopdesk-agenthooks" {
        return Some("slopdesk-hook");
    }
    RUST_ROOT_TOOLS
        .iter()
        .chain(RUST_CRATE_TOOLS)
        .find(|candidate| ***candidate == *tool)
        .copied()
}

#[cfg(test)]
mod tests {
    use super::{cli_tools, is_root_tool, rust_tools, tool_crate};

    #[test]
    fn the_hook_installer_rides_the_relays_crate() {
        assert_eq!(tool_crate("slopdesk-agenthooks"), Some("slopdesk-hook"));
        assert_eq!(tool_crate("slopdesk-hook"), Some("slopdesk-hook"));
    }

    #[test]
    fn the_product_pair_is_not_a_cargo_tool() {
        assert_eq!(tool_crate("slopdesk"), None);
        assert_eq!(tool_crate("slopdesk-hostd"), None);
    }

    /// The tarball is the two halves and nothing else, with no name repeated.
    #[test]
    fn the_tarball_is_the_two_halves() {
        let all = cli_tools();
        assert_eq!(all.len(), 2 + rust_tools().len());
        let mut sorted = all.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), all.len(), "a tool is listed twice: {all:?}");
    }

    #[test]
    fn a_daemon_is_not_a_root_member() {
        assert!(is_root_tool("slopdesk-ctl"));
        assert!(!is_root_tool("slopdesk-superd"));
    }
}
