//! What the Android panel's five surfaces SAY, and every fold either renderer would otherwise have
//! taken on its own.
//!
//! The list, the stage, the header, the running card and the console had ONE renderer until the Mac
//! drew them in `AppKit`, so every word in them and every phase→drawing answer had a single speller
//! BY ACCIDENT. There are two renderers now — and, since the port, neither of them is where the
//! answer lives.
//!
//! ## Why the folds and not just the words
//!
//! A copy string drifts LOUDLY: somebody reads the phone's screen and the Mac's and sees two
//! sentences. An ORDERING drifts silently, and this panel has three of them that would have gone
//! unnoticed for a release:
//!
//! * [`can_enter`] — whether a tap on a device opens its mirror at all. It was spelled TWICE inside
//!   one Swift file pair already, which is one spelling away from a Mac that opens a booting
//!   emulator and a phone that refuses it.
//! * [`stage`] — loading OUTRANKS stalled, which outranks streaming, and the loading answer then
//!   asks a SECOND question (is the DEVICE still coming up, or only the mirror).
//! * [`device_menu`] — a verb table. One half quietly grows a verb the other has not got, and
//!   nothing is red until somebody notices their context menu is shorter.
//!
//! ## What is NOT here
//!
//! **No ink, no metric, no font.** A reading names its own SILHOUETTE (an SF Symbol, by NAME — both
//! renderers already resolve one) and its own INK ROLE ([`Ink`]), and each renderer spells the hue.
//! The two MEASURED lengths that are not design tokens — the veil's delay and the fallback aspect —
//! live here, because they were measured once.
//!
//! **No layout.** Where the trays sit, how a card is framed, which container scrolls: that is the
//! renderer's, and the two frameworks are entitled to disagree about it.
//!
//! **Nothing shared with the SIMULATOR panel.** The two surfaces look alike and share not one byte
//! of protocol — `scrcpy` over `adb` against `baguette`'s WebSocket, Annex-B against AVC, packed
//! control messages against JSON envelopes — so a common device vocabulary would be an abstraction
//! over a coincidence. What they genuinely share is [`crate::geometry`], [`crate::panel_key`] and
//! `slopdesk_devicelog`, lifted one fact at a time and never as a family.

use slopdesk_devicelog::Severity;

/// A text ROLE, resolved to a hue by whichever half is drawing.
///
/// Four rungs and one alarm, which is the whole ladder this panel uses. A role rather than a colour
/// because the design floor sits ABOVE the panel on the Swift side, so naming its ladder here would
/// invert the dependency the split is built on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Ink {
    /// The thing being read — a device's name, a log message's own line.
    Primary = 0,
    /// A supporting line: a summary, a caption, a log body.
    Secondary = 1,
    /// A fact, a label, a resting verb.
    Tertiary = 2,
    /// A silhouette. The same value as [`Ink::Secondary`] on both halves today, and named apart
    /// because it answers a different question.
    Icon = 3,
    /// The one hue this panel spends, and only on a fault.
    Err = 4,
}

impl Ink {
    /// The byte the C door answers with.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// What the mirroring stage is showing, once the veil's delay has been waited out.
///
/// FOUR DEFINITE THINGS, never an indicator with no end. A stage with no picture on it says which
/// of the reasons that is, because an empty rectangle and a dead stream are pixel-identical and the
/// ambiguous object IS the rectangle.
///
/// The two loading answers are separate cases rather than one carrying a caption, because that is
/// the whole distinction: a mirror the HOST is starting and a device that is still booting are two
/// different waits with two different owners, and the second can be tens of seconds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum StageReading {
    /// Nothing over the picture.
    Streaming = 0,
    /// The veil, over a device that has not finished coming up.
    StartingDevice = 1,
    /// The veil, over a device that is up and a mirror that is not.
    StartingMirror = 2,
    /// The veil, with the retry the failure actually fixes.
    Stalled = 3,
}

impl StageReading {
    /// The byte the C door answers with.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// The line drawn under the spinner, or over the retry. Empty for [`Self::Streaming`], which
    /// has nothing over the picture at all.
    #[must_use]
    pub const fn caption(self) -> &'static str {
        match self {
            Self::Streaming => "",
            Self::StartingDevice => "Starting the device…",
            Self::StartingMirror => "Starting the mirror…",
            Self::Stalled => "No video from this device.",
        }
    }
}

/// The eight things the stage's toolbar can ask of a device.
///
/// A row IDENTITY on both halves — `SwiftUI`'s `ForEach(_:id:)` and the `AppKit` half's plate table
/// both key on the action rather than on the whole verb, so that a help string changing cannot
/// rebuild a control the pointer is inside.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum StageAction {
    /// `BACK_OR_SCREEN_ON` rather than a bare `KEYCODE_BACK`: on a sleeping device the same press
    /// wakes it, which is what the hardware key does and what anyone pressing it means.
    Back = 0,
    /// `KEYCODE_HOME`.
    Home = 1,
    /// `KEYCODE_APP_SWITCH`.
    Recents = 2,
    /// ONE rotate, not a pair. `scrcpy`'s `ROTATE_DEVICE` is a toggle between the device's natural
    /// orientation and the other one — there is no left and right to offer.
    Rotate = 3,
    /// 250 ms and ~300 KB, which is why it is a press rather than a poll.
    Capture = 4,
    /// The clipboard hop, ONE WAY. The panel can PUSH the client's clipboard to the device and
    /// deliberately cannot pull the device's back — a `GET_CLIPBOARD` makes the device write a
    /// reply into the byte stream this panel is decoding as video.
    PasteClipboard = 5,
    /// The DEVICE's own backlight, not the mirror's.
    DisplayPower = 6,
    /// The logcat drawer.
    Console = 7,
}

impl StageAction {
    /// The byte the C door answers with.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// One control on the stage's toolbar: what it DOES, what it looks like, and what the pointer is
/// told.
///
/// A verb rather than a closure because the two renderers build their plates differently and must
/// not each decide which glyph means Recents.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StageVerb {
    /// What the plate asks of the device.
    pub action: StageAction,
    /// The SF Symbol name at rest.
    pub symbol: &'static str,
    /// The tooltip at rest.
    pub help: &'static str,
    /// The glyph while the thing this verb turns on is ON — the same name as [`Self::symbol`] for
    /// the six verbs that do not latch, so a renderer needs no presence flag to draw one.
    pub latched_symbol: &'static str,
    /// The sentence while the thing this verb turns on is ON.
    pub latched_help: &'static str,
}

impl StageVerb {
    const fn plain(action: StageAction, symbol: &'static str, help: &'static str) -> Self {
        Self {
            action,
            symbol,
            help,
            latched_symbol: symbol,
            latched_help: help,
        }
    }
}

