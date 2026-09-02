//! PATH 2 smoothness harness: how much of a moving source's cadence survives the stream?
//!
//! ## Why it exists
//! [`super::video`] proves the pipe is ALIVE — a decoded frame, a presented frame — and says
//! nothing about how many of the source's frames reached the client's glass or how evenly. Every
//! smoothness claim before this was read off a hand-scrolled window by eye, and the memory of those
//! runs records why that ranks nothing: pause variance in a hand scroll is larger than any lever.
//!
//! ## What it measures
//! A Chrome `--app` page that scrolls itself at the display's refresh under `requestAnimationFrame`
//! — deterministic 60 fps motion with NO input path in it — is served by `slopdesk-videohostd` to
//! one client, and `slopdesk-framewatch` watches BOTH windows at once for the same span:
//!
//! - the SOURCE window, which is the ceiling (a `ScreenCaptureKit` capture delivers a frame only
//!   when the window's content changed, so its arrival cadence IS the page's presentation cadence);
//! - the client's REMOTE window, which is what the user's eye sees after capture → encode → UDP →
//!   decode → the pacer → a Metal present.
//!
//! Each side reports new frames, effective fps, the inter-frame interval at p50/p90/p99/max, the
//! stall bins and the identical-content re-deliveries. The ratio of remote to source frames is the
//! headline: 1.0 is every source frame on the glass; 0.5 is every other one.
//!
//! With [`Options::latency`] the page FLASHES instead (dark ↔ light every 500 ms, longer than the
//! instrument's ±450 ms pairing window) and the same two windows go through framewatch's latency
//! mode — per-flash compositor-to-compositor delay, p50/p90/min/max — so a cadence change can be
//! checked against the latency it cost on the same harness.
//!
//! ## What it asserts
//! The verdict is the source's own cadence (below 50 fps the machine is too loaded to measure
//! anything, or the page never scrolled), a streaming remote window, and — when `--floor` is
//! given — a remote fps at or above it. The numbers themselves are the report; the floor is the
//! ratchet a measured default earns.
//!
//! ## Why the titles are disjoint
//! framewatch matches a title by SUBSTRING and then takes the largest window, so a client window
//! titled `"<source> (remote)"` — the video gate's shape — would match the source's own query and
//! the instrument would read one window twice. `SRCSCROLL` / `SRCFLASH` and `SDREMOTE` share no
//! substring.
//!
//! Needs an unlocked Aqua session and Screen-Recording TCC for BOTH `slopdesk-videohostd` and
//! `slopdesk-framewatch`. Whatever `SLOPDESK_*` is in the environment reaches the host and the
//! client, which is how an A/B is typed: `SLOPDESK_PACER=deadline just gui-smooth`.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use std::{fs, thread};

use super::video::{ClientProcess, VideoHost, autoconnect_environment, await_first_frame, shareable_listing};
use super::{Hostd, Suite, banner, build_app, complain, framewatch_binary, poll, port, reap, say, work_dir};
use crate::ops::container;

/// The scrolling page's title, and the framewatch query for it.
const SCROLL_TITLE: &str = "SRCSCROLL";
/// The flashing page's title.
const FLASH_TITLE: &str = "SRCFLASH";
/// The client's remote window title — disjoint from both source titles, see the module note.
const REMOTE_TITLE: &str = "SDREMOTE";
/// The source window, in points; the same 1280×800 the latency runs of 2026-08-06 used.
const SOURCE_SIZE: (u32, u32) = (1280, 800);
/// Below this the source itself is not a 60 fps workload and nothing downstream can be read.
const SOURCE_FLOOR_FPS: f64 = 50.0;
/// How many remote frames say "streaming" rather than "one IDR and silence".
const REMOTE_MIN_FRAMES: f64 = 30.0;
/// The framewatch capture ceiling: twice the display so a 60 Hz arrival is never quantised by it.
const WATCH_HZ: &str = "120";
/// The host's per-frame line (one in fifteen) under `SLOPDESK_VIDEO_DEBUG`, `session_pump.rs`.
const ENCODED_MARK: &str = "encoded+sent frame #";
/// The client's per-frame line (one in fifteen), `SlopDeskVideoClientSession.finishDecode`.
const DECODED_MARK: &str = "DECODED frame #";

