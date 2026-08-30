//! Starting one device's `scrcpy-server` and handing back its two sockets.
//!
//! The dialect below was measured against `scrcpy-server` v4.1 on 2026-08-04, and the byte-level
//! claims are what `docs/48-android-panel.md` records. scrcpy publishes no wire specification — its
//! own documentation says the protocol is defined by the unit tests on both sides — so the version
//! string is pinned and the jar is located rather than guessed at.
//!
//! ## The launch, in order
//!
//! ```text
//! adb -s S push <jar> /data/local/tmp/scrcpy-server.jar
//! adb -s S forward tcp:0 localabstract:scrcpy_<scid>      → prints the allocated port
//! adb -s S shell CLASSPATH=/data/local/tmp/scrcpy-server.jar \
//!        app_process / com.genymobile.scrcpy.Server 4.1 scid=<scid> …
//! connect 127.0.0.1:<port>  → read ONE byte   (the video socket)
//! connect 127.0.0.1:<port>  →                 (the control socket)
//! read 64 bytes off the video socket          (the device name)
//! adb -s S forward --remove tcp:<port>
//! ```
//!
//! ⚠️ **The 64-byte device name is written only after EVERY expected socket has connected.**
//! Reading it straight after the dummy byte hangs forever against a healthy server — measured, and
//! it looks exactly like a server that failed to start.
//!
//! ⚠️ **Push the jar every session.** It costs milliseconds over `adb` and it is the only defence
//! against a stale optimised-dex cache in `/data/local/tmp/oat`, which makes `app_process` die with
//! the single word `Aborted` — no stack, no scrcpy log line, nothing in `logcat`. Measured
//! 2026-08-04: two hours of a working setup became an unexplained abort, and re-pushing fixed it.
//!
//! ## `clipboard_autosync=false` is load-bearing, not a preference
//!
//! The bridge gives the client ONE full-duplex connection: scrcpy's video stream flows down it and
//! scrcpy's control messages flow up it. That works only because the control socket is, under these
//! options, strictly client→device. scrcpy's server has exactly three device→client messages —
//! clipboard, clipboard-ack and UHID output — and each is reachable only from a request this bridge
//! never makes. Leave autosync on and the device will spontaneously write a clipboard message into
//! a stream the client is parsing as H.264.

use std::net::TcpStream;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::error::BridgeError;
use crate::net::{connect_loopback, read_exactly, shutdown};
use crate::toolchain::Toolchain;

/// Pinned to the jar this build expects.
///
/// scrcpy's server refuses to run unless the client version string matches it EXACTLY, which is a
/// feature: an upgrade that moves the jar under us fails loudly at launch instead of decoding as
/// garbage.
pub const SERVER_VERSION: &str = "4.1";
/// Where the jar is pushed on the device.
pub const DEVICE_JAR_PATH: &str = "/data/local/tmp/scrcpy-server.jar";
/// scrcpy's `SC_DEVICE_NAME_FIELD_LENGTH`.
pub const DEVICE_NAME_LENGTH: usize = 64;

/// Options the panel varies per session. Everything else is fixed by the invariants above.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Options {
    /// The longer edge, in pixels. **This flag genuinely bites** — measured 1080×2400 → 460×1024,
    /// which also doubled the frame rate (13.7 → 25.3 fps) because an emulator has only SOFTWARE
    /// encoders and is encoder-bound.
    pub max_size: i64,
    /// Encoder target. Measured ~2.4 Mbit/s under a continuous drag at 460×1024.
    pub bit_rate: i64,
    /// H.264 and nothing else, by default and on purpose. Measured on this emulator: H.265 at the
    /// same size ran at 11.3 fps against H.264's 25.3, because `c2.android.hevc.encoder` is
    /// software and costs more per frame than the bytes it saves are worth on a mesh. A
    /// physical device with a hardware HEVC encoder would flip that, which is why it is a
    /// field.
    pub codec: Codec,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            max_size: 1024,
            bit_rate: 4_000_000,
            codec: Codec::H264,
        }
    }
}

/// The video codecs the server will accept. A closed set because this string reaches an argument
/// vector, and the server treats an unknown codec as a fatal error.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Codec {
    /// The default — see [`Options::codec`].
    #[default]
    H264,
    /// Worth it only where the encoder is hardware.
    H265,
    /// Likewise.
    Av1,
}

impl Codec {
    /// The server's own spelling.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::H264 => "h264",
            Self::H265 => "h265",
            Self::Av1 => "av1",
        }
    }

    /// The codec a client asked for, or `None` for a word the server would refuse.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "h264" => Some(Self::H264),
            "h265" => Some(Self::H265),
            "av1" => Some(Self::Av1),
            _other => None,
        }
    }
}

/// A running `scrcpy-server` and the two sockets it is speaking through.
#[derive(Debug)]
pub struct Session {
    /// Frames down. Positioned at the codec id — the 64-byte device name has been consumed.
    pub video: TcpStream,
    /// Control messages up. Nothing ever comes back down it (see the module comment).
    pub control: TcpStream,
    /// The device's own name for itself, off the handshake.
    pub device_name: String,
    process: Child,
}

