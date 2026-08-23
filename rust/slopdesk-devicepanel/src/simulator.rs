//! What the Simulators surface SAYS, and which of its situations a state picks.
//!
//! The seven surfaces below the Simulators tab — the list, the running card, the stage, the device
//! header, the console drawer, the location popover and the bezel — had ONE renderer until the Mac
//! drew them itself, so every word in them and every fold behind them had a single speller BY
//! ACCIDENT. There are two renderers now, and neither of them is where the answer lives.
//!
//! ## Why one module, and not one fold beside each drawing
//!
//! The argument is about ORDER. Four rules here are sequences whose steps are not interchangeable —
//! the row's subtitle suppression, the stage's three states, the console's three empty sentences,
//! and which facts the header prints — and each is a rule a second renderer would re-derive from
//! the same paragraph and get subtly wrong.
//!
//! ## What is NOT here
//!
//! **No ink, no metric, no font.** What descends is a ROLE ([`Ink`]) and a SILHOUETTE (an SF Symbol
//! name, which is a name and not a picture); each renderer spells the hue and mounts the image type
//! its framework has. The measured GEOMETRY that is not a design token — the bezel's fit, the
//! footprint swap a turned device needs — does descend, because those are facts about the artwork
//! rather than rungs on a ladder.
//!
//! **No socket, no poll.** The one asynchronous rule the Swift held — the veil's delayed rise — is
//! here as [`VEIL_DELAY_MS`] alone: the DELAY is the decision, and the sleep is the caller's
//! concurrency, not this crate's.
//!
//! **Nothing shared with the ANDROID panel.** See [`crate::android`]'s header for why that is a
//! rule rather than an omission.

use slopdesk_devicelog::Severity;

/// Which TIER of the text ladder a run of words sits on, or that it is the panel's one alarm.
///
/// ⚠️ `Alarm` IS THE ONLY COLOUR THIS PANEL HAS. Three of its surfaces broke that rule
/// independently before 2026-08-04 — a green "Live" dot in the header, green info lines in the
/// console, a coloured status pill — and the rule the removals left behind is worth stating where
/// both halves read it: a hue means SOMETHING IS WRONG, and nothing else. Healthy states ride
/// luminance and weight.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Ink {
    /// The thing being read.
    Primary = 0,
    /// A supporting line.
    Secondary = 1,
    /// A fact, a label, a resting verb.
    Tertiary = 2,
    /// The one hue this panel spends, and only on a fault.
    Alarm = 3,
}

impl Ink {
    /// The byte the C door answers with.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// The four ways a simulated device can be held.
///
/// The wire spellings are the SERVER's own, measured against a live one on 2026-08-04 rather than
/// guessed from what the status bar shows: it rejects the whole body on one bad field, so a
/// plausible synonym costs the entire request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum Orientation {
    /// Upright, and the ordinary case.
    #[default]
    Portrait = 0,
    /// Turned anticlockwise.
    LandscapeLeft = 1,
    /// Turned clockwise.
    LandscapeRight = 2,
    /// Upside down.
    PortraitUpsideDown = 3,
}

/// Which way a quarter turn goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Turn {
    /// Anticlockwise.
    Left = 0,
    /// Clockwise.
    Right = 1,
}

/// The physical cycle, clockwise. Turning right four times returns to where it started, which is
/// what lets a rotate button be pressed forever without reaching a dead end.
const CLOCKWISE: [Orientation; 4] = [
    Orientation::Portrait,
    Orientation::LandscapeRight,
    Orientation::PortraitUpsideDown,
    Orientation::LandscapeLeft,
];

impl Orientation {
    /// The byte the C door answers with.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// The orientation for `byte`, or `None` for a value no build of this crate wrote.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Portrait),
            1 => Some(Self::LandscapeLeft),
            2 => Some(Self::LandscapeRight),
            3 => Some(Self::PortraitUpsideDown),
            _ => None,
        }
    }

    /// The server's own spelling — kebab-case, matching `baguette orientation`'s argument.
    #[must_use]
    pub const fn wire_value(self) -> &'static str {
        match self {
            Self::Portrait => "portrait",
            Self::LandscapeLeft => "landscape-left",
            Self::LandscapeRight => "landscape-right",
            Self::PortraitUpsideDown => "portrait-upside-down",
        }
    }

    /// What a person calls it.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::Portrait => "Portrait",
            Self::LandscapeLeft => "Landscape Left",
            Self::LandscapeRight => "Landscape Right",
            Self::PortraitUpsideDown => "Upside Down",
        }
    }

    /// Whether the device is on its side.
    #[must_use]
    pub const fn is_landscape(self) -> bool {
        matches!(self, Self::LandscapeLeft | Self::LandscapeRight)
    }

    /// How far the PANEL must turn the picture to put the device upright, in degrees clockwise.
    ///
    /// The framebuffer never rotates. Measured 2026-08-04 on an iPhone 17 Pro: a rotated Safari
    /// still streams 1206×2622, with its interface drawn sideways INSIDE that portrait buffer — so
    /// nothing about the bezel geometry or the touch mapping changes when the device turns, and the
    /// panel's only job is to turn what it draws. Do not "fix" this by transposing the screen rect:
    /// there is no landscape framebuffer to fit into it.
    #[must_use]
    pub const fn view_angle(self) -> f64 {
        match self {
            Self::Portrait => 0.0,
            Self::LandscapeLeft => 90.0,
            Self::LandscapeRight => -90.0,
            Self::PortraitUpsideDown => 180.0,
        }
    }

    /// A quarter turn, wrapping.
    #[must_use]
    pub fn turned(self, direction: Turn) -> Self {
        let Some(index) = CLOCKWISE.iter().position(|entry| *entry == self) else {
            return Self::Portrait;
        };
        let step = match direction {
            Turn::Right => 1,
            Turn::Left => CLOCKWISE.len() - 1,
        };
        CLOCKWISE
            .get((index + step) % CLOCKWISE.len())
            .copied()
            .unwrap_or(Self::Portrait)
    }
}