/// Android's three navigation keys, in the platform's own order — Back, Home, Recents, left to
/// right, which is where a device with on-screen keys draws them.
///
/// They are a tray of their own because on a gesture-navigation device they have NO on-screen
/// target to press and are otherwise unreachable from a mirror. Everything a finger can already do
/// — pulling the shade down, swiping between apps — is deliberately absent from every tray:
/// `scrcpy` injects real touch events, so those gestures work on the frame itself, and a plate that
/// duplicates a gesture is a plate that can be pressed by mistake.
pub const NAVIGATION_TRAY: [StageVerb; 3] = [
    StageVerb::plain(StageAction::Back, "chevron.backward", "Back"),
    StageVerb::plain(StageAction::Home, "circle", "Home"),
    StageVerb::plain(StageAction::Recents, "square.on.square", "Recent Apps"),
];

/// The second tray: the host-side and protocol-side settings, which have no gesture at all.
pub const ACTION_TRAY: [StageVerb; 4] = [
    StageVerb::plain(StageAction::Rotate, "rotate.right", "Rotate"),
    StageVerb::plain(StageAction::Capture, "camera.viewfinder", "Copy Screenshot"),
    // Not "the Mac's clipboard", which is what this said while there was one renderer: the surface
    // draws on a phone too, and a help string that names the wrong machine is the cheapest possible
    // drift.
    StageVerb::plain(
        StageAction::PasteClipboard,
        "document.on.clipboard",
        "Paste the clipboard into the device",
    ),
    // A phone on a desk lighting up the room while somebody mirrors it is a real annoyance, and the
    // stream is unaffected.
    StageVerb {
        action: StageAction::DisplayPower,
        symbol: "lightbulb",
        help: "Turn the device's screen off",
        latched_symbol: "lightbulb.slash",
        latched_help: "Turn the device's screen back on",
    },
];

/// The console plate, deliberately OFF the trays.
///
/// It LATCHES, and a latched plate is drawn as a lit key, which reads as lit only against the
/// panel's own tone. Sitting it on a tray would put a lit key inside a lit tray and cost exactly
/// the signal it exists to carry. Its glyph does not change across the latch, for the same reason
/// the simulator console's Follow plate keeps one: the lit state already says it.
pub const CONSOLE_VERB: StageVerb = StageVerb {
    action: StageAction::Console,
    symbol: "list.bullet.rectangle",
    help: "Show logcat",
    latched_symbol: "list.bullet.rectangle",
    latched_help: "Hide logcat",
};

/// How long the model may be loading before the veil admits it, in milliseconds.
///
/// 600 rather than the simulator stage's 400, and measured: a warm emulator's first keyframe
/// arrives 0.83 s after the request (2026-08-04), because the host has to push the server jar,
/// start `app_process` and wait for the device's encoder. So the veil DOES appear on an ordinary
/// selection here — unlike the simulator's 0.09 s case, where any delay at all would have made it a
/// flash. What the delay still buys is the second selection: a device opened, left and reopened
/// while the panel is warm comes back faster than this, and flashing grey over it would be the
/// failure state drawn onto the ordinary case.
pub const VEIL_DELAY_MS: u32 = 600;

/// 9:19.5 — the proportions of essentially every current Android phone, and the right guess for a
/// device that has not said.
pub const FALLBACK_ASPECT: f64 = 9.0 / 19.5;

/// What the panel says when the paste verb finds nothing to paste. A report rather than a silent
/// no-op, because pressing a plate and getting nothing at all reads as a broken button.
pub const EMPTY_CLIPBOARD_REPORT: &str = "The clipboard has no text.";

/// The device list's search field.
pub const SEARCH_PLACEHOLDER: &str = "Search devices";

/// What the list draws in place of rows when the HOST has none — distinct from the filtered-out
/// sentence, because they are different failures and the second one is actionable.
pub const NO_DEVICES: &str = "No Android devices or emulators on the host.";

/// The header's way back to the list.
pub const BACK_HELP: &str = "All Devices";

/// The stage's one TEXT button.
pub const RETRY_TITLE: &str = "Try Again";

/// The drawer's caps title. `Logcat`, not "Console": the panel carries the tool's own name because
/// what it shows is the tool's own output, filter spec and all.
pub const CONSOLE_TITLE: &str = "Logcat";

/// The console filter field.
pub const CONSOLE_FILTER_PLACEHOLDER: &str = "Filter";

/// The console's priority picker.
pub const CONSOLE_LEVEL_HELP: &str = "Minimum priority — changing it restarts logcat";

/// The console's clear plate.
pub const CONSOLE_CLEAR_HELP: &str = "Clear Console";

/// The console's dismiss plate.
pub const CONSOLE_HIDE_HELP: &str = "Hide Console";

/// The console's Follow plate, whose glyph does not change across its latch.
pub const CONSOLE_FOLLOW_SYMBOL: &str = "arrow.down.to.line";

/// The console's clear plate.
pub const CONSOLE_CLEAR_SYMBOL: &str = "trash";

/// The console's dismiss plate.
pub const CONSOLE_HIDE_SYMBOL: &str = "xmark";

/// A log row's own Copy verb.
pub const LOG_COPY_LINE: &str = "Copy Line";

/// The whole console's Copy verb.
pub const LOG_COPY_CONSOLE: &str = "Copy Console";

/// One entry of a log row's context menu.
///
/// `FilterByTag` carries no text here for the reason the device menu's copy verbs do not: the tag
/// is the caller's own row. What it DOES carry, uniquely, is a title that names the tag — see
/// [`filter_by_tag`], which is the one log verb whose words are not a constant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum LogVerb {
    /// This row.
    CopyLine = 0,
    /// Every row.
    CopyConsole = 1,
    /// The one filter action worth a slot: a tag is what somebody actually wants to isolate, and
    /// typing it into the field is the step this removes.
    FilterByTag = 2,
}

impl LogVerb {
    /// The byte the C door answers with.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// A log row's menu. The tag item appears only where there IS a tag.
#[must_use]
pub fn log_menu(has_name: bool) -> Vec<LogVerb> {
    let mut verbs = vec![LogVerb::CopyLine, LogVerb::CopyConsole];
    if has_name {
        verbs.push(LogVerb::FilterByTag);
    }
    verbs
}

/// What the tag filter item is called. "Filter by `ActivityManager`" is the whole reason the item
/// is worth a menu slot.
#[must_use]
pub fn filter_by_tag(tag: &str) -> String {
    format!("Filter by {tag}")
}

/// The Follow plate's tooltip, which is the one place the latch is spelled out.
#[must_use]
pub const fn console_follow_help(is_following: bool) -> &'static str {
    if is_following {
        "Following new output"
    } else {
        "Follow new output"
    }
}

/// The stream is over waiting and there is still no video.
///
/// Distinct from "loading" by the model's own deadline and from "streaming" by whether a frame has
/// decoded, which is what makes the stage always resolve into one definite thing.
#[must_use]
pub const fn is_stalled(has_selection: bool, is_awaiting_stream: bool, has_video: bool) -> bool {
    has_selection && !is_awaiting_stream && !has_video
}

