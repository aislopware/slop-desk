//! The accept loop and the seven operations behind it.
//!
//! One thread per connection, threads rather than a pool because every path in here blocks by
//! design (see [`crate::net`]) and a blocking pump on a shared executor starves everything behind
//! it. A panel drives at most a handful of connections — a list poll, a mirror, a logcat — so the
//! thread count is bounded by what the user has open.
//!
//! A thread that panics costs its own connection and nothing else, which is why this crate builds
//! with `panic = "unwind"`. There is no shared mutable state beyond the live-session list, which
//! exists only so a shutdown can end the mirrors it is holding.
//!
//! ## Why there is a bridge at all
//!
//! `adb forward` binds `127.0.0.1` and has no option not to. The device's frames therefore land on
//! a loopback socket ON THE HOST, and a `SlopDesk` client is somewhere else on the mesh. Something
//! has to carry them across, and this is it.
//!
//! The alternative was considered and rejected: `adb` can be told to serve on all interfaces
//! (`adb -a server -H 0.0.0.0`), which would let the client speak the adb protocol itself and reach
//! `localabstract:scrcpy_…` directly, with no relay in the middle. It is rejected because it is a
//! MACHINE-WIDE change to how the user's `adb` runs, it hands every peer on the mesh a shell on
//! every attached device rather than a mirror of one, and it needs the user to restart their adb
//! server with special flags before the panel works at all.
//!
//! What DID change is which process holds it: the relay used to be a listener inside hostd, so an
//! H.264 stream was pumped by the daemon that owns every keystroke and a `make host-restart` took
//! every mirror with it. Now the client dials this binary directly and hostd is not in the byte
//! path at all.

use std::collections::HashMap;
use std::io::Read as _;
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

use crate::catalog::{self, Device};
use crate::console;
use crate::error::BridgeError;
use crate::net::{pump, read_request_line, shutdown, write_line};
use crate::protocol::{
    Request, emulator_arguments, encode_device, encode_error, encode_failure, encode_ok, logcat_level,
    open_refusal,
};
use crate::scrcpy::{Codec, Options, Session};
use crate::toolchain::{self, Toolchain};

/// The marker hostd looks for when it re-learns the port of an androidd that survived its restart.
///
/// The service's own first words ARE the record — there is no state file and no port handshake, the
/// same discipline `SupervisedServiceProcess` applies to the panel backends (`docs/51` §6.7).
pub const ANNOUNCE_PREFIX: &str = "androidd: listening on 0.0.0.0:";

/// What the RUNNING build's version is prefixed with inside the announce parenthetical.
///
/// The announce line is already the one channel carrying facts about an androidd hostd did not
/// start — that is what `ANNOUNCE_PREFIX` above is for — so the running build's version rides here
/// rather than on a wire that has no handshake to add it to. FIRST in the parenthetical and
/// `v`-prefixed so the position is stable however the rest of that text grows. Spelled identically
/// in the other two announcing daemons and in `SidecarAnnounce.versionMarker`;
/// `rust/slopdesk-invariants` ratchets all four.
pub const ANNOUNCE_VERSION_PREFIX: &str = "(v";

/// One `adb shell` round trip carries both halves of a device probe; this splits them. Eight
/// `getprop <key>` calls would be eight process spawns per device per poll.
pub const PROBE_MARKER: &str = "--slopdesk-wm--";

/// The hard cap on a request line. A peer that never sends a newline is a bounded mistake.
const REQUEST_LIMIT: usize = 8192;

/// The running bridge: the toolchain it dials through, and the mirrors it is holding.
#[derive(Debug)]
pub struct Bridge {
    /// Where this host's `adb`, `emulator` and scrcpy jar live.
    pub toolchain: Toolchain,
    sessions: Mutex<Vec<Arc<Mutex<Session>>>>,
}

impl Bridge {
    /// A bridge over an already-located toolchain.
    #[must_use]
    pub const fn new(toolchain: Toolchain) -> Self {
        Self {
            toolchain,
            sessions: Mutex::new(Vec::new()),
        }
    }