/// What the caller asked for.
#[derive(Debug, Clone, Copy)]
pub struct Options {
    /// How long each framewatch watches, in seconds.
    pub seconds: u32,
    /// `--fps N` for the host; `None` leaves the daemon's default in place.
    pub fps: Option<u32>,
    /// `--scale N` for the host; `None` leaves the daemon's default in place.
    pub scale: Option<f64>,
    /// The flash page and framewatch's latency mode instead of the scroll page and cadence.
    pub latency: bool,
    /// The remote fps at or above which the cadence run passes; `0` reports without a ratchet.
    pub floor_fps: f64,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            seconds: 15,
            fps: None,
            scale: None,
            latency: false,
            floor_fps: 0.0,
        }
    }
}

/// One framewatch cadence report, understood.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Cadence {
    /// Deliveries the capture made, identical re-deliveries included.
    pub frames: f64,
    /// Deliveries per second over the span they took.
    pub fps: f64,
    /// The span the deliveries covered, in seconds.
    pub span: f64,
    /// Inter-frame interval, milliseconds.
    pub p50: f64,
    /// Inter-frame interval, milliseconds.
    pub p90: f64,
    /// Inter-frame interval, milliseconds.
    pub p99: f64,
    /// Inter-frame interval, milliseconds.
    pub max: f64,
    /// Intervals of one empty 60 Hz slot (28–42 ms).
    pub one_slot: f64,
    /// Intervals of two empty slots (42–60 ms).
    pub two_slot: f64,
    /// Intervals longer than 60 ms.
    pub longer: f64,
    /// Deliveries whose content matched the previous one.
    pub repeats: f64,
}

impl Cadence {
    /// Read framewatch's four cadence lines. `None` when any of them is missing — an instrument
    /// that refused to start prints its reason on stderr and none of these.
    #[must_use]
    pub fn parse(report: &str) -> Option<Self> {
        Some(Self {
            frames: number_after(report, "frames=")?,
            fps: number_after(report, "eff_fps=")?,
            span: number_after(report, "span=")?,
            p50: number_after(report, "p50=")?,
            p90: number_after(report, "p90=")?,
            p99: number_after(report, "p99=")?,
            max: number_after(report, "max=")?,
            one_slot: number_after(report, "28-42ms(1-slot)=")?,
            two_slot: number_after(report, "42-60ms(2-slot)=")?,
            longer: number_after(report, ">60ms=")?,
            repeats: number_after(report, "re-deliveries=")?,
        })
    }

    /// Deliveries whose content was NEW — the frames a viewer could tell apart.
    ///
    /// A capture re-delivers an unchanged window whenever the display around it recomposites (a
    /// client presenting without vsync makes the SOURCE read 80 deliveries a second), so the
    /// delivery count says how busy the display was and this says how many frames there were.
    #[must_use]
    pub fn unique(&self) -> f64 {
        (self.frames - self.repeats).max(0.0)
    }

    /// New frames per second over the span.
    #[must_use]
    pub fn unique_fps(&self) -> f64 {
        self.unique() / self.span.max(f64::EPSILON)
    }

    /// One table row.
    fn row(&self, label: &str) -> String {
        format!(
            "{label:<10} {:>5} {:>6.1} {:>6} {:>7.1} {:>7.1} {:>7.1} {:>7.1} {:>6} {:>6} {:>6}",
            self.unique(),
            self.unique_fps(),
            self.frames,
            self.p50,
            self.p90,
            self.p99,
            self.max,
            self.one_slot,
            self.two_slot,
            self.longer
        )
    }
}

/// The table's header, aligned with [`Cadence::row`]. `new` is the frame count a viewer could tell
/// apart; `deliv` is every delivery, repeats included, and the interval columns are over those.
const CADENCE_HEADER: &str =
    "window       new  new/s  deliv  p50/ms  p90/ms  p99/ms  max/ms 1-slot 2-slot  >60ms";

