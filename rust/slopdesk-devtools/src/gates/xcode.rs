//! The three gates that need `xcodebuild`, and the one that needs a simulator.
//!
//! ## The hole each one closes
//! `swift build` compiles `Sources/` and `Tests/`, on macOS, for the macOS slice. That leaves three
//! surfaces nothing headless ever compiled:
//!
//! * the `#if os(iOS)` sources — the `UIKit` input host and the iOS components in
//!   `Sources/SlopDeskPhoneUI/iOS/`. They compiled only in someone's head and rotted silently, so
//!   [`ios_typecheck`] builds the iOS-Simulator app, which links the phone package and forces the
//!   whole fork through the compiler.
//! * the two macOS app SHELLS. They are Xcode targets, not `SwiftPM` ones. The video carve renamed
//!   `VideoSurfaceHost` to `MacVideoSurfaceHost`, updated the `@retroactive` conformance 98 lines
//!   below the call site, and missed the call site itself — `swift build`, `swift test`, `just
//!   lint`, the ratchet and the iOS triple were ALL green over a client shell that could not
//!   compile. [`macos_apps_typecheck`] is the only thing that compiles them.
//! * the iOS triple's ASSERTIONS. `swift test` compiles the MACOS branch of every `#if os(iOS)`
//!   fork, so an iOS default asserted there is asserted about the wrong branch — a macOS build of
//!   `platformDefaultFollowSessionFocus` reads the opposite value. [`ios_tests`] is the only thing
//!   in the tree that executes an assertion on that triple.
//!
//! ## Why `ios_tests` hands the bundle to `xctest` by hand
//! `xcodebuild test` must ENUMERATE simulator devices through DVT, and on a machine whose /Library
//! `CoreSimulator` package is older than the installed Xcode expects, DVT refuses the whole device
//! list and offers only the generic placeholder. Installing that package needs admin rights a CI or
//! agent run does not have. `simctl` is unaffected, so the build targets the GENERIC destination
//! (which DVT allows) and the bundle goes to the simulator's own `xctest` agent. That is also why
//! the bundle is host-less: no app and no window server, so `xctest` can load it directly.
//!
//! ## `-derivedDataPath` under `.build/`
//! Rather than the shared `~/Library/Developer/Xcode/DerivedData`: each gate's cache is then wiped
//! with the rest of `.build/`'s derived state, and Xcode.app working on the same project
//! cannot evict it out from under the stamp.

#![expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "the build steps and the xcodebuild failure are this gate's report"
)]

use std::fs;
use std::path::Path;
use std::process::Command;

use regex::Regex;

use super::{code_text, stamp};
use crate::proc;

/// The iOS gate's cached verdict.
const IOS_STAMP: &str = ".build/check-ios.sha256";

/// The iOS TEST BUNDLE build's cached verdict, which is a second stamp over the SAME inputs.
///
/// Two stamps rather than one because the two builds now run at different rates: the app build is
/// in `quick`, the bundle build only in `check`. One stamp would let a `quick` that ran the app
/// build record "iOS inputs checked" and let the pre-push `check` skip the bundle it never built.
const IOS_TESTS_STAMP: &str = ".build/check-ios-bundle.sha256";

/// The macOS app-shell gate's cached verdict.
const MACOS_STAMP: &str = ".build/check-macos-apps.sha256";

/// The iOS app spec and the project it generates.
const IOS_SPEC: &str = "Apps/ClientApp-iOS/project.yml";
const IOS_PROJECT: &str = "Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj";

/// The macOS shells. One, since `docs/60` F.9 deleted the menu-bar host app: the host is driven
/// from the CLI and has no shell to build. A slice rather than a scalar because the gate's shape —
/// generate each spec, build each project — is the same for one as for two, and a second client
/// shell is a plausible thing to add.
const MACOS_APPS: &[&str] = &["ClientApp-macOS"];

/// Refuse early and by name rather than ten minutes into a build.
fn need_xcodegen() -> Result<(), String> {
    if proc::on_path("xcodegen") {
        Ok(())
    } else {
        Err("xcodegen not found on PATH (install: brew install xcodegen)".to_owned())
    }
}

