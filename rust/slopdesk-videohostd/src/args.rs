//! The daemon's argv grammar, and the one environment knob that can override it.
//!
//! Pure, and deliberately so: [`Arguments::parse`] takes the already-resolved `SLOPDESK_VD` text
//! rather than reading it. The resolution order is `docs/58`'s — the process environment first, the
//! settings overlay second — and it belongs to whoever owns the overlay table, which is the process
//! and not this grammar. Threading the resolved value in is also what makes the whole grammar
//! testable on a machine with no window server and no sidecar.
//!
//! ## Faithfulness
//!
//! Carried from the Swift daemon's `VideoHostdArguments` verbatim, including the parts that are not
//! the project's usual shape. An unknown argument is a USAGE error rather than an ignored token.
//! `--help` takes the same path as a parse failure, so the usage text goes to stderr and the exit
//! code is 2 either way. The `--scale`/`--bitrate`/`--fps` bounds are checked during the parse, not
//! after, so `--fps 0` is a usage error rather than a clamp. `--vd-point-size` lowercases before
//! splitting, so `1920X1080` parses. `-h`/`--help` is not a separate arm: it falls through the same
//! `_` the unknown arguments do.

use core::fmt;

/// How wide a virtual display may be asked to be, in points.
///
/// The floor the Swift checked, kept as a named constant because the two dimensions have different
/// ones and an inlined pair reads like a typo.
const VD_MIN_POINT_WIDTH: u32 = 320;

/// How tall a virtual display may be asked to be, in points.
const VD_MIN_POINT_HEIGHT: u32 = 240;

/// The frame-rate ceiling `--fps` accepts.
///
/// The default is the rate a 60 Hz source actually produces. Every changed frame the capture
/// delivers is encoded; the number is what the stream is ANNOUNCED and BUDGETED at (the bitrate
/// target, `ExpectedFrameRate`, the client's cold-start cadence), and it is the base rung the fps
/// governor steps down from under congestion. A default below the source's rate would have the
/// stream run at one rate while everything that reads the number believes another.
const FPS_MAX: u32 = 120;

/// Everything the daemon learns from its own command line.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Arguments {
    /// Enumerate the host's shareable windows and exit.
    pub list: bool,
    /// Probe whether `ScreenCaptureKit` can see the virtual display, and exit.
    pub vd_sck_probe: bool,
    /// Serve the window with this `CGWindowID`.
    ///
    /// Only `--list` and the per-`hello` mint actually pick a window — the daemon always runs the
    /// UDP-mux path and mints a per-channel session from each client's own `windowID`, so this is a
    /// convenience for driving one pane by hand rather than a required argument.
    pub window_id: Option<u32>,
    /// UDP media/control/geometry/input port.
    pub media_port: u16,
    /// UDP dedicated cursor port.
    pub cursor_port: u16,
    /// Capture at window-points × this many PIXELS. `1` is point-res; raise for sharper text.
    pub scale: f64,
    /// Live-encoder target bitrate, in Mbps.
    pub bitrate_mbps: u32,
    /// The announced and budgeted encode rate, and the governor's base rung.
    pub fps: u32,
    /// Create a `HiDPI` virtual display and park each remoted window on it.
    ///
    /// DEFAULT OFF: capture the real display directly — no synthetic display in the host's
    /// arrangement and no window parking. On a 1× host that means 1× capture, and the virtual
    /// display is the only way to get 2× there.
    pub virtual_display: bool,
    /// Virtual-display logical width, in points.
    pub vd_point_width: u32,
    /// Virtual-display logical height, in points.
    pub vd_point_height: u32,
}

impl Default for Arguments {
    fn default() -> Self {
        Self {
            list: false,
            vd_sck_probe: false,
            window_id: None,
            media_port: 9000,
            cursor_port: 9001,
            scale: 1.0,
            bitrate_mbps: 12,
            fps: 60,
            virtual_display: false,
            vd_point_width: 1920,
            vd_point_height: 1080,
        }
    }
}

/// The one substring `--window-title` matches against, kept out of [`Arguments`] so that type stays
/// `Copy` — every consumer of the parsed arguments passes them by value across a queue boundary.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WindowTitle(pub Option<String>);

/// What a parse produced: the flags, plus the one owned string among them.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Parsed {
    /// The scalar half.
    pub arguments: Arguments,
    /// Serve the first on-screen window whose title contains this.
    pub window_title: WindowTitle,
}