/// What stands over the picture, from the veil's own (delayed) state and the model's.
///
/// ⚠️ THE ORDER IS THE RULE. Loading outranks stalled: the two are reachable in the same frame
/// while a reattempt is in flight, and answering "no video" over a mirror that is being reopened
/// puts a failure on the ordinary case. `shows_loading` is the VIEW's delayed mirror of the model's
/// awaiting flag rather than the flag itself — see [`VEIL_DELAY_MS`].
///
/// `device_is_running` is `None` when there is no selected device to ask, and then the wait is the
/// mirror's by definition.
#[must_use]
#[expect(
    clippy::fn_params_excessive_bools,
    reason = "the four flags ARE the rule: each is an independent fact about the frame, and               \
              folding them into a struct would hide the ORDER this function exists to fix"
)]
pub const fn stage(
    shows_loading: bool,
    has_selection: bool,
    is_awaiting_stream: bool,
    has_video: bool,
    device_is_running: Option<bool>,
) -> StageReading {
    if shows_loading {
        return match device_is_running {
            Some(false) => StageReading::StartingDevice,
            _ => StageReading::StartingMirror,
        };
    }
    if is_stalled(has_selection, is_awaiting_stream, has_video) {
        // A stalled mirror is the one failure here that a second attempt genuinely fixes — the jar
        // is pushed, the server is up, the encoder never started — so the stage offers the retry
        // rather than making someone go back to the list and pick the same row again.
        StageReading::Stalled
    } else {
        StageReading::Streaming
    }
}

/// `adb`'s word for a device that is running AND reachable.
///
/// A device that is `unauthorized` is attached but will refuse every shell, so it must not offer a
/// mirror button that can only fail.
const READY_STATE: &str = "device";

/// Running and reachable, from the two fields that decide it rather than from a caller's summary.
///
/// The pair below and [`can_enter`] take `has_serial` and `state` rather than an `is_running` a
/// caller computed, because a rule spelled half here and half at the call site is the drift this
/// module exists to end.
#[must_use]
pub fn is_running(has_serial: bool, state: &str) -> bool {
    has_serial && state == READY_STATE
}

/// Attached but not usable — the state that needs an explanation rather than an action. The user
/// has to accept a debugging prompt on the device itself; nothing this panel sends can do it.
#[must_use]
pub fn is_attached_but_unusable(has_serial: bool, state: &str) -> bool {
    has_serial && state != READY_STATE
}

/// ⚠️ WHETHER A TAP OPENS THE MIRROR AT ALL, and the one predicate in this panel that was already
/// spelled twice before a second renderer existed.
///
/// A BOOTING emulator may be entered — the stage knows how to wait for a device, and "click, then
/// watch it come up" is strictly better than "watch the list until clicking works". A physical
/// device that is attached-but-unusable may NOT: its fix is an authorization dialog on its own
/// screen, which is not something waiting can do, so the card stays un-clickable rather than
/// opening onto a wait that can never end.
#[must_use]
pub fn can_enter(has_serial: bool, state: &str, is_emulator: bool) -> bool {
    is_running(has_serial, state) || is_emulator && has_serial
}

/// The screen's physical proportions, when known.
///
/// Used to draw the frame before the first video packet names a size — otherwise a freshly-opened
/// device is a blank rectangle of the wrong shape for as long as the encoder takes to start.
#[must_use]
#[expect(
    clippy::cast_precision_loss,
    reason = "a screen dimension is four digits; f64 is exact to 2^53"
)]
pub fn aspect_ratio(width: i64, height: i64) -> Option<f64> {
    (width > 0 && height > 0).then(|| width as f64 / height as f64)
}

/// The card's screen box at a fixed art HEIGHT, from the device's own aspect ratio, so what varies
/// between two cards is the shape and nothing else.
///
/// Clamped so an unreported or absurd ratio cannot produce a box wider than the card. The three
/// lengths are the CALLER's — they are design tokens, and the design floor sits above the panel —
/// which leaves exactly the arithmetic here: the fallback, the multiply, and the order of the
/// clamp. That order is the part worth sharing.
#[must_use]
pub fn art_width(ratio: Option<f64>, art: f64, floor: f64, cap: f64) -> f64 {
    let width = art * ratio.unwrap_or(FALLBACK_ASPECT);
    // `f64::max`/`min`, never a `<` ternary: the IEEE pair propagates a NaN operand's PARTNER,
    // where a comparison hands back whichever side the test happened to fall on and lets one NaN
    // upstream survive as a NaN width.
    width.max(floor).min(cap)
}

/// The device's state as a sentence, with the one reading `adb`'s word alone would get wrong.
///
/// An EMULATOR that is `offline` is almost always a boot in progress — the serial registers within
/// seconds of launch and the guest's `adbd` answers ~21 s later (measured 2026-08-07) — and "Not
/// responding" over a card that is doing exactly what was asked reads as a fault.
#[must_use]
pub fn explain(state: &str, is_emulator: bool) -> &str {
    if is_emulator && state == "offline" {
        return "Starting up…";
    }
    explain_state(state)
}

/// `adb`'s state word as a sentence.
///
/// The words are `adb`'s own and mean nothing to most readers — `unauthorized` in particular reads
/// as a permissions error on the HOST, when what it means is that a dialog is waiting on the
/// device's screen. A word this build has not seen is answered with itself, never with a blank.
#[must_use]
pub fn explain_state(state: &str) -> &str {
    match state {
        "unauthorized" => "Waiting for you to allow debugging on the device",
        "offline" => "Not responding",
        "authorizing" => "Authorizing…",
        "connecting" => "Connecting…",
        "recovery" => "In recovery mode",
        "sideload" => "In sideload mode",
        "bootloader" => "In the bootloader",
        "device" => "Ready",
        other => other,
    }
}

/// One entry of a device's context menu.
///
/// `Separator` is a case rather than an absent row because the rule is about the LINE, not about a
/// missing verb.
///
/// The two copy verbs are KINDS here and carry no text: the serial and the name are the caller's
/// own row, and handing one back across a C ABI would be a copy made only to be compared with the
/// one it came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum DeviceMenuEntry {
    /// The rule between what acts on the DEVICE and what copies a fact about it.
    Separator = 0,
    /// Open the mirror.
    OpenScreen = 1,
    /// A 250 ms round trip for a PNG.
    CopyScreenshot = 2,
    /// Emulators only — a physical device is somebody's phone.
    ShutDown = 3,
    /// Boot the AVD this row names.
    Start = 4,
    /// `adb -s`, an install target, a bug report — every other tool wants this one.
    CopySerial = 5,
    /// The device's own name.
    CopyName = 6,
}

