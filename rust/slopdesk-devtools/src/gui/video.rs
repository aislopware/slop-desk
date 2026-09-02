//! PATH 2 (GUI window sharing) runtime gate: capture → HEVC → UDP → decode → a Metal drawable.
//!
//! ## Why it exists
//! [`super::macos`]' `--connect` proves the TERMINAL path end to end; the GUI VIDEO path had no
//! runtime gate at all. This closes it the same way, and then asserts the two legs a live dial
//! cannot vouch for.
//!
//! ## What it proves
//! - `slopdesk-videohostd` captures a real on-screen window and HEVC-encodes it,
//! - the client boots the DETACHED remote-desktop window, connects both UDP channels, and the host
//!   streams,
//! - the client DECODED at least one frame and PRESENTED at least one frame into a Metal drawable,
//! - and the screenshot shows the decoded remote pixels.
//!
//! With [`Options::second_client`] it also proves the multi-client half of `docs/45` §10: a SECOND
//! instance, given only the TERMINAL autoconnect, learns the detached `.desktop` pane from the
//! HOST's workspace document, dials its own UDP lane, and decodes and presents the SAME window
//! while the first keeps streaming. That is the one claim a unit test cannot make — two concurrent
//! `SCStream`s and two `VTCompressionSession`s on ONE capture target, which the hang-safety rule
//! forbids constructing in `XCTest`. Its assertions are the PAIR, never one: client B rendering
//! while A went dark is a takeover rather than a fan-out, so A's counters are re-read AFTER B is up
//! and must have GROWN.
//!
//! ## Why TWO daemons
//! `slopdesk-videohostd` for the pixels, and `slopdesk-hostd` because the detached `.desktop` pane
//! is an object in the HOST's workspace document (`docs/45`). The client asks for it with an intent
//! over `channelClass 1` and has nowhere to send one without a terminal daemon — so without hostd
//! the client renders an empty window and this gate would pass on a blank screenshot.
//!
//! ## MUST run from a real, unlocked GUI login session
//! Not over SSH, not detached, not while the screen is locked: live `ScreenCaptureKit` streaming
//! needs a full window-server connection, and without one the host aborts with `CGS_REQUIRE_INIT`
//! or simply delivers zero frames. One-shot `screencapture -l` works in more contexts than a live
//! `SCStream` — do not be misled by that. Screen-Recording TCC is required.

use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use std::{fs, thread};

use regex::Regex;

use super::control::Launch;
use super::{
    Hostd, Log, Suite, alive, banner, build_app, complain, holds_udp, kill_matching, poll, port, raise, reap,
    say, screenshot, work_dir,
};
use crate::ops::container;

/// The UDP port pair the video lane uses. Fixed, and the same pair `ConnectionTarget` defaults to,
/// which is what lets the second client resolve them off the document without being told.
const MEDIA_PORT: u16 = 9000;
/// The cursor lane's port.
const CURSOR_PORT: u16 = 9001;

/// What `slopdesk-videohostd` says (under `SLOPDESK_VIDEO_DEBUG`) when a resize was served by
/// swapping an encoder under the live capture stream — `session_resize.rs`, the in-place path.
const IN_PLACE_SWAP: &str = "in-place resize: encoder swapped";
/// What it says on EITHER way the fast path declines and the restart path serves the resize.
const STREAM_RESTART: &str = "restarting the stream";
/// What the client says (under `SLOPDESK_VIDEO_DEBUG`) once a decoded buffer at the new size
/// arrived and the session adopted it — `SlopDeskVideoClientSession.swift`, `ResizeAdoption`.
const CLIENT_ADOPTED: &str = "resize: adopted decodedSize=";

/// What the caller asked for.
#[derive(Debug, Clone, Default)]
pub struct Options {
    /// Serve the window whose listing line contains this, rather than the largest one.
    pub window_title: Option<String>,
    /// Run the fan-out half as well.
    pub second_client: bool,
}

/// One line of `slopdesk-videohostd --list`, understood.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    /// The `CGWindowID` to serve.
    pub id: u32,
    /// The app and title, with the id prefix and the pixel suffix taken off. It becomes the
    /// detached pane's window title and is read off the screenshot, so it is kept clean.
    pub title: String,
    /// Width in pixels.
    pub width: u32,
    /// Height in pixels.
    pub height: u32,
}

impl Candidate {
    /// Pixels, which is what "largest" means — most pixels is the easiest visual confirmation.
    #[must_use]
    pub const fn area(&self) -> u64 {
        self.width as u64 * self.height as u64
    }
}

