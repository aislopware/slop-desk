//! The emulator's own telnet control channel.
//!
//! Every running AVD listens on `127.0.0.1:<console port>`, where the port is the number in its
//! `adb` serial (`emulator-5554` → 5554). It is a line protocol: a greeting, then `auth <token>`
//! with the token from `~/.emulator_console_auth_token`, then commands, each answered by output and
//! a bare `OK` or `KO: …`.
//!
//! **Why this and not the emulator's gRPC service.** The emulator also exposes `-grpc <port>`,
//! whose `EmulatorController` covers the same ground. It was rejected for the video path first —
//! its `streamScreenshot` returns PNG or raw RGB888 frames, megabytes per frame at 1080×2400, and
//! the WebRTC alternative needs a `goldfish-webrtc-bridge` binary that ships only in Google's
//! container images. Having chosen scrcpy for frames, gRPC's remaining value is control — and a
//! protobuf stack is a large dependency for a feature set this text protocol already covers.
//!
//! What it buys the panel, verified against a live AVD on 2026-08-04: `geo fix`, `rotate`,
//! `power capacity`, `sms send`, `gsm`, `network` shaping, `fold`/`unfold`, `sensor set`,
//! `finger touch`. It answers only for EMULATORS — a physical device has no console.

use std::io::{Read as _, Write as _};
use std::net::TcpStream;
use std::path::Path;
use std::time::Duration;

use crate::net::connect_loopback;

/// How much is read per turn, and the window the verdict scan looks back over.
const CHUNK: usize = 8192;

/// The console port carried by an emulator's serial, or `None` for a physical device's serial.
#[must_use]
pub fn port_for_serial(serial: &str) -> Option<u16> {
    serial.strip_prefix("emulator-")?.parse().ok()
}

/// The shared auth token. Read fresh per session rather than cached: the emulator rewrites it, and
/// a cached token survives into a run where it is wrong.
#[must_use]
pub fn auth_token(home: &Path) -> Option<String> {
    let text = std::fs::read_to_string(home.join(".emulator_console_auth_token")).ok()?;
    let token = text.trim();
    (!token.is_empty()).then(|| token.to_owned())
}

/// Runs one command and returns everything the console said before its verdict line.
///
/// Blocking, like the rest of the bridge. `None` means the console could not be reached or refused
/// the token; a `KO: …` verdict is returned as TEXT, because the console's own complaint
/// ("KO: unknown command") is a better message than any this layer could invent.
#[must_use]
pub fn run(command: &str, serial: &str, home: &Path, timeout: Duration) -> Option<String> {
    let port = port_for_serial(serial)?;
    let token = auth_token(home)?;
    let mut stream = connect_loopback(port, timeout)?;

    // The greeting arrives unprompted and has no fixed length, so it is drained by reading until
    // the console falls quiet rather than by counting bytes.
    let _greeting = drain(&mut stream);
    stream.write_all(format!("auth {token}\n").as_bytes()).ok()?;
    let reply = drain(&mut stream)?;
    if !reply.contains("OK") {
        return None;
    }

    stream.write_all(format!("{command}\n").as_bytes()).ok()?;
    drain(&mut stream)
}

/// Reads until the console stops talking.
///
/// The socket carries a receive timeout from [`connect_loopback`], so a console that says nothing
/// more ends this loop instead of parking the thread — which is the whole reason the reply is not
/// parsed for a terminator: `help` ends with a bare command name, and `sensor status` ends with a
/// line that has no verdict at all.
fn drain(stream: &mut TcpStream) -> Option<String> {
    let mut collected: Vec<u8> = Vec::new();
    let mut buffer = [0_u8; CHUNK];
    while let Ok(read) = stream.read(&mut buffer) {
        if read == 0 {
            break;
        }
        collected.extend_from_slice(buffer.get(..read).unwrap_or_default());
        if collected.len() > 256 * 1024 {
            break;
        }
        // A verdict line ends a well-formed reply; the timeout ends every other kind. Matched on
        // BYTES rather than on a decoded string: the tail of a chunk can split a multi-byte
        // sequence, and re-decoding the whole buffer per chunk is quadratic in a reply that can run
        // to a quarter of a megabyte.
        if ends_with_verdict(&collected) {
            break;
        }
    }
    if collected.is_empty() {
        return None;
    }
    // Lossy: the console echoes whatever a command printed, and a reply that survived the handshake
    // must reach the caller even if one byte of it is not UTF-8.
    Some(String::from_utf8_lossy(&collected).into_owned())
}

/// Whether the reply has reached its verdict.
///
/// `KO` is looked for over the NEWEST bytes only: the verdict is the last thing the console says,
/// so a window covering the chunk just appended plus the boundary it may straddle sees everything a
/// whole-buffer scan would.
#[must_use]
pub fn ends_with_verdict(data: &[u8]) -> bool {
    let tail = data.get(data.len().saturating_sub(CHUNK + 4)..).unwrap_or(data);
    if tail.ends_with(b"OK\r\n") || tail.ends_with(b"OK\n") {
        return true;
    }
    tail.windows(3).any(|window| window == b"\nKO")
}

#[cfg(test)]
mod tests {
    use super::{ends_with_verdict, port_for_serial};

    #[test]
    fn the_console_port_is_carried_by_the_serial() {
        assert_eq!(port_for_serial("emulator-5554"), Some(5554));
        assert_eq!(port_for_serial("emulator-5556"), Some(5556));
        // A physical device has no console — the panel offers its verbs on emulator rows alone.
        assert_eq!(port_for_serial("39121FDJH000TR"), None);
        assert_eq!(port_for_serial("emulator-not-a-number"), None);
    }

    #[test]
    fn both_verdict_spellings_end_a_reply() {
        assert!(ends_with_verdict(b"Pixel_API36\r\nOK\r\n"));
        assert!(ends_with_verdict(b"Pixel_API36\nOK\n"));
        assert!(ends_with_verdict(b"something\nKO: unknown command\r\n"));
    }

    #[test]
    fn output_that_has_not_reached_its_verdict_keeps_reading() {
        assert!(!ends_with_verdict(b"half a line"));
        // `OK` inside a payload is not a verdict — only a trailing one is.
        assert!(!ends_with_verdict(b"OK so far, more coming"));
    }
}