/// One framewatch latency report, understood.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Latency {
    /// Source flips the detector saw.
    pub source_flips: f64,
    /// Client flips it saw.
    pub client_flips: f64,
    /// Flips paired within the window.
    pub paired: f64,
    /// Compositor-to-compositor, milliseconds.
    pub p50: f64,
    /// Compositor-to-compositor, milliseconds.
    pub p90: f64,
    /// Compositor-to-compositor, milliseconds.
    pub min: f64,
    /// Compositor-to-compositor, milliseconds.
    pub max: f64,
}

impl Latency {
    /// Read framewatch's latency lines. `None` when too few pairs formed for the distribution line
    /// to print — the instrument's own "setup, not a measurement" answer.
    #[must_use]
    pub fn parse(report: &str) -> Option<Self> {
        Some(Self {
            source_flips: number_after(report, "sourceFlips=")?,
            client_flips: number_after(report, "clientFlips=")?,
            paired: number_after(report, "paired=")?,
            p50: number_after(report, "glass-to-glass p50=")?,
            p90: number_after(report, "p90=")?,
            min: number_after(report, "min=")?,
            max: number_after(report, "max=")?,
        })
    }
}

/// The lines of a paired framewatch report that carry `tag` — `framewatch[A]: …` — joined back into
/// one report [`Cadence::parse`] reads.
#[must_use]
pub fn tagged_lines(report: &str, tag: &str) -> String {
    let prefix = format!("framewatch[{tag}]:");
    report
        .lines()
        .filter(|line| line.starts_with(&prefix))
        .fold(String::new(), |mut joined, line| {
            joined.push_str(line);
            joined.push('\n');
            joined
        })
}

/// The host's debug lines a cadence run counts, each with the word the table uses for it.
const HOST_MARKS: &[(&str, &str)] = &[
    ("capture delivery gap", "capture delivery gaps"),
    ("frame dropped", "encoder-size drops"),
    ("encoder self-dropped", "encoder self-drops"),
    ("encode-load pacer:", "encode-load pacer steps"),
    ("backpressure skip", "backpressure skips"),
    ("send gap", "send gaps"),
];
/// The client's.
const CLIENT_MARKS: &[(&str, &str)] = &[("present gap", "present gaps")];

/// Line counts for a set of marks, taken twice so the steady state can be read as a difference.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Counts(Vec<usize>);

impl Counts {
    fn of(log: &super::Log, marks: &[(&str, &str)]) -> Self {
        Self(marks.iter().map(|(mark, _)| log.count(mark)).collect())
    }

    fn since(&self, earlier: &Self) -> Self {
        Self(
            self.0
                .iter()
                .zip(earlier.0.iter())
                .map(|(now, before)| now.saturating_sub(*before))
                .collect(),
        )
    }

    fn describe(&self, marks: &[(&str, &str)]) -> String {
        self.0
            .iter()
            .zip(marks.iter())
            .map(|(count, (_, word))| format!("{count} {word}"))
            .collect::<Vec<_>>()
            .join(", ")
    }
}

/// The frame id on the LAST line of `text` carrying `mark`, or `0` when there is none.
///
/// Read as an integer, not through the float parser: a frame id is a count, and the two ids a run
/// subtracts must be exact.
#[must_use]
pub fn last_frame_id(text: &str, mark: &str) -> u32 {
    text.lines()
        .rev()
        .find_map(|line| {
            let after = &line[line.find(mark)? + mark.len()..];
            let digits: String = after.chars().take_while(char::is_ascii_digit).collect();
            digits.parse().ok()
        })
        .unwrap_or(0)
}

/// The number that follows the first `key` in `text`: an optional sign, digits, one optional
/// fraction. `None` when the key is absent or nothing numeric follows it.
#[must_use]
pub fn number_after(text: &str, key: &str) -> Option<f64> {
    let start = text.find(key)? + key.len();
    let rest = text.get(start..)?;
    let end = rest
        .char_indices()
        .find(|(index, character)| {
            !(character.is_ascii_digit() || *character == '.' || (*index == 0 && *character == '-'))
        })
        .map_or(rest.len(), |(index, _)| index);
    rest.get(..end)?.parse().ok()
}

