//! The `slopdesk-dropd` entry point: bind the upload port, announce it, serve until killed.
//!
//! No daemonising, no pid file, no config file. superd holds it on a PTY and hostd reads the
//! announce line off that ring to re-learn the port after a restart — the same "the restart is the
//! reload" discipline the rest of the tree runs on.
//!
//! ```text
//! slopdesk-dropd --port <n> [--drop-dir <path>]
//! ```
//!
//! `--port 0` binds an OS-chosen port and announces the real one, which is what the tests use.

use std::path::PathBuf;
use std::process::ExitCode;

use slopdesk_dropd::server::{announce, bind, serve};

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let (port, drop_dir) = match parse(&arguments) {
        Ok(parsed) => parsed,
        Err(message) => {
            eprintln!("dropd: {message}");
            eprintln!("usage: slopdesk-dropd --port <n> [--drop-dir <path>]");
            return ExitCode::FAILURE;
        },
    };

    let listener = match bind(port) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("dropd: cannot bind port {port}: {error}");
            return ExitCode::FAILURE;
        },
    };
    if let Err(error) = announce(&listener, &drop_dir) {
        eprintln!("dropd: cannot report the bound port: {error}");
        return ExitCode::FAILURE;
    }
    match serve(&listener, &drop_dir) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("dropd: fatal: {error}");
            ExitCode::FAILURE
        },
    }
}

/// `--port` (required) and `--drop-dir` (default `$HOME/Downloads`, which is where the Swift server
/// this replaces dropped files when nothing said otherwise).
fn parse(arguments: &[String]) -> Result<(u16, PathBuf), String> {
    let mut port: Option<u16> = None;
    let mut drop_dir: Option<PathBuf> = None;
    let mut index = 0;
    while let Some(flag) = arguments.get(index) {
        let value = arguments.get(index + 1);
        match flag.as_str() {
            "--port" => {
                let text = value.ok_or_else(|| "--port needs a number".to_owned())?;
                port = Some(text.parse().map_err(|_ignored| format!("bad port {text}"))?);
            },
            "--drop-dir" => {
                let text = value.ok_or_else(|| "--drop-dir needs a path".to_owned())?;
                drop_dir = Some(PathBuf::from(text));
            },
            other => return Err(format!("unknown argument {other}")),
        }
        index += 2;
    }
    let port = port.ok_or_else(|| "--port is required".to_owned())?;
    let drop_dir = drop_dir.unwrap_or_else(|| {
        std::env::var_os("HOME").map_or_else(
            || PathBuf::from("/tmp"),
            |home| PathBuf::from(home).join("Downloads"),
        )
    });
    Ok((port, drop_dir))
}