impl DeviceMenuEntry {
    /// The byte the C door answers with.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// What the item is called, or the empty string for [`Self::Separator`], which has no words.
    #[must_use]
    pub const fn title(self) -> &'static str {
        match self {
            Self::Separator => "",
            Self::OpenScreen => "Open Screen",
            Self::CopyScreenshot => "Copy Screenshot",
            Self::ShutDown => "Shut Down",
            Self::Start => "Start",
            Self::CopySerial => "Copy Serial",
            Self::CopyName => "Copy Name",
        }
    }
}

/// A device's context menu, in order.
///
/// A TABLE rather than a pair of `if` blocks per renderer, for the reason at the head of this
/// module: one half growing a verb the other has not got is silent until somebody compares two
/// screens. The separator is part of the table because where the line falls is the same kind of
/// decision as which verbs are above it.
#[must_use]
pub fn device_menu(
    has_serial: bool,
    state: &str,
    is_emulator: bool,
    has_avd_name: bool,
) -> Vec<DeviceMenuEntry> {
    let mut entries = Vec::with_capacity(5);
    if is_running(has_serial, state) {
        entries.push(DeviceMenuEntry::OpenScreen);
        entries.push(DeviceMenuEntry::CopyScreenshot);
        if is_emulator {
            entries.push(DeviceMenuEntry::ShutDown);
        }
    } else if has_avd_name {
        entries.push(DeviceMenuEntry::Start);
    }
    entries.push(DeviceMenuEntry::Separator);
    if has_serial {
        entries.push(DeviceMenuEntry::CopySerial);
    }
    entries.push(DeviceMenuEntry::CopyName);
    entries
}

/// One MEASURED fact under the device's name.
///
/// `copies` is the WHOLE value and `text` may abbreviate it; the reason a short form is safe to
/// draw at all is that the full one is one right-click away.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fact {
    /// Names the fact, in title case — the tooltip, the Copy verb, and the row's identity within
    /// one line, which is what lets a line animate a fact in or out without reshuffling.
    pub label: &'static str,
    /// What is drawn.
    pub text: String,
    /// What Copy hands over.
    pub copies: String,
    /// The rung the value sits on.
    pub ink: Ink,
    /// Measured facts render in the instrument face; named ones render in the system face, so the
    /// line itself tells you which of its parts were read off a machine.
    pub is_measured: bool,
    /// Whether the grey label is DRAWN ahead of the value. False for a fact whose presence is
    /// already the news.
    pub shows_label: bool,
}

/// What a fact's own Copy verb is called.
///
/// The LABEL names the fact, so the item reads "Copy Density" rather than "Copy" — which is the
/// whole reason a fact carries a label at all.
#[must_use]
pub fn copy_title(label: &str) -> String {
    format!("Copy {label}")
}

/// The facts under the device's name, in order.
///
/// Ordered by how often each is the thing being checked: the screen, then the density and ABI where
/// they are known, then the SERIAL — which is what every other tool wants pasted into it.
///
/// THE STREAM'S SIZE IS DELIBERATELY ABSENT. The panel mirrors at a cap, so the encoded size is a
/// fact about this panel's REQUEST and not about the device; printing both would be two resolutions
/// in one line, one of them wrong for every purpose anyone would use it for.
///
/// A dimension of `0` or less is "not reported", which is the same non-answer the JSON decode makes
/// of a missing key.
#[must_use]
pub fn facts(width: i64, height: i64, density: i64, abi: &str, serial: &str) -> Vec<Fact> {
    let mut facts = Vec::with_capacity(4);
    if width > 0 && height > 0 {
        facts.push(Fact {
            label: "Screen",
            text: format!("{width} × {height}"),
            copies: format!("{width} × {height}"),
            ink: Ink::Secondary,
            is_measured: true,
            shows_label: true,
        });
    }
    if density > 0 {
        // `420 dpi` rather than the bucket's name (`xxhdpi`): the number is what a layout is
        // reasoned about in, and the bucket is derivable from it while the reverse is not.
        facts.push(Fact {
            label: "Density",
            text: format!("{density} dpi"),
            copies: format!("{density} dpi"),
            ink: Ink::Tertiary,
            is_measured: true,
            shows_label: true,
        });
    }
    if !abi.is_empty() {
        // Unlabelled: `arm64-v8a` names itself, and it is here because a native build that refuses
        // to install is almost always this line disagreeing with the APK.
        facts.push(Fact {
            label: "ABI",
            text: abi.to_owned(),
            copies: abi.to_owned(),
            ink: Ink::Tertiary,
            is_measured: false,
            shows_label: false,
        });
    }
    if !serial.is_empty() {
        facts.push(Fact {
            label: "Serial",
            text: serial.to_owned(),
            copies: serial.to_owned(),
            ink: Ink::Tertiary,
            is_measured: true,
            shows_label: true,
        });
    }
    facts
}

/// The one-line fact under the headline: what this device IS, in the terms someone picking one out
/// of a list needs.
///
/// Assembled from whatever is known rather than templated, so a row missing a field reads as a
/// shorter sentence instead of one with a hole in it. An empty string, or an `api_level` of `0` or
/// less, is a field the host did not report.
#[must_use]
pub fn summary(
    release: &str,
    api_level: i64,
    width: i64,
    height: i64,
    is_emulator: bool,
    manufacturer: &str,
    model: &str,
) -> String {
    let mut parts: Vec<String> = Vec::with_capacity(3);
    if release.is_empty() {
        if api_level > 0 {
            parts.push(format!("API {api_level}"));
        }
    } else {
        parts.push(format!("Android {release}"));
    }
    if width > 0 && height > 0 {
        parts.push(format!("{width}×{height}"));
    }
    if !is_emulator && !manufacturer.is_empty() && !model.is_empty() && !model.starts_with(manufacturer) {
        parts.push(manufacturer.to_owned());
    }
    parts.join(" · ")
}

/// The heading over the devices `adb` has handed a transport id.
///
/// ATTACHED, not "Running": a device on the end of a cable is not something this panel started, and
/// half the rows under it are physical handsets somebody plugged in. The simulator panel's
/// [`crate::simulator::RUNNING_TITLE`] says the other word for the other reason.
pub const ATTACHED_TITLE: &str = "Attached";

/// What a device calls its platform version, or `None` when it has said nothing about one.
///
/// The release string is the one to print when there is one — `Android 15` is the version a person
/// reads on the device itself — and the API level is the fallback, because a device that reported
/// only `ro.build.version.sdk` has still told us more than nothing. An EMPTY release is not a
/// release: `adb` answers a blank property rather than omitting it, and `Android ` with a dangling
/// space is the panel printing a fact it does not have.
///
/// This is the label [`sections`](crate::sections) lifts into a heading, which is why it has one
/// spelling: a header printing a version the grouping never compared is the drift the fold exists
/// to make impossible.
#[must_use]
pub fn version_label(release: Option<&str>, api_level: Option<i64>) -> Option<String> {
    if let Some(release) = release
        && !release.is_empty()
    {
        return Some(format!("Android {release}"));
    }
    api_level.map(|level| format!("API {level}"))
}