/// The page that scrolls itself: four thousand paragraphs, six points per animation frame, bouncing
/// at either end. Text rather than a gradient because text is what the product streams and what
/// the encoder's rate control is tuned on.
fn scroll_page() -> String {
    format!(
        "<!doctype html><html><head><meta \
         charset=\"utf-8\"><title>{SCROLL_TITLE}</title><style>body{{margin:0;font:16px/1.5 \
         -apple-system,Helvetica;background:#fff;color:#222}}p{{margin:0 24px \
         12px;max-width:900px}}</style></head><body><div id=\"t\"></div><script>const \
         t=document.getElementById('t');let s='';for(let i=0;i<4000;i++){{s+='<p><b>'+i+'</b> Lorem ipsum \
         dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore \
         magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip \
         ex ea commodo consequat. ('+(i*7919%1000)+')</p>';}}t.innerHTML=s;const \
         max=()=>document.documentElement.scrollHeight-window.innerHeight;let y=0,dir=1;const px=6;function \
         step(){{y+=dir*px;if(y>=max()){{y=max();dir=-1}}if(y<=0){{y=0;dir=1}}window.scrollTo(0,y);\
         requestAnimationFrame(step)}}requestAnimationFrame(step);</script></body></html>"
    )
}

/// The page that flashes: the whole viewport dark ↔ light every 500 ms.
fn flash_page() -> String {
    format!(
        "<!doctype html><html><head><meta \
         charset=\"utf-8\"><title>{FLASH_TITLE}</title><style>html,body{{margin:0;height:100%;background:#\
         000}}</style></head><body><script>let \
         on=false;setInterval(()=>{{on=!on;document.body.style.background=on?'#fff':'#000'}},500);</\
         script></body></html>"
    )
}

/// The browser showing the source page, reaped whatever happens next.
#[derive(Debug)]
struct Source {
    child: Child,
}

impl Drop for Source {
    fn drop(&mut self) {
        reap(self.child.id(), "Google Chrome");
        let _ignored = self.child.wait();
    }
}

/// Where Chrome is. `--app` gives a window whose title is the page's, with no tab strip or toolbar
/// to scroll under the capture; its own profile directory keeps it out of the developer's running
/// browser, which would otherwise adopt the URL as a tab and exit.
const CHROME: &str = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

impl Source {
    fn open(work: &Path, page: &str, html: &str) -> Result<Self, String> {
        let file = work.join(page);
        fs::write(&file, html).map_err(|error| format!("{}: {error}", file.display()))?;
        let profile = work.join("chrome-profile");
        super::fresh(&profile)?;
        let chrome = PathBuf::from(CHROME);
        if !chrome.is_file() {
            return Err(format!("{CHROME} is not installed; the source page needs it"));
        }
        let child = Command::new(&chrome)
            .arg(format!("--app=file://{}", file.display()))
            .arg(format!("--user-data-dir={}", profile.display()))
            .arg("--no-first-run")
            .arg(format!("--window-size={},{}", SOURCE_SIZE.0, SOURCE_SIZE.1))
            .arg("--window-position=40,60")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| format!("{CHROME}: {error}"))?;
        Ok(Self { child })
    }
}

/// One framewatch run, started now and read later — two of them watch two windows over the SAME
/// span, which is the only way the two rows of the table are comparable.
fn watch(framewatch: &Path, arguments: &[&str]) -> Result<Child, String> {
    Command::new(framewatch)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("{}: {error}", framewatch.display()))
}

/// Both streams of a finished framewatch, joined.
fn collect(child: Child) -> Result<String, String> {
    let output = child
        .wait_with_output()
        .map_err(|error| format!("framewatch: {error}"))?;
    Ok(format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    ))
}