/// The stage's three definite situations.
///
/// A stage with no picture on it says WHICH of the two reasons that is, rather than leaving the
/// reader an empty rectangle to interpret — an empty rectangle, a black screenshot and a dead
/// stream are pixel-identical.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum StageState {
    /// The device is on screen; draw the bezel (or the bare rect) and nothing over it.
    Live = 0,
    /// A veil with a spinner and a caption. Delayed — see [`VEIL_DELAY_MS`].
    Starting = 1,
    /// A veil with a caption and a retry button labelled [`RETRY_TITLE`].
    Stalled = 2,
}

impl StageState {
    /// The byte the C door answers with.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// The line drawn under the spinner, or over the retry. Empty for [`Self::Live`], which has
    /// nothing over the picture at all.
    #[must_use]
    pub const fn caption(self) -> &'static str {
        match self {
            Self::Live => "",
            Self::Starting => "Starting the stream…",
            Self::Stalled => "No video from this device.",
        }
    }
}

/// Which of the three things the stage is doing.
///
/// ⚠️ THE ORDER IS THE RULE. `shows_loading` first, because it is the DELAYED mirror of the model's
/// own awaiting flag and outranks a stall that has not been waited out yet; then the stall, which
/// is defined by the model's deadline having passed with no video; then live. Asked in any other
/// order the stage shows "no video" for the 90 ms before the first keyframe of every selection.
///
/// `has_video` is DECODABLE video, not "a frame arrived". The seed does not count: a seed-only
/// stream is a photograph of a device nobody is driving.
#[must_use]
#[expect(
    clippy::fn_params_excessive_bools,
    reason = "the four flags ARE the rule: each is an independent fact about the frame, and               \
              folding them into a struct would hide the ORDER this function exists to fix"
)]
pub const fn stage(
    is_selected: bool,
    shows_loading: bool,
    is_awaiting_stream: bool,
    has_video: bool,
) -> StageState {
    if shows_loading {
        return StageState::Starting;
    }
    if is_selected && !is_awaiting_stream && !has_video {
        StageState::Stalled
    } else {
        StageState::Live
    }
}

/// How long the model may be loading before the veil admits it, in milliseconds.
///
/// MEASURED: a booted device's first keyframe lands 0.09 s after the socket opens, so a veil with
/// no delay would flash grey over the bezel on every single selection — the whole failure being
/// drawn onto the ordinary case. This delay is the entire reason a renderer keeps its own copy of
/// the loading state instead of reading the model's.
///
/// The SHAPE is shared with the Android stage and the NUMBER deliberately is not: 400 was measured
/// against this server's 0.09 s first keyframe and the bridge's 600 against its own 0.83 s, and
/// merging them would throw away both measurements.
pub const VEIL_DELAY_MS: u32 = 400;

/// The floor between two-finger envelopes, in milliseconds.
///
/// MEASURED 2026-08-04: `touch2-move` occupies the server for 25 ms, a thousand times what a
/// `touch1-move` costs, so the two-finger path is rate-limited on BOTH halves — the Mac's
/// synthesized magnify and the phone's real second finger alike. One measurement about the SERVER,
/// and a number two files carry is a number that gets re-tuned in one of them.
pub const PINCH_INTERVAL_MS: u32 = 40;

/// The device list's search field.
pub const SEARCH_PLACEHOLDER: &str = "Search devices";

/// What the list draws in place of rows when the HOST has none.
///
/// Distinct from [`no_matches`] because "there are no devices" and "your filter hid them all" are
/// different sentences, and the second one is actionable.
pub const NO_DEVICES: &str = "No simulator devices on the host.";

/// The header's way back to the list.
pub const BACK_HELP: &str = "All Devices";

/// The stage's one TEXT button.
///
/// A stall is the one failure here that a second attempt genuinely fixes — the socket is fine, the
/// encoder never started — so the stage offers it rather than making someone go back to the list
/// and pick the same row again.
pub const RETRY_TITLE: &str = "Try Again";

