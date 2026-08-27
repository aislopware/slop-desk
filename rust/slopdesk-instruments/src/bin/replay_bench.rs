//! `slopdesk-replay-bench` — how long a cold reattach stalls on the compose.
//!
//! Times [`Verb::Compose`] — the whole cold-reattach state-transfer render — over synthetic churn
//! shaped like the workloads that actually fill the `ReplayBuffer` ring. The number is END-TO-END
//! through `slopdesk-screend`: the frame encode, the `AF_UNIX` round trip, and the parse + render.
//! That is the number this bench exists to move; it was 17.9 MiB/s when the parser was Swift and
//! ~21 MiB/s after the model walk was fixed (`docs/DECISIONS.md`, 2026-07-25).
//!
//! ## Why it is no longer Swift
//! `TerminalReplaySnapshot` is a 47-line face over `ScreenClient`, which is a face over this wire.
//! Timing it from Swift measured two marshalling layers around the thing under test, and — worse —
//! FELL BACK to passthrough when no screend was listening, so the run printed a meaningless number
//! that only the rendered-byte count gave away. Here a missing daemon is a non-zero exit that says
//! so.
//!
//! ## The 64 MiB case was never really 64 MiB
//! A request frame is `HEADER_LEN + pane + raw`, and screend refuses one past
//! [`slopdesk_screenwire::MAX_FRAME`] — which is 64 MiB exactly. So a 64 MiB churn plus its header
//! is eight bytes over the cliff, and the Swift bench's largest size silently took the passthrough
//! path. Sizes are clamped to what actually fits and the byte count sent is printed.
//!
//! Deterministic: a seeded LCG, no clock and no randomness in the stream, so two runs are
//! comparable. It needs a screend — `just screend` builds one and hostd starts one at connect.
//!
//! ```text
//! slopdesk-replay-bench [mib…]     # default sizes 4, 16, 64
//! ```

// A candidate count or a byte count becomes an `f64` to be divided into a rate. The counts here are
// millions of comparisons and tens of megabytes, `f64` is exact to 2^53, so the loss the lint names
// cannot occur — and a `try_from` ladder around arithmetic with no failure mode would only make the
// number harder to read. Scoped to the two benches that print rates.
#![expect(
    clippy::cast_precision_loss,
    reason = "counts far below 2^53 divided into a rate"
)]

use std::io::{Read as _, Write as _};
use std::os::unix::net::UnixStream;
use std::process::ExitCode;
use std::time::Instant;

use slopdesk_screenwire::{
    FLAG_REASSERT_INPUT_MODES, HEADER_LEN, LENGTH_PREFIX_LEN, MAX_FRAME, Request, SOCKET_ENV_KEY, Status,
    Verb, decode_reply, encode_request, reply_body_length, socket_path,
};

/// The pane geometry every size is composed at — a typical pane, and the one the Swift bench used,
/// so today's number is comparable with the ones already recorded.
const ROWS: usize = 45;
/// The pane width, for [`ROWS`]' reason.
const COLS: usize = 170;

/// Sizes in MiB when the caller names none.
const DEFAULT_SIZES: [usize; 3] = [4, 16, 64];

/// Bytes in a mebibyte.
const MIB: usize = 1024 * 1024;

/// The deterministic filler's generator — the same constants the Swift instrument used, so the
/// corpus is the same corpus and the numbers stay comparable across the port.
#[derive(Debug)]
struct Lcg {
    /// The running state.
    state: u64,
}

impl Lcg {
    /// A generator seeded exactly as the Swift bench seeded it.
    const fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    /// The next raw word.
    const fn step(&mut self) -> u64 {
        self.state = self
            .state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        self.state
    }

    /// The next word folded into `0..bound`. `bound` is a non-zero literal at every call site.
    const fn below(&mut self, bound: u64) -> u64 {
        self.step() % bound
    }
}

/// The words a synthetic build line uses.
const WORDS: [&str; 6] = ["Compiling", "Testing", "Building", "Linking", "Planning", "Write"];

/// The files a synthetic build line names.
const FILES: [&str; 4] = [
    "MuxChannelSession.swift",
    "ReplayBuffer.swift",
    "HostServer.swift",
    "PaneScreenScanner.swift",
];

