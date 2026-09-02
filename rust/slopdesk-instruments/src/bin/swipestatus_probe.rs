//! `slopdesk-swipestatus-probe` — does a running videohostd actually PUSH type-3 `SwipeNavStatus`?
//!
//! The push path — `slopdesk_videohostd::navstatus`'s beat → the registry fan-out →
//! `LaneSession::push_nav_status` → the cursor flow (`docs/20-wire-protocol.md` §9.6) — logs
//! nothing unless `SLOPDESK_SWIPE_NAV_TRACE` is set, so "the chip never lit up" and "everything
//! works" read identically from an ordinary host log. This is
//! the discriminator: it mints a real DISPLAY session the way a GUI client would (a `HelloDisplay`
//! on the media socket, a cursor-flow prime on the cursor socket) and reports every cursor-socket
//! message that arrives. The kicker heartbeats every 2 s, so a healthy host shows a type-3 within
//! about 4 s.
//!
//! Exit `0` ⇒ at least one `SwipeNavStatus` arrived. Exit `2` ⇒ none did, which means the push path
//! is dead or gated. Exit `1` ⇒ the probe could not open its sockets or read its arguments.
//!
//! ## Why it is no longer Swift
//! Every shape it speaks — the mux prefix, the control messages, the cursor channel and the status
//! message itself — is `slopdesk_video`'s. The Swift version reached them through
//! `SlopDeskVideoProtocol`, a marshalling face over exactly these types, so the probe questioned
//! the host through a second spelling of the encoder. Here it writes the bytes the host's own crate
//! writes.
//!
//! ```text
//! slopdesk-swipestatus-probe [--host 127.0.0.1] [--port 9000] [--cursor-port 9001]
//!                            [--display-id 0] [--seconds 12]
//! ```

// Every line this probe prints is a reading; the exit code is its verdict, and the readings go to
// stderr so a caller that only wants the verdict can drop them.
#![expect(
    clippy::print_stderr,
    reason = "stderr is this probe's report; the exit code is its verdict"
)]

use std::net::UdpSocket;
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use slopdesk_video::cursor::CursorChannelMessage;
use slopdesk_video::geometry::VideoSize;
use slopdesk_video::mux_header;
use slopdesk_video::session_state::PROTOCOL_VERSION;
use slopdesk_video::swipe_nav::SwipeNavStatusMessage;
use slopdesk_video::video_control::VideoControlMessage;

/// The media mux's control-channel tag. The `VideoChannel` enum lives host- and client-side; the
/// raw tag is the agreement between them.
const CONTROL_TAG: u8 = 0x00;
/// The media mux's video tag — counted, never decoded, as proof frames are flowing.
const VIDEO_TAG: u8 = 0x01;

/// The largest datagram the probe will read.
const READ_BUFFER: usize = 65536;

/// How often the probe re-sends its hello and re-primes the cursor flow.
const TICK: Duration = Duration::from_millis(300);

/// One tick in every this many re-primes the cursor flow — the keepalive idiom the GUI client uses.
const PRIME_EVERY: u32 = 3;

/// The viewport a display session asks for. Nothing depends on it: a desktop pane never resizes the
/// host's display, so the host acks at the display's own size and the client letterboxes.
const VIEWPORT: VideoSize = VideoSize::new(1280.0, 800.0);

/// Everything one run learns, behind one lock because two drain threads write it.
#[derive(Debug, Default)]
struct Learned {
    /// Whether the host accepted the session.
    acked: bool,
    /// Video datagrams seen — the "media is flowing" half.
    video_packets: u64,
    /// Cursor position updates seen.
    cursor_updates: u64,
    /// Cursor shape bitmaps seen.
    cursor_shapes: u64,
    /// Swipe-nav status pushes seen — the thing under test.
    status_count: u64,
    /// The most recent push, for the summary line.
    last_status: Option<SwipeNavStatusMessage>,
}

/// What the caller asked for.
#[derive(Debug)]
struct Options {
    /// The host to dial.
    host: String,
    /// The media port, which carries control and video.
    media_port: u16,
    /// The cursor port, which carries the push under test.
    cursor_port: u16,
    /// The display to stream; `0` resolves to the main display.
    display_id: u32,
    /// How long to watch.
    seconds: f64,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".to_owned(),
            media_port: 9000,
            cursor_port: 9001,
            display_id: 0,
            seconds: 12.0,
        }
    }
}