/// The console drawer's caps title.
pub const CONSOLE_TITLE: &str = "Console";

/// The console filter field.
pub const CONSOLE_FILTER_PLACEHOLDER: &str = "Filter";

/// The console's level picker.
pub const CONSOLE_LEVEL_HELP: &str = "Minimum log level — changing it re-subscribes";

/// The console's clear plate.
pub const CONSOLE_CLEAR_HELP: &str = "Clear Console";

/// The console's clear plate.
pub const CONSOLE_CLEAR_SYMBOL: &str = "trash";

/// The console's dismiss plate.
pub const CONSOLE_HIDE_HELP: &str = "Hide Console";

/// The console's dismiss plate.
pub const CONSOLE_HIDE_SYMBOL: &str = "xmark";

/// A log row's Copy verb.
pub const CONSOLE_COPY_LINE: &str = "Copy Line";

/// The whole drawer's Copy verb.
pub const CONSOLE_COPY_CONSOLE: &str = "Copy Console";

/// FOLLOW IS A LATCH, not an inferred scroll position.
///
/// The usual "stick to the bottom until the reader scrolls away" needs a scroll offset this
/// deployment target does not report, and a latch is legible at rest and cannot disagree with
/// reality. Its glyph does not change across it.
pub const CONSOLE_FOLLOW_SYMBOL: &str = "arrow.down.to.line";

/// The Follow plate's tooltip, which is the one place its latch is spelled out.
#[must_use]
pub const fn console_follow_help(is_following: bool) -> &'static str {
    if is_following {
        "Following new output"
    } else {
        "Follow new output"
    }
}

/// The location popover's title, and the header fact's label.
pub const LOCATION_TITLE: &str = "Simulated Location";

/// The format every map app copies to the clipboard, shown as the placeholder because that is where
/// a coordinate typed into this field almost always comes from.
pub const LOCATION_PLACEHOLDER: &str = "37.334886, -122.008988";

/// The popover's commit verb.
pub const LOCATION_SET: &str = "Set";

/// The popover's undo verb. Absent while nothing is pinned — a control that undoes nothing is a
/// control that has to be reasoned about before it is ignored.
pub const LOCATION_CLEAR: &str = "Clear";

/// What the popover says while the device is not pinned anywhere.
pub const LOCATION_LIVE: &str = "The device is using live values.";

/// What the popover says while it is.
#[must_use]
pub fn location_pinned(readout: &str) -> String {
    format!("Pinned to {readout}")
}

/// The empty list's second sentence — the filter's doing, not the host's.
#[must_use]
pub fn no_matches(query: &str) -> String {
    format!("No devices match “{query}”.")
}

/// The trailing text on a shut-down device's row: the live state while the device is CHANGING, the
/// runtime when it is not and the heading has not already said it, and nothing at all otherwise.
///
/// ⚠️ THE TRANSITION OUTRANKS THE SUPPRESSION. A device spends seconds in `Booting`, and showing
/// its runtime through that is the panel claiming nothing is happening while something is. A
/// renderer that read only "does the heading already say the runtime" would draw the quiet answer
/// for exactly the row worth watching.
#[must_use]
pub fn row_subtitle(state: &str, is_booted: bool, runtime: &str, shows_runtime: bool) -> String {
    let settled = state.is_empty() || is_booted || state.eq_ignore_ascii_case("shutdown");
    if !settled {
        return state.to_owned();
    }
    if shows_runtime && !runtime.is_empty() {
        runtime.to_owned()
    } else {
        String::new()
    }
}

/// One entry of a device's context menu.
///
/// A VALUE rather than each half typing the same five titles in the same order: the menu differs by
/// exactly one branch (booted or not), and a renderer holding loose strings is a renderer that can
/// be handed them in the other order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum DeviceVerb {
    /// Open the mirror.
    OpenScreen = 0,
    /// A round trip for a PNG.
    CopyScreenshot = 1,
    /// Power the device down.
    Shutdown = 2,
    /// Power it up.
    Boot = 3,
    /// A rule, not a verb — the cut between what acts on the DEVICE and what copies a fact about
    /// it.
    Separator = 4,
    /// What every other tool wants — `xcrun simctl`, a test invocation, a bug report — and far too
    /// long to put in a row, which is the whole reason this cut exists.
    CopyUdid = 5,
    /// The device's own name.
    CopyName = 6,
}

impl DeviceVerb {
    /// The byte the C door answers with.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// What the item is called, or the empty string for [`Self::Separator`], which has no words.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::OpenScreen => "Open Screen",
            Self::CopyScreenshot => "Copy Screenshot",
            Self::Shutdown => "Shut Down",
            Self::Boot => "Boot",
            Self::Separator => "",
            Self::CopyUdid => "Copy UDID",
            Self::CopyName => "Copy Name",
        }
    }
}