/// The chrome and backstops that are windows but are never a shareable TARGET.
///
/// The Finder "(untitled)" desktop, the menu bar, the Dock, the wallpaper, Control Center, the
/// backstop, the underbelly, status indicators and menu-bar items — each is a real window the
/// server will happily hand over, and each would make this gate prove that a blank rectangle
/// survives an HEVC round trip.
const NEVER_A_TARGET: [&str; 10] = [
    "untitled",
    "Menubar",
    "Dock",
    "Wallpaper",
    "Control Center",
    "Backstop",
    "underbelly",
    "StatusIndicator",
    "Item-",
    "BentoBox",
];

/// The smallest window worth serving, in pixels.
const MIN_WIDTH: u32 = 300;
/// The smallest window worth serving, in pixels.
const MIN_HEIGHT: u32 = 200;

/// Read one listing into candidates.
///
/// A line that carries no `id=` and no `[WxH]` is not a window, however much it looks like one —
/// the listing carries banners and diagnostics too.
#[must_use]
pub fn candidates(listing: &str) -> Vec<Candidate> {
    let Ok(shape) = Regex::new(r"id=(\d+).*\[(\d+)x(\d+)\]") else {
        return Vec::new();
    };
    let Ok(trim) = Regex::new(r"^.*id=\d+ +|\s*\[\d+x\d+\]\s*$") else {
        return Vec::new();
    };
    listing
        .lines()
        .filter_map(|line| {
            let found = shape.captures(line)?;
            Some(Candidate {
                id: found.get(1)?.as_str().parse().ok()?,
                width: found.get(2)?.as_str().parse().ok()?,
                height: found.get(3)?.as_str().parse().ok()?,
                title: trim.replace_all(line, "").trim().to_owned(),
            })
        })
        .collect()
}

/// Pick the window to serve: the one the caller named, else the largest real app window.
///
/// An explicit title is taken as written and NOT size-filtered — a caller who names a window has
/// already decided, and second-guessing them turns "serve Slack" into "no suitable window found".
#[must_use]
pub fn pick(listing: &str, needle: Option<&str>) -> Option<Candidate> {
    let all = candidates(listing);
    if let Some(wanted) = needle {
        let lowered = wanted.to_lowercase();
        return all
            .into_iter()
            .find(|candidate| candidate.title.to_lowercase().contains(&lowered));
    }
    all.into_iter()
        .filter(|candidate| {
            candidate.width >= MIN_WIDTH
                && candidate.height >= MIN_HEIGHT
                && !NEVER_A_TARGET
                    .iter()
                    .any(|chrome| candidate.title.contains(chrome))
        })
        .max_by_key(Candidate::area)
}

/// The video host, reaped whatever happens next.
#[derive(Debug)]
struct VideoHost {
    child: Child,
    log: Log,
}

impl Drop for VideoHost {
    fn drop(&mut self) {
        reap(self.child.id(), "slopdesk-videohostd");
        let _ignored = self.child.wait();
    }
}

/// A launched client instance, reaped whatever happens next.
#[derive(Debug)]
struct ClientProcess {
    child: Child,
    log: Log,
}

impl Drop for ClientProcess {
    fn drop(&mut self) {
        reap(self.child.id(), "SlopDesk");
        let _ignored = self.child.wait();
    }
}

impl ClientProcess {
    /// How many frames this instance has DECODED, and how many it has PRESENTED.
    ///
    /// Read off the client's own `SLOPDESK_VIDEO_DEBUG` stream:
    /// `DECODED frame #N` from `SlopDeskVideoClientSession.finishDecode`, the decode-SUCCESS path
    /// only; `PRESENTED#N` from `MetalVideoRenderer.render`, immediately AFTER
    /// `commandBuffer.present(drawable)`.
    ///
    /// NOT `RENDER#`, and that distinction is the whole assertion. `RENDER#` prints the instant
    /// `metalLayer.nextDrawable()` returns, which is BEFORE every guard that follows it —
    /// `makeTexture` for either plane, `CVMetalTextureGetTexture`, `makeCommandBuffer` /
    /// `makeRenderCommandEncoder` — each of which returns having encoded no pass and presented
    /// nothing. So a decoder that starts vending a non-NV12 or 10-bit `CVPixelBuffer` accumulates
    /// decode markers, prints `RENDER#0` once, draws NOTHING ever, and a gate counting `RENDER#`
    /// passed on it.
    fn frames(&self) -> (usize, usize) {
        (self.log.count("DECODED frame #"), self.log.count("PRESENTED#"))
    }
}