    /// Ends every live mirror.
    ///
    /// Booted DEVICES are deliberately left running, for the reason the simulator panel leaves its
    /// server up: an emulator the user started is their machine's state and outlives any one
    /// daemon.
    pub fn stop_sessions(&self) {
        // A poisoned lock is recovered rather than propagated: the state behind it is a Vec of
        // handles, and a shutdown that skipped them because another thread panicked would leave the
        // device-side servers running with nobody left to stop them.
        let live = std::mem::take(&mut *self.held_sessions());
        for session in live {
            stop_session(&session);
        }
    }

    fn remember(&self, session: &Arc<Mutex<Session>>) {
        self.held_sessions().push(Arc::clone(session));
    }

    fn forget(&self, session: &Arc<Mutex<Session>>) {
        self.held_sessions().retain(|kept| !Arc::ptr_eq(kept, session));
    }

    fn held_sessions(&self) -> std::sync::MutexGuard<'_, Vec<Arc<Mutex<Session>>>> {
        self.sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// Binds the bridge port.
///
/// # Errors
/// Propagates the bind failure — the caller reports it and exits, because a bridge that is not on
/// its port is a bridge no client can reach.
pub fn bind(port: u16) -> std::io::Result<TcpListener> {
    crate::net::bind(port)
}

/// Announces the bound port on stderr, in the shape hostd parses.
///
/// # Errors
/// Propagates the failure to read the listener's own address.
pub fn announce(listener: &TcpListener, toolchain: &Toolchain) -> std::io::Result<u16> {
    let port = listener.local_addr()?.port();
    eprintln!("{}", announce_line(port, toolchain));
    Ok(port)
}

/// The exact line [`announce`] prints.
///
/// Split out so the shape hostd parses is a value a test can hold, rather than a side effect on a
/// file descriptor. `env!` reads THIS binary's compile-time version — never a number off disk.
#[must_use]
pub fn announce_line(port: u16, toolchain: &Toolchain) -> String {
    // The two optional pieces are named here because "the panel lists but will not mirror" is a
    // question answered by this line and otherwise by a bisect.
    format!(
        "{ANNOUNCE_PREFIX}{port} {ANNOUNCE_VERSION_PREFIX}{}, adb {}, emulator {}, scrcpy-server {})",
        env!("CARGO_PKG_VERSION"),
        toolchain.adb.display(),
        toolchain
            .emulator
            .as_ref()
            .map_or_else(|| "missing".to_owned(), |path| path.display().to_string()),
        toolchain
            .scrcpy_server_jar
            .as_ref()
            .map_or_else(|| "missing".to_owned(), |path| path.display().to_string()),
    )
}

/// Accepts connections until the process is killed.
///
/// # Errors
/// Propagates an accept failure that is not per-connection; a per-connection error is logged and
/// dropped.
pub fn serve(listener: &TcpListener, bridge: &Arc<Bridge>) -> std::io::Result<()> {
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let held = Arc::clone(bridge);
                // A failed spawn (thread limit) costs this one connection, not the daemon.
                if let Err(error) = std::thread::Builder::new()
                    .name("androidd-conn".to_owned())
                    .stack_size(512 * 1024)
                    .spawn(move || serve_connection(stream, &held))
                {
                    eprintln!("androidd: cannot spawn connection thread: {error}");
                }
            },
            Err(error) => eprintln!("androidd: accept failed: {error}"),
        }
    }
    Ok(())
}