/// The verbs a device's context menu offers, in order.
///
/// `Open Screen` and `Copy Screenshot` need a running device; `Boot` is the whole menu for one that
/// is not.
#[must_use]
pub fn device_menu(is_booted: bool) -> Vec<DeviceVerb> {
    let mut verbs = Vec::with_capacity(6);
    if is_booted {
        verbs.push(DeviceVerb::OpenScreen);
        verbs.push(DeviceVerb::CopyScreenshot);
        verbs.push(DeviceVerb::Shutdown);
    } else {
        verbs.push(DeviceVerb::Boot);
    }
    verbs.push(DeviceVerb::Separator);
    verbs.push(DeviceVerb::CopyUdid);
    verbs.push(DeviceVerb::CopyName);
    verbs
}

/// The idle row's one verb, as a sentence.
#[must_use]
pub fn boot_help(name: &str) -> String {
    format!("Boot {name}")
}

/// The running card's tooltip.
#[must_use]
pub fn open_help(name: &str) -> String {
    format!("Open {name}")
}

/// The running card's stop plate.
#[must_use]
pub fn shutdown_help(name: &str) -> String {
    format!("Shut down {name}")
}

/// A section heading's stop-all control.
///
/// Offered only once MORE THAN ONE device is up: with one running it is the same click as that
/// card's own stop button under a longer name.
#[must_use]
pub fn shutdown_all_help(count: usize) -> String {
    format!("Shut down all {count} running devices")
}

/// `1206 × 2622`.
///
/// THE MULTIPLICATION SIGN, not a lowercase x — this sits in a row of measured figures and a letter
/// standing in for an operator is the detail that makes a panel look improvised.
#[must_use]
pub fn pixels(width: f64, height: f64) -> String {
    format!("{} × {}", round_to_i64(width), round_to_i64(height))
}

/// A dimension as the whole number a person reads.
///
/// Saturating rather than wrapping: a NaN or an infinity in a frame size is a bug upstream, and a
/// figure of `0` in the header is a legible symptom where a wrapped one would be a plausible lie.
const fn round_to_i64(value: f64) -> i64 {
    let rounded = value.round();
    if rounded.is_nan() {
        return 0;
    }
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the saturating cast is the intent — see the doc comment"
    )]
    {
        rounded as i64
    }
}

/// The leading block of a UDID, which is what a person reads to tell two devices apart.
///
/// The full value is 36 characters and would own the line; Copy hands over the whole thing. Cut on
/// a CHARACTER boundary rather than a byte one — every UDID is hex and a dash, but a truncation
/// that could split a code point is a panic waiting for the first server that answers otherwise.
#[must_use]
pub fn shortened_udid(udid: &str) -> String {
    udid.chars().take(8).collect()
}

/// One entry of the header's fact line.
///
/// The TINT is a role here rather than a colour, and `is_measured` stays a fact about the VALUE (it
/// was measured, so it renders in the instrument face) rather than a styling flag: the distinction
/// is what makes a line tell a reader which of its parts were read off an instrument.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fact {
    /// Names the fact, in title case — the tooltip, the Copy verb, and the row's identity within
    /// one line, which is what lets a line animate a fact in or out without reshuffling.
    pub label: &'static str,
    /// What is drawn. May be an abbreviation of [`Self::copies`].
    pub text: String,
    /// What Copy hands over — the WHOLE value, never the abbreviation. The reason the short form is
    /// safe to draw at all is that the full one is one right-click away.
    pub copies: String,
    /// The rung the value sits on.
    pub ink: Ink,
    /// Measured facts render mono; named ones render in the system face.
    pub is_measured: bool,
    /// Whether the label is DRAWN ahead of the value. False for a fact that only appears when it is
    /// abnormal — its presence is the news, and the width is worth more to its neighbours.
    pub shows_label: bool,
}

/// What a fact's own Copy verb is called.
///
/// The LABEL names the fact, so the item reads "Copy Resolution" rather than "Copy" — which is the
/// whole reason a fact carries a label at all.
#[must_use]
pub fn copy_title(label: &str) -> String {
    format!("Copy {label}")
}