/// The trailing text on a row that is not running: the platform version where the heading has not
/// already said it, and the SCREEN otherwise. Empty for a row with neither.
///
/// The screen is the fact the simulator list could not print — an AVD's `config.ini` is its
/// definition, not a lookalike's — and it is what tells two similarly-named AVDs apart when they
/// share a system image.
#[must_use]
pub fn subtitle(version_label: &str, shows_version: bool, width: i64, height: i64) -> String {
    if shows_version && !version_label.is_empty() {
        return version_label.to_owned();
    }
    if width > 0 && height > 0 {
        return format!("{width} × {height}");
    }
    String::new()
}

/// The empty list's second sentence — the filter's doing, not the host's.
#[must_use]
pub fn no_matches(query: &str) -> String {
    format!("No devices match “{query}”.")
}

/// The one verb an idle row offers, as a sentence.
#[must_use]
pub fn start_help(name: &str) -> String {
    format!("Start {name}")
}

/// The card's stop plate.
///
/// A physical device is somebody's phone: this panel mirrors it and does not power it off, so the
/// plate is simply ABSENT rather than present-and-refusing — which is [`is_stoppable`]'s job.
#[must_use]
pub fn shut_down_help(name: &str) -> String {
    format!("Shut down {name}")
}

/// A section heading's stop-all control.
#[must_use]
pub fn shut_down_all_help(count: usize) -> String {
    format!("Shut down all {count} running emulators")
}

/// Whether a section heading's stop-all control may act on this device.
///
/// Emulators only: a physical device is not something this panel may power off, so a control that
/// named every attached device would promise a verb it refuses for half of them.
#[must_use]
pub fn is_stoppable(has_serial: bool, state: &str, is_emulator: bool) -> bool {
    is_running(has_serial, state) && is_emulator
}

/// The card's tooltip: a verb for a device that can be opened, and its STATE for one that cannot.
#[must_use]
pub fn card_help(name: &str, has_serial: bool, state: &str, is_emulator: bool) -> String {
    if is_running(has_serial, state) {
        format!("Open {name}")
    } else {
        format!("{name} — {}", explain(state, is_emulator))
    }
}

/// Three states, three sentences.
///
/// "Nothing here" over a console that never connected is the failure this exists to distinguish —
/// and the order matters: a live filter answers first, because rows exist and the reader is the
/// reason none are showing. `level_title` is the priority picker's own word, lowercased here so the
/// sentence reads as one.
#[must_use]
pub fn console_empty_message(
    has_lines: bool,
    is_log_started: bool,
    level_title: &str,
    filter: &str,
) -> String {
    if has_lines {
        return format!("Nothing matches “{filter}”.");
    }
    if is_log_started {
        format!("Waiting for output at {} priority…", level_title.to_lowercase())
    } else {
        "Connecting to logcat…".to_owned()
    }
}

/// The tag's ink. COLOUR ONLY FOR A FAILURE.
///
/// Everything healthy is a grey, and the only difference between the greys is how far back they
/// sit. A warning is a grey too: `logcat` at warning level on an ordinary Android device is dozens
/// of lines a minute of framework noise, so tinting it would spend the alarm colour on the state of
/// nothing being wrong.
///
/// It does not share the simulator console's answer, for a reason the twin does not have:
/// [`Severity::Plain`] recedes HERE because it holds `logcat`'s V and D, and does NOT recede over
/// there because `Df` is that grammar's ordinary default.
#[must_use]
pub const fn log_ink(severity: Severity) -> Ink {
    match severity {
        Severity::Fatal | Severity::Error => Ink::Err,
        Severity::Warning | Severity::Info => Ink::Secondary,
        // `logcat`'s V and D both land in `Plain`, and both should recede. `Debug` is the unified
        // log's bucket and `logcat` never answers it — it is here so this match stays exhaustive
        // over one shared severity scale rather than over an alphabet only Android has.
        Severity::Debug | Severity::Plain => Ink::Tertiary,
    }
}

/// Which kind of Android device a row is, and so which silhouette and heading it gets.
///
/// The SOURCE is better here than on the simulator side. That panel has to infer the family from
/// the product name because `/simulators.json` carries no device-type field; Android states it
/// outright — `ro.build.characteristics` on a running device, `tag.id` on an AVD on disk — so
/// [`device_kind`] is a lookup with the name only as a fallback.
///
/// The discriminant IS the rank, for the reason [`crate::simulator::DeviceKind`] states.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum DeviceKind {
    /// The fallback, and the commonest answer.
    Phone = 0,
    /// Drawn LANDSCAPE, like the simulator panel's iPad.
    Tablet = 1,
    /// Wear OS.
    Watch = 2,
    /// Android TV.
    Tv = 3,
    /// Android Automotive.
    Automotive = 4,
}

impl DeviceKind {
    /// The byte the C door answers with, which is also the heading's rank.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// The kind a byte names, or [`DeviceKind::Phone`] for one no build of this crate wrote.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Self {
        match byte {
            1 => Self::Tablet,
            2 => Self::Watch,
            3 => Self::Tv,
            4 => Self::Automotive,
            _ => Self::Phone,
        }
    }

    /// The silhouette's SF Symbol NAME.
    ///
    /// THE SAME GLYPH SET AS THE SIMULATOR PANEL, deliberately. These marks say PHONE, TABLET,
    /// WATCH — a shape, not a brand — and drawing an Android tablet with a different rectangle than
    /// an iPad would claim a distinction the reader does not need to make: the two panels are
    /// different tabs, and the row already carries the device's name and its Android version.
    ///
    /// The tablet is drawn landscape for the reason [`crate::simulator::DeviceKind::symbol`]
    /// records for the iPad: at 13 points tall, aspect is the only channel left and turning the
    /// rectangle is what changes the silhouette.
    #[must_use]
    pub const fn symbol(self) -> &'static str {
        match self {
            Self::Phone => "iphone",
            Self::Tablet => "ipad.landscape",
            Self::Watch => "applewatch",
            Self::Tv => "appletv",
            Self::Automotive => "car.fill",
        }
    }

    /// The heading a group of these sits under.
    #[must_use]
    pub const fn group_title(self) -> &'static str {
        match self {
            Self::Phone => "Phone",
            Self::Tablet => "Tablet",
            Self::Watch => "Wear",
            Self::Tv => "TV",
            Self::Automotive => "Automotive",
        }
    }
}

/// Every kind in rank order — what the ONE table delivery iterates.
pub const DEVICE_KINDS: [DeviceKind; 5] = [
    DeviceKind::Phone,
    DeviceKind::Tablet,
    DeviceKind::Watch,
    DeviceKind::Tv,
    DeviceKind::Automotive,
];