/// Serves one connection to completion.
fn serve_connection(mut client: TcpStream, bridge: &Arc<Bridge>) {
    let Some(line) = read_request_line(&mut client, REQUEST_LIMIT) else {
        refuse(&mut client, BridgeError::BadRequest);
        return;
    };
    let Some(request) = Request::decode(&line) else {
        refuse(&mut client, BridgeError::BadRequest);
        return;
    };

    match request.op.as_str() {
        "list" => {
            let devices: Vec<Value> = device_list(&bridge.toolchain).iter().map(encode_device).collect();
            reply(&mut client, &encode_ok(json!({ "devices": devices })));
            shutdown(&client);
        },
        "boot" => {
            let outcome = boot(&bridge.toolchain, request.string("avd"));
            answer(&mut client, outcome);
        },
        "shutdown" => {
            let outcome = shutdown_device(&bridge.toolchain, request.string("serial"));
            answer(&mut client, outcome);
        },
        "console" => run_console(&mut client, &request),
        "screenshot" => screenshot(&mut client, &bridge.toolchain, &request),
        "logcat" => stream_logcat(&mut client, &bridge.toolchain, &request),
        "open" => open_mirror(client, bridge, &request),
        _unknown => refuse(&mut client, BridgeError::BadRequest),
    }
}

/// Writes one reply line, ignoring a peer that has already gone.
fn reply(client: &mut TcpStream, line: &str) -> bool {
    write_line(client, line)
}

/// Refuses and closes.
fn refuse(client: &mut TcpStream, error: BridgeError) {
    reply(client, &encode_error(error));
    shutdown(client);
}

/// Answers a verb that either worked or named a reason, then closes.
fn answer(client: &mut TcpStream, outcome: Option<BridgeError>) {
    let line = outcome.map_or_else(|| encode_ok(json!({})), encode_error);
    reply(client, &line);
    shutdown(client);
}

// MARK: - The device list

/// The whole catalogue: attached targets folded with the AVDs on disk.
#[must_use]
pub fn device_list(toolchain: &Toolchain) -> Vec<Device> {
    let listing = toolchain
        .adb(None, &["devices", "-l"], Duration::from_secs(5))
        .unwrap_or_default();
    let mut running: Vec<Device> = Vec::new();
    for entry in catalog::parse_devices(&listing) {
        // A target that is `offline` or `unauthorized` cannot answer a shell, so it is recorded from
        // what `adb devices` alone said. Probing it would cost the poll its timeout.
        if entry.state != "device" {
            // A booting emulator can still say WHICH AVD it is: the guest's `adbd` answers nothing
            // for the first ~21 s of a cold boot (measured 2026-08-07), but the QEMU console is up
            // from process launch. Naming it here is what folds the transient `emulator-5554 ·
            // offline` row into the AVD row the user booted — one identity for the whole boot, so an
            // early selection survives it.
            let avd_name = console::port_for_serial(&entry.serial).and_then(|_port| {
                let reply = console::run(
                    "avd name",
                    &entry.serial,
                    &home_directory(),
                    Duration::from_secs(2),
                );
                catalog::parse_console_avd_name(reply.as_deref())
            });
            running.push(Device::bare(Some(entry.serial), avd_name, &entry.state));
            continue;
        }
        let probe = toolchain
            .adb(
                Some(&entry.serial),
                &[
                    "shell",
                    &format!("getprop; echo {PROBE_MARKER}; wm size; wm density"),
                ],
                Duration::from_secs(5),
            )
            .unwrap_or_default();
        let (properties_half, metrics) = probe.split_once(PROBE_MARKER).unwrap_or((probe.as_str(), ""));
        running.push(catalog::running_device(
            &entry.serial,
            &entry.state,
            &catalog::parse_properties(properties_half),
            catalog::parse_display_size(metrics),
            catalog::parse_density(metrics),
        ));
    }
    catalog::merge(running, available_avds(toolchain))
}

/// Every AVD on disk, read from its own `config.ini`. A host with no emulator binary simply has
/// none — attached devices still list.
fn available_avds(toolchain: &Toolchain) -> Vec<Device> {
    let Some(ref emulator) = toolchain.emulator else {
        return Vec::new();
    };
    let Some(output) = toolchain::run(emulator, &["-list-avds"], Duration::from_secs(10)) else {
        return Vec::new();
    };
    let home = home_directory();
    catalog::parse_avd_names(&output)
        .iter()
        .map(|name| {
            let path = home.join(".android/avd").join(format!("{name}.avd/config.ini"));
            std::fs::read_to_string(&path).map_or_else(
                // An AVD whose config cannot be read still exists and can still be booted; it just
                // has nothing but its name to show.
                |_error| Device::bare(None, Some(name.clone()), "offline"),
                |text| catalog::avd_device(name, &catalog::parse_config(&text)),
            )
        })
        .collect()
}