/// Run the harness.
///
/// # Errors
/// When a build fails, Chrome is missing or its window never lists, either daemon does not stay up,
/// the client never presents, the source does not reach 50 fps, the remote window delivers fewer
/// than thirty frames, the remote fps is under `--floor`, or (latency) too few flashes paired.
#[expect(
    clippy::too_many_lines,
    reason = "one harness is one narrative; splitting it hides which reading follows which"
)]
#[expect(
    clippy::print_stdout,
    reason = "the table and the banner are this harness's report"
)]
pub fn run(root: &Path, options: &Options) -> Result<(), String> {
    let work = work_dir(root, "video-smooth")?;
    let suite = Suite::for_gate("smooth");

    // RELEASE for the video host: the frame budget is the subject, and the daemon's own profile
    // (`opt-level = 3`, thin LTO) is the daemon; reading a debug build's cadence would be reading a
    // different program. The terminal daemon only carries the document and stays as the gate
    // substrate builds it.
    say(
        "smooth",
        "building slopdesk-videohostd (release) + slopdesk-hostd + slopdesk-framewatch",
    );
    crate::hostbin::build_of(root, crate::hostbin::Daemon::Video, true)?;
    crate::hostbin::build(root, false)?;
    let framewatch = framewatch_binary(root)?;
    say("smooth", "generating + building the client app");
    let app = build_app(root, &work, "DD")?;

    let daemon_state = work.join("daemon-state");
    super::fresh(&daemon_state)?;
    let environment = container(&daemon_state)?;

    // ── the source ──────────────────────────────────────────────────────────────────────────
    let (source_title, page, html) = if options.latency {
        (FLASH_TITLE, "flash.html", flash_page())
    } else {
        (SCROLL_TITLE, "scroll.html", scroll_page())
    };
    say("smooth", &format!("opening the {source_title} page in Chrome"));
    let source = Source::open(&work, page, &html)?;
    let videohostd = crate::hostbin::binary_of(root, crate::hostbin::Daemon::Video, true);
    let mut listing = String::new();
    // A cold Chrome takes several seconds to show its first window; list until it is there.
    if poll("the source window to list", 40, || {
        listing = shareable_listing(&videohostd, &environment).unwrap_or_default();
        super::video::pick(&listing, Some(source_title)).is_some()
    })
    .is_err()
    {
        complain("==> FAIL: the source page never listed as a shareable window. Candidates:");
        for line in listing.lines() {
            complain(&format!("    {line}"));
        }
        complain("    (an empty list ⇒ grant Screen-Recording TCC + run from a real GUI session)");
        return Err("no source window".to_owned());
    }
    let Some(target) = super::video::pick(&listing, Some(source_title)) else {
        return Err("no source window".to_owned());
    };
    say(
        "smooth",
        &format!(
            "serving window id={} ({}) [{}x{}]",
            target.id, target.title, target.width, target.height
        ),
    );

    // ── the video host, with the caller's cadence and scale ─────────────────────────────────
    let mut extra = Vec::new();
    if let Some(fps) = options.fps {
        extra.push("--fps".to_owned());
        extra.push(fps.to_string());
    }
    if let Some(scale) = options.scale {
        extra.push("--scale".to_owned());
        extra.push(scale.to_string());
    }
    let video_host = VideoHost::start("smooth", &videohostd, &work, &environment, target.id, &extra)?;

    // ── the terminal daemon and the client ──────────────────────────────────────────────────
    say(
        "smooth",
        &format!("starting slopdesk-hostd on 127.0.0.1:{}", port::SMOOTH),
    );
    let hostd = Hostd::start(root, &work, port::SMOOTH)?;
    super::kill_matching("video-smooth/DD.*MacOS/SlopDesk");
    suite.seed_first_launch()?;
    let client = ClientProcess::launch(
        "smooth",
        &app,
        &suite,
        &work,
        "client-home",
        "client.log",
        autoconnect_environment(target.id, REMOTE_TITLE, port::SMOOTH, false),
    )?;
    await_first_frame("smooth", &hostd, &video_host, &client, port::SMOOTH)?;
    // The stream's first seconds are its ramp — the connect-time size negotiation, the first IDR,
    // the rate controller finding its level — and none of that is the steady state under test.
    thread::sleep(Duration::from_secs(3));

    let seconds = options.seconds.to_string();
    let mut lines = Vec::new();
    // The pipe's own count of the same span: the host's last sampled frame id and the client's,
    // before and after the watch. Both print one line in fifteen, so the delta is exact to ±15.
    let encoded_before = last_frame_id(&video_host.log.text(), ENCODED_MARK);
    let decoded_before = last_frame_id(&client.log.text(), DECODED_MARK);
    // The diagnostics are counted the same way, from here: the connect-time keyframe backs the
    // send lane up for a few frames (backpressure skips), and none of that is the steady state.
    let host_before = Counts::of(&video_host.log, HOST_MARKS);
    let client_before = Counts::of(&client.log, CLIENT_MARKS);
    if options.latency {
        say(
            "smooth",
            &format!("framewatch latency: {source_title} → {REMOTE_TITLE} for {seconds}s"),
        );
        let report = collect(watch(&framewatch, &[
            "--latency",
            "--title-a",
            source_title,
            "--title-b",
            REMOTE_TITLE,
            "--seconds",
            &seconds,
            "--fps",
            WATCH_HZ,
        ])?)?;
        print!("{report}");
        let Some(latency) = Latency::parse(&report) else {
            video_host.log.dump("video host log", 40);
            return Err(
                "too few flashes paired for a latency distribution (see the report above)".to_owned(),
            );
        };
        lines.push(format!(
            "glass-to-glass (compositor→compositor, loopback): p50 {:.1} ms  p90 {:.1} ms  min {:.1}  max \
             {:.1}  over {} pairs ({} source / {} client flips)",
            latency.p50,
            latency.p90,
            latency.min,
            latency.max,
            latency.paired,
            latency.source_flips,
            latency.client_flips
        ));
        lines.push("The client's own scanout (~half a refresh) is not in this number.".to_owned());
    } else {
        say(
            "smooth",
            &format!("framewatch cadence: {source_title} and {REMOTE_TITLE}, together, for {seconds}s"),
        );
        // ONE framewatch over both windows: a second enumeration beside the live stream answers
        // "nothing shareable" (framewatch's own module note), and two spans are not the same span.
        let report = collect(watch(&framewatch, &[
            "--title-a",
            source_title,
            "--title-b",
            REMOTE_TITLE,
            "--seconds",
            &seconds,
            "--fps",
            WATCH_HZ,
        ])?)?;
        let (Some(source_cadence), Some(remote_cadence)) = (
            Cadence::parse(&tagged_lines(&report, "A")),
            Cadence::parse(&tagged_lines(&report, "B")),
        ) else {
            complain("==> FAIL: framewatch produced no cadence report for one of the windows:");
            complain(&report);
            return Err("framewatch did not report".to_owned());
        };
        println!("{CADENCE_HEADER}");
        println!("{}", source_cadence.row(source_title));
        println!("{}", remote_cadence.row(REMOTE_TITLE));
        let ratio = remote_cadence.unique() / source_cadence.unique().max(1.0);
        lines.push(format!(
            "remote/source new frames: {ratio:.2}  (remote {:.1} new/s of a {:.1} new/s source)",
            remote_cadence.unique_fps(),
            source_cadence.unique_fps()
        ));
        lines.push(format!(
            "remote stalls: {} one-slot, {} two-slot, {} >60 ms across {} deliveries ({} repeats)",
            remote_cadence.one_slot,
            remote_cadence.two_slot,
            remote_cadence.longer,
            remote_cadence.frames,
            remote_cadence.repeats
        ));

        if source_cadence.unique_fps() < SOURCE_FLOOR_FPS {
            return Err(format!(
                "the source itself ran at {:.1} new frames/s (< {SOURCE_FLOOR_FPS}): the machine is too \
                 loaded to measure, or the page never scrolled",
                source_cadence.unique_fps()
            ));
        }
        if remote_cadence.unique() < REMOTE_MIN_FRAMES {
            video_host.log.dump("video host log", 40);
            client.log.dump("client log", 40);
            return Err(format!(
                "the remote window showed {} new frames in {seconds}s — not streaming",
                remote_cadence.unique()
            ));
        }
        if remote_cadence.unique_fps() < options.floor_fps {
            return Err(format!(
                "remote {:.1} new frames/s is under the floor {:.1}",
                remote_cadence.unique_fps(),
                options.floor_fps
            ));
        }
    }

    let span = f64::from(options.seconds.max(1));
    let encoded = last_frame_id(&video_host.log.text(), ENCODED_MARK).saturating_sub(encoded_before);
    let decoded = last_frame_id(&client.log.text(), DECODED_MARK).saturating_sub(decoded_before);
    lines.push(format!(
        "pipe over the span: host encoded ≈ {:.1} fps, client decoded ≈ {:.1} fps (frame ids, sampled 1 in \
         15)",
        f64::from(encoded) / span,
        f64::from(decoded) / span
    ));

    // What the host and the client said about the same span — diagnostics for the table, never
    // an assertion: each is a line the daemon prints only under `SLOPDESK_VIDEO_DEBUG`.
    let host = Counts::of(&video_host.log, HOST_MARKS).since(&host_before);
    let client_counts = Counts::of(&client.log, CLIENT_MARKS).since(&client_before);
    lines.push(format!(
        "over the span — host: {}; client: {}",
        host.describe(HOST_MARKS),
        client_counts.describe(CLIENT_MARKS)
    ));
    lines.push(format!(
        "host: --fps {}  --scale {}  (the daemon's defaults where unset)",
        options
            .fps
            .map_or_else(|| "default".to_owned(), |fps| fps.to_string()),
        options
            .scale
            .map_or_else(|| "default".to_owned(), |scale| scale.to_string()),
    ));
    lines.push(format!("host log:   {}", video_host.log.path.display()));
    lines.push(format!("client log: {}", client.log.path.display()));
    println!("{}", banner(&lines));
    drop(source);
    Ok(())
}