/// Run the gate.
///
/// # Errors
/// When a build fails, no shareable window is found, either daemon does not stay up, the workspace
/// channel is never accepted, no UDP flow appears, the client decodes or presents nothing, or one
/// auto-connect attaches anything but exactly one shell.
#[expect(
    clippy::too_many_lines,
    reason = "one gate is one narrative; splitting it hides which assertion follows which"
)]
#[expect(clippy::print_stdout, reason = "the banner is this gate's report")]
pub fn run(root: &Path, options: &Options) -> Result<(), String> {
    let work = work_dir(root, "video-verify")?;
    let suite = Suite::for_gate("video");

    say("video", "building slopdesk-videohostd + slopdesk-hostd");
    crate::hostbin::build_of(root, crate::hostbin::Daemon::Video, false)?;
    crate::hostbin::build(root, false)?;
    say("video", "generating + building the client app");
    let app = build_app(root, &work, "DD")?;

    // Before ANY daemon runs, including the `--list` enumeration: `slopdesk-videohostd` folds
    // `video-prefs.json` into its `env::Overlay` on its very first line of `main`, so even the
    // listing pass would otherwise read the developer's tuning and measure a configuration nobody
    // wrote down. And `parked-windows.json` is a crash journal it READS at launch — AX-moving the
    // windows it names back off a dead virtual display — and UNLINKS unconditionally, so pointed at
    // the real container an automation run restores and then DESTROYS the record belonging to the
    // developer's own videohostd, moving their windows while doing it.
    let daemon_state = work.join("daemon-state");
    super::fresh(&daemon_state)?;
    let environment = container(&daemon_state)?;

    say(
        "video",
        "enumerating shareable windows (needs Screen-Recording TCC + a GUI session)",
    );
    let videohostd = crate::hostbin::binary_of(root, crate::hostbin::Daemon::Video, false);
    let mut listing_command = Command::new(&videohostd);
    listing_command.arg("--list");
    for (key, value) in &environment {
        listing_command.env(key, value);
    }
    let listing_output = listing_command
        .output()
        .map_err(|error| format!("{}: {error}", videohostd.display()))?;
    let listing = format!(
        "{}{}",
        String::from_utf8_lossy(&listing_output.stdout),
        String::from_utf8_lossy(&listing_output.stderr)
    );

    let Some(target) = pick(&listing, options.window_title.as_deref()) else {
        complain("==> FAIL: no suitable shareable window found. Candidates:");
        for line in listing.lines() {
            complain(&format!("    {line}"));
        }
        complain("    (an empty list ⇒ grant Screen-Recording TCC + run from a real GUI session;");
        complain("     or name one explicitly: slopdesk-guigate video --window-title Slack)");
        return Err("no shareable window".to_owned());
    };
    say(
        "video",
        &format!(
            "serving window id={} ({}) on media:{MEDIA_PORT} cursor:{CURSOR_PORT}",
            target.id, target.title
        ),
    );

    // ── the video host ──────────────────────────────────────────────────────────────────────
    kill_matching(&format!("slopdesk-videohostd --window-id {}", target.id));
    let host_log = Log::at(work.join("host.log"));
    host_log.truncate()?;
    let sink =
        fs::File::create(&host_log.path).map_err(|error| format!("{}: {error}", host_log.path.display()))?;
    let errors = sink
        .try_clone()
        .map_err(|error| format!("{}: {error}", host_log.path.display()))?;
    let mut command = Command::new(&videohostd);
    command
        .args([
            "--window-id",
            &target.id.to_string(),
            "--media-port",
            &MEDIA_PORT.to_string(),
            "--cursor-port",
            &CURSOR_PORT.to_string(),
        ])
        .env("SLOPDESK_VIDEO_DEBUG", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::from(sink))
        .stderr(Stdio::from(errors));
    for (key, value) in &environment {
        command.env(key, value);
    }
    let video_host = VideoHost {
        child: command
            .spawn()
            .map_err(|error| format!("{}: {error}", videohostd.display()))?,
        log: host_log,
    };
    thread::sleep(Duration::from_secs(1));
    if !alive(video_host.child.id()) {
        video_host.log.dump("video host log", 0);
        return Err("slopdesk-videohostd did not stay up".to_owned());
    }
    say("video", &format!("host up (pid {})", video_host.child.id()));

    // ── the terminal daemon, which owns the workspace document ──────────────────────────────
    say(
        "video",
        &format!("starting slopdesk-hostd on 127.0.0.1:{}", port::VIDEO),
    );
    let hostd = Hostd::start(root, &work, port::VIDEO)?;
    say("video", &format!("hostd up (pid {})", hostd.pid()));

    // ── client A, with the PATH-2 auto-open seam ────────────────────────────────────────────
    let app_pattern = "video-verify/DD.*MacOS/SlopDesk";
    kill_matching(app_pattern);
    suite.seed_first_launch()?;
    let client_a_log = Log::at(work.join("client.log"));
    client_a_log.truncate()?;
    let client_a = ClientProcess {
        child: Launch {
            binary: &app.binary,
            container: work.join("client-home"),
            suite: &suite,
            socket: None,
            log: client_a_log.path.clone(),
            environment: vec![
                ("SLOPDESK_VIDEO_DEBUG".to_owned(), "1".to_owned()),
                // The resize proof below drags the client window; only with host-follow on does
                // the pane's new size become a `resizeRequest` the host acts on (default-off in
                // the product, where a pane resize letterboxes instead of moving the window).
                ("SLOPDESK_GUI_WINDOW_FOLLOWS_PANE".to_owned(), "1".to_owned()),
                (
                    "SLOPDESK_VIDEO_AUTOCONNECT_HOST".to_owned(),
                    "127.0.0.1".to_owned(),
                ),
                (
                    "SLOPDESK_VIDEO_AUTOCONNECT_MEDIA_PORT".to_owned(),
                    MEDIA_PORT.to_string(),
                ),
                (
                    "SLOPDESK_VIDEO_AUTOCONNECT_CURSOR_PORT".to_owned(),
                    CURSOR_PORT.to_string(),
                ),
                (
                    "SLOPDESK_VIDEO_AUTOCONNECT_WINDOW_ID".to_owned(),
                    target.id.to_string(),
                ),
                (
                    "SLOPDESK_VIDEO_AUTOCONNECT_TITLE".to_owned(),
                    format!("{} (remote)", target.title),
                ),
                // `WorkspaceStore.videoTarget(from:)` reads this for the TCP leg of the very same
                // `ConnectionTarget`, so pointing it at the terminal daemon is the whole wiring.
                ("SLOPDESK_AUTOCONNECT_PORT".to_owned(), port::VIDEO.to_string()),
            ],
            arguments: Vec::new(),
        }
        .spawn()?,
        log: client_a_log,
    };
    let pid_a = client_a.child.id();
    say("video", &format!("client up (pid {pid_a})"));

    // ── the connectivity gates: assertions, not observations ────────────────────────────────
    // A client that never dialled cannot have rendered anything, so a screenshot past this point
    // would prove nothing. Each exits non-zero and dumps the logs rather than printing a warning
    // and carrying on to a picture of the desktop.
    say(
        "video",
        &format!("waiting for the workspace document channel on :{}…", port::VIDEO),
    );
    if poll("a workspace document channel", 20, || {
        hostd.accepted_channels() >= 1
    })
    .is_err()
    {
        complain("==> FAIL: slopdesk-hostd never accepted a workspace channel — the client has no document");
        complain("    to send its pane-spawn intent to, so no remote-desktop pane can exist.");
        hostd.log.dump("hostd log", 0);
        client_a.log.dump("client log", 0);
        return Err("no workspace document channel".to_owned());
    }
    say("video", "workspace document channel accepted ✅");

    say(
        "video",
        &format!("waiting for client↔host UDP (media:{MEDIA_PORT} + cursor:{CURSOR_PORT})…"),
    );
    if poll("a client→host UDP flow", 20, || holds_udp(pid_a, MEDIA_PORT)).is_err() {
        complain(&format!(
            "==> FAIL: no client→host UDP flow on :{MEDIA_PORT} — the remote-desktop pane never dialled."
        ));
        video_host.log.dump("video host log", 0);
        client_a.log.dump("client log", 0);
        return Err("the video lane never dialled".to_owned());
    }
    say("video", "client connected to host over UDP ✅");
    // The capture→encode→decode→render pipeline gets a few seconds to produce and present frames.
    thread::sleep(Duration::from_secs(5));

    // ── a frame was DECODED, and a frame was PRESENTED ──────────────────────────────────────
    // Everything above proves the client DIALLED. A client that dialled can still show a blank pane
    // for ever — a VT decompression session that errors on the first IDR, a `CAMetalLayer` that
    // never hands out a drawable, a decode gate that never re-opens — and in every one of those,
    // capture, encode and both sockets stay perfectly healthy, so not one check above moves.
    // Without this the gate printed ✅ four times and exited 0 on a white window.
    say("video", "waiting for a DECODED frame and a PRESENTED frame…");
    let _ignored = poll("a decoded and a presented frame", 40, || {
        let (decoded, presented) = client_a.frames();
        decoded > 0 && presented > 0
    });
    let (decoded, presented) = client_a.frames();
    if decoded < 1 {
        complain(
            "==> FAIL: the client decoded NOT ONE frame. Both sockets are up and the host is streaming,",
        );
        complain("    so this is the decode leg: VideoToolbox rejected the stream, or the decode gate never");
        complain("    re-opened. The remote-desktop pane is blank.");
        video_host.log.dump("video host log", 60);
        client_a.log.dump("client log", 60);
        return Err("the client decoded nothing".to_owned());
    }
    if presented < 1 {
        complain(&format!(
            "==> FAIL: the client is decoding ({decoded} decode marker(s)) and PRESENTED none. The pixels"
        ));
        complain(
            "    exist and never reached a drawable — the Metal present path (no CAMetalLayer drawable, a",
        );
        complain("    plane that will not make an MTLTexture, a command encoder the device refused, a pacer");
        complain("    that never fires). The remote-desktop pane is blank.");
        complain(&format!(
            "    (RENDER# markers seen: {} — those print BEFORE the texture/encoder guards, so a positive",
            client_a.log.count("RENDER#")
        ));
        complain("     count here is the signature of exactly this bug.)");
        client_a.log.dump("client log", 60);
        return Err("the client presented nothing".to_owned());
    }
    say(
        "video",
        &format!("frames DECODED and PRESENTED ({decoded} decode / {presented} present markers) ✅"),
    );

    // ONE auto-connect spawns ONE shell. The video shape is a lone terminal plus a DETACHED desktop
    // pane, and a `.desktop` pane runs no PTY — so exactly one shell may ever attach. A second
    // means the bootstrap adopted a tree the window was not already showing and abandoned the
    // first pane's shell. Read AFTER the render settle, so a late second attach still counts.
    let shells = hostd.attached_shells();
    if shells != 1 {
        hostd.log.dump("hostd log", 0);
        return Err(format!(
            "one auto-connect must attach exactly 1 shell; saw {shells}"
        ));
    }
    say("video", "exactly one shell attached for one auto-connect ✅");

    // ── the in-place encoder resize, on the path a user's drag takes ────────────────────────
    // Every unit test of `session_resize.rs` runs over doubles, and none can show that a real
    // `SCStream` took a new configuration or that the first buffer after it arrived at the new
    // size. This is the only place that is seen: drag the client's remote window, which the pane
    // turns into a `resizeRequest`, which the host answers by AX-resizing the captured window and
    // swapping a new encoder UNDER the live stream — and then read three things off the logs.
    // The host says it swapped, the host never says it restarted, and the client adopted a new
    // decoded size and kept decoding after it. A host that swapped encoders into a client that
    // rejects every frame would pass the first two and fail the third.
    // Counted from BEFORE the drag, not from zero: with host-follow on, the connect-time 1:1
    // negotiation is itself a resize the host may have already served in place, and a gate that
    // asked for "one swap, ever" would pass on that one without the drag having done anything.
    say(
        "video",
        "resizing the client's remote window — waiting for the host's in-place encoder swap…",
    );
    let (decoded_before, _) = client_a.frames();
    let swaps_before = video_host.log.count(IN_PLACE_SWAP);
    let adopted_before = client_a.log.count(CLIENT_ADOPTED);
    resize_remote_window(pid_a, &format!("{} (remote)", target.title), 1100, 720)?;
    if poll("the host's in-place encoder swap", 40, || {
        video_host.log.count(IN_PLACE_SWAP) > swaps_before
    })
    .is_err()
    {
        complain("==> FAIL: the host never swapped an encoder in place after the pane resize. Either no");
        complain("    resizeRequest left the client (host-follow off, or the debounce never settled), the");
        complain("    AX resize was refused, or the fast path declined and the restart path served it.");
        video_host.log.dump("video host log", 40);
        client_a.log.dump("client log", 40);
        return Err("no in-place encoder swap".to_owned());
    }
    let restarts = video_host.log.count(STREAM_RESTART);
    if restarts > 0 {
        complain(&format!(
            "==> FAIL: the host restarted the stream {restarts} time(s) around the resize — the swap was not"
        ));
        complain("    the path that served it, or a decline fell through to the restart after it.");
        video_host.log.dump("video host log", 40);
        return Err("the resize restarted the stream".to_owned());
    }
    if poll("the client adopting the new decoded size", 40, || {
        client_a.log.count(CLIENT_ADOPTED) > adopted_before
    })
    .is_err()
    {
        complain("==> FAIL: the host swapped encoders but the client never adopted a new decoded size —");
        complain("    every post-swap frame is being rejected, or the ack never arrived.");
        video_host.log.dump("video host log", 40);
        client_a.log.dump("client log", 60);
        return Err("the client never adopted the new size".to_owned());
    }
    if poll("decoding to continue past the swap", 40, || {
        client_a.frames().0 >= decoded_before + 5
    })
    .is_err()
    {
        complain("==> FAIL: the client adopted the new size and then stopped decoding.");
        client_a.log.dump("client log", 60);
        return Err("decoding stopped after the swap".to_owned());
    }
    say(
        "video",
        &format!(
            "in-place resize: encoder swapped ({} swap(s) in all), no restart, client adopted the new size \
             and kept decoding ({} → {} decode markers) ✅",
            video_host.log.count(IN_PLACE_SWAP),
            decoded_before,
            client_a.frames().0
        ),
    );

    let client_b = if options.second_client {
        Some(fan_out(&app, &suite, &work, &hostd, &client_a, decoded)?)
    } else {
        None
    };

    capture_oslog(&work);

    // ── the picture ─────────────────────────────────────────────────────────────────────────
    // One shot per instance, each taken with THAT instance in front, is what makes the pair
    // readable as a pair.
    let shot_a = work.join("client-shot.png");
    raise_and_shoot(pid_a, &shot_a, "client A");
    let mut lines = vec![
        "Document channel, UDP flow, a decoded + presented frame and the one-shell rule are ASSERTED"
            .to_owned(),
        "above; what is left is whether the pixels are the RIGHT ones.".to_owned(),
        format!("read  {}", shot_a.display()),
        format!(
            "PASS = the remote-desktop window shows the remote '{}' window's live pixels.",
            target.title
        ),
        "FAIL = it shows some OTHER window, or a stale/garbled frame. A blank pane cannot reach here."
            .to_owned(),
        format!("host log:   {}", video_host.log.path.display()),
        format!("client log: {}", client_a.log.path.display()),
    ];
    if let Some(second) = &client_b {
        let shot_b = work.join("client-b-shot.png");
        raise_and_shoot(second.child.id(), &shot_b, "client B");
        lines.push(format!(
            "client B:   {}  (document-driven — it was given a port, never a window)",
            second.log.path.display()
        ));
        lines.push(format!("read  {}", shot_b.display()));
        lines.push(
            "PASS also needs client B's OWN window showing that same remote window's live pixels —"
                .to_owned(),
        );
        lines.push(
            "two clients watching one target, which is the claim no unit test may construct.".to_owned(),
        );
    }
    println!("{}", banner(&lines));
    Ok(())
}