/// The header's fact line, in order — and WHICH facts are present at all, which is the half a
/// second renderer would have re-derived.
///
/// Ordered by how often it is the thing being checked: the pixel size, then anything abnormal, then
/// the short UDID. Orientation and position appear ONLY when they have something to say — a
/// portrait device and a device using live GPS are the ordinary case, and printing them would spend
/// the line's width on the absence of news.
///
/// The RUNTIME is deliberately absent: it rides the title beside the name, where it names the
/// device ("iPhone 17 Pro · iOS 26.5"). On this line it was one dot-separated figure among four,
/// which is where the thing you are actually looking for goes to hide.
///
/// The pinned position is NOT accented. It appears only when a position is pinned, so its presence
/// already says the device is lying about where it is, and the toolbar plate that pinned it is
/// latched six points below — two accents for one state inside one band is the colour noise this
/// header lost its status dot over.
///
/// `resolution` is `None` for a stream that has not named a size yet, and `pinned_readout` is empty
/// for a device using live values.
#[must_use]
pub fn facts(
    udid: &str,
    resolution: Option<(f64, f64)>,
    orientation: Orientation,
    pinned_readout: &str,
) -> Vec<Fact> {
    let mut facts = Vec::with_capacity(4);
    if let Some((width, height)) = resolution {
        facts.push(Fact {
            label: "Resolution",
            text: pixels(width, height),
            copies: pixels(width, height),
            ink: Ink::Secondary,
            is_measured: true,
            shows_label: true,
        });
    }
    if orientation != Orientation::Portrait {
        // Unlabelled: "Landscape Left" names itself, and it prints at all only because the device
        // is not upright.
        facts.push(Fact {
            label: "Orientation",
            text: orientation.title().to_owned(),
            copies: orientation.wire_value().to_owned(),
            ink: Ink::Tertiary,
            is_measured: false,
            shows_label: false,
        });
    }
    if !pinned_readout.is_empty() {
        // "Simulated Location" is three words wide in a column that has none to spare, and the
        // shorter label the toolbar plate already uses does the naming.
        facts.push(Fact {
            label: LOCATION_TITLE,
            text: pinned_readout.to_owned(),
            copies: pinned_readout.to_owned(),
            ink: Ink::Secondary,
            is_measured: true,
            shows_label: false,
        });
    }
    facts.push(Fact {
        label: "UDID",
        text: shortened_udid(udid),
        copies: udid.to_owned(),
        ink: Ink::Tertiary,
        is_measured: true,
        shows_label: true,
    });
    facts
}

/// One plate on the toolbar or the console strip: its SILHOUETTE and its tooltip — the two halves
/// of a control that are not a drawing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Plate {
    /// The SF Symbol's name.
    pub symbol: &'static str,
    /// The tooltip.
    pub help: &'static str,
}

impl Plate {
    const fn new(symbol: &'static str, help: &'static str) -> Self {
        Self { symbol, help }
    }
}

/// Turn it, anticlockwise.
pub const ROTATE_LEFT: Plate = Plate::new("rotate.left", "Rotate Left");

/// Turn it, clockwise.
pub const ROTATE_RIGHT: Plate = Plate::new("rotate.right", "Rotate Right");

/// The home gesture.
pub const HOME: Plate = Plate::new("house", "Home");

/// A TOGGLE, and the tooltip says so.
///
/// Measured 2026-08-04 against a booted device: the verb is the swipe-up-and-hold gesture, so it
/// opens the card stack from an app or the home screen and DISMISSES it when the stack is already
/// up — and on a device with nothing backgrounded it does nothing visible, exactly like the
/// hardware. Neither this nor `swipe-to-app-switcher` is an idempotent "show".
pub const APP_SWITCHER: Plate = Plate::new("square.on.square", "App Switcher — press again to dismiss");

/// Capture it.
pub const SCREENSHOT: Plate = Plate::new("camera.viewfinder", "Copy Screenshot");

/// The demo status bar's plate, which is latched while the override is in force.
///
/// NOTIFICATION CENTRE AND LOCK ARE NOT ON THIS TOOLBAR (user-directed 2026-08-04). Both were,
/// because the server offers the verb — which is not a reason. Nobody driving an app reaches for
/// the shade or the lock screen, and both are DESTRUCTIVE to the thing you are actually doing: a
/// mis-click blanks the device and costs a wake and a swipe to undo. The server still accepts
/// `pull-down-to-notification-center` and `lock`; only what this panel puts under the pointer
/// changed.
#[must_use]
pub const fn status_bar_plate(is_overridden: bool) -> Plate {
    Plate::new(
        "clock",
        if is_overridden {
            "Restore the real status bar"
        } else {
            "Demo status bar (9:41)"
        },
    )
}

/// Latched while a position is pinned, so the toolbar says the device is somewhere else without
/// anyone opening the popover to find out. The header carries the actual coordinate; this is the
/// glance.
#[must_use]
pub const fn location_plate(is_pinned: bool) -> Plate {
    Plate::new(
        "location",
        if is_pinned {
            "Simulated location"
        } else {
            "Simulate a location"
        },
    )
}

/// A ruled list, not a terminal prompt.
///
/// This opens a READER over the device's output, and the `>_` glyph promises a place to type.
/// (`terminal` is also the Terminal.app icon, and deprecated at this target.)
#[must_use]
pub const fn console_plate(is_open: bool) -> Plate {
    Plate::new(
        "list.bullet.rectangle",
        if is_open {
            "Hide the device log"
        } else {
            "Show the device log"
        },
    )
}

/// The box a TURNED device has to fit into.
///
/// A rotation does not change layout on either framework, so fitting a quarter-turned phone against
/// the panel's real bounds sizes it to a width it will not occupy and the device overflows the
/// column sideways. Swapping the bounds first is what makes a landscape device fill the panel the
/// way a portrait one does.
#[must_use]
pub const fn footprint(width: f64, height: f64, turned: bool) -> (f64, f64) {
    if turned { (height, width) } else { (width, height) }
}