impl Arguments {
    /// Parses `argv`, skipping the program name.
    ///
    /// `vd_env` is the already-resolved `SLOPDESK_VD` text — see the module docs for why it is a
    /// parameter. It applies ONLY when neither `--virtual-display` nor `--no-virtual-display` was
    /// given: an explicit flag always wins. Only the exact text `0` keeps the display off; any
    /// other value turns it on, which is the Swift's own idiom and not the project's usual one.
    ///
    /// `None` means "print the usage and exit 2", and `--help` deliberately takes that path too.
    #[must_use]
    pub fn parse(argv: &[String], vd_env: Option<&str>) -> Option<Parsed> {
        let mut parsed = Parsed::default();
        // An explicit CLI flag wins over the environment, so the override below has to know whether
        // one was seen at all — `virtual_display == false` cannot distinguish "unset" from
        // "--no-virtual-display".
        let mut vd_explicit = false;
        let mut index = 1;
        while index < argv.len() {
            let take = |offset: &mut usize| -> Option<&str> {
                let value = argv.get(*offset + 1)?;
                *offset += 1;
                Some(value.as_str())
            };
            match argv.get(index)?.as_str() {
                "--list" => parsed.arguments.list = true,
                "--vd-sck-probe" => parsed.arguments.vd_sck_probe = true,
                "--window-id" => parsed.arguments.window_id = Some(take(&mut index)?.parse().ok()?),
                "--window-title" => parsed.window_title = WindowTitle(Some(take(&mut index)?.to_owned())),
                "--media-port" => parsed.arguments.media_port = take(&mut index)?.parse().ok()?,
                "--cursor-port" => parsed.arguments.cursor_port = take(&mut index)?.parse().ok()?,
                "--scale" => {
                    let scale: f64 = take(&mut index)?.parse().ok()?;
                    // Asked in the direction the Swift asked it. `NaN >= 1` is FALSE there, and a
                    // negated `<` would make it TRUE here — the one input where the two spellings
                    // are not the same predicate.
                    #[expect(
                        clippy::neg_cmp_op_on_partial_ord,
                        reason = "the negation is what excludes NaN, which a `<` would admit"
                    )]
                    if !(scale >= 1.0) {
                        return None;
                    }
                    parsed.arguments.scale = scale;
                },
                "--bitrate" => {
                    let mbps: u32 = take(&mut index)?.parse().ok()?;
                    if mbps < 1 {
                        return None;
                    }
                    parsed.arguments.bitrate_mbps = mbps;
                },
                "--fps" => {
                    let fps: u32 = take(&mut index)?.parse().ok()?;
                    if !(1..=FPS_MAX).contains(&fps) {
                        return None;
                    }
                    parsed.arguments.fps = fps;
                },
                "--virtual-display" => {
                    parsed.arguments.virtual_display = true;
                    vd_explicit = true;
                },
                "--no-virtual-display" => {
                    parsed.arguments.virtual_display = false;
                    vd_explicit = true;
                },
                "--vd-point-size" => {
                    let (width, height) = parse_point_size(take(&mut index)?)?;
                    parsed.arguments.vd_point_width = width;
                    parsed.arguments.vd_point_height = height;
                },
                // `--help` and an unknown argument take the SAME path on purpose: both print the
                // usage to stderr and exit 2, which is what the Swift did and what a caller
                // piping stderr already expects.
                _ => return None,
            }
            index += 1;
        }
        if !vd_explicit && let Some(value) = vd_env {
            parsed.arguments.virtual_display = value != "0";
        }
        // Two DISTINCT non-zero UDP ports: the sockets must differ, and zero is not bindable as a
        // fixed port the client can be told about.
        if parsed.arguments.media_port == 0
            || parsed.arguments.cursor_port == 0
            || parsed.arguments.media_port == parsed.arguments.cursor_port
        {
            return None;
        }
        Some(parsed)
    }
}

/// `WxH`, lowercased first so `1920X1080` parses the way the Swift's `.lowercased()` made it.
fn parse_point_size(raw: &str) -> Option<(u32, u32)> {
    let lowered = raw.to_lowercase();
    let mut parts = lowered.split('x');
    let width: u32 = parts.next()?.parse().ok()?;
    let height: u32 = parts.next()?.parse().ok()?;
    // Exactly two components. `1920x1080x2` is a typo, not a size.
    if parts.next().is_some() || width < VD_MIN_POINT_WIDTH || height < VD_MIN_POINT_HEIGHT {
        return None;
    }
    Some((width, height))
}