#[cfg(test)]
mod tests {
    #![expect(clippy::expect_used, reason = "a panic in a test is the failure report")]
    use super::{Cadence, Counts, Latency, number_after, tagged_lines};

    const CADENCE: &str = "\
framewatch: watching id=2592 Google Chrome \"SRCSCROLL\" [1280x800] for 8s @120Hz
framewatch: frames=489 span=8.1s eff_fps=59.9
framewatch: dt p50=16.5ms p90=20.3ms p99=25.7ms max=32.3ms
framewatch: bins ≤20ms=423 20-28ms=63 28-42ms(1-slot)=2 42-60ms(2-slot)=0 >60ms=0
framewatch: identical-content re-deliveries=9
";

    /// The four cadence lines framewatch prints, read back number for number — the same text its
    /// own tests pin, so a rewording there is a red here and not a silent zero.
    #[test]
    fn a_cadence_report_is_read_number_for_number() {
        let cadence = Cadence::parse(CADENCE).expect("four lines");
        assert_eq!(cadence, Cadence {
            frames: 489.0,
            fps: 59.9,
            span: 8.1,
            p50: 16.5,
            p90: 20.3,
            p99: 25.7,
            max: 32.3,
            one_slot: 2.0,
            two_slot: 0.0,
            longer: 0.0,
            repeats: 9.0,
        });
    }