/// A tablet's shortest side, in dp. Android's own resource qualifier for a tablet layout is
/// `sw600dp`, so this is the platform's line rather than one invented here.
pub const TABLET_SHORTEST_WIDTH_DP: i64 = 600;

/// `smallestScreenWidthDp` — the shorter side in density-independent pixels, or `None` when the
/// device did not report a whole screen.
///
/// `density` is Android's DPI bucket, where 160 is the definition of 1dp = 1px. A zero on any axis
/// is not a small screen, it is a device that answered nothing, and dividing by it would be the one
/// arithmetic fault this whole function can have.
#[must_use]
#[expect(
    clippy::integer_division,
    reason = "`smallestScreenWidthDp` is a whole number of dp on the platform's own side — Android \
              truncates it and the layout qualifier it feeds compares integers, so rounding here would put \
              this panel's grouping half a dp away from the device's own answer"
)]
pub const fn shortest_width_dp(width: i64, height: i64, density: i64) -> Option<i64> {
    if width <= 0 || height <= 0 || density <= 0 {
        return None;
    }
    let shortest = if width < height { width } else { height };
    // Saturating rather than wrapping: a hand-edited `config.ini` with an absurd `hw.lcd.width`
    // must not come back as a small number that reads like a phone.
    Some(shortest.saturating_mul(160) / density)
}

/// The family for a device, from the platform's hint first and its geometry second.
///
/// ## The hint is read as TOKENS, and that is the trap the whole function turns on
///
/// `ro.build.characteristics` is a comma-separated list whose commonest value on an emulator is
/// `emulator,nosdcard` — and `nosdcard` CONTAINS `car`. A substring test therefore reads every
/// ordinary emulator as an automotive head unit. The hint is split on its separators and each token
/// matched on its own, which is also why this cannot be a plain dictionary: the platform's words do
/// not partition cleanly. `emulator,nosdcard` says how a device RUNS and not what it is, and a
/// tablet AVD's `tag.id` is `google_apis` like every other.
///
/// ## Then the name, then the size
///
/// The name is checked before the size because a device profile that says so is more certain than a
/// threshold — a `Pixel_Tablet` AVD created at an unusual density would otherwise be classified by
/// arithmetic when it had already said what it was.
///
/// The geometry test is what catches the case the hint cannot: every emulator, phone or tablet,
/// reports `emulator,nosdcard`. `config.ini` gives an un-booted AVD exact `hw.lcd.*`, so the dp
/// conversion is available on a row that has never run — which is the whole reason the panel can
/// group a cold device list correctly at all.
#[must_use]
pub fn device_kind(hint: &str, name: &str, width: i64, height: i64, density: i64) -> DeviceKind {
    let folded_hint = hint.to_lowercase();
    // Split on anything that is not a letter or a digit, which is the Swift this replaces spelled
    // one language over. It cut on `Character`s and this cuts on scalars; every value that reaches
    // here is `ro.build.characteristics` or a `tag.id`, both ASCII by the platform's own grammar,
    // so the two agree on every input and the difference is unreachable rather than tolerated.
    let says =
        |predicate: &dyn Fn(&str) -> bool| folded_hint.split(|c: char| !c.is_alphanumeric()).any(predicate);
    if says(&|token| token.contains("watch") || token.contains("wear")) {
        return DeviceKind::Watch;
    }
    if says(&|token| token.contains("automotive") || token == "car") {
        return DeviceKind::Automotive;
    }
    if says(&|token| token == "tv" || token == "atv" || token.contains("television")) {
        return DeviceKind::Tv;
    }
    if says(&|token| token.contains("tablet")) {
        return DeviceKind::Tablet;
    }

    let folded_name = name.to_lowercase();
    if folded_name.contains("wear") || folded_name.contains("watch") {
        return DeviceKind::Watch;
    }
    if folded_name.contains("tv") {
        return DeviceKind::Tv;
    }
    if folded_name.contains("tablet") || folded_name.contains("fold") {
        return DeviceKind::Tablet;
    }

    match shortest_width_dp(width, height, density) {
        Some(shortest) if shortest >= TABLET_SHORTEST_WIDTH_DP => DeviceKind::Tablet,
        _ => DeviceKind::Phone,
    }
}

#[cfg(test)]
mod tests {
    use slopdesk_devicelog::Severity;

    use super::{
        ACTION_TRAY, CONSOLE_VERB, DeviceKind, DeviceMenuEntry, FALLBACK_ASPECT, Ink, NAVIGATION_TRAY,
        StageAction, StageReading, art_width, aspect_ratio, can_enter, card_help, console_empty_message,
        copy_title, device_kind, device_menu, explain, explain_state, facts, is_attached_but_unusable,
        is_running, is_stoppable, log_ink, stage, subtitle, summary,
    };

    #[test]
    fn a_booting_emulator_may_be_entered_and_an_unauthorized_phone_may_not() {
        // The emulator is `offline` — still coming up — and the stage knows how to wait for it.
        assert!(can_enter(true, "offline", true));
        // A physical device waiting on its own authorization dialog cannot be waited out.
        assert!(!can_enter(true, "unauthorized", false));
        // …and neither can an AVD that has not registered a serial yet.
        assert!(!can_enter(false, "offline", true));
        // Ready is ready, emulator or not.
        assert!(can_enter(true, "device", false));
    }

    #[test]
    fn running_and_attached_but_unusable_partition_an_attached_device() {
        assert!(is_running(true, "device"));
        assert!(!is_attached_but_unusable(true, "device"));
        assert!(!is_running(true, "unauthorized"));
        assert!(is_attached_but_unusable(true, "unauthorized"));
        // No serial is neither: the device is not attached at all.
        assert!(!is_running(false, "device"));
        assert!(!is_attached_but_unusable(false, "device"));
    }

    #[test]
    fn loading_outranks_stalled_and_names_which_wait_it_is() {
        // A reattempt in flight: both readings are reachable in this frame, and loading wins.
        assert_eq!(
            stage(true, true, false, false, Some(true)),
            StageReading::StartingMirror
        );
        // The device itself is still coming up, which is the tens-of-seconds wait.
        assert_eq!(
            stage(true, true, true, false, Some(false)),
            StageReading::StartingDevice
        );
        // Nothing selected to ask: the wait is the mirror's by definition.
        assert_eq!(
            stage(true, false, true, false, None),
            StageReading::StartingMirror
        );
        assert_eq!(
            stage(false, true, false, false, Some(true)),
            StageReading::Stalled
        );
        assert_eq!(
            stage(false, true, false, true, Some(true)),
            StageReading::Streaming
        );
        // No selection is never a stall — there is nothing that failed.
        assert_eq!(stage(false, false, false, false, None), StageReading::Streaming);
    }

