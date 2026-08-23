//! The Android panel's hardware gate: the two claims only a real device can settle.
//!
//! `make test` covers everything about this panel that is PURE — the scrcpy stream reassembler, the
//! control-message encoder, the layout, the scroll machine, the logcat parser, the device decode,
//! the bridge's ack/stream split, and the whole catalogue, argument-vector and refusal surface as
//! `rust/slopdesk-androidd` unit tests. None of that opens a socket (hang-safety), which is exactly
//! why it proves nothing about the two things that can only be wrong against real hardware: whether
//! the `scrcpy-server` handshake still completes at the pinned version, and whether the bridge's
//! own line-JSON-then-bytes framing survives a real `adb`.
//!
//! Nothing here is destructive: it lists, opens ONE mirror session, and closes it. Dialect,
//! measurements and traps: `docs/48-android-panel.md`.
//!
//! ## The resolution order is production's, deliberately
//! Override, then the vendored prefix, then `PATH` — the same order `HostServiceProcess` walks. A
//! gate that proved the handshake against a different `adb` than the panel runs would be proving
//! the wrong thing. The ANSWER is then exported rather than left to the daemon's own locator, which
//! is what makes the proof hold on a host where the provisioned `adb` is not on `PATH` (the normal
//! case).

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The vendored toolchain prefix `make provision` fills.
const VENDORED_ADB: &str = "ThirdParty/tools/.prefix/bin/adb";

/// Where a `scrcpy-server` jar may be, in the order production looks.
const JAR_CANDIDATES: &[&str] = &[
    "ThirdParty/tools/vendor/scrcpy-server",
    "/opt/homebrew/share/scrcpy/scrcpy-server",
    "/usr/local/share/scrcpy/scrcpy-server",
];

/// The `adb` this gate and the daemon under test will both use.
///
/// # Errors
/// When no `adb` is reachable by any of the three routes.
pub fn locate_adb(root: &Path) -> Result<PathBuf, String> {
    if let Some(override_path) = env::var_os("SLOPDESK_ADB_BIN").filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(override_path));
    }
    let vendored = root.join(VENDORED_ADB);
    if vendored.is_file() {
        return Ok(vendored);
    }
    which("adb").ok_or_else(|| {
        "no adb found (provision it: make provision), or set SLOPDESK_ADB_BIN to one".to_owned()
    })
}

/// The `scrcpy-server` jar, override first.
///
/// # Errors
/// When none of the candidates exists — which means a broken checkout, since the jar is committed.
pub fn locate_jar(root: &Path) -> Result<PathBuf, String> {
    if let Some(override_path) = env::var_os("SLOPDESK_ANDROID_SERVER_JAR").filter(|value| !value.is_empty())
    {
        return Ok(PathBuf::from(override_path));
    }
    JAR_CANDIDATES
        .iter()
        .map(|candidate| {
            if candidate.starts_with('/') {
                PathBuf::from(candidate)
            } else {
                root.join(candidate)
            }
        })
        .find(|path| path.is_file())
        .ok_or_else(|| {
            "no scrcpy-server jar found — it is committed at ThirdParty/tools/vendor/, so this means a \
             broken checkout. Restore it, or set SLOPDESK_ANDROID_SERVER_JAR to one"
                .to_owned()
        })
}

/// How many devices `adb devices` reports in state `device`.
///
/// Any other state cannot be mirrored: `unauthorized` in particular means a dialog is waiting on
/// the device's own screen, and every shell the gate runs would fail with a message that does not
/// say so.
#[must_use]
pub fn ready_devices(listing: &str) -> usize {
    listing
        .lines()
        .skip(1)
        .filter_map(|line| line.split_whitespace().nth(1))
        .filter(|state| *state == "device")
        .count()
}

/// Resolve the toolchain, refuse an unusable device set, and run the hardware suite.
///
/// The gate's cases are `rust/slopdesk-androidd/tests/hardware.rs`: the bridge they exercise is
/// that crate, and there is no Swift copy of it to test.
///
/// # Errors
/// When the toolchain is missing, no device is ready, or the suite fails.
pub fn run(root: &Path) -> Result<(), String> {
    let adb = locate_adb(root)?;
    println!("==> adb: {}", adb.display());

    let listing = Command::new(&adb)
        .arg("devices")
        .current_dir(root)
        .output()
        .map_err(|error| format!("{}: {error}", adb.display()))?;
    let listing = String::from_utf8_lossy(&listing.stdout).into_owned();
    let ready = ready_devices(&listing);
    if ready == 0 {
        eprintln!("ERROR: no device in state 'device'. Boot an emulator or plug a phone in and accept the");
        eprintln!("       USB-debugging prompt, then re-run.");
        eprint!("{listing}");
        return Err("android: no ready device".to_owned());
    }
    println!("==> {ready} device(s) ready");

    let jar = locate_jar(root)?;
    println!("==> scrcpy-server: {}", jar.display());

    println!("==> cargo test --test hardware (rust/slopdesk-androidd)");
    let status = Command::new("cargo")
        .args(["test", "--test", "hardware", "--", "--nocapture", "--test-threads=1"])
        .current_dir(root.join("rust/slopdesk-androidd"))
        // Handed to the daemon under test rather than left to its own locator, and
        // `SLOPDESK_ANDROID_HW` is the gate the cases themselves read — without it every case
        // returns early after saying why, which is what keeps a clean checkout green on a machine
        // that has never seen the Android SDK.
        .env("SLOPDESK_ADB_BIN", &adb)
        .env("SLOPDESK_ANDROID_SERVER_JAR", &jar)
        .env("SLOPDESK_ANDROID_HW", "1")
        .status()
        .map_err(|error| format!("cargo: {error}"))?;
    if !status.success() {
        return Err(format!("hardware suite exited {}", status.code().unwrap_or(-1)));
    }
    println!("==> Android hardware gate OK");
    Ok(())
}

/// The first `program` on `PATH`.
fn which(program: &str) -> Option<PathBuf> {
    env::var_os("PATH").and_then(|paths| {
        env::split_paths(&paths)
            .map(|directory| directory.join(program))
            .find(|candidate| candidate.is_file())
    })
}

#[cfg(test)]
mod tests {
    use super::ready_devices;

    /// The header line is not a device, and only state `device` counts.
    #[test]
    fn only_a_device_in_state_device_is_ready() {
        let listing = "List of devices \
                       attached\nemulator-5554\tdevice\nR5CT12345\tunauthorized\nR5CT67890\toffline\\
                       nR5CTAAAAA\tdevice\n";
        assert_eq!(ready_devices(listing), 2);
    }

    #[test]
    fn an_empty_listing_is_no_devices() {
        assert_eq!(ready_devices("List of devices attached\n\n"), 0);
        assert_eq!(ready_devices(""), 0);
    }
}