/// The fan-out half: a SECOND client that learns the pane from the HOST's document.
///
/// B gets the TERMINAL autoconnect and NOTHING else. Giving it `SLOPDESK_VIDEO_AUTOCONNECT_*` would
/// have it mint its own detached pane from its own environment, which proves only that two
/// independently-configured clients can both dial — the trivial case. Withholding them makes B
/// learn the pane from `pane/kind` + `pane/videoTarget`, resolve the ports off its
/// `ConnectionTarget` defaults, and dial a window nobody told it about. That is the real
/// second-device shape, and it exercises document → satellite window → video lane end to end.
///
/// # Errors
/// When B never starts, never opens its own document channel, renders nothing, A stops streaming
/// once B attaches, or either client ends up without a media lane of its own.
fn fan_out(
    app: &super::AppBundle,
    suite: &Suite,
    work: &Path,
    hostd: &Hostd,
    client_a: &ClientProcess,
    decoded_before: usize,
) -> Result<ClientProcess, String> {
    say(
        "video",
        "launching a SECOND client (document-driven, no video autoconnect)",
    );
    let log = Log::at(work.join("client-b.log"));
    log.truncate()?;
    let client_b = ClientProcess {
        child: Launch {
            binary: &app.binary,
            // Its own container, so it shares neither `workspace-cache.json` nor
            // `device-prefs.json` with A — and the SAME defaults suite, because the pair are meant
            // to agree and what is being kept out is the developer's own MRU.
            container: work.join("client-b-home"),
            suite,
            socket: None,
            log: log.path.clone(),
            environment: vec![
                ("SLOPDESK_VIDEO_DEBUG".to_owned(), "1".to_owned()),
                ("SLOPDESK_AUTOCONNECT_HOST".to_owned(), "127.0.0.1".to_owned()),
                ("SLOPDESK_AUTOCONNECT_PORT".to_owned(), port::VIDEO.to_string()),
            ],
            arguments: Vec::new(),
        }
        .spawn()?,
        log,
    };
    let pid_b = client_b.child.id();
    say("video", &format!("second client up (pid {pid_b})"));

    // TWO accepted channels. Without this, everything below could be measuring a B that never
    // reached the document at all — and a B with no document has no pane to render, so its silence
    // would read as "two SCStreams are impossible" when it means "B never asked".
    say(
        "video",
        &format!(
            "waiting for a SECOND workspace document channel on :{}…",
            port::VIDEO
        ),
    );
    let _ignored = poll("a second workspace channel", 40, || {
        hostd.accepted_channels() >= 2
    });
    let channels = hostd.accepted_channels();
    if channels < 2 {
        complain(&format!(
            "==> FAIL: the second client never opened a workspace document channel (saw {channels})."
        ));
        hostd.log.dump("hostd log", 60);
        client_b.log.dump("client B log", 60);
        return Err("the second client never reached the document".to_owned());
    }
    say("video", "two workspace document channels ✅");

    say("video", "waiting for the second client to DECODE and PRESENT…");
    let _ignored = poll("the second client to render", 60, || {
        let (decoded, presented) = client_b.frames();
        decoded > 0 && presented > 0
    });
    let (decoded_b, presented_b) = client_b.frames();
    if decoded_b < 1 || presented_b < 1 {
        complain(&format!(
            "==> FAIL: the second client rendered nothing ({decoded_b} decode / {presented_b} present)."
        ));
        complain(
            "    It HAS the document (two channels accepted above), so this is the fan-out claim itself",
        );
        complain(
            "    failing: either the client never materialised the document's desktop pane, or the host",
        );
        complain("    cannot serve a second SCStream / VTCompressionSession on one capture target.");
        hostd.log.dump("hostd log", 60);
        client_b.log.dump("client B log", 60);
        return Err("the second client rendered nothing".to_owned());
    }
    say(
        "video",
        &format!("second client DECODED + PRESENTED ({decoded_b} / {presented_b}) ✅"),
    );

    // And A is STILL streaming. This separates a fan-out from a takeover: a host that can only hold
    // one session per target might hand the newcomer the stream and leave the incumbent on a frozen
    // last frame — in which case every check above still passes. GROWTH, not merely a non-zero
    // total from before B existed.
    thread::sleep(Duration::from_secs(3));
    let (decoded_after, _) = client_a.frames();
    if decoded_after <= decoded_before {
        complain(&format!(
            "==> FAIL: the FIRST client stopped decoding once the second attached ({decoded_before} → \
             {decoded_after})."
        ));
        complain("    The second client took the stream over instead of joining it — a fan-out serves both.");
        client_a.log.dump("client A log", 60);
        return Err("the second client took the stream over".to_owned());
    }
    say(
        "video",
        &format!(
            "the first client kept streaming across the join ({decoded_before} → {decoded_after} decodes) ✅"
        ),
    );

    for (name, pid) in [("A", client_a.child.id()), ("B", pid_b)] {
        if !holds_udp(pid, MEDIA_PORT) {
            return Err(format!(
                "client {name} (pid {pid}) holds no UDP flow to :{MEDIA_PORT}"
            ));
        }
    }
    say("video", "both clients hold their own media lane ✅");
    Ok(client_b)
}