/// The `--version` banner: the binary's name, a space, the crate's version.
///
/// The shape every shipped tool answers, and the one `slopdesk-release package`, the formula's
/// `test do` and hostd's install-side audit all read as "field two of line one" (`docs/49`).
#[must_use]
pub fn version_banner() -> String {
    format!("slopdesk-videohostd {}", env!("CARGO_PKG_VERSION"))
}

/// The usage text, with the program name the process was invoked under.
#[derive(Debug, Clone, Copy)]
pub struct Usage<'a>(pub &'a str);

impl fmt::Display for Usage<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let program = self.0;
        write!(
            f,
            "usage: {program} [--version] [--list] [--window-id N | --window-title SUBSTR] [--media-port N] \
             [--cursor-port N]\n\n\x20 --version          print `slopdesk-videohostd <version>` and \
             exit\n\x20 --list             enumerate shareable windows (id, app, title, size) and \
             exit\n\x20 --window-id N      serve the window with CGWindowID N\n\x20 --window-title S   \
             serve the first on-screen window whose title contains S\n\x20 --media-port N     UDP \
             media/control/geometry/input port (default 9000)\n\x20 --cursor-port N    UDP dedicated cursor \
             port (default 9001)\n\x20 --scale N          capture at window-points × N PIXELS (default 1 = \
             light; 2 = Retina/sharper)\n\x20 --bitrate N        live-encoder target bitrate in Mbps \
             (default 12; higher = crisper text,\n\x20                    but the low-latency rate-control \
             caps keyframe growth — for truly sharp\n\x20                    text raise --scale instead, or \
             use an all-intra mode)\n\x20 --fps N            announced encode rate and governor base \
             (default 60; the capture\n\x20                    ceiling is twice this)\n\x20 \
             --virtual-display  create a HiDPI 2× virtual display and move each remoted window onto it so \
             it\n\x20                    renders at REAL Retina backing (razor-sharp text) — the only way \
             to get 2×\n\x20                    on a 1× host. DEFAULT OFF. Also via SLOPDESK_VD=1.\n\x20 \
             --no-virtual-display  (default) capture the real display directly — no synthetic display, \
             no\n\x20                    window parking; 1× capture on a 1× host. Also via \
             SLOPDESK_VD=0.\n\x20 --vd-point-size WxH  virtual-display logical size in points (default \
             1920x1080 → 3840x2160 px)\n\nNeeds Screen-Recording (capture) + Accessibility & Post-Event \
             (input) TCC, and a\nreal GUI login session. Run from the desktop, not over SSH."
        )
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, and a grammar that rounds is not a grammar"
    )]

    use super::*;

    fn argv(rest: &[&str]) -> Vec<String> {
        core::iter::once("slopdesk-videohostd")
            .chain(rest.iter().copied())
            .map(str::to_owned)
            .collect()
    }

    fn parse(rest: &[&str]) -> Option<Parsed> {
        Arguments::parse(&argv(rest), None)
    }

    #[test]
    fn a_bare_invocation_is_the_documented_default() {
        let parsed = parse(&[]).expect("no arguments is a valid invocation");
        assert_eq!(parsed.arguments, Arguments::default());
        assert_eq!(parsed.window_title, WindowTitle(None));
    }

    #[test]
    fn every_valued_flag_consumes_its_value() {
        let parsed = parse(&[
            "--window-id",
            "12345",
            "--media-port",
            "7000",
            "--cursor-port",
            "7001",
            "--scale",
            "2",
            "--bitrate",
            "20",
            "--fps",
            "90",
            "--vd-point-size",
            "2560x1440",
        ])
        .expect("every value is in range");
        assert_eq!(parsed.arguments.window_id, Some(12345));
        assert_eq!(parsed.arguments.media_port, 7000);
        assert_eq!(parsed.arguments.cursor_port, 7001);
        assert!((parsed.arguments.scale - 2.0).abs() < f64::EPSILON);
        assert_eq!(parsed.arguments.bitrate_mbps, 20);
        assert_eq!(parsed.arguments.fps, 90);
        assert_eq!(parsed.arguments.vd_point_width, 2560);
        assert_eq!(parsed.arguments.vd_point_height, 1440);
    }

    #[test]
    fn an_unknown_argument_is_a_usage_error_rather_than_an_ignored_token() {
        assert!(parse(&["--sharpen"]).is_none());
    }

    /// Field two of line one is the version, and field one is the name the manifest lists —
    /// the contract every shipped binary's banner keeps (`docs/49`).
    #[test]
    fn the_version_banner_is_name_then_version_and_nothing_else() {
        let banner = version_banner();
        let fields: Vec<&str> = banner.split_whitespace().collect();
        assert_eq!(
            fields,
            ["slopdesk-videohostd", env!("CARGO_PKG_VERSION")],
            "{banner:?}"
        );
        assert!(!banner.contains('\n'));
    }

    #[test]
    fn help_takes_the_usage_path() {
        assert!(parse(&["-h"]).is_none());
        assert!(parse(&["--help"]).is_none());
    }

    #[test]
    fn a_valued_flag_at_the_end_with_no_value_is_a_usage_error() {
        assert!(parse(&["--window-id"]).is_none());
        assert!(parse(&["--vd-point-size"]).is_none());
    }

    #[test]
    fn the_bounds_are_checked_during_the_parse_rather_than_clamped() {
        assert!(parse(&["--scale", "0.5"]).is_none());
        assert!(parse(&["--bitrate", "0"]).is_none());
        assert!(parse(&["--fps", "0"]).is_none());
        assert!(parse(&["--fps", "121"]).is_none());
        assert!(parse(&["--fps", "120"]).is_some(), "the ceiling is inclusive");
    }

    #[test]
    fn the_two_ports_must_be_distinct_and_non_zero() {
        assert!(parse(&["--media-port", "0"]).is_none());
        assert!(parse(&["--cursor-port", "0"]).is_none());
        assert!(
            parse(&["--media-port", "9001"]).is_none(),
            "equal to the cursor default"
        );
        assert!(parse(&["--media-port", "9001", "--cursor-port", "9000"]).is_some());
    }

    #[test]
    fn a_point_size_lowercases_before_it_splits() {
        let parsed = parse(&["--vd-point-size", "1920X1080"]).expect("an upper-case X is the same size");
        assert_eq!(parsed.arguments.vd_point_width, 1920);
        assert_eq!(parsed.arguments.vd_point_height, 1080);
    }

    #[test]
    fn a_point_size_below_either_floor_is_refused() {
        assert!(parse(&["--vd-point-size", "319x1080"]).is_none());
        assert!(parse(&["--vd-point-size", "1920x239"]).is_none());
        assert!(
            parse(&["--vd-point-size", "320x240"]).is_some(),
            "both floors are inclusive"
        );
    }

    #[test]
    fn a_point_size_with_a_third_component_is_a_typo_rather_than_a_size() {
        assert!(parse(&["--vd-point-size", "1920x1080x2"]).is_none());
        assert!(parse(&["--vd-point-size", "1920"]).is_none());
    }

    #[test]
    fn the_environment_turns_the_virtual_display_on_unless_it_is_exactly_zero() {
        let on = Arguments::parse(&argv(&[]), Some("1")).expect("valid");
        assert!(on.arguments.virtual_display);
        let also_on = Arguments::parse(&argv(&[]), Some("yes")).expect("valid");
        assert!(
            also_on.arguments.virtual_display,
            "the Swift tested `!= \"0\"`, not truthiness"
        );
        let off = Arguments::parse(&argv(&[]), Some("0")).expect("valid");
        assert!(!off.arguments.virtual_display);
    }

    #[test]
    fn an_explicit_flag_beats_the_environment_in_both_directions() {
        let forced_off = Arguments::parse(&argv(&["--no-virtual-display"]), Some("1")).expect("valid");
        assert!(!forced_off.arguments.virtual_display);
        let forced_on = Arguments::parse(&argv(&["--virtual-display"]), Some("0")).expect("valid");
        assert!(forced_on.arguments.virtual_display);
    }

    #[test]
    fn a_title_substring_survives_the_parse_verbatim() {
        let parsed = parse(&["--window-title", "main.swift — Ghostty"]).expect("valid");
        assert_eq!(
            parsed.window_title,
            WindowTitle(Some("main.swift — Ghostty".to_owned()))
        );
    }
}