/// Synthetic PTY churn of about `target` bytes, in the three shapes that fill a real ring.
///
/// Build/test log lines with SGR colour runs, `\r`-overprint progress bars (the compaction-heavy
/// shape), and prompt redraw clusters (OSC 133 + DECSCUSR + an SGR-heavy prompt).
fn make_churn(target: usize) -> Vec<u8> {
    let mut rng = Lcg::new(0x5EED);
    let mut out: Vec<u8> = Vec::with_capacity(target + 4096);
    while out.len() < target {
        match rng.below(10) {
            0..=4 => {
                // A build/test log line with a colour run.
                let word = WORDS
                    .get(usize::try_from(rng.below(6)).unwrap_or(0))
                    .copied()
                    .unwrap_or("Compiling");
                let file = FILES
                    .get(usize::try_from(rng.below(4)).unwrap_or(0))
                    .copied()
                    .unwrap_or("ReplayBuffer.swift");
                let step = rng.below(9000);
                out.extend_from_slice(
                    format!("\u{1b}[1m[{step}/9000]\u{1b}[0m {word} SlopDeskHost {file}\r\n").as_bytes(),
                );
            },
            5..=7 => {
                // A `\r`-overprint progress bar, repainted many times.
                let repaints = 20 + rng.below(60);
                for painted in 0..repaints {
                    let percent = std::cmp::min(100, painted * 100 / repaints);
                    let bar = "=".repeat(usize::try_from(percent / 4).unwrap_or(0));
                    let counter = rng.below(100_000);
                    out.extend_from_slice(
                        format!("\r\u{1b}[K\u{1b}[32m[{bar}>\u{1b}[0m] {percent}% ({counter} / 100000)")
                            .as_bytes(),
                    );
                }
                out.extend_from_slice(b"\r\n");
            },
            _ => {
                // A prompt redraw cluster: OSC 133 marks, DECSCUSR, an SGR-heavy prompt.
                out.extend_from_slice(
                    concat!(
                        "\u{1b}]133;A\u{7}\u{1b}[5 q\u{1b}[1;36m~/oss/slop-desk\u{1b}[0m ",
                        "\u{1b}[35mmain\u{1b}[0m \u{276f} \u{1b}]133;B\u{7}git push\r\n",
                        "\u{1b}[0 q\u{1b}]133;C\u{7}"
                    )
                    .as_bytes(),
                );
            },
        }
    }
    out
}

/// One request, one reply. The payload is the verb's result; anything else is an error naming it.
fn round_trip(stream: &mut UnixStream, request: &Request<'_>) -> Result<Vec<u8>, String> {
    let frame = encode_request(request);
    stream
        .write_all(&frame)
        .map_err(|error| format!("write: {error}"))?;
    stream.flush().map_err(|error| format!("flush: {error}"))?;

    let mut prefix = [0_u8; LENGTH_PREFIX_LEN];
    stream
        .read_exact(&mut prefix)
        .map_err(|error| format!("read reply length: {error}"))?;
    let length = reply_body_length(prefix)
        .ok_or_else(|| "screend answered a frame length this end will not read".to_owned())?;
    let mut body = vec![0_u8; length];
    stream
        .read_exact(&mut body)
        .map_err(|error| format!("read reply body: {error}"))?;

    let (status, payload) = decode_reply(&body).map_err(|error| format!("reply: {error:?}"))?;
    if status == Status::Ok {
        return Ok(payload.to_vec());
    }
    Err(format!(
        "screend answered {status:?}: {}",
        String::from_utf8_lossy(payload)
    ))
}

/// The largest churn that still leaves the request frame under screend's ceiling.
const fn largest_raw() -> usize {
    MAX_FRAME - HEADER_LEN
}

/// Dial screend, then time one compose per requested size.
fn main() -> ExitCode {
    let asked: Vec<usize> = std::env::args()
        .skip(1)
        .filter_map(|argument| argument.parse::<usize>().ok())
        .collect();
    let sizes = if asked.is_empty() {
        DEFAULT_SIZES.to_vec()
    } else {
        asked
    };

    let socket_override = std::env::var_os(SOCKET_ENV_KEY);
    let tmpdir = std::env::var_os("TMPDIR");
    let path = socket_path(socket_override.as_deref(), tmpdir.as_deref());

    let Ok(mut stream) = UnixStream::connect(&path) else {
        eprintln!(
            "no screend listening at {} — `just screend` builds it, and hostd starts one. Without it there \
             is no compose to time.",
            path.display()
        );
        return ExitCode::from(1);
    };

    let hello = Request {
        verb: Verb::Hello,
        flags: 0,
        rows: 0,
        cols: 0,
        pane: "",
        raw: &[],
    };
    match round_trip(&mut stream, &hello) {
        Ok(banner) => println!("screend: {}", String::from_utf8_lossy(&banner).trim_end()),
        Err(failure) => {
            eprintln!("screend did not answer hello: {failure}");
            return ExitCode::from(1);
        },
    }

    println!("compose bench — rows={ROWS} cols={COLS} (typical pane), churn=synthetic build/test stream");
    for mib in sizes {
        let target = std::cmp::min(mib.saturating_mul(MIB), largest_raw());
        let input = make_churn(target);
        let request = Request {
            verb: Verb::Compose,
            flags: FLAG_REASSERT_INPUT_MODES,
            rows: ROWS,
            cols: COLS,
            pane: "",
            raw: &input,
        };
        let started = Instant::now();
        let rendered = match round_trip(&mut stream, &request) {
            Ok(rendered) => rendered,
            Err(failure) => {
                eprintln!("  {mib:3} MiB — FAILED: {failure}");
                return ExitCode::from(1);
            },
        };
        let seconds = started.elapsed().as_secs_f64();
        // Left to right, one division at a time — the same fold the Swift instrument printed.
        let rate = input.len() as f64 / 1024.0 / 1024.0 / seconds;
        println!(
            "  {mib:3} MiB in  {seconds:7.3} s   ({rate:6.1} MiB/s)  -> sent {} bytes, rendered {} bytes",
            input.len(),
            rendered.len()
        );
    }
    ExitCode::SUCCESS
}