/// Capture the host and client `OSLog` flow — diagnostics, never an assertion.
///
/// It carries the session SETUP only ("client decode pipeline up at capture `WxH`"); there is no
/// per-frame counter in it, and "the pipeline was built" is the premise rather than the claim.
fn capture_oslog(work: &Path) {
    use std::io::Write as _;

    let path = work.join("oslog.txt");
    let mut text = String::new();
    for (label, predicate) in [
        (
            "### host (slopdesk-videohostd) ###",
            "process == \"slopdesk-videohostd\"",
        ),
        (
            "### client (SlopDesk) — video subsystem ###",
            "process == \"SlopDesk\" AND subsystem BEGINSWITH \"slopdesk.video\"",
        ),
    ] {
        text.push_str(label);
        text.push('\n');
        if let Ok(output) = Command::new("/usr/bin/log")
            .args([
                "show",
                "--last",
                "60s",
                "--info",
                "--debug",
                "--predicate",
                predicate,
                "--style",
                "compact",
            ])
            .stderr(Stdio::null())
            .output()
        {
            text.push_str(&String::from_utf8_lossy(&output.stdout));
        }
    }
    if let Ok(mut sink) = fs::File::create(&path) {
        let _ignored = sink.write_all(text.as_bytes());
    }
    say(
        "video",
        &format!("OSLog flow → {} ({} lines)", path.display(), text.lines().count()),
    );
}

