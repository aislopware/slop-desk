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

/// Versioned by the PRODUCT version (`docs/49` §"The six version sites"), whoever builds them.
///
/// These two are the app the user installed; they do not carry a version of their own and must
/// not. A pin entry for either would be a seventh version site — so these are the names
/// `pinned_tools` subtracts, and WHO BUILDS THEM is a separate question from who versions them.
/// `slopdesk` is the proof that the two questions are separate: it moved to cargo when the CLI
/// process was ported out of Swift, and its number did not move with it.
pub const PRODUCT_TOOLS: &[&str] = &["slopdesk", "slopdesk-hostd"];

/// `rust/Cargo.toml`'s workspace members: ONE shared `rust/target/`, built with `-p` from `rust/`.
pub const RUST_ROOT_PACKAGES: &[&str] = &["slopdesk-cli", "slopdesk-ctl", "slopdesk-probe", "slopdesk-hook"];

/// The binaries those members produce.
///
/// `slopdesk-hook` is a package producing TWO of them — the relay and the installer that puts it
/// in place — and the installer finds the relay at `executable.parent()/slopdesk-hook`, so the two
/// must land in the same directory or the hook install silently has nothing to copy.
///
/// `slopdesk` is the other name that is not its own crate: `slopdesk-cli` builds it, and it is a
/// PRODUCT tool, so it is built and staged here and versioned nowhere near here.
pub const RUST_ROOT_TOOLS: &[&str] = &[
    "slopdesk",
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
///
/// `slopdesk-hostd` heads the list because it is not a daemon like the others — it is the app's own
/// process, and it was the last name in `SPM_TOOLS` until `docs/60` stage F. That constant is gone
/// rather than empty: an empty `SwiftPM` half would have kept a `swift build` loop, a
/// `--show-bin-path` probe and a fallback search alive in the packager for a set with nothing in
/// it.
pub const RUST_CRATE_TOOLS: &[&str] = &[
    "slopdesk-hostd",
    "slopdesk-superd",
    "slopdesk-screend",
    "slopdesk-dropd",
    "slopdesk-inspectord",
    "slopdesk-androidd",
    "slopdesk-codeseed",
    // The GUI video host (`docs/61`). Last, because it was the last to ship: it lived in a
    // checkout only until 2026-09-02, while the client's remote-window pane dialled its ports on
    // every `brew install` and waited for a hello nobody would answer (`docs/70` §2b).
    "slopdesk-videohostd",
];

/// Every cargo-built tool, root members first, in declaration order.
#[must_use]
pub fn rust_tools() -> Vec<&'static str> {
    let mut all = RUST_ROOT_TOOLS.to_vec();
    all.extend_from_slice(RUST_CRATE_TOOLS);
    all
}

/// Every cargo tool that carries a version of its OWN — the whole of the pin, and nothing else.
///
/// The subtraction is the seventh-site guard, and it is done here rather than at each reader
/// because there are three of them: the stamper writes the pin from this, the bumper plans from
/// the stamper's scan, and the packager checks each staged binary against the pin. A product tool
/// reaching any one of them is a second writer of the product's number.
#[must_use]
pub fn pinned_tools() -> Vec<&'static str> {
    rust_tools()
        .into_iter()
        .filter(|tool| !PRODUCT_TOOLS.contains(tool))
        .collect()
}

/// Everything the CLI tarball ships.
///
/// One half now. It was two — `SwiftPM` first, then cargo — until stage F moved the last `SwiftPM`
/// name; the function stays because four readers ask it what the tarball is, and folding it into
/// [`rust_tools`] at each of them would be four places to notice a future third half.
#[must_use]
pub fn cli_tools() -> Vec<&'static str> {
    rust_tools()
}

/// True when `tool`'s version IS the product's — so it has no pin entry and no stamp.
#[must_use]
pub fn is_product(tool: &str) -> bool {
    PRODUCT_TOOLS.contains(&tool)
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
    // The other name that is not its own crate: a package named for the product would collide with
    // the product's own directory, so the binary is `slopdesk` and the package is `slopdesk-cli`.
    if tool == "slopdesk" {
        return Some("slopdesk-cli");
    }
    RUST_ROOT_TOOLS
        .iter()
        .chain(RUST_CRATE_TOOLS)
        .find(|candidate| ***candidate == *tool)
        .copied()
}

#[cfg(test)]
mod tests {
    use super::{
        PRODUCT_TOOLS, cli_tools, is_crate_tool, is_root_tool, pinned_tools, rust_tools, tool_crate,
    };

    #[test]
    fn the_hook_installer_rides_the_relays_crate() {
        assert_eq!(tool_crate("slopdesk-agenthooks"), Some("slopdesk-hook"));
        assert_eq!(tool_crate("slopdesk-hook"), Some("slopdesk-hook"));
    }

    /// The product binary is cargo's now; the crate it comes from is not named for it.
    ///
    /// The host is the other way round — it IS named for its crate, because the crate came second
    /// and took the binary's name.
    #[test]
    fn the_product_binary_rides_the_cli_crate() {
        assert_eq!(tool_crate("slopdesk"), Some("slopdesk-cli"));
        assert_eq!(tool_crate("slopdesk-hostd"), Some("slopdesk-hostd"));
    }

    /// THE seventh-site guard: a product tool never reaches the pin, whoever builds it.
    ///
    /// `slopdesk` is a cargo tool AND a product tool, which is the case the two tables did not have
    /// to tell apart while it was Swift's. The stamper, the bumper and the packager all read
    /// `pinned_tools`, so this one assertion covers all three.
    #[test]
    fn a_product_tool_is_never_pinned() {
        let pinned = pinned_tools();
        for tool in PRODUCT_TOOLS {
            assert!(!pinned.contains(tool), "{tool} would be a seventh version site");
        }
        assert!(pinned.contains(&"slopdesk-ctl"));
        assert_eq!(
            pinned.len(),
            rust_tools().len() - PRODUCT_TOOLS.len(),
            "both product tools are cargo's since stage F, and neither may be pinned"
        );
    }

    /// Who builds a tool and who versions it are separate questions.
    ///
    /// Both product tools are cargo's now, and they still build from DIFFERENT places: the CLI is a
    /// root workspace member, the host is its own workspace. A test that only checked "is it cargo"
    /// would pass against a table that had lost that distinction, and the packager would then look
    /// for the host's binary in `rust/target/`, where nothing writes it.
    #[test]
    fn the_product_pair_is_cargos_but_not_from_the_same_workspace() {
        assert!(is_root_tool("slopdesk"));
        assert!(!is_crate_tool("slopdesk"));
        assert!(is_crate_tool("slopdesk-hostd"));
        assert!(!is_root_tool("slopdesk-hostd"));
    }

    /// The tarball is cargo's whole tool set and nothing else, with no name repeated.
    #[test]
    fn the_tarball_is_every_cargo_tool_once() {
        let all = cli_tools();
        assert_eq!(all.len(), rust_tools().len());
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
