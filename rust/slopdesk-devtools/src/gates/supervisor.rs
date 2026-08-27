//! The half of the hostd↔superd contract that needs a toolchain.
//!
//! Every CONSTANT in that contract is compared textually by `slopdesk-invariants`, which reads the
//! tree once and needs neither a build nor a daemon. This is the other half: the five sidecar
//! suites and the Swift tests that drive a real one. It is behind its own verb for the reason it
//! was behind a `--tests` flag in the shell — the constant comparison is the part worth running on
//! every commit, and this part costs a build.
//!
//! Nothing here decides anything. The suites decide; this names them, in one place, so that "the
//! tests that need a live daemon" is a list with an owner rather than a habit.

use std::path::Path;

use crate::proc;

/// The sidecars whose own suites run here, in dependency order.
///
/// The SOCKET cases in `slopdesk-androidd` need a booted device and are gated on
/// `SLOPDESK_ANDROID_HW=1` (`slopdesk-gate android`); without it they print why they proved nothing
/// and pass.
const SIDECARS: [&str; 5] = [
    "slopdesk-superd",
    "slopdesk-screend",
    "slopdesk-dropd",
    "slopdesk-androidd",
    "slopdesk-inspectord",
];

/// The Swift suites that spawn a real daemon rather than a fake.
///
/// A cross-language mirror fixture is banned (`CLAUDE.md`, one implementation), so the only way to
/// assert that hostd and a sidecar agree at run time is to run both — which is why these cannot
/// live in the fast suite and why they are named rather than pattern-matched.
const SWIFT_SUITES: [&str; 12] = [
    "SupervisedPaneSurvivalTests",
    "SupervisedServiceProcessTests",
    "PTYProcessTests",
    "HostRestartSurvivalTests",
    "SupervisorProtocolTests",
    "AgentSupervisionIntegrationTests",
    "PaneOutputStreamTests",
    "PaneScreenScanner",
    "DropdE2ETests",
    "FileDropServiceManagerTests",
    "AndroidServiceManagerTests",
    "InspectorServiceManagerTests",
];

/// The sidecar binaries the Swift suites launch, built before the suites ask for them.
const SIDECAR_RECIPES: [&str; 5] = ["superd", "screend", "dropd", "androidd", "inspectord"];

/// Run every suite that needs a toolchain.
///
/// # Errors
/// The first suite that fails, named — a later suite proves nothing about a contract an earlier one
/// already showed broken.
pub fn run(root: &Path) -> Result<(), String> {
    for sidecar in SIDECARS {
        proc::step(&format!("cargo test ({sidecar})"));
        proc::run("cargo", &["test", "--quiet"], &root.join("rust").join(sidecar))
            .map_err(|why| format!("supervisor-tests: FAIL — {sidecar}: {why}"))?;
    }

    proc::step("the sidecar binaries the Swift suites launch");
    proc::run("just", &SIDECAR_RECIPES, root)
        .map_err(|why| format!("supervisor-tests: FAIL — just sidecars: {why}"))?;

    proc::step("the Swift suites that drive a real daemon");
    let filter = SWIFT_SUITES.join("|");
    proc::run("swift", &["test", "--filter", &filter], root)
        .map_err(|why| format!("supervisor-tests: FAIL — swift test: {why}"))?;

    println!("supervisor-tests: OK");
    Ok(())
}