/// Raise one instance and photograph the screen with it in front.
///
/// **A GOTCHA, HW-learned 2026-06-09:** running `--list` again while the serving host's `SCStream`
/// is ACTIVE hangs the enumeration. Never list-while-active — raise the client and take a
/// full-screen grab instead, which is the window that needs reading anyway.
/// Drags the client's remote-window pane to `width`×`height` points through System Events, by the
/// window's title rather than by `window 1` — the video shape is a workspace window plus a DETACHED
/// remote window, and whichever is frontmost is not the one this wants.
///
/// A refusal is an error rather than a warning: the assertions after it are about what the resize
/// caused, and a window that did not move makes every one of them vacuous.
fn resize_remote_window(pid: u32, title: &str, width: u32, height: u32) -> Result<(), String> {
    let script = format!(
        "tell application \"System Events\" to tell (first process whose unix id is {pid}) to set size of \
         (first window whose name contains \"{}\") to {{{width}, {height}}}",
        title.replace('"', "\\\"")
    );
    let status = Command::new("/usr/bin/osascript")
        .args(["-e", &script])
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|error| format!("osascript: {error}"))?;
    if !status.success() {
        return Err(format!(
            "System Events could not resize the client's '{title}' window (Accessibility for this terminal?)"
        ));
    }
    Ok(())
}