/// `$HOME`, or `/` when the daemon was launched without one — which yields no AVDs and no console
/// token rather than a wrong guess at somebody's home.
fn home_directory() -> PathBuf {
    std::env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from)
}

// MARK: - Lifecycle verbs

/// Boots an AVD headless. See [`emulator_arguments`] for why `-gpu host` is stated.
fn boot(toolchain: &Toolchain, avd: Option<&str>) -> Option<BridgeError> {
    let avd = avd?;
    let Some(ref emulator) = toolchain.emulator else {
        return Some(BridgeError::EmulatorMissing);
    };
    let extra: Vec<String> = std::env::var("SLOPDESK_ANDROID_EMULATOR_ARGS")
        .unwrap_or_default()
        .split_whitespace()
        .map(str::to_owned)
        .collect();
    let spawned = Command::new(emulator)
        .args(emulator_arguments(avd, &extra))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .stdin(Stdio::null())
        .spawn();
    // Deliberately NOT waited on and deliberately not tracked: an emulator outlives the panel that
    // started it, and this daemon restarting must not take the user's device down with it.
    match spawned {
        Ok(_child) => None,
        Err(_error) => Some(BridgeError::LaunchFailed),
    }
}

/// Shuts a device down. `adb emu kill` is the emulator's own clean exit; a physical device is not
/// something this panel may power off, so it is refused rather than approximated with `reboot -p`.
fn shutdown_device(toolchain: &Toolchain, serial: Option<&str>) -> Option<BridgeError> {
    let serial = serial?;
    console::port_for_serial(serial)?;
    toolchain
        .adb(Some(serial), &["emu", "kill"], Duration::from_secs(10))
        .map_or(Some(BridgeError::UnknownDevice), |_output| None)
}

/// The emulator console verbs — `geo fix`, `rotate`, `power capacity`, `sms send`, `network`…
fn run_console(client: &mut TcpStream, request: &Request) {
    let (Some(serial), Some(command)) = (request.string("serial"), request.string("command")) else {
        refuse(client, BridgeError::BadRequest);
        return;
    };
    let output = console::run(command, serial, &home_directory(), Duration::from_secs(5));
    let line = output.map_or_else(
        || encode_failure("The emulator console did not answer."),
        |text| encode_ok(json!({ "output": text })),
    );
    reply(client, &line);
    shutdown(client);
}

// MARK: - Screenshot

/// One capture of the device's screen, as a PNG.
///
/// ON DEMAND ONLY, and the measurement is why. `adb exec-out screencap -p` against this host's
/// emulator, 2026-08-04: **300 KB in ~250 ms**, three times over. There is no scale or quality
/// argument — `screencap` renders the framebuffer at native size and PNG-encodes it ON THE DEVICE —
/// so the 250 ms is the device's CPU, not the link's. The simulator panel polls its server's
/// `screenshot.jpg?scale=6&quality=0.5` at 13.5 KB in 22 ms and can afford a card that refreshes
/// every two seconds; the same cadence here would be 150 KB/s and an eighth of a phone's core per
/// listed device, for a thumbnail. So the Android list draws facts instead — which it has, and the
/// simulator list did not — and a picture is taken when somebody asks for one.
///
/// The reply names the byte count and the bytes follow it, rather than riding the JSON as base64: a
/// 4K tablet's capture is several megabytes, and base64 would add a third to that and force the
/// client to buffer the whole line before it could see the length.
fn screenshot(client: &mut TcpStream, toolchain: &Toolchain, request: &Request) {
    let Some(serial) = request.string("serial") else {
        refuse(client, BridgeError::BadRequest);
        return;
    };
    // `exec-out` rather than `shell`: `shell` allocates a pty on some transports and translates `\n`
    // to `\r\n`, which rewrites every 0x0A byte inside the PNG.
    let png = toolchain::capture(
        &toolchain.adb,
        &["-s", serial, "exec-out", "screencap", "-p"],
        Duration::from_secs(20),
        false,
    );
    let Some(png) = png.filter(|bytes| is_png(bytes)) else {
        reply(client, &encode_failure("The device did not return a screenshot."));
        shutdown(client);
        return;
    };
    if reply(client, &encode_ok(json!({ "bytes": png.len() }))) {
        use std::io::Write as _;
        let _ignored = client.write_all(&png);
    }
    shutdown(client);
}

