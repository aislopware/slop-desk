//! The `slopdesk-inspectord` entry point: bind the inspector port, announce it, tail, serve.
//!
//! No daemonising, no pid file, no config file — superd holds it on a PTY and hostd reads the
//! announce line off that ring to re-learn the port after a restart. The restart IS the reload.
//!
//! ```text
//! slopdesk-inspectord --port <n> [--transcript <path>] [--keep-alive-secs <n>]
//! ```
//!
//! `--port 0` binds an OS-chosen port and announces the real one, which is what the tests use.
//! Without `--transcript` the daemon still binds and serves: a client can connect and subscribe,
//! and the replay window stays empty — which is the honest state of an inspector with nothing to
//! inspect yet, and is exactly what the Swift server did.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use slopdesk_inspectord::engine::{DEFAULT_POLL_INTERVAL, Engine, Sources};
use slopdesk_inspectord::replay::ReplayLog;
use slopdesk_inspectord::server::{DEFAULT_KEEP_ALIVE, Server};

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let options = match parse(&arguments) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("inspectord: {message}");
            eprintln!("usage: slopdesk-inspectord --port <n> [--transcript <path>] [--keep-alive-secs <n>]");
            return ExitCode::FAILURE;
        },
    };

    let log = Arc::new(ReplayLog::default());
    let server = match Server::bind(options.port, Arc::clone(&log), options.keep_alive) {
        Ok(server) => server,
        Err(error) => {
            eprintln!("inspectord: cannot bind port {}: {error}", options.port);
            return ExitCode::FAILURE;
        },
    };
    if let Err(error) = server.announce(options.transcript.as_deref()) {
        eprintln!("inspectord: cannot report the bound port: {error}");
        return ExitCode::FAILURE;
    }

    // The engine outlives every connection: the replay window is what lets a client that connects
    // LATER still see the whole session, so the tail runs whether or not anyone is watching.
    let _engine = options.transcript.map(|path| {
        Engine::start(
            Sources::from_transcript(path),
            Arc::clone(&log),
            DEFAULT_POLL_INTERVAL,
        )
    });

    server.run();
    ExitCode::SUCCESS
}

/// What the daemon was asked to do.
struct Options {
    port: u16,
    transcript: Option<PathBuf>,
    keep_alive: Duration,
}

/// `--port` (required), `--transcript` (optional), `--keep-alive-secs` (optional).
///
/// An unknown flag is an ERROR rather than a shrug: superd passes exactly what hostd's manager
/// builds, so an argument this build does not understand means the two have drifted, and failing
/// loudly at startup beats serving with a silently-ignored option.
fn parse(arguments: &[String]) -> Result<Options, String> {
    let mut port: Option<u16> = None;
    let mut transcript: Option<PathBuf> = None;
    let mut keep_alive = DEFAULT_KEEP_ALIVE;
    let mut index = 0;

    while let Some(flag) = arguments.get(index) {
        let value = arguments.get(index + 1);
        match flag.as_str() {
            "--port" => {
                let text = value.ok_or_else(|| "--port needs a number".to_owned())?;
                port = Some(text.parse().map_err(|_ignored| format!("bad port {text}"))?);
            },
            "--transcript" => {
                let text = value.ok_or_else(|| "--transcript needs a path".to_owned())?;
                transcript = Some(PathBuf::from(text));
            },
            "--keep-alive-secs" => {
                let text = value.ok_or_else(|| "--keep-alive-secs needs a number".to_owned())?;
                let seconds: u64 = text
                    .parse()
                    .map_err(|_ignored| format!("bad keep-alive {text}"))?;
                // Zero would spin the pump thread writing keep-alives as fast as the socket takes
                // them; the flag exists for tests to shorten the interval, not to remove it.
                keep_alive = Duration::from_secs(seconds.max(1));
            },
            other => return Err(format!("unknown argument {other}")),
        }
        index += 2;
    }

    Ok(Options {
        port: port.ok_or_else(|| "--port is required".to_owned())?,
        transcript,
        keep_alive,
    })
}