fn raise_and_shoot(pid: u32, path: &Path, label: &str) {
    let _ = raise(pid);
    thread::sleep(Duration::from_secs(1));
    screenshot(path);
    say(
        "video",
        &format!("screenshot ({label} raised) saved: {}", path.display()),
    );
}

#[cfg(test)]
mod tests {
    #![expect(clippy::expect_used, reason = "a panic in a test is the failure report")]
    const LISTING: &str = "\
slopdesk-videohostd: shareable windows
  id=11 Finder — (untitled) [1728x1117]
  id=22 Menubar [1728x24]
  id=33 Terminal — slop-desk [1200x800]
  id=44 Slack — general [1600x1000]
  id=55 Tiny — thing [120x90]
  not a window at all
";

    /// The largest REAL app window wins, and the chrome the server also hands over does not.
    #[test]
    fn the_largest_real_app_window_is_the_default_target() {
        let picked = super::pick(LISTING, None).expect("there is a real window");
        assert_eq!(picked.id, 44, "1600x1000 beats 1200x800");
        assert_eq!(picked.title, "Slack — general");
    }

    /// The desktop backstop, the menu bar and a status-sized surface are never targets, however
    /// large the first of them is — 1728x1117 is the biggest line in the listing.
    #[test]
    fn the_desktop_backstop_is_never_the_target() {
        let all = super::candidates(LISTING);
        assert_eq!(
            all.len(),
            5,
            "five lines carry an id and a size; the sixth is prose"
        );
        let picked = super::pick(LISTING, None).expect("there is a real window");
        assert_ne!(
            picked.id, 11,
            "the Finder (untitled) desktop is not shareable content"
        );
        assert_ne!(picked.id, 22);
        assert_ne!(picked.id, 55, "120x90 is below the floor");
    }