/// The PNG magic, checked before the byte count is promised — a device that answered with an `adb`
/// complaint instead of an image must not be reported as an image.
fn is_png(bytes: &[u8]) -> bool {
    bytes.len() > 8 && bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47])
}

// MARK: - logcat

/// Streams `logcat` until the client hangs up.
///
/// A separate connection from the mirror, for the reason `docs/47` gives for keeping the
/// simulator's log socket separate from its stream: the console opens and closes while the stream
/// stays up, and a log subscription that died with a video reconnect would lose the output covering
/// the moment being investigated.
fn stream_logcat(client: &mut TcpStream, toolchain: &Toolchain, request: &Request) {
    let Some(serial) = request.string("serial") else {
        refuse(client, BridgeError::BadRequest);
        return;
    };
    // `*:<level>` is logcat's own filter spec. The level is validated against a closed set rather
    // than interpolated: this string reaches an argument vector.
    let level = format!("*:{}", logcat_level(request.string("level")));
    let spawned = Command::new(&toolchain.adb)
        // `-v time` gives each line its own timestamp; `-T 200` starts with the last 200 lines so a
        // console opened after the interesting moment still shows it.
        .args(["-s", serial, "logcat", "-v", "time", "-T", "200", &level])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .stdin(Stdio::null())
        .spawn();
    let Ok(mut child) = spawned else {
        reply(client, &encode_failure("Could not start logcat."));
        shutdown(client);
        return;
    };
    reply(client, &encode_ok(json!({})));

    if let Some(mut output) = child.stdout.take() {
        use std::io::Write as _;
        let mut buffer = vec![0_u8; 16 * 1024];
        while let Ok(read) = output.read(&mut buffer) {
            if read == 0 {
                break;
            }
            let Some(chunk) = buffer.get(..read) else {
                break;
            };
            if client.write_all(chunk).is_err() {
                break;
            }
        }
    }
    let _ignored = child.kill();
    let _ignored = child.wait();
    shutdown(client);
}

// MARK: - The mirror