/// The value that follows the flag at `index`, or a message naming the flag that wanted one.
fn value_after(arguments: &[String], index: usize, flag: &str) -> Result<String, String> {
    arguments
        .get(index + 1)
        .cloned()
        .ok_or_else(|| format!("{flag} needs a value"))
}

/// Reads the command line, or names the argument it could not.
fn parse_options() -> Result<Options, String> {
    let mut options = Options::default();
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let mut index = 0_usize;
    while let Some(flag) = arguments.get(index) {
        match flag.as_str() {
            "--host" => options.host = value_after(&arguments, index, flag)?,
            "--port" => {
                options.media_port = value_after(&arguments, index, flag)?
                    .parse()
                    .map_err(|_| "--port is not a port".to_owned())?;
            },
            "--cursor-port" => {
                options.cursor_port = value_after(&arguments, index, flag)?
                    .parse()
                    .map_err(|_| "--cursor-port is not a port".to_owned())?;
            },
            "--display-id" => {
                options.display_id = value_after(&arguments, index, flag)?
                    .parse()
                    .map_err(|_| "--display-id is not a display id".to_owned())?;
            },
            "--seconds" => {
                options.seconds = value_after(&arguments, index, flag)?
                    .parse()
                    .map_err(|_| "--seconds is not a number of seconds".to_owned())?;
            },
            other => return Err(format!("unknown argument: {other}")),
        }
        index = index.saturating_add(2);
    }
    Ok(options)
}

/// A high, clock-derived lane id.
///
/// The GUI client's allocator is monotonic from small values, so an id in a high band cannot
/// collide with a live lane on a shared daemon. The clock is the source because this program has no
/// randomness dependency and needs none: only two probes started in the same nanosecond would
/// collide, and there is no such pair.
fn lane_id() -> u32 {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.subsec_nanos());
    0x6000_0000 | (nanos & 0x0FFF_FFFF)
}

/// A datagram out. UDP is lossy by design here and every caller re-sends, so a local send error is
/// the same nothing as a datagram dropped on the wire.
fn send(socket: &UdpSocket, datagram: &[u8]) {
    let _sent = socket.send(datagram);
}

/// Seconds since the run began, as the log prints them.
fn stamp(started: Instant) -> String {
    format!("t+{:.1}s", started.elapsed().as_secs_f64())
}

/// Counts video datagrams and reports the first `HelloAck`.
fn drain_media(socket: &UdpSocket, learned: &Mutex<Learned>, started: Instant) {
    let mut buffer = vec![0_u8; READ_BUFFER];
    loop {
        let Ok(read) = socket.recv(&mut buffer) else {
            std::thread::sleep(TICK);
            continue;
        };
        let Some(datagram) = buffer.get(..read) else {
            continue;
        };
        let Ok((_, rest)) = mux_header::decode(datagram) else {
            continue;
        };
        let Some((tag, payload)) = rest.split_first() else {
            continue;
        };
        if *tag == VIDEO_TAG {
            if let Ok(mut state) = learned.lock() {
                state.video_packets = state.video_packets.saturating_add(1);
            }
            continue;
        }
        if *tag != CONTROL_TAG {
            continue;
        }
        let Ok(VideoControlMessage::HelloAck {
            accepted,
            stream_id,
            capture_width,
            capture_height,
            ..
        }) = VideoControlMessage::decode(payload)
        else {
            continue;
        };
        let mut first = false;
        if let Ok(mut state) = learned.lock() {
            first = !state.acked;
            state.acked = true;
        }
        if first {
            eprintln!(
                "{} helloAck accepted={accepted} stream={stream_id} {capture_width}x{capture_height}",
                stamp(started)
            );
        }
    }
}

/// Classifies every cursor-socket message, and prints each swipe-nav status as it lands.
fn drain_cursor(socket: &UdpSocket, learned: &Mutex<Learned>, started: Instant) {
    let mut buffer = vec![0_u8; READ_BUFFER];
    loop {
        let Ok(read) = socket.recv(&mut buffer) else {
            std::thread::sleep(TICK);
            continue;
        };
        let Some(datagram) = buffer.get(..read) else {
            continue;
        };
        let Ok((_, payload)) = mux_header::decode(datagram) else {
            continue;
        };
        let Ok(message) = CursorChannelMessage::decode(payload) else {
            continue;
        };
        let mut line = None;
        if let Ok(mut state) = learned.lock() {
            match message {
                CursorChannelMessage::Update(_) => {
                    state.cursor_updates = state.cursor_updates.saturating_add(1);
                },
                CursorChannelMessage::Shape(_) => {
                    state.cursor_shapes = state.cursor_shapes.saturating_add(1);
                },
                CursorChannelMessage::SwipeNavStatus(status) => {
                    state.status_count = state.status_count.saturating_add(1);
                    state.last_status = Some(status);
                    let history = if status.history_known {
                        format!("back={} fwd={}", status.can_go_back, status.can_go_forward)
                    } else {
                        "unknown".to_owned()
                    };
                    line = Some(format!(
                        "{} SwipeNavStatus #{}: eligible={} slowTier={} fireTravel={} history={history}",
                        stamp(started),
                        state.status_count,
                        status.eligible,
                        status.slow_tier,
                        status.fire_travel
                    ));
                },
            }
        }
        if let Some(line) = line {
            eprintln!("{line}");
        }
    }
}

