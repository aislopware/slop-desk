//! The Android path's dedicated gate (`slopdesk-gate android`).
//!
//! These do NOT run under `just test` or `cargo test` on a clean checkout: they need a booted
//! Android device or emulator, an `adb`, and a `scrcpy-server` jar. `docs/46-gates-env-paths.md` is
//! where each path's gate is recorded; this one is `SLOPDESK_ANDROID_HW=1`. Without it every test
//! here returns early after saying so, so a machine that has never seen the Android SDK stays
//! green.
//!
//! They are also the only place the bridge's SOCKETS are exercised — the unit tests beside them
//! cover everything that is pure, and the hang-safety rule keeps real connections out of the fast
//! gate.
//!
//! Rust has no `XCTSkip`, so a precondition that is not met prints WHY and passes. A silent pass
//! would be indistinguishable from a gate that ran and proved nothing, which is the failure mode
//! the printed reason exists to prevent.

// A skipped hardware test says so on stderr — that line is the only way a run without
// `SLOPDESK_ANDROID_HW=1` can tell you it proved nothing. Scoped to this gate's file.
#![expect(clippy::print_stderr, reason = "the skip notice is this gate's only report")]
#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]

use std::io::{Read as _, Write as _};
use std::net::TcpStream;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use slopdesk_androidd::server::{Bridge, bind, locate_toolchain, serve};

/// The gate. Off ⇒ every test here is a no-op.
fn enabled() -> bool {
    std::env::var("SLOPDESK_ANDROID_HW").as_deref() == Ok("1")
}

/// Announces why a test proved nothing, and yields `false` so the caller can return.
fn skipped(reason: &str) -> bool {
    eprintln!("SKIP: {reason}");
    false
}

/// A bridge on an ephemeral port, serving on its own thread for the life of the test.
///
/// The listener is deliberately leaked with the process: a test binary that ends takes its threads
/// and sockets with it, and an explicit stop would need a shutdown channel this crate does not have
/// (the production daemon is stopped by superd killing it).
fn start_bridge() -> Option<(u16, Arc<Bridge>)> {
    let toolchain = match locate_toolchain(None, None) {
        Ok(toolchain) => toolchain,
        Err(error) => {
            skipped(&format!("{error}"));
            return None;
        },
    };
    let listener = match bind(0) {
        Ok(listener) => listener,
        Err(error) => {
            skipped(&format!("could not bind a bridge port: {error}"));
            return None;
        },
    };
    let port = listener.local_addr().ok()?.port();
    let bridge = Arc::new(Bridge::new(toolchain));
    let served = Arc::clone(&bridge);
    std::thread::spawn(move || {
        let _ignored = serve(&listener, &served);
    });
    Some((port, bridge))
}

/// One request/response round trip against the bridge, as a client would make it.
fn request(payload: &Value, port: u16) -> Option<Value> {
    let mut socket = connect(port)?;
    let line = format!("{payload}\n");
    socket.write_all(line.as_bytes()).ok()?;
    let reply = read_line(&mut socket)?;
    serde_json::from_str(&reply).ok()
}

fn connect(port: u16) -> Option<TcpStream> {
    let socket = TcpStream::connect(("127.0.0.1", port)).ok()?;
    socket.set_read_timeout(Some(Duration::from_secs(30))).ok()?;
    socket.set_write_timeout(Some(Duration::from_secs(30))).ok()?;
    Some(socket)
}

/// Reads the reply line byte at a time, leaving whatever follows it on the socket — the mirror test
/// depends on that, since the very next byte is the codec id.
fn read_line(socket: &mut TcpStream) -> Option<String> {
    let mut collected = Vec::new();
    let mut byte = [0_u8; 1];
    while collected.len() < 1 << 20 {
        if !matches!(socket.read(&mut byte), Ok(1)) {
            return None;
        }
        let &first = byte.first()?;
        if first == b'\n' {
            return String::from_utf8(collected).ok();
        }
        collected.push(first);
    }
    None
}

fn read_exactly(socket: &mut TcpStream, count: usize) -> Option<Vec<u8>> {
    let mut buffer = vec![0_u8; count];
    socket.read_exact(&mut buffer).ok().map(|()| buffer)
}