    #[test]
    fn only_the_streaming_reading_has_nothing_to_say() {
        assert!(StageReading::Streaming.caption().is_empty());
        for reading in [
            StageReading::StartingDevice,
            StageReading::StartingMirror,
            StageReading::Stalled,
        ] {
            assert!(!reading.caption().is_empty());
        }
    }

    #[test]
    fn the_menu_grows_and_shrinks_by_what_the_device_can_do() {
        assert_eq!(device_menu(true, "device", true, true), vec![
            DeviceMenuEntry::OpenScreen,
            DeviceMenuEntry::CopyScreenshot,
            DeviceMenuEntry::ShutDown,
            DeviceMenuEntry::Separator,
            DeviceMenuEntry::CopySerial,
            DeviceMenuEntry::CopyName,
        ]);
        // A physical device is somebody's phone: no stop verb.
        assert_eq!(device_menu(true, "device", false, false), vec![
            DeviceMenuEntry::OpenScreen,
            DeviceMenuEntry::CopyScreenshot,
            DeviceMenuEntry::Separator,
            DeviceMenuEntry::CopySerial,
            DeviceMenuEntry::CopyName,
        ]);
        // An AVD on disk: one verb, and no serial to copy.
        assert_eq!(device_menu(false, "", true, true), vec![
            DeviceMenuEntry::Start,
            DeviceMenuEntry::Separator,
            DeviceMenuEntry::CopyName,
        ]);
        // Attached, unusable, not an AVD: nothing acts on it, and the line still falls.
        assert_eq!(device_menu(true, "unauthorized", false, false), vec![
            DeviceMenuEntry::Separator,
            DeviceMenuEntry::CopySerial,
            DeviceMenuEntry::CopyName,
        ]);
    }

    #[test]
    fn the_separator_is_the_one_entry_with_no_words() {
        assert!(DeviceMenuEntry::Separator.title().is_empty());
        for entry in [
            DeviceMenuEntry::OpenScreen,
            DeviceMenuEntry::CopyScreenshot,
            DeviceMenuEntry::ShutDown,
            DeviceMenuEntry::Start,
            DeviceMenuEntry::CopySerial,
            DeviceMenuEntry::CopyName,
        ] {
            assert!(!entry.title().is_empty());
        }
    }

    #[test]
    fn an_offline_emulator_is_starting_up_and_an_offline_phone_is_not() {
        assert_eq!(explain("offline", true), "Starting up…");
        assert_eq!(explain("offline", false), "Not responding");
        // A word this build has not seen answers with itself rather than with a blank.
        assert_eq!(explain_state("teleporting"), "teleporting");
        assert_eq!(
            explain_state("unauthorized"),
            "Waiting for you to allow debugging on the device"
        );
    }

    #[test]
    fn the_card_offers_a_verb_when_it_can_and_a_reason_when_it_cannot() {
        assert_eq!(card_help("Pixel 9", true, "device", false), "Open Pixel 9");
        assert_eq!(
            card_help("Pixel 9", true, "unauthorized", false),
            "Pixel 9 — Waiting for you to allow debugging on the device"
        );
    }

    #[test]
    fn only_a_running_emulator_may_be_stopped_in_bulk() {
        assert!(is_stoppable(true, "device", true));
        assert!(!is_stoppable(true, "device", false));
        assert!(!is_stoppable(true, "offline", true));
    }

    #[test]
    fn an_unreported_ratio_falls_back_and_the_clamp_runs_outward() {
        assert_eq!(aspect_ratio(0, 2400), None);
        assert_eq!(aspect_ratio(1080, 0), None);
        assert!((aspect_ratio(1080, 2160).unwrap_or_default() - 0.5).abs() < f64::EPSILON);
        // No ratio: the fallback, times the art height.
        assert!((art_width(None, 100.0, 0.0, 1000.0) - 100.0 * FALLBACK_ASPECT).abs() < 1e-9);
        // An absurd ratio cannot make a box wider than the card…
        assert!((art_width(Some(9.0), 100.0, 10.0, 60.0) - 60.0).abs() < f64::EPSILON);
        // …and a degenerate one cannot make it thinner than the floor.
        assert!((art_width(Some(0.0), 100.0, 10.0, 60.0) - 10.0).abs() < f64::EPSILON);
        // A NaN ratio takes the floor rather than surviving as a NaN width — the whole reason the
        // clamp is `max` then `min` over IEEE operations.
        assert!((art_width(Some(f64::NAN), 100.0, 10.0, 60.0) - 10.0).abs() < f64::EPSILON);
    }

    #[test]
    fn the_header_prints_only_the_facts_the_host_reported() {
        let full = facts(1080, 2400, 420, "arm64-v8a", "emulator-5554");
        assert_eq!(full.iter().map(|fact| fact.label).collect::<Vec<_>>(), [
            "Screen", "Density", "ABI", "Serial"
        ]);
        assert_eq!(full.first().map(|fact| fact.text.as_str()), Some("1080 × 2400"));
        assert_eq!(full.get(1).map(|fact| fact.text.as_str()), Some("420 dpi"));
        // The ABI names itself, so its label is not drawn.
        assert_eq!(full.get(2).map(|fact| fact.shows_label), Some(false));
        assert!(facts(0, 0, 0, "", "").is_empty());
        assert_eq!(copy_title("Density"), "Copy Density");
    }

    #[test]
    fn a_summary_missing_a_field_is_shorter_rather_than_holed() {
        assert_eq!(
            summary("15", 0, 1080, 2400, false, "Google", "Pixel 9"),
            "Android 15 · 1080×2400 · Google"
        );
        // The API level is the fallback for a release the host did not report.
        assert_eq!(summary("", 35, 0, 0, true, "", ""), "API 35");
        // A model that already names its maker does not repeat it.
        assert_eq!(summary("", 0, 0, 0, false, "Google", "Google Pixel 9"), "");
        assert_eq!(summary("", 0, 0, 0, true, "", ""), "");
    }

    #[test]
    fn a_row_prints_its_version_or_its_screen_and_never_both() {
        assert_eq!(subtitle("Android 15", true, 1080, 2400), "Android 15");
        assert_eq!(subtitle("Android 15", false, 1080, 2400), "1080 × 2400");
        // The heading already said the version and the AVD reported no size.
        assert!(subtitle("Android 15", false, 0, 0).is_empty());
        // No version to print falls through to the screen.
        assert_eq!(subtitle("", true, 1080, 2400), "1080 × 2400");
    }

    #[test]
    fn the_filter_answers_before_the_connection_does() {
        assert_eq!(
            console_empty_message(true, true, "Warn", "boom"),
            "Nothing matches “boom”."
        );
        assert_eq!(
            console_empty_message(false, true, "Warn", ""),
            "Waiting for output at warn priority…"
        );
        assert_eq!(
            console_empty_message(false, false, "Warn", ""),
            "Connecting to logcat…"
        );
    }