/// Starts a mirror session and becomes its byte pump.
fn open_mirror(mut client: TcpStream, bridge: &Arc<Bridge>, request: &Request) {
    let Some(serial) = request.string("serial") else {
        refuse(&mut client, BridgeError::BadRequest);
        return;
    };
    let options = mirror_options(request);

    // The device's state is asked of `adb` NOW rather than trusted from the panel's list, which is up
    // to four seconds stale and misses every boot in progress. Without this, an `open` against a
    // booting device dies inside `adb push` with a sentence about tunnels — measured 2026-08-07: a
    // cold boot sits `offline` for ~21 s, and an open issued the moment it turns `device` can stall
    // in push for ~15 s more. The client's reattempt loop absorbs the wait; this reply is what tells
    // it the wait is worth making.
    let listing = bridge
        .toolchain
        .adb(None, &["devices"], Duration::from_secs(5))
        .unwrap_or_default();
    let state = catalog::parse_devices(&listing)
        .into_iter()
        .find(|entry| entry.serial == serial)
        .map(|entry| entry.state);
    if let Some(refusal) = open_refusal(state.as_deref()) {
        refuse(&mut client, refusal);
        return;
    }

    let started = match Session::start(&bridge.toolchain, serial, options) {
        Ok(session) => session,
        Err(error) => {
            refuse(&mut client, error);
            return;
        },
    };
    let device_name = started.device_name.clone();
    // Both directions are pumped at once, so each leg needs a handle of its own. `try_clone`
    // duplicates the descriptor rather than the connection — a `shutdown` through any one of them
    // ends the socket for all, which is exactly how the teardown unblocks the other pump.
    let legs = started
        .video
        .try_clone()
        .and_then(|video| started.control.try_clone().map(|control| (video, control)));
    let (mut from_device, mut to_device) = match legs {
        Ok(pair) => pair,
        Err(_error) => {
            let mut session = started;
            session.stop();
            refuse(&mut client, BridgeError::ServerDidNotStart);
            return;
        },
    };
    let Ok(mut from_client) = client.try_clone() else {
        let mut session = started;
        session.stop();
        refuse(&mut client, BridgeError::ServerDidNotStart);
        return;
    };
    let session = Arc::new(Mutex::new(started));
    bridge.remember(&session);

    // Nagle on the downstream leg too, and not only on the control leg it was first set for. A frame
    // is written as one call but leaves as a run of full segments and one short tail, and it is the
    // tail that Nagle holds back until the client acknowledges what came before — which the client,
    // having a whole frame to decode, is in no hurry to do. The delay lands at a frame boundary every
    // time, which is exactly where the eye is looking for it.
    let _ignored = client.set_nodelay(true);
    reply(&mut client, &encode_ok(json!({ "device": device_name })));

    // Upstream on its own thread; downstream on this one. Whichever direction ends first, the
    // teardown below closes both sockets, which unblocks the other out of its `read` — there is no
    // cancellation flag for a pump to poll.
    let upstream = std::thread::Builder::new()
        .name("androidd-control".to_owned())
        .spawn(move || pump(&mut from_client, &mut to_device, 64 * 1024));

    pump(&mut from_device, &mut client, 256 * 1024);

    finish(bridge, &session, &client);
    if let Ok(thread) = upstream {
        let _ignored = thread.join();
    }
}

/// The per-session options a client may vary, each clamped to a range the server will accept.
///
/// Out-of-range is IGNORED rather than refused: a client asking for a 16K mirror has made a mistake
/// this daemon can answer with a 1024-pixel one, and a session is worth more than a lecture.
fn mirror_options(request: &Request) -> Options {
    let mut options = Options::default();
    if let Some(max_size) = request.int("maxSize").filter(|size| (320..=4096).contains(size)) {
        options.max_size = max_size;
    }
    if let Some(bit_rate) = request
        .int("bitRate")
        .filter(|rate| (200_000..=50_000_000).contains(rate))
    {
        options.bit_rate = bit_rate;
    }
    if let Some(codec) = request.string("codec").and_then(Codec::parse) {
        options.codec = codec;
    }
    options
}

/// Ends a mirror: the device-side server, both sockets, and the bridge's record of it.
fn finish(bridge: &Arc<Bridge>, session: &Arc<Mutex<Session>>, client: &TcpStream) {
    stop_session(session);
    shutdown(client);
    bridge.forget(session);
}

/// Stops one held session, recovering a lock poisoned by a panicking pump — the whole point of
/// reaching it is to end the device-side server, and a panic upstream is a stronger reason to, not
/// a reason to skip it.
fn stop_session(session: &Arc<Mutex<Session>>) {
    session
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .stop();
}