    /// New frames are deliveries less repeats, and their rate is over the span — 80 deliveries a
    /// second of a 60 fps source read as 60 new a second, not 80.
    #[test]
    fn new_frames_are_deliveries_less_repeats() {
        let cadence = Cadence::parse(CADENCE).expect("four lines");
        assert!((cadence.unique() - 480.0).abs() < f64::EPSILON);
        assert!((cadence.unique_fps() - 480.0 / 8.1).abs() < 1e-9);
    }

    /// Two count snapshots read as a difference, and a count that went nowhere reads as zero.
    #[test]
    fn counts_since_are_a_saturating_difference() {
        let before = Counts(vec![3, 0, 7]);
        let after = Counts(vec![5, 2, 7]);
        assert_eq!(after.since(&before), Counts(vec![2, 2, 0]));
        assert_eq!(before.since(&after), Counts(vec![0, 0, 0]));
        assert_eq!(
            Counts(vec![1, 2]).describe(&[("a", "apples"), ("b", "bananas")]),
            "1 apples, 2 bananas"
        );
    }

    /// A refusal prints none of the four lines, and reads as no report rather than a zero one.
    #[test]
    fn a_refusal_is_not_a_report() {
        assert!(Cadence::parse("no window matching \"SDREMOTE\" — try --list\n").is_none());
        assert!(Cadence::parse("").is_none());
    }