/// Binds an ephemeral local port and points it at `host:port`.
fn dial(host: &str, port: u16) -> Result<UdpSocket, String> {
    let socket = UdpSocket::bind("0.0.0.0:0").map_err(|error| format!("bind: {error}"))?;
    socket
        .connect((host, port))
        .map_err(|error| format!("connect {host}:{port}: {error}"))?;
    Ok(socket)
}

/// Mint a display session, watch the cursor socket, and report what arrived.
fn main() -> ExitCode {
    let options = match parse_options() {
        Ok(options) => options,
        Err(failure) => {
            eprintln!("{failure}");
            return ExitCode::from(1);
        },
    };

    let media = match dial(&options.host, options.media_port) {
        Ok(socket) => socket,
        Err(failure) => {
            eprintln!("{failure}");
            return ExitCode::from(1);
        },
    };
    let cursor = match dial(&options.host, options.cursor_port) {
        Ok(socket) => socket,
        Err(failure) => {
            eprintln!("{failure}");
            return ExitCode::from(1);
        },
    };
    let (Ok(media_drain), Ok(cursor_drain)) = (media.try_clone(), cursor.try_clone()) else {
        eprintln!("could not clone a socket for its drain thread");
        return ExitCode::from(1);
    };

    let lane = lane_id();
    let hello = VideoControlMessage::HelloDisplay {
        protocol_version: PROTOCOL_VERSION,
        requested_display_id: options.display_id,
        viewport: VIEWPORT,
    };
    let hello_datagram = mux_header::encode_media(lane, CONTROL_TAG, &hello.encode());
    let bye_datagram = mux_header::encode_media(lane, CONTROL_TAG, &VideoControlMessage::Bye.encode());
    // The cursor flow is primed with a one-byte body on the lane, exactly as the GUI client primes
    // it.
    let prime_datagram = mux_header::encode(lane, &[0x00]);

    eprintln!(
        "probe -> {}:{}/{} helloDisplay(display={}) lane={lane:#x}, {:.0}s",
        options.host, options.media_port, options.cursor_port, options.display_id, options.seconds
    );

    let learned = Arc::new(Mutex::new(Learned::default()));
    let started = Instant::now();
    // Both drains run for the life of the process; nothing joins them, because the deadline below
    // is the run and returning from `main` is how it ends.
    let media_state = Arc::clone(&learned);
    let _media_thread = std::thread::spawn(move || drain_media(&media_drain, &media_state, started));
    let cursor_state = Arc::clone(&learned);
    let _cursor_thread = std::thread::spawn(move || drain_cursor(&cursor_drain, &cursor_state, started));

    let deadline = started + Duration::from_secs_f64(options.seconds);
    let mut until_prime = 0_u32;
    while Instant::now() < deadline {
        if !learned.lock().is_ok_and(|state| state.acked) {
            send(&media, &hello_datagram);
        }
        if until_prime == 0 {
            send(&cursor, &prime_datagram);
            until_prime = PRIME_EVERY;
        }
        until_prime = until_prime.saturating_sub(1);
        std::thread::sleep(TICK);
    }
    send(&media, &bye_datagram);

    let Ok(state) = learned.lock() else {
        eprintln!("probe done — the shared state was poisoned, so nothing can be reported");
        return ExitCode::from(2);
    };
    eprintln!(
        "probe done — helloAck={} videoPkts={} cursorUpdates={} shapes={} swipeNavStatus={} last={:?}",
        state.acked,
        state.video_packets,
        state.cursor_updates,
        state.cursor_shapes,
        state.status_count,
        state.last_status
    );
    if state.status_count > 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(2)
    }
}