/// Locates the toolchain this daemon will serve through, or reports what is missing.
///
/// # Errors
/// [`BridgeError::AdbMissing`] — the one piece without which there is nothing to serve. A missing
/// `emulator` or scrcpy jar deliberately does NOT land here: a host with a phone plugged in and no
/// emulator still has devices to list, and a host with no jar still lists and boots them. Those two
/// report themselves per-operation, where the panel can name the missing piece against the action
/// that wanted it.
pub fn locate_toolchain(
    vendored_bin: Option<&Path>,
    vendored_jar: Option<&Path>,
) -> Result<Toolchain, BridgeError> {
    let environment: HashMap<String, String> = std::env::vars().collect();
    Toolchain::locate(&environment, vendored_bin, vendored_jar).ok_or(BridgeError::AdbMissing)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        ANNOUNCE_PREFIX, ANNOUNCE_VERSION_PREFIX, PROBE_MARKER, announce_line, is_png, mirror_options,
    };
    use crate::protocol::Request;
    use crate::scrcpy::{Codec, Options};
    use crate::toolchain::Toolchain;

    fn request(text: &str) -> Request {
        Request::decode(text.as_bytes()).expect("decodes")
    }

    /// A host with `adb` and neither optional piece — the shape that exercises the `missing` arms.
    fn bare_toolchain() -> Toolchain {
        Toolchain {
            adb: std::path::PathBuf::from("/opt/android/platform-tools/adb"),
            emulator: None,
            scrcpy_server_jar: None,
        }
    }

    #[test]
    fn the_announce_prefix_is_what_hostd_parses() {
        // Spelled identically in `AndroidServiceManager.announceMarker`, and compared by
        // `rust/slopdesk-invariants` — a build that changes one and not the other fails there.
        assert_eq!(ANNOUNCE_PREFIX, "androidd: listening on 0.0.0.0:");
    }

    #[test]
    fn the_announce_line_still_leads_with_the_port_hostd_parses() {
        let line = announce_line(7414, &bare_toolchain());
        let rest = line
            .strip_prefix(ANNOUNCE_PREFIX)
            .expect("the announce marker is the line's prefix");
        // hostd takes the digits directly after the marker as a run, so nothing may sit between.
        assert!(rest.starts_with("7414 "), "port must follow the marker: {line}");
    }

    #[test]
    fn the_announce_line_carries_the_running_builds_version_first_in_the_parenthetical() {
        let line = announce_line(7414, &bare_toolchain());
        let at = line
            .find(ANNOUNCE_VERSION_PREFIX)
            .expect("the version marker is on the line");
        let after = line
            .get(at + ANNOUNCE_VERSION_PREFIX.len()..)
            .expect("the marker is not the line's tail");
        let version = after
            .split([',', ')'])
            .next()
            .expect("split always yields a first field");
        assert_eq!(version, env!("CARGO_PKG_VERSION"), "in {line}");
    }

    #[test]
    fn the_probe_marker_splits_one_round_trip_into_two_halves() {
        let probe = format!("[ro.product.model]: [Pixel 7]\n{PROBE_MARKER}\nPhysical size: 1080x2400");
        let (properties, metrics) = probe.split_once(PROBE_MARKER).expect("splits");
        assert!(properties.contains("ro.product.model"));
        assert!(metrics.contains("1080x2400"));
    }

    #[test]
    fn a_reply_that_is_not_an_image_is_not_reported_as_one() {
        assert!(is_png(b"\x89PNG\r\n\x1a\n\x00\x00"));
        // What `adb` prints when the device went away mid-capture.
        assert!(!is_png(b"error: device offline\n"));
        assert!(!is_png(b"\x89PNG"));
        assert!(!is_png(b""));
    }

    #[test]
    fn an_out_of_range_option_falls_back_rather_than_refusing_the_session() {
        let defaults = Options::default();
        let wild = mirror_options(&request(
            r#"{"op":"open","serial":"x","maxSize":16384,"bitRate":1,"codec":"vp9"}"#,
        ));
        assert_eq!(wild.max_size, defaults.max_size);
        assert_eq!(wild.bit_rate, defaults.bit_rate);
        assert_eq!(wild.codec, defaults.codec);
    }

    #[test]
    fn an_in_range_option_is_honoured() {
        let asked = mirror_options(&request(
            r#"{"op":"open","serial":"x","maxSize":720,"bitRate":2000000,"codec":"h265"}"#,
        ));
        assert_eq!(asked.max_size, 720);
        assert_eq!(asked.bit_rate, 2_000_000);
        assert_eq!(asked.codec, Codec::H265);
    }
}