/// Aspect-FIT, and never above 1: a bezel blown past its artwork's own size is a soft, resampled
/// device body, which looks worse than the same body drawn small and sharp.
///
/// It fits the BLEED rect, never the viewport — side buttons protrude past the body — and fitting
/// the viewport alone clips them at the panel's edge. A degenerate content or bounds size answers
/// `0`, which is a bezel that is not drawn rather than one drawn at an infinite scale.
#[must_use]
pub fn bezel_fit(content_width: f64, content_height: f64, width: f64, height: f64) -> f64 {
    if content_width <= 0.0 || content_height <= 0.0 || width <= 0.0 || height <= 0.0 {
        return 0.0;
    }
    // `f64::min`, never a `<` ternary — see `android::art_width` for why the IEEE operation is the
    // one that survives a NaN upstream.
    (width / content_width).min(height / content_height).min(1.0)
}

/// The server's button ids are wire tokens (`volume-up`, `action`).
///
/// Spelled out for the tooltip rather than shown raw — and titled FROM the id when it is one this
/// build has not seen, so a new button is still labelled with something.
#[must_use]
pub fn button_label(id: &str) -> String {
    match id {
        "power" => "Power".to_owned(),
        "volume-up" => "Volume Up".to_owned(),
        "volume-down" => "Volume Down".to_owned(),
        "action" => "Action Button".to_owned(),
        "home" => "Home".to_owned(),
        "lock" => "Lock".to_owned(),
        "digital-crown" => "Digital Crown".to_owned(),
        "side-button" => "Side Button".to_owned(),
        other => other.split('-').map(capitalized).collect::<Vec<_>>().join(" "),
    }
}

/// One dash-separated word of an unknown button id, with its first character raised.
///
/// The rest of the word is left ALONE rather than lowercased, which is Swift's `capitalized`
/// behaviour for a token that is already `ID` or `HDMI` — the id is a wire token this build has
/// never seen, and folding its case would be a guess on top of a guess.
fn capitalized(word: &str) -> String {
    let mut characters = word.chars();
    characters.next().map_or_else(String::new, |first| {
        first.to_uppercase().collect::<String>() + characters.as_str()
    })
}

/// What a failed read of a dropped file says.
///
/// The server routes a dropped file by EXTENSION — an `.app`/`.ipa` is installed, an image or video
/// lands in Photos — so this side accepts any file and lets the server classify it; getting that
/// taxonomy wrong locally would reject the one build someone wanted. The only local failure is not
/// being able to read the bytes at all.
#[must_use]
pub fn unreadable_drop(file_name: &str) -> String {
    format!("Could not read {file_name}.")
}

/// Three states, three sentences.
///
/// "Nothing here" over a console that never connected is the failure this exists to distinguish,
/// and the order is why: a non-empty history with nothing visible is the FILTER's doing and must be
/// said first, or a narrowed console reads as a dead one.
#[must_use]
pub fn console_empty_message(has_lines: bool, is_started: bool, level_title: &str, filter: &str) -> String {
    if has_lines {
        return format!("Nothing matches “{filter}”.");
    }
    if is_started {
        format!("Waiting for output at {} level…", level_title.to_lowercase())
    } else {
        "Connecting to the device log…".to_owned()
    }
}

/// The process name's ink. COLOUR ONLY FOR A FAULT.
///
/// Everything healthy is a grey, and the only difference between the greys is how far back they
/// sit. Info used to be green (user-directed 2026-08-04). Info is the ordinary case: a busy device
/// emits hundreds of info lines a second, so the rule spent the console's one alarm colour on the
/// state of nothing being wrong, and a wall half-green made the handful of red lines it exists to
/// surface no easier to find. Debug still recedes, because a debug line IS lower-value than the
/// default and luminance is the channel for that.
#[must_use]
pub const fn log_ink(severity: Severity) -> Ink {
    match severity {
        Severity::Fatal | Severity::Error => Ink::Alarm,
        Severity::Debug => Ink::Tertiary,
        // `Warning` is `logcat`'s bucket and the unified log never answers it — it is here so this
        // match stays exhaustive over one shared severity scale rather than over an alphabet only
        // the simulator has.
        Severity::Info | Severity::Warning | Severity::Plain => Ink::Secondary,
    }
}

#[cfg(test)]
mod tests {
    use slopdesk_devicelog::Severity;

    use super::{
        DeviceVerb, Ink, Orientation, StageState, Turn, bezel_fit, button_label, console_empty_message,
        console_follow_help, copy_title, device_menu, facts, footprint, location_pinned, log_ink, no_matches,
        pixels, row_subtitle, shortened_udid, stage, status_bar_plate, unreadable_drop,
    };