/// Regenerate a project from its committed spec.
///
/// The `.xcodeproj` is gitignored and derived; `project.yml` is the source of truth. A stale
/// checkout would otherwise compile `AppMain.swift` against an outdated source list and fail with
/// "cannot find … in scope".
fn generate(root: &Path, spec: &str) -> Result<(), String> {
    println!("==> xcodegen generate --spec {spec}");
    proc::run("xcodegen", &["generate", "--spec", spec, "--quiet"], root)
}

/// The iOS-triple typecheck, cached against [`stamp`].
///
/// The LIBRARY scheme's removal was measured rather than assumed: the app target's own dependency
/// dump showed `SlopDeskPhoneUI` as an explicit dependency, so that scheme's graph was a strict
/// SUBSET that compiled nothing the first had not — for ~85 s on every Swift edit. The one thing it
/// would have caught, the app spec dropping that dependency, cannot happen quietly: the app does
/// not build without it.
///
/// ⚠️ THE TEST BUNDLE USED TO BUILD HERE TOO, AND IT COST 25 MINUTES A KEYSTROKE. It is
/// [`ios_test_bundle_build`] now, in `check` rather than in `quick` — see that function for the
/// measurement and for why the two builds cannot share their compiled modules.
///
/// # Errors
/// When xcodegen is absent, the build fails, or the stamp cannot be written.
pub fn ios_typecheck(root: &Path, force: bool) -> Result<(), String> {
    let want = stamp::current_for(root, stamp::Scope::Ios)?;
    if !force && stamp::is_warm(&root.join(IOS_STAMP), &want) {
        println!("==> iOS typecheck OK (cached — no iOS-compiled input changed)");
        return Ok(());
    }
    need_xcodegen()?;
    generate(root, IOS_SPEC)?;

    println!("==> iOS-triple build: ClientApp-iOS");
    proc::run(
        "xcodebuild",
        &[
            "-project",
            IOS_PROJECT,
            "-scheme",
            "ClientApp-iOS",
            "-destination",
            "generic/platform=iOS Simulator",
            "-derivedDataPath",
            ".build/ios-dd",
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        root,
    )?;

    // Recomputed rather than reused: xcodegen rewrote the .xcodeproj above, and a source edited
    // while the build ran must not be recorded as checked.
    stamp::record(
        &root.join(IOS_STAMP),
        &stamp::current_for(root, stamp::Scope::Ios)?,
    )?;
    println!("==> iOS typecheck OK");
    Ok(())
}

/// The iOS TEST BUNDLE compiles — the half of the iOS gate that is not in the inner loop.
///
/// `Apps/ClientApp-iOS/Tests` is a strict SUPERSET of what any other gate compiles: `swift build`
/// never sees `Apps/`, and `swift test` compiles the macOS branch of every `#if os(iOS)` fork. Left
/// uncompiled it went unbuildable for weeks with every gate green, which is the same hole
/// `check-macos-apps` closes on the other shell. So it must be built by something; the question
/// this function answers differently from its predecessor is HOW OFTEN.
///
/// ## ⚠️ IT IS NOT IN `quick`, AND THE REASON IS A MEASUREMENT
///
/// This ran inside [`ios_typecheck`] until 2026-08-30, which put it in `quick` — after every edit.
/// A `quick` whose iOS stamp missed took **41 minutes**, of which this build alone was **25+**, at
/// 94% of ONE core out of ten. The stamp covers the closure of the products the iOS spec names, so
/// the miss is not exotic: editing `SlopDeskWorkspaceCore`, `SlopDeskClientCore`, `SlopDeskPhoneUI`
/// or the FFI header — most of the tree — pays it. Warm, `quick` is 72 seconds.
///
/// The predecessor's doc asserted the second build "compiles the test sources and links — not the
/// app graph again". That was wrong, and the spec says why: the bundle carries
/// `SWIFT_ENABLE_TESTABILITY: YES` and the app target does not, so the two are different build
/// configurations and NOTHING is shared. Five of the seven test files `@testable import`, so the
/// setting is not removable either — the second compile of the package graph is the price of the
/// bundle existing, and the only lever left is its RATE.
///
/// Hence `check` and not `quick`: the protection is unchanged before a push, where a 25-minute
/// build is one cost against a whole branch rather than against one keystroke. Its own stamp
/// ([`IOS_TESTS_STAMP`]) is what keeps that honest — see the note there.
///
/// RUNNING these assertions still needs a booted simulator and stays in `check-ios-tests`, out of
/// `check` entirely.
///
/// # Errors
/// When xcodegen is absent, the build fails, or the stamp cannot be written.
pub fn ios_test_bundle_build(root: &Path, force: bool) -> Result<(), String> {
    let want = stamp::current_for(root, stamp::Scope::Ios)?;
    if !force && stamp::is_warm(&root.join(IOS_TESTS_STAMP), &want) {
        println!("==> iOS test bundle OK (cached — no iOS-compiled input changed)");
        return Ok(());
    }
    need_xcodegen()?;
    generate(root, IOS_SPEC)?;

    println!("==> iOS-triple build-for-testing: ClientApp-iOSTests");
    proc::run(
        "xcodebuild",
        &[
            "-project",
            IOS_PROJECT,
            "-scheme",
            "ClientApp-iOSTests",
            "-destination",
            "generic/platform=iOS Simulator",
            "-derivedDataPath",
            ".build/ios-dd",
            "CODE_SIGNING_ALLOWED=NO",
            "build-for-testing",
        ],
        root,
    )?;

    // Recomputed rather than reused, for [`ios_typecheck`]'s reason.
    stamp::record(
        &root.join(IOS_TESTS_STAMP),
        &stamp::current_for(root, stamp::Scope::Ios)?,
    )?;
    println!("==> iOS test bundle OK");
    Ok(())
}

/// The macOS app-shell typecheck, cached against what THESE two shells compile.
///
/// Narrowed to the closure of the products their specs name, never to `Apps/` alone: a change under
/// `Sources/` can break a shell's call site without touching `Apps/` at all, which is exactly the
/// bug this exists for. What the narrowing does drop is the phone: `SlopDeskPhoneUI` is in neither
/// macOS shell's closure, so an iOS-only edit no longer costs two macOS builds.
///
/// # Errors
/// When xcodegen is absent, either build fails, or the stamp cannot be written.
pub fn macos_apps_typecheck(root: &Path, force: bool) -> Result<(), String> {
    let want = stamp::current_for(root, stamp::Scope::MacosApps)?;
    if !force && stamp::is_warm(&root.join(MACOS_STAMP), &want) {
        println!("==> macOS app typecheck OK (cached — no compiled input changed)");
        return Ok(());
    }
    need_xcodegen()?;

    for app in MACOS_APPS {
        generate(root, &format!("Apps/{app}/project.yml"))?;
        println!("==> macOS build: {app}");
        proc::run(
            "xcodebuild",
            &[
                "-project",
                &format!("Apps/{app}/{app}.xcodeproj"),
                "-scheme",
                app,
                "-destination",
                "platform=macOS,arch=arm64",
                "-derivedDataPath",
                ".build/macos-apps-dd",
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
            root,
        )?;
    }

    stamp::record(
        &root.join(MACOS_STAMP),
        &stamp::current_for(root, stamp::Scope::MacosApps)?,
    )?;
    println!("==> macOS app typecheck OK");
    Ok(())
}

/// How `ios_tests` was asked to run.
#[derive(Debug, Clone)]
pub struct SimulatorRequest {
    /// The device to boot, by name.
    pub device: String,
    /// Leave a simulator this gate booted running afterwards.
    pub keep_booted: bool,
}

impl Default for SimulatorRequest {
    fn default() -> Self {
        Self {
            device: "iPhone 17 Pro".to_owned(),
            keep_booted: false,
        }
    }
}

/// The UDID of an available iOS simulator with this name.
///
/// `simctl list` prints an "Install Failed: Authorization is required" line on a machine whose
/// `CoreSimulator` package is out of date. That is about INSTALLING a newer package, not about the
/// devices — they are listed and bootable regardless — so reading the JSON keeps the noise out.
///
/// # Errors
/// When `simctl` cannot be run or answers something that is not the expected document.
pub fn simulator_udid(json: &str, device: &str) -> Result<String, String> {
    let document: serde_json::Value = serde_json::from_str(json).map_err(|error| error.to_string())?;
    let runtimes = document
        .get("devices")
        .and_then(serde_json::Value::as_object)
        .ok_or_else(|| "simctl: no `devices` map".to_owned())?;
    let mut names: Vec<&String> = runtimes.keys().collect();
    names.sort_unstable();
    for runtime in names {
        if !runtime.contains("iOS") {
            continue;
        }
        let listed = runtimes[runtime]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or_default();
        for entry in listed {
            if entry.get("name").and_then(serde_json::Value::as_str) == Some(device) {
                return entry
                    .get("udid")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned)
                    .ok_or_else(|| format!("simctl: {device} has no udid"));
            }
        }
    }
    Err(format!("no available iOS simulator named '{device}'"))
}

/// How many `func test…` the committed iOS sources declare.
///
/// Derived rather than hardcoded, because a hardcoded number is a second thing to keep in step and
/// the day it drifted this gate would fail on an honest new test.
///
/// It counts declarations in CODE. A commented-out `func test…` is not one, and the direction that
/// used to be safe was still wrong: reading the source verbatim inflated the count and redded a run
/// the simulator had passed. That was left standing while the honest fix meant hand-rolling a
/// second `//` filter here — the duplication the census in [`super`] exists to refuse — and it
/// stopped meaning that when [`code_text`](super::code_text) landed in this directory.
///
/// # Errors
/// When the test directory cannot be walked.
pub fn declared_tests(root: &Path) -> Result<usize, String> {
    let pattern = Regex::new(r"(^|\s)func test[A-Za-z0-9_]*\(").map_err(|error| error.to_string())?;
    let directory = root.join("Apps/ClientApp-iOS/Tests");
    let mut total = 0;
    let mut files = Vec::new();
    collect_swift(&directory, &mut files)?;
    for file in files {
        let bytes = fs::read(&file).unwrap_or_default();
        let code = code_text::code_only(&bytes, code_text::Dialect::Swift);
        let text = String::from_utf8_lossy(&code);
        total += text.lines().filter(|line| pattern.is_match(line)).count();
    }
    Ok(total)
}

/// The count in the LAST `Executed N tests` summary, which is the whole-run one.
///
/// The COUNT is the verdict, not the summary line: `XCTest` prints "Test Suite 'All tests' passed /
/// Executed 0 tests, with 0 failures" for an EMPTY bundle and exits 0, so "the summary says passed"
/// is satisfied by a run that asserted nothing at all.
#[must_use]
pub fn executed_tests(log: &str) -> Option<usize> {
    let pattern = Regex::new(r"Executed (\d+) tests?,").ok()?;
    pattern
        .captures_iter(log)
        .last()
        .and_then(|capture| capture[1].parse().ok())
}

/// Build the host-less iOS test bundle and run it on a simulator.
///
/// # Errors
/// When the toolchain is incomplete, no such device exists, the bundle fails to build or load, the
/// executed count does not match the declared count, or the run does not end green.
pub fn ios_tests(root: &Path, request: &SimulatorRequest) -> Result<(), String> {
    need_xcodegen()?;
    let developer = proc::capture("xcode-select", &["-p"], root)?;
    let agent =
        format!("{developer}/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest");
    if !Path::new(&agent).is_file() {
        return Err(format!("no iPhoneSimulator xctest agent at {agent}"));
    }

    let listed = proc::capture(
        "xcrun",
        &["simctl", "list", "devices", "available", "--json"],
        root,
    )?;
    let udid = simulator_udid(&listed, &request.device)?;

    let booted = proc::ask("xcrun", &["simctl", "list", "devices", "booted"], root).unwrap_or_default();
    let we_booted = !booted.contains(&udid);
    if we_booted {
        println!("==> booting {} ({udid})", request.device);
        let _ignored = proc::ask("xcrun", &["simctl", "boot", &udid], root);
        // `bootstatus -b` returns when the device finishes booting; a no-op on an already-booted
        // one.
        let _ignored = proc::ask("xcrun", &["simctl", "bootstatus", &udid, "-b"], root);
    }
    println!("==> simulator: {} ({udid})", request.device);

    let outcome = run_bundle(root, &udid, &agent);
    if we_booted && !request.keep_booted {
        let _ignored = proc::ask("xcrun", &["simctl", "shutdown", &udid], root);
    }
    outcome
}

/// Build the bundle, run it, and read the count back.
fn run_bundle(root: &Path, udid: &str, agent: &str) -> Result<(), String> {
    const SCHEME: &str = "ClientApp-iOSTests";
    let derived = root.join(".work/ios-test-dd");
    let bundle = derived.join(format!("Build/Products/Debug-iphonesimulator/{SCHEME}.xctest"));
    let log = root.join(".work/ios-test-dd.log");

    generate(root, IOS_SPEC)?;
    println!("==> build-for-testing: {SCHEME}");
    let built = Command::new("xcodebuild")
        .args([
            "-project",
            IOS_PROJECT,
            "-scheme",
            SCHEME,
            "-destination",
            "generic/platform=iOS Simulator",
            "-derivedDataPath",
            &derived.to_string_lossy(),
            "CODE_SIGNING_ALLOWED=NO",
            "build-for-testing",
        ])
        .current_dir(root)
        .output()
        .map_err(|error| format!("xcodebuild: {error}"))?;
    if let Some(parent) = log.parent() {
        fs::create_dir_all(parent).map_err(|error| format!("{}: {error}", parent.display()))?;
    }
    let mut transcript = built.stdout.clone();
    transcript.extend_from_slice(&built.stderr);
    fs::write(&log, &transcript).map_err(|error| format!("{}: {error}", log.display()))?;
    if !built.status.success() {
        let text = String::from_utf8_lossy(&transcript);
        eprintln!(
            "==> FAIL: iOS test bundle did not build; tail of {}:",
            log.display()
        );
        for line in text.lines().rev().take(40).collect::<Vec<_>>().into_iter().rev() {
            eprintln!("{line}");
        }
        return Err("iOS test bundle did not build".to_owned());
    }
    if !bundle.is_dir() {
        return Err(format!("no test bundle at {}", bundle.display()));
    }

    println!("==> xctest {SCHEME}.xctest");
    let run = Command::new("xcrun")
        .args([
            "simctl",
            "spawn",
            udid,
            agent,
            "-XCTest",
            "All",
            &bundle.to_string_lossy(),
        ])
        .current_dir(root)
        .output()
        .map_err(|error| format!("simctl spawn: {error}"))?;
    let mut output = run.stdout.clone();
    output.extend_from_slice(&run.stderr);
    let text = String::from_utf8_lossy(&output).into_owned();
    for line in text.lines() {
        if !line.contains("Install Started") && !line.contains("Authorization is required to install") {
            println!("{line}");
        }
    }
    // The agent's own exit code is the primary verdict: a bundle that fails to LOAD exits non-zero
    // having run nothing, which "0 failures" would not catch.
    if !run.status.success() {
        return Err(format!("xctest exited {}", run.status.code().unwrap_or(-1)));
    }

    let declared = declared_tests(root)?;
    if declared == 0 {
        return Err("Apps/ClientApp-iOS/Tests declares no tests — this gate would assert nothing".to_owned());
    }
    let Some(executed) = executed_tests(&text) else {
        return Err("xctest printed no 'Executed N tests' summary — it failed to load the bundle".to_owned());
    };
    if executed != declared {
        return Err(format!(
            "Apps/ClientApp-iOS/Tests declares {declared} test(s), but the simulator executed {executed}. A \
             test that does not RUN on the iOS triple is a fork branch nobody asserts."
        ));
    }
    if !text.contains("Test Suite 'All tests' passed") {
        return Err(format!(
            "the '{executed} tests' run did not end in a passing 'All tests' summary"
        ));
    }
    println!("==> iOS tests OK — {executed} of {declared} declared tests ran on the iOS-Simulator triple");
    Ok(())
}

/// Every `.swift` under `dir`.
fn collect_swift(dir: &Path, into: &mut Vec<std::path::PathBuf>) -> Result<(), String> {
    if !dir.is_dir() {
        return Ok(());
    }
    let entries = fs::read_dir(dir).map_err(|error| format!("{}: {error}", dir.display()))?;
    for entry in entries {
        let path = entry.map_err(|error| error.to_string())?.path();
        if path.is_dir() {
            collect_swift(&path, into)?;
        } else if path.extension().and_then(|value| value.to_str()) == Some("swift") {
            into.push(path);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #![expect(clippy::unwrap_used, reason = "a panic in a test is the failure report")]
    use std::fs;

    use super::{declared_tests, executed_tests, simulator_udid};

    const LISTED: &str = r#"{"devices": {
      "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
        {"name": "iPhone 17 Pro", "udid": "WATCH-DECOY"}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
        {"name": "iPhone 16", "udid": "AAA"},
        {"name": "iPhone 17 Pro", "udid": "BBB"}
      ]
    }}"#;

    /// A watchOS runtime can carry a device of the same name; only an iOS one counts.
    #[test]
    fn the_udid_comes_from_an_ios_runtime() {
        assert_eq!(simulator_udid(LISTED, "iPhone 17 Pro").unwrap(), "BBB");
        assert_eq!(simulator_udid(LISTED, "iPhone 16").unwrap(), "AAA");
    }

    #[test]
    fn an_unknown_device_is_an_error_naming_it() {
        let error = simulator_udid(LISTED, "iPhone 3G").unwrap_err();
        assert!(error.contains("iPhone 3G"), "{error}");
    }

    /// The LAST summary is the whole-run one; per-suite lines print the same shape above it.
    #[test]
    fn the_executed_count_is_the_last_summary() {
        let log = "Test Suite 'A' passed\n     Executed 3 tests, with 0 failures\nTest Suite 'All tests' \
                   passed\n     Executed 11 tests, with 0 failures\n";
        assert_eq!(executed_tests(log), Some(11));
    }

    /// An empty bundle prints a PASSING summary and exits 0 — the count is what catches it.
    #[test]
    fn an_empty_bundle_reports_zero_rather_than_nothing() {
        let log = "Test Suite 'All tests' passed\n     Executed 0 tests, with 0 failures\n";
        assert_eq!(executed_tests(log), Some(0));
    }

    #[test]
    fn a_bundle_that_never_loaded_prints_no_summary() {
        assert_eq!(executed_tests("dyld: symbol not found\n"), None);
    }

    #[test]
    fn one_test_is_singular_in_the_summary() {
        assert_eq!(executed_tests("Executed 1 test, with 0 failures\n"), Some(1));
    }

    /// A commented-out declaration is not one the simulator can execute.
    ///
    /// The gate demands the two counts be EQUAL, so an inflated left side reds a run that passed.
    /// The fixture is a directory rather than a string because `declared_tests` walks one, and it
    /// last line is why this is a lexer's job rather than a `//` filter's: a strip to end-of-line
    /// would cut that URL in half, and the `//` it cut at is inside a string literal.
    ///
    /// A `func test…` spelled INSIDE a literal would still be counted, because `code_only` emits
    /// literal bytes verbatim — deliberately, since a stripper that erased them is the direction
    /// that hides code. That leaves the same false ALARM this test narrows, one shape rarer.
    #[test]
    fn a_commented_declaration_is_not_counted() {
        let dir = std::env::temp_dir().join(format!("xcode-declared-{}", std::process::id()));
        let tests = dir.join("Apps/ClientApp-iOS/Tests");
        fs::create_dir_all(&tests).unwrap();
        fs::write(
            tests.join("Probe.swift"),
            "func testReal() {}\n// func testCommented() {}\n/* func testBlocked() {} */\n\
             func testSecond() {}\nlet url = \"https://x\" // func testTrailing() {}\n",
        )
        .unwrap();
        let counted = declared_tests(&dir).unwrap();
        fs::remove_dir_all(&dir).ok();
        assert_eq!(counted, 2, "only the two real declarations are executable");
    }
}