    #[test]
    fn a_log_rows_menu_grows_its_tag_item_only_where_there_is_a_tag() {
        assert_eq!(super::log_menu(true), vec![
            super::LogVerb::CopyLine,
            super::LogVerb::CopyConsole,
            super::LogVerb::FilterByTag,
        ]);
        assert_eq!(super::log_menu(false), vec![
            super::LogVerb::CopyLine,
            super::LogVerb::CopyConsole
        ]);
        assert_eq!(
            super::filter_by_tag("ActivityManager"),
            "Filter by ActivityManager"
        );
    }

    #[test]
    fn only_a_fault_spends_the_alarm_colour() {
        assert_eq!(log_ink(Severity::Fatal), Ink::Err);
        assert_eq!(log_ink(Severity::Error), Ink::Err);
        assert_eq!(log_ink(Severity::Warning), Ink::Secondary);
        assert_eq!(log_ink(Severity::Info), Ink::Secondary);
        assert_eq!(log_ink(Severity::Debug), Ink::Tertiary);
        assert_eq!(log_ink(Severity::Plain), Ink::Tertiary);
    }

    #[test]
    fn every_plate_the_panel_draws_names_a_glyph_and_a_sentence() {
        let plates = NAVIGATION_TRAY
            .iter()
            .chain(ACTION_TRAY.iter())
            .chain(core::iter::once(&CONSOLE_VERB));
        for plate in plates {
            assert!(!plate.symbol.is_empty());
            assert!(!plate.help.is_empty());
            assert!(!plate.latched_symbol.is_empty());
            assert!(!plate.latched_help.is_empty());
        }
    }

    #[test]
    fn no_action_appears_on_two_plates() {
        let mut seen: Vec<StageAction> = Vec::new();
        for plate in NAVIGATION_TRAY
            .iter()
            .chain(ACTION_TRAY.iter())
            .chain(core::iter::once(&CONSOLE_VERB))
        {
            assert!(!seen.contains(&plate.action));
            seen.push(plate.action);
        }
        assert_eq!(seen.len(), 8);
    }

    #[test]
    fn the_six_verbs_that_do_not_latch_answer_the_same_glyph_either_way() {
        for plate in NAVIGATION_TRAY.iter().chain(ACTION_TRAY.iter()) {
            if plate.action == StageAction::DisplayPower {
                assert_ne!(plate.symbol, plate.latched_symbol);
            } else {
                assert_eq!(plate.symbol, plate.latched_symbol);
                assert_eq!(plate.help, plate.latched_help);
            }
        }
        // The console plate latches its SENTENCE and keeps its glyph — the lit key already says it.
        assert_eq!(CONSOLE_VERB.symbol, CONSOLE_VERB.latched_symbol);
        assert_ne!(CONSOLE_VERB.help, CONSOLE_VERB.latched_help);
    }

    /// The reason [`super::device_kind`] reads TOKENS: `nosdcard` contains `car`, and
    /// `emulator,nosdcard` is the commonest `ro.build.characteristics` value there is. A substring
    /// test reads every ordinary emulator as an automotive head unit.
    #[test]
    fn an_ordinary_emulator_is_not_an_automotive_head_unit() {
        assert_eq!(
            device_kind("emulator,nosdcard", "Pixel_8", 1080, 2400, 420),
            DeviceKind::Phone,
        );
        // And a real one still resolves, from the token that actually says so.
        assert_eq!(
            device_kind("automotive,emulator", "Automotive_1024p", 1024, 768, 160),
            DeviceKind::Automotive,
        );
        assert_eq!(
            device_kind("nosdcard,car", "Whatever", 0, 0, 0),
            DeviceKind::Automotive,
            "the bare token IS the platform's word for it"
        );
    }

    /// The hint leads, the name breaks the ties it cannot, and the size answers last.
    #[test]
    fn the_hint_leads_the_name_follows_and_the_size_decides_what_is_left() {
        assert_eq!(
            device_kind("watch", "Wear_OS_Round", 454, 454, 320),
            DeviceKind::Watch,
        );
        assert_eq!(
            device_kind("tv", "Television_1080p", 1920, 1080, 320),
            DeviceKind::Tv
        );
        assert_eq!(device_kind("tablet", "Tab", 800, 1280, 213), DeviceKind::Tablet);

        // No usable hint: `google_apis` is what every AVD's `tag.id` says.
        assert_eq!(
            device_kind("google_apis", "Pixel_Tablet", 1600, 2560, 320),
            DeviceKind::Tablet,
            "a profile that names itself outranks the arithmetic"
        );
        assert_eq!(
            device_kind("google_apis", "Pixel_Fold", 2208, 1840, 420),
            DeviceKind::Tablet,
        );

        // Neither hint nor name: `sw600dp` is Android's own line.
        assert_eq!(device_kind("", "AVD_1", 1600, 2560, 320), DeviceKind::Tablet);
        assert_eq!(device_kind("", "AVD_2", 1080, 2400, 420), DeviceKind::Phone);
        assert_eq!(
            device_kind("", "AVD_3", 0, 0, 0),
            DeviceKind::Phone,
            "a device that reported no screen is a phone, not a division by zero"
        );
    }

    /// `sw600dp` is a threshold, so the two rows either side of it are the test.
    #[test]
    fn the_shortest_side_is_the_shorter_one_converted_at_a_hundred_and_sixty() {
        assert_eq!(super::shortest_width_dp(1080, 2400, 420), Some(411));
        assert_eq!(super::shortest_width_dp(2400, 1080, 420), Some(411));
        assert_eq!(super::shortest_width_dp(1200, 1920, 320), Some(600));
        assert_eq!(super::shortest_width_dp(0, 1920, 320), None);
        assert_eq!(super::shortest_width_dp(1200, 1920, 0), None);
        assert_eq!(super::shortest_width_dp(-1, 1920, 320), None);
    }

    /// Every kind draws its own shape and sits under its own heading, and the byte round-trips.
    #[test]
    fn every_family_carries_its_own_silhouette_and_heading() {
        let mut symbols: Vec<&str> = super::DEVICE_KINDS.iter().map(|k| k.symbol()).collect();
        let mut titles: Vec<&str> = super::DEVICE_KINDS.iter().map(|k| k.group_title()).collect();
        symbols.sort_unstable();
        symbols.dedup();
        titles.sort_unstable();
        titles.dedup();
        assert_eq!(symbols.len(), super::DEVICE_KINDS.len());
        assert_eq!(titles.len(), super::DEVICE_KINDS.len());

        for (rank, kind) in super::DEVICE_KINDS.iter().enumerate() {
            assert_eq!(usize::from(kind.as_byte()), rank, "the discriminant IS the rank");
            assert_eq!(DeviceKind::from_byte(kind.as_byte()), *kind);
        }
        assert_eq!(
            DeviceKind::from_byte(200),
            DeviceKind::Phone,
            "a byte we never wrote"
        );
    }
}