impl Session {
    /// Ends the session.
    ///
    /// Closing the sockets is what actually stops the device-side server (it exits when its stream
    /// socket breaks); killing the `adb shell` is the belt to that braces.
    pub fn stop(&mut self) {
        shutdown(&self.video);
        shutdown(&self.control);
        let _ignored = self.process.kill();
        let _ignored = self.process.wait();
    }

    /// Launches the server and completes the handshake.
    ///
    /// Runs entirely on the calling thread and blocks — call it from the bridge's per-connection
    /// thread, never from anything that answers something else.
    ///
    /// # Errors
    /// A [`BridgeError`] naming the step that failed, which is what the panel renders.
    pub fn start(toolchain: &Toolchain, serial: &str, options: Options) -> Result<Self, BridgeError> {
        let jar = toolchain
            .scrcpy_server_jar
            .as_ref()
            .ok_or(BridgeError::ScrcpyServerMissing)?;
        let jar = jar.to_string_lossy().into_owned();

        let scid = session_id();

        toolchain
            .adb(
                Some(serial),
                &["push", &jar, DEVICE_JAR_PATH],
                Duration::from_mins(1),
            )
            .ok_or(BridgeError::PushFailed)?;

        let socket_name = format!("localabstract:scrcpy_{scid}");
        let port: u16 = toolchain
            .adb(
                Some(serial),
                &["forward", "tcp:0", &socket_name],
                Duration::from_secs(10),
            )
            .and_then(|output| output.trim().parse().ok())
            .ok_or(BridgeError::ForwardFailed)?;

        let result = Self::launch(toolchain, serial, &scid, port, options);

        // The tunnel exists only to get two sockets across; it is removed as soon as they are open,
        // exactly as scrcpy does, so a panel opened thirty times does not leave thirty forwards.
        let remove = format!("tcp:{port}");
        let _ignored = toolchain.adb(
            Some(serial),
            &["forward", "--remove", &remove],
            Duration::from_secs(10),
        );

        result
    }

    /// The half of `start` that runs while the `adb forward` tunnel is up.
    fn launch(
        toolchain: &Toolchain,
        serial: &str,
        scid: &str,
        port: u16,
        options: Options,
    ) -> Result<Self, BridgeError> {
        let mut command = Command::new(&toolchain.adb);
        command
            .args(["-s", serial, "shell", &format!("CLASSPATH={DEVICE_JAR_PATH}")])
            .args(["app_process", "/", "com.genymobile.scrcpy.Server", SERVER_VERSION])
            .args(server_arguments(scid, options))
            // The server's log is its own diagnostic channel and nothing here reads it; discarding
            // it keeps a long session from filling a pipe nobody drains.
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .stdin(Stdio::null());
        let mut process = command.spawn().map_err(|_error| BridgeError::LaunchFailed)?;

        let Some(mut video) = dial_until_the_server_answers(port) else {
            let _ignored = process.kill();
            return Err(BridgeError::ServerDidNotStart);
        };
        let Some(control) = connect_loopback(port, Duration::from_secs(2)) else {
            shutdown(&video);
            let _ignored = process.kill();
            return Err(BridgeError::ServerDidNotStart);
        };
        // A 32-byte touch message that waits for a companion before leaving is a pointer that lags
        // behind the finger, and coalescing buys nothing when the messages are already this small.
        let _ignored = control.set_nodelay(true);

        let Some(name_bytes) = read_exactly(&mut video, DEVICE_NAME_LENGTH) else {
            shutdown(&video);
            shutdown(&control);
            let _ignored = process.kill();
            return Err(BridgeError::ServerDidNotStart);
        };
        // The field is a fixed 64 bytes, NUL-padded; a device whose name fills it has no
        // terminator.
        let trimmed: Vec<u8> = name_bytes.into_iter().take_while(|&byte| byte != 0).collect();
        let device_name = String::from_utf8_lossy(&trimmed).into_owned();

        // Handshake done: from here the stream is quiet for as long as the screen is still
        // (measured idle floor 547 B/s), so the dial-time receive timeout has to go or the
        // pump reads that as a dead peer.
        let _ignored = video.set_read_timeout(None);
        let _ignored = video.set_write_timeout(None);
        let _ignored = control.set_read_timeout(None);
        let _ignored = control.set_write_timeout(None);

        Ok(Self {
            video,
            control,
            device_name,
            process,
        })
    }
}