    /// A named window is taken as written and NOT size-filtered: a caller who names one has already
    /// decided, and second-guessing them turns "serve it" into "no suitable window found".
    #[test]
    fn a_named_window_wins_over_the_largest_one() {
        let picked = super::pick(LISTING, Some("terminal")).expect("the named window is found");
        assert_eq!(picked.id, 33, "the needle is matched case-insensitively");
        let tiny = super::pick(LISTING, Some("Tiny")).expect("a named window skips the size floor");
        assert_eq!(tiny.id, 55);
    }

    /// The title is the app and title ALONE — it becomes the detached pane's window title and is
    /// read off a screenshot, so neither the `id=` prefix nor the `[WxH]` suffix may survive.
    #[test]
    fn a_title_carries_neither_the_id_prefix_nor_the_pixel_suffix() {
        let picked = super::pick(LISTING, Some("slop-desk")).expect("the named window is found");
        assert_eq!(picked.title, "Terminal — slop-desk");
        assert!(!picked.title.contains("id="));
        assert!(!picked.title.contains('['));
    }

    /// An empty listing is "grant TCC", not a panic — and it is the listing a run without
    /// Screen-Recording actually gets.
    #[test]
    fn an_empty_listing_picks_nothing() {
        assert!(super::pick("", None).is_none());
        assert!(super::pick("slopdesk-videohostd: 0 windows\n", None).is_none());
    }
}