/// A big-endian `u32` out of a header slice.
fn be32(bytes: &[u8], offset: usize) -> u64 {
    bytes.get(offset..offset.saturating_add(4)).map_or(0, |slice| {
        slice
            .iter()
            .fold(0_u64, |value, &byte| (value << 8) | u64::from(byte))
    })
}

/// The devices the bridge lists, or `None` when it could not be asked.
fn list_devices(port: u16) -> Option<Vec<Value>> {
    let reply = request(&json!({ "op": "list" }), port)?;
    assert_eq!(reply.get("ok"), Some(&Value::Bool(true)), "list failed: {reply}");
    reply.get("devices").and_then(Value::as_array).cloned()
}

#[test]
fn lists_the_hosts_devices() {
    if !enabled() && !skipped("SLOPDESK_ANDROID_HW=1 not set") {
        return;
    }
    let Some((port, _bridge)) = start_bridge() else {
        return;
    };
    let Some(devices) = list_devices(port) else {
        skipped("the bridge did not answer a list");
        return;
    };
    assert!(
        !devices.is_empty(),
        "expected at least one AVD or attached device"
    );

    // Every row must carry the three things the panel titles, selects and renders state from,
    // whatever that state is.
    for device in &devices {
        for field in ["name", "key", "state"] {
            assert!(
                device.get(field).and_then(Value::as_str).is_some(),
                "a row is missing `{field}`: {device}"
            );
        }
    }
    // An AVD on disk knows its own screen even when it has never booted — the fact the iOS panel
    // could not have. If this ever fails, the list has lost its subject for shut-down rows.
    if let Some(avd) = devices
        .iter()
        .find(|device| device.get("isEmulator") == Some(&Value::Bool(true)))
    {
        assert!(avd.get("width").is_some(), "an AVD row lost its width: {avd}");
        assert!(avd.get("density").is_some(), "an AVD row lost its density: {avd}");
    }
}

/// The whole mirror path: handshake, codec id, session header, then real H.264.
#[test]
fn opens_a_mirror_and_receives_decodable_frames() {
    if !enabled() && !skipped("SLOPDESK_ANDROID_HW=1 not set") {
        return;
    }
    let Some((port, _bridge)) = start_bridge() else {
        return;
    };
    let Some(serial) = list_devices(port).and_then(|devices| first_running(&devices)) else {
        skipped("no booted device — `emulator -avd <name> -no-window` first");
        return;
    };

    let Some(mut socket) = connect(port) else {
        skipped("could not dial the bridge");
        return;
    };
    let open = json!({ "op": "open", "serial": serial, "maxSize": 1024 });
    socket
        .write_all(format!("{open}\n").as_bytes())
        .expect("writes the open request");
    let ack: Value =
        serde_json::from_str(&read_line(&mut socket).expect("an ack line")).expect("the ack is JSON");
    assert_eq!(ack.get("ok"), Some(&Value::Bool(true)), "open failed: {ack}");

    // From here the connection is raw scrcpy. The codec id is four ASCII bytes.
    let codec = read_exactly(&mut socket, 4).expect("a codec id");
    assert_eq!(String::from_utf8_lossy(&codec), "h264");

    // Then exactly one session header: MSB set, width and height big-endian at 4 and 8.
    let session = read_exactly(&mut socket, 12).expect("a session header");
    assert_eq!(
        session.first().map(|byte| byte & 0x80),
        Some(0x80),
        "expected a session header"
    );
    let width = be32(&session, 4);
    let height = be32(&session, 8);
    assert!(width > 0 && height > 0, "the session header has no dimensions");
    // `max_size` genuinely bites here, unlike the simulator server's ignored `scale`.
    assert!(
        width.max(height) <= 1024,
        "max_size was not honoured: {width}x{height}"
    );

    // The first media packet must be the config packet — SPS/PPS in Annex-B, which is what the
    // client's format description is built from. Its start code proves the framing is Annex-B and
    // NOT the AVCC the simulator panel receives.
    let mut saw_config = false;
    let mut saw_keyframe = false;
    for _packet in 0..40 {
        let Some(header) = read_exactly(&mut socket, 12) else {
            break;
        };
        let flags = header.first().copied().unwrap_or(0);
        if flags & 0x80 != 0 {
            continue;
        }
        let length = usize::try_from(be32(&header, 8)).unwrap_or(0);
        assert!(length > 0, "a media packet claimed no payload");
        let payload = read_exactly(&mut socket, length).expect("the packet's payload");
        if flags & 0x40 != 0 {
            saw_config = true;
            assert_eq!(
                payload.get(..4),
                Some([0, 0, 0, 1].as_slice()),
                "config must be Annex-B"
            );
            assert_eq!(
                payload.get(4).map(|byte| byte & 0x1F),
                Some(7),
                "the first NAL of the config must be an SPS"
            );
        }
        if flags & 0x20 != 0 {
            saw_keyframe = true;
        }
        if saw_config && saw_keyframe {
            break;
        }
    }
    assert!(
        saw_config,
        "no config packet — the client would have no format description"
    );
    assert!(saw_keyframe, "no keyframe — the client would decode nothing");
}