/// The server's argument vector. Pure, because every line of it is a decision worth pinning.
#[must_use]
pub fn server_arguments(scid: &str, options: Options) -> Vec<String> {
    vec![
        format!("scid={scid}"),
        "log_level=error".to_owned(),
        // The panel is a screen. Audio would be a second socket, a second decoder and a second set
        // of sync questions for something nobody debugs an app by listening to.
        "audio=false".to_owned(),
        format!("video_codec={}", options.codec.as_str()),
        format!("max_size={}", options.max_size),
        format!("video_bit_rate={}", options.bit_rate),
        // The client dials in; the device listens. The alternative (`adb reverse`) needs the device
        // to reach back to the host, which an emulator on a shared machine cannot always do and a
        // device on someone's desk certainly cannot.
        "tunnel_forward=true".to_owned(),
        // See the module comment — this one is not a preference.
        "clipboard_autosync=false".to_owned(),
        // A device that sleeps mid-session leaves a black rectangle and no explanation; the server
        // restores the setting on a clean exit.
        "stay_awake=true".to_owned(),
    ]
}

/// A per-session id, so two clients driving two devices cannot collide on the abstract socket name
/// and a previous session's orphaned server is never mistaken for this one.
///
/// ⚠️ **The top bit must be CLEAR.** The server reads this with `Integer.parseInt(s, 16)`, which is
/// SIGNED, so anything from `80000000` up dies with `NumberFormatException` — on the device, into a
/// log this bridge discards, leaving a launch that simply never answers. Measured 2026-08-04: a
/// full-width 32-bit id fails for half of all sessions, which reads as a flaky panel rather than a
/// bug.
///
/// The entropy is the clock rather than a PRNG dependency: the id only has to be unlikely to repeat
/// within one host's session lifetimes, and nanoseconds-since-boot folded into 31 bits is that.
#[must_use]
pub fn session_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.subsec_nanos());
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs());
    let mixed = u64::from(nanos) ^ seconds.rotate_left(17);
    // Mask to 31 bits: the top one MUST stay clear (see above).
    format!("{:08x}", mixed & 0x7FFF_FFFF)
}

/// Connects, then proves the far side is really the server by reading its dummy byte.
///
/// The `adb forward` tunnel completes a TCP handshake whether or not anything is listening on the
/// device, so a successful `connect` proves nothing at all. The device-side server takes roughly a
/// fifth of a second to come up (measured: first socket at 0.23 s, first keyframe at 0.60 s), and
/// the retry budget below is ~5 s — long enough for a loaded host, short enough that a genuinely
/// broken launch reports rather than hangs.
#[must_use]
fn dial_until_the_server_answers(port: u16) -> Option<TcpStream> {
    for _attempt in 0..100_u8 {
        if let Some(mut stream) = connect_loopback(port, Duration::from_secs(2)) {
            if read_exactly(&mut stream, 1).is_some() {
                return Some(stream);
            }
            shutdown(&stream);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::{Codec, Options, server_arguments, session_id};

    #[test]
    fn the_launch_disables_clipboard_autosync() {
        // What makes the control socket strictly client→device, which is what lets the bridge put
        // video down and control up on ONE connection.
        let arguments = server_arguments("0badf00d", Options::default());
        assert!(arguments.iter().any(|a| a == "clipboard_autosync=false"));
        assert!(arguments.iter().any(|a| a == "tunnel_forward=true"));
        assert!(arguments.iter().any(|a| a == "audio=false"));
        assert!(arguments.iter().any(|a| a == "scid=0badf00d"));
    }

    #[test]
    fn the_default_codec_is_h264() {
        // Even though the server offers H.265 and AV1: measured on this host's emulator, H.265 at
        // the same size ran at 11.3 fps against H.264's 25.3, because every encoder an emulator
        // exposes is a SOFTWARE one.
        assert_eq!(Options::default().codec, Codec::H264);
        assert!(
            server_arguments("x", Options::default())
                .iter()
                .any(|a| a == "video_codec=h264")
        );
    }

    #[test]
    fn the_codec_is_a_closed_set_because_it_reaches_an_argument_vector() {
        assert_eq!(Codec::parse("h265"), Some(Codec::H265));
        assert_eq!(Codec::parse("av1"), Some(Codec::Av1));
        assert_eq!(Codec::parse("vp9; rm -rf /"), None);
        assert_eq!(Codec::parse(""), None);
    }

    #[test]
    fn the_session_id_never_sets_the_top_bit() {
        // The server parses it SIGNED; anything from `80000000` up dies on the device, into a log
        // this bridge discards.
        for _round in 0..64 {
            let id = session_id();
            assert_eq!(id.len(), 8, "the server expects eight hex digits");
            let value = u32::from_str_radix(&id, 16).unwrap_or(u32::MAX);
            assert!(value <= 0x7FFF_FFFF, "the top bit must stay clear, got {id}");
        }
    }

    #[test]
    fn the_options_reach_the_argument_vector_verbatim() {
        let arguments = server_arguments("abc", Options {
            max_size: 720,
            bit_rate: 2_000_000,
            codec: Codec::H265,
        });
        assert!(arguments.iter().any(|a| a == "max_size=720"));
        assert!(arguments.iter().any(|a| a == "video_bit_rate=2000000"));
        assert!(arguments.iter().any(|a| a == "video_codec=h265"));
    }
}