    /// The latency line, including a negative minimum — the sign is part of the number.
    #[test]
    fn a_latency_report_keeps_its_sign() {
        let report = "framewatch[latency]: sourceFlips=40 clientFlips=39 paired=38\nframewatch[latency]: \
                      glass-to-glass p50=27.4ms p90=39.9ms min=-2.3ms max=47.8ms n=38\n";
        let latency = Latency::parse(report).expect("two lines");
        assert!((latency.paired - 38.0).abs() < f64::EPSILON);
        assert!((latency.p50 - 27.4).abs() < f64::EPSILON);
        assert!(
            (latency.min + 2.3).abs() < f64::EPSILON,
            "the sign is part of the number"
        );
        assert!((latency.max - 47.8).abs() < f64::EPSILON);
    }

    /// Too few pairs prints the counts and no distribution, which is "setup", not a measurement.
    #[test]
    fn too_few_pairs_is_not_a_latency() {
        assert!(Latency::parse("framewatch[latency]: sourceFlips=3 clientFlips=2 paired=1\n").is_none());
    }

    /// A paired report splits by its tag, and each half reads as a report of its own.
    #[test]
    fn a_paired_report_splits_by_tag() {
        let paired = "\
framewatch[A]: watching id=1 Google Chrome \"SRCSCROLL\" [1280x800] for 8s @120Hz
framewatch[B]: watching id=2 SlopDesk \"SDREMOTE\" [1280x832] for 8s @120Hz
framewatch[A]: frames=480 span=8.0s eff_fps=60.0
framewatch[A]: dt p50=16.6ms p90=17.0ms p99=20.0ms max=25.0ms
framewatch[A]: bins ≤20ms=470 20-28ms=9 28-42ms(1-slot)=0 42-60ms(2-slot)=0 >60ms=0
framewatch[A]: identical-content re-deliveries=0
framewatch[B]: frames=240 span=8.0s eff_fps=30.0
framewatch[B]: dt p50=33.3ms p90=34.0ms p99=40.0ms max=50.0ms
framewatch[B]: bins ≤20ms=0 20-28ms=0 28-42ms(1-slot)=230 42-60ms(2-slot)=9 >60ms=0
framewatch[B]: identical-content re-deliveries=1
";
        let a = Cadence::parse(&tagged_lines(paired, "A")).expect("A");
        let b = Cadence::parse(&tagged_lines(paired, "B")).expect("B");
        assert!((a.fps - 60.0).abs() < f64::EPSILON);
        assert!((b.fps - 30.0).abs() < f64::EPSILON);
        assert!((b.one_slot - 230.0).abs() < f64::EPSILON);
        assert!(Cadence::parse(&tagged_lines(paired, "C")).is_none());
    }

    /// The last sampled frame id wins, and a log without one reads as zero rather than nothing.
    #[test]
    fn the_last_frame_id_is_the_last_line_that_carries_one() {
        let log =
            "x: encoded+sent frame #1 (2B)\nx: capture delivery gap 30ms\nx: encoded+sent frame #15 (3B)\n";
        assert_eq!(super::last_frame_id(log, "encoded+sent frame #"), 15);
        assert_eq!(super::last_frame_id("nothing yet\n", "encoded+sent frame #"), 0);
    }

    /// The number stops at the unit, a missing key is `None`, and a key with nothing numeric after
    /// it is `None` rather than zero.
    #[test]
    fn the_number_stops_where_the_unit_starts() {
        assert_eq!(number_after("p50=16.5ms p90=20.3ms", "p90="), Some(20.3));
        assert_eq!(number_after("frames=489 span", "frames="), Some(489.0));
        assert_eq!(number_after("frames=489", "fps="), None);
        assert_eq!(number_after("fps=ms", "fps="), None);
    }
}