    #[test]
    fn loading_outranks_a_stall_that_has_not_been_waited_out() {
        assert_eq!(stage(true, true, false, false), StageState::Starting);
        assert_eq!(stage(true, false, false, false), StageState::Stalled);
        assert_eq!(stage(true, false, false, true), StageState::Live);
        // A stream still legitimately awaited is not a stall.
        assert_eq!(stage(true, false, true, false), StageState::Live);
        // Nothing selected is never a stall — there is nothing that failed.
        assert_eq!(stage(false, false, false, false), StageState::Live);
    }

    #[test]
    fn only_the_live_stage_has_nothing_to_say() {
        assert!(StageState::Live.caption().is_empty());
        assert!(!StageState::Starting.caption().is_empty());
        assert!(!StageState::Stalled.caption().is_empty());
    }

    #[test]
    fn a_transition_outranks_the_runtime_suppression() {
        // `Booting` is the row worth watching, and it prints through the suppression.
        assert_eq!(row_subtitle("Booting", false, "iOS 26.5", true), "Booting");
        assert_eq!(row_subtitle("Booting", false, "iOS 26.5", false), "Booting");
        // Settled and the heading has not said it: the runtime.
        assert_eq!(row_subtitle("Shutdown", false, "iOS 26.5", true), "iOS 26.5");
        // Settled and the heading already said it: nothing.
        assert!(row_subtitle("Shutdown", false, "iOS 26.5", false).is_empty());
        // A booted device is settled whatever its word says.
        assert!(row_subtitle("Booted", true, "iOS 26.5", false).is_empty());
        // Case is not a state change — the comparison drives an affordance.
        assert!(row_subtitle("shutdown", false, "", true).is_empty());
    }

    #[test]
    fn the_menu_differs_by_exactly_one_branch() {
        assert_eq!(device_menu(true), vec![
            DeviceVerb::OpenScreen,
            DeviceVerb::CopyScreenshot,
            DeviceVerb::Shutdown,
            DeviceVerb::Separator,
            DeviceVerb::CopyUdid,
            DeviceVerb::CopyName,
        ]);
        assert_eq!(device_menu(false), vec![
            DeviceVerb::Boot,
            DeviceVerb::Separator,
            DeviceVerb::CopyUdid,
            DeviceVerb::CopyName,
        ]);
    }

    #[test]
    fn the_separator_is_the_one_verb_with_no_words() {
        assert!(DeviceVerb::Separator.title().is_empty());
        for verb in [
            DeviceVerb::OpenScreen,
            DeviceVerb::CopyScreenshot,
            DeviceVerb::Shutdown,
            DeviceVerb::Boot,
            DeviceVerb::CopyUdid,
            DeviceVerb::CopyName,
        ] {
            assert!(!verb.title().is_empty());
        }
    }

    #[test]
    fn a_figure_is_drawn_with_the_multiplication_sign() {
        assert_eq!(pixels(1206.0, 2622.0), "1206 × 2622");
        assert_eq!(pixels(1205.6, 2621.4), "1206 × 2621");
        // A NaN size is a bug upstream, and `0` is a legible symptom.
        assert_eq!(pixels(f64::NAN, 2622.0), "0 × 2622");
    }

    #[test]
    fn a_udid_is_cut_on_a_character_boundary() {
        assert_eq!(shortened_udid("A1B2C3D4-5E6F-4A8B-9C0D-1E2F3A4B5C6D"), "A1B2C3D4");
        assert_eq!(shortened_udid("short"), "short");
        assert!(shortened_udid("").is_empty());
        // Not hex, and not one byte per character: the cut must not split the code point.
        assert_eq!(shortened_udid("émoji🙂tail"), "émoji🙂ta");
    }

    #[test]
    fn the_header_prints_the_abnormal_and_nothing_else() {
        let quiet = facts("UDID-1234-5678", None, Orientation::Portrait, "");
        assert_eq!(quiet.iter().map(|fact| fact.label).collect::<Vec<_>>(), ["UDID"]);
        assert_eq!(quiet.first().map(|fact| fact.text.as_str()), Some("UDID-123"));
        assert_eq!(
            quiet.first().map(|fact| fact.copies.as_str()),
            Some("UDID-1234-5678")
        );

        let loud = facts(
            "UDID-1234-5678",
            Some((1206.0, 2622.0)),
            Orientation::LandscapeLeft,
            "37.334886, -122.008988",
        );
        assert_eq!(loud.iter().map(|fact| fact.label).collect::<Vec<_>>(), [
            "Resolution",
            "Orientation",
            "Simulated Location",
            "UDID"
        ]);
        // The orientation copies the WIRE spelling, not the one it draws.
        assert_eq!(
            loud.get(1).map(|fact| fact.copies.as_str()),
            Some("landscape-left")
        );
        // Neither the orientation nor the pinned position is accented.
        assert_eq!(loud.get(1).map(|fact| fact.ink), Some(Ink::Tertiary));
        assert_eq!(loud.get(2).map(|fact| fact.shows_label), Some(false));
        assert_eq!(copy_title("Resolution"), "Copy Resolution");
    }

