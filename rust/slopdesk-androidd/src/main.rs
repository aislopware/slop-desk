//! The `slopdesk-androidd` entry point: locate the toolchain, bind the bridge port, announce it,
//! serve until killed.
//!
//! No daemonising, no pid file, no config file. superd holds it on a PTY and hostd reads the
//! announce line off that ring to re-learn the port after a restart — the same "the restart is the
//! reload" discipline the rest of the tree runs on.
//!
//! ```text
//! slopdesk-androidd --port <n> [--vendored-bin <dir>] [--vendored-jar <path>]
//! ```
//!
//! `--port 0` binds an OS-chosen port and announces the real one, which is what hostd uses: the
//! Android bridge has no fixed offset from the terminal port the way dropd does, because one host
//! has exactly one of it no matter how many hostds a machine has seen.
//!
//! The two vendored paths are passed IN rather than discovered here. `VendoredTools` in hostd
//! already walks up from the running binary for `ThirdParty/tools/tools.lock`, and it serves the
//! code and simulator panels too; re-walking it here would be the same capability in a second
//! language, which is the thing the one-implementation rule forbids. Passing the answer down on
//! argv also means a daemon adopted from a differently-configured hostd cannot silently resolve to
//! different tools.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use slopdesk_androidd::server::{Bridge, announce, bind, locate_toolchain, serve};

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let options = match parse(&arguments) {
        Ok(parsed) => parsed,
        Err(message) => {
            eprintln!("androidd: {message}");
            eprintln!("usage: slopdesk-androidd --port <n> [--vendored-bin <dir>] [--vendored-jar <path>]");
            return ExitCode::FAILURE;
        },
    };

    // A host with no `adb` has no Android panel at all, and saying so once here beats answering every
    // request with the same sentence — hostd sees the exit and reports the service unavailable.
    let toolchain = match locate_toolchain(options.vendored_bin.as_deref(), options.vendored_jar.as_deref()) {
        Ok(toolchain) => toolchain,
        Err(error) => {
            eprintln!("androidd: {error}");
            return ExitCode::FAILURE;
        },
    };

    let listener = match bind(options.port) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("androidd: cannot bind port {}: {error}", options.port);
            return ExitCode::FAILURE;
        },
    };
    if let Err(error) = announce(&listener, &toolchain) {
        eprintln!("androidd: cannot report the bound port: {error}");
        return ExitCode::FAILURE;
    }

    let bridge = Arc::new(Bridge::new(toolchain));
    match serve(&listener, &bridge) {
        Ok(()) => {
            // Only reachable if the listener itself ended. Live mirrors are stopped so the
            // device-side servers do not outlive the process that started them.
            bridge.stop_sessions();
            ExitCode::SUCCESS
        },
        Err(error) => {
            eprintln!("androidd: fatal: {error}");
            bridge.stop_sessions();
            ExitCode::FAILURE
        },
    }
}

/// What the daemon was told on argv.
#[derive(Debug)]
struct Options {
    /// The bridge port. `0` means "any", and the real one is announced.
    port: u16,
    /// hostd's `.prefix/bin` — where the pinned `adb` lives, if this host has one.
    vendored_bin: Option<PathBuf>,
    /// hostd's `ThirdParty/tools/vendor/scrcpy-server`.
    vendored_jar: Option<PathBuf>,
}

/// `--port` (required), plus the two paths hostd resolved.
fn parse(arguments: &[String]) -> Result<Options, String> {
    let mut port: Option<u16> = None;
    let mut vendored_bin: Option<PathBuf> = None;
    let mut vendored_jar: Option<PathBuf> = None;
    let mut index = 0;
    while let Some(flag) = arguments.get(index) {
        let value = arguments.get(index + 1);
        match flag.as_str() {
            "--port" => {
                let text = value.ok_or_else(|| "--port needs a number".to_owned())?;
                port = Some(text.parse().map_err(|_ignored| format!("bad port {text}"))?);
            },
            "--vendored-bin" => {
                let text = value.ok_or_else(|| "--vendored-bin needs a path".to_owned())?;
                vendored_bin = Some(PathBuf::from(text));
            },
            "--vendored-jar" => {
                let text = value.ok_or_else(|| "--vendored-jar needs a path".to_owned())?;
                vendored_jar = Some(PathBuf::from(text));
            },
            other => return Err(format!("unknown argument {other}")),
        }
        index += 2;
    }
    Ok(Options {
        port: port.ok_or_else(|| "--port is required".to_owned())?,
        vendored_bin,
        vendored_jar,
    })
}