/// The emulator console is the panel's route to GPS, battery and rotation. It answers only for
/// emulators, which is why the panel offers those verbs on emulator rows alone.
#[test]
fn the_emulator_console_answers() {
    if !enabled() && !skipped("SLOPDESK_ANDROID_HW=1 not set") {
        return;
    }
    let Some((port, _bridge)) = start_bridge() else {
        return;
    };
    let Some(serial) = list_devices(port).and_then(|devices| first_running_emulator(&devices)) else {
        skipped("no booted emulator");
        return;
    };

    let reply = request(
        &json!({ "op": "console", "serial": serial, "command": "avd name" }),
        port,
    )
    .expect("the console verb answers");
    assert_eq!(
        reply.get("ok"),
        Some(&Value::Bool(true)),
        "console failed: {reply}"
    );
    let output = reply
        .get("output")
        .and_then(Value::as_str)
        .expect("the reply carries the console's output");
    assert!(output.contains("OK"), "console said: {output}");
}

/// `open` for a serial `adb` has never heard of is refused BEFORE the scrcpy attempt, with the
/// sentence that says so. The preflight is what turns a mid-boot open from "push, forward, time
/// out, cryptic tunnel error" into an answer the panel's wait loop can act on.
#[test]
fn an_open_for_an_unknown_serial_is_refused_up_front() {
    if !enabled() && !skipped("SLOPDESK_ANDROID_HW=1 not set") {
        return;
    }
    let Some((port, _bridge)) = start_bridge() else {
        return;
    };
    let reply = request(
        &json!({ "op": "open", "serial": "emulator-9999", "maxSize": 1024 }),
        port,
    )
    .expect("the bridge answers");
    assert_eq!(reply.get("ok"), Some(&Value::Bool(false)));
    assert_eq!(
        reply.get("error").and_then(Value::as_str),
        Some(slopdesk_androidd::BridgeError::UnknownDevice.message())
    );
}

/// A malformed first line is answered and the connection closed — never a trap, never a hang.
#[test]
fn a_malformed_request_is_answered() {
    if !enabled() && !skipped("SLOPDESK_ANDROID_HW=1 not set") {
        return;
    }
    let Some((port, _bridge)) = start_bridge() else {
        return;
    };
    let mut socket = connect(port).expect("dials the bridge");
    socket
        .write_all(b"this is not json\n")
        .expect("writes the bad line");
    let reply: Value =
        serde_json::from_str(&read_line(&mut socket).expect("an answer")).expect("the answer is JSON");
    assert_eq!(reply.get("ok"), Some(&Value::Bool(false)));
    assert!(reply.get("error").and_then(Value::as_str).is_some());
}

/// The first serial in state `device`.
fn first_running(devices: &[Value]) -> Option<String> {
    devices
        .iter()
        .find(|device| device.get("state").and_then(Value::as_str) == Some("device"))
        .and_then(|device| device.get("serial").and_then(Value::as_str))
        .map(str::to_owned)
}

/// The first booted EMULATOR's serial — a physical device has no console.
fn first_running_emulator(devices: &[Value]) -> Option<String> {
    devices
        .iter()
        .find(|device| {
            device.get("state").and_then(Value::as_str) == Some("device")
                && device.get("isEmulator") == Some(&Value::Bool(true))
        })
        .and_then(|device| device.get("serial").and_then(Value::as_str))
        .map(str::to_owned)
}