    #[test]
    fn a_quarter_turn_wraps_in_both_directions() {
        assert_eq!(
            Orientation::Portrait.turned(Turn::Right),
            Orientation::LandscapeRight
        );
        assert_eq!(
            Orientation::Portrait.turned(Turn::Left),
            Orientation::LandscapeLeft
        );
        let mut angle = Orientation::Portrait;
        for _ in 0..4 {
            angle = angle.turned(Turn::Right);
        }
        assert_eq!(angle, Orientation::Portrait);
    }

    #[test]
    fn only_the_two_sides_are_landscape_and_the_picture_turns_the_other_way() {
        assert!(Orientation::LandscapeLeft.is_landscape());
        assert!(Orientation::LandscapeRight.is_landscape());
        assert!(!Orientation::Portrait.is_landscape());
        assert!(!Orientation::PortraitUpsideDown.is_landscape());
        assert!((Orientation::LandscapeLeft.view_angle() - 90.0).abs() < f64::EPSILON);
        assert!((Orientation::LandscapeRight.view_angle() + 90.0).abs() < f64::EPSILON);
    }

    #[test]
    fn every_orientation_survives_the_byte_it_crosses_as_and_names_two_spellings() {
        for orientation in [
            Orientation::Portrait,
            Orientation::LandscapeLeft,
            Orientation::LandscapeRight,
            Orientation::PortraitUpsideDown,
        ] {
            assert_eq!(Orientation::from_byte(orientation.as_byte()), Some(orientation));
            assert!(!orientation.title().is_empty());
            assert!(!orientation.wire_value().is_empty());
        }
        assert_eq!(Orientation::from_byte(4), None);
    }

    #[test]
    fn a_turned_device_is_fitted_against_swapped_bounds() {
        assert_eq!(footprint(400.0, 900.0, true), (900.0, 400.0));
        assert_eq!(footprint(400.0, 900.0, false), (400.0, 900.0));
    }

    #[test]
    fn a_bezel_is_never_blown_past_its_artwork() {
        // Room to spare in both axes: the scale is capped at 1 rather than filling the panel.
        assert!((bezel_fit(100.0, 200.0, 400.0, 900.0) - 1.0).abs() < f64::EPSILON);
        // Height-bound.
        assert!((bezel_fit(100.0, 200.0, 400.0, 100.0) - 0.5).abs() < f64::EPSILON);
        // Width-bound.
        assert!((bezel_fit(100.0, 200.0, 25.0, 900.0) - 0.25).abs() < f64::EPSILON);
        // A degenerate size is a bezel that is not drawn.
        assert!((bezel_fit(0.0, 200.0, 400.0, 900.0)).abs() < f64::EPSILON);
        assert!((bezel_fit(100.0, 200.0, 400.0, 0.0)).abs() < f64::EPSILON);
    }

    #[test]
    fn an_unknown_button_id_is_still_labelled_with_something() {
        assert_eq!(button_label("volume-up"), "Volume Up");
        assert_eq!(button_label("digital-crown"), "Digital Crown");
        assert_eq!(button_label("camera-control"), "Camera Control");
        assert_eq!(button_label("shutter"), "Shutter");
        assert!(button_label("").is_empty());
    }

    #[test]
    fn the_filter_answers_before_the_connection_does() {
        assert_eq!(
            console_empty_message(true, true, "Info", "boom"),
            "Nothing matches “boom”."
        );
        assert_eq!(
            console_empty_message(false, true, "Info", ""),
            "Waiting for output at info level…"
        );
        assert_eq!(
            console_empty_message(false, false, "Info", ""),
            "Connecting to the device log…"
        );
    }

    #[test]
    fn info_is_a_grey_and_only_a_fault_is_not() {
        assert_eq!(log_ink(Severity::Fatal), Ink::Alarm);
        assert_eq!(log_ink(Severity::Error), Ink::Alarm);
        assert_eq!(log_ink(Severity::Info), Ink::Secondary);
        assert_eq!(log_ink(Severity::Warning), Ink::Secondary);
        assert_eq!(log_ink(Severity::Plain), Ink::Secondary);
        // Debug recedes, which is the one place this differs from the Android console.
        assert_eq!(log_ink(Severity::Debug), Ink::Tertiary);
    }

    #[test]
    fn the_latching_plates_say_which_way_they_are_latched() {
        assert_ne!(status_bar_plate(true).help, status_bar_plate(false).help);
        assert_eq!(status_bar_plate(true).symbol, status_bar_plate(false).symbol);
        assert_ne!(console_follow_help(true), console_follow_help(false));
    }

    #[test]
    fn the_sentences_that_carry_a_value_carry_it_verbatim() {
        assert_eq!(no_matches("iphone"), "No devices match “iphone”.");
        assert_eq!(location_pinned("1.0, 2.0"), "Pinned to 1.0, 2.0");
        assert_eq!(unreadable_drop("App.ipa"), "Could not read App.ipa.");
    }
}
