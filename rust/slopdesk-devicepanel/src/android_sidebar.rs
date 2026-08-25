//! What the Android sidebar DECIDES about its own list, its console ring, its patience and its
//! words.
//!
//! [`crate::android`] is what the panel SAYS about one device — a row's flags, its menu, its
//! summary, the stage over its mirror. This module is the surface a step above that: the model
//! behind the column, which reads a whole LIST rather than a row, holds the one live selection, and
//! keeps the clocks that decide when a wait has gone on too long.
//!
//! ## No identity crosses
//!
//! A device is named by a KEY (an AVD name, or a serial for a physical device) and, once booted, by
//! a SERIAL. Neither crosses. The near side holds the list and does its own string comparison, and
//! hands this module one [`DeviceRow`] per device saying which of its rows the question is ABOUT.
//! Every answer is a POSITION into the list the caller still holds, or a verdict about it. That is
//! `store_rollup::most_recent_survivor`'s shape — the membership test is the caller's because the
//! values are, and the RULE over the flags is here.
//!
//! ## The clocks are milliseconds, and they are the crate's
//!
//! Eleven numbers decided this surface's timing and every one of them was a Swift literal beside
//! the code that read it: the console's ring, the mirror's requested size, five deadlines and three
//! cadences. They are one indexed family here ([`Measure`]) for the reason `docs/55` gives about a
//! family of constant doors — five doors that each answer one number are five entry points to keep
//! in step, and an unknown index answers `0`, which is a value no member of this family can hold.
//!
//! ## What did NOT move, and why
//!
//! The guards around a lifecycle verb — "this row has an AVD name and no serial yet", "this key is
//! already in flight" — read `@Observable` state and a `Set` the model mutates across an `await`.
//! They are actor plumbing rather than rules, and pulling them here would mean crossing the set.
//! Likewise `address(of:)`, which destructures a Swift enum the near side owns.

/// One device row, as this surface's LIST rules read it.
///
/// Three flags rather than a name, a serial and a state word: every question below is a fold over
/// which rows are the SUBJECT and what those rows carry, and the strings that decide the first two
/// are the caller's. A row is cheap enough to build per call that the panel's four readers can each
/// hand over the whole list.
///
/// A sweep over the list ("stop every emulator") needs no row here at all: that is
/// [`crate::android::is_stoppable`] asked once per row, which the near side already crosses for
/// through the device-flags bitfield.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DeviceRow {
    /// Whether this row is the one the caller named by KEY.
    pub matches_key: bool,
    /// Whether this row carries the SERIAL the caller named. Independent of `matches_key`: a dying
    /// emulator can be listed under a different row than the one that started it.
    pub matches_serial: bool,
    /// Whether the row has a serial at all — the fact that a boot has SURFACED.
    pub has_serial: bool,
}

/// Where the row the caller named by key sits, or `None` when the list no longer carries it.
///
/// Four readers on the near side ask this one question: the serial for a key, the selected device,
/// whether a refreshed list still holds the selection, and whether a retry has something to open.
/// A list with two rows under one key answers the FIRST, which is the one every reader was already
/// taking.
#[must_use]
pub fn row_position(rows: &[DeviceRow]) -> Option<usize> {
    rows.iter().position(|row| row.matches_key)
}

/// The launch has SURFACED: the booted serial folded into the row that was pressed.
///
/// State does not matter — `offline` is a boot in progress, and the row already says so from the
/// attached shelf. A key the list does not carry has not surfaced, which is the same answer as a
/// row still waiting for its serial.
#[must_use]
pub fn boot_is_visible(rows: &[DeviceRow]) -> bool {
    rows.iter().any(|row| row.matches_key && row.has_serial)
}

/// The shutdown has LANDED: no row carries the serial any more, under whatever key the dying
/// emulator was listed.
///
/// Keyed on the serial rather than the row because the row itself outlives the shutdown — the AVD
/// stays listed, merely no longer running.
#[must_use]
pub fn shutdown_is_visible(rows: &[DeviceRow]) -> bool {
    !rows.iter().any(|row| row.matches_serial)
}

/// How many rows the console must drop from the FRONT to be back inside [`Measure::LogCapacity`].
///
/// `0` for a console still under the cap, which is the common answer — the trim runs once per
/// arriving BATCH rather than once per line, so a quiet device never reaches it and a booting one
/// reaches it every batch.
#[must_use]
pub fn log_overflow(count: usize) -> usize {
    let capacity = usize::try_from(Measure::LogCapacity.value()).unwrap_or(usize::MAX);
    count.saturating_sub(capacity)
}

/// Whether a session packet's geometry is NEWS — worth writing to the one field every positional
/// message on the wire is paired with.
///
/// A degenerate size is not an answer: a width or height of zero (and a NaN, which fails the same
/// test) is the encoder saying nothing rather than saying a rectangle, and writing it would make
/// every finger the device receives carry a size it discards.
///
/// The comparison is over BIT PATTERNS rather than `==`, and for these inputs the two agree
/// exactly: the only values where they differ are `+0.0` against `-0.0` and NaN against itself,
/// and the positivity test above has already refused all three. Comparing the bits keeps the rule
/// out of float-equality's usual ambiguity without changing a single answer.
#[must_use]
pub fn stream_size_is_news(current: Option<(f64, f64)>, width: f64, height: f64) -> bool {
    let sized = width > 0.0 && height > 0.0;
    if !sized {
        return false;
    }
    current.is_none_or(|(known_width, known_height)| {
        known_width.to_bits() != width.to_bits() || known_height.to_bits() != height.to_bits()
    })
}

/// Whether a wait for video still has patience left.
///
/// `elapsed_ms` is how long the CAMPAIGN has been running — one clock across every retry inside it,
/// so a boot's worth of reattempts cannot extend the deadline forever. `None` is no campaign
/// running, and there is nothing to be out of patience with.
#[must_use]
pub const fn within_grace(elapsed_ms: Option<u64>) -> bool {
    match elapsed_ms {
        Some(elapsed) => elapsed < Measure::DeviceGraceMs.value(),
        None => true,
    }
}

// ---------------------------------------------------------------------------------------------- //
// The words
// ---------------------------------------------------------------------------------------------- //

/// What a sentence calls a device it has no name for.
///
/// The panel reaches a report through a list that may already have dropped the row — a device that
/// went away between the click and the read-back is the ordinary case here, not the exotic one — so
/// every sentence below has to survive being handed nothing.
pub const UNNAMED_DEVICE: &str = "This device";

/// The name a sentence uses for `name`: itself, or [`UNNAMED_DEVICE`] when there is none.
#[must_use]
pub const fn subject(name: &str) -> &str {
    if name.is_empty() { UNNAMED_DEVICE } else { name }
}

/// The failures this surface reports in its own words.
///
/// Six sentences, each about a device rather than about a socket: what the panel says is what it
/// asked the device to do and did not see happen. Three of them name the device and three cannot —
/// the two that describe the MIRROR are about a device already named on screen, and the screenshot
/// one is about the bytes rather than the machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Report {
    /// A launch the host accepted, whose serial never folded into the row.
    BootNeverSurfaced,
    /// A `kill` the host accepted, whose serial never left the list.
    ShutdownNeverLanded,
    /// The device is gone from a freshly-read list.
    NoLongerRunning,
    /// The device is up, the mirror is open, and no video has arrived.
    NoVideo,
    /// The device never reached a state that could take a mirror before patience ran out.
    NeverFinishedStarting,
    /// The bytes the host sent back are not an image anything can paste.
    ScreenshotUnreadable,
}

impl Report {
    /// Every report, in crossing order. The order IS the contract with the C byte below.
    pub const ALL: [Self; 6] = [
        Self::BootNeverSurfaced,
        Self::ShutdownNeverLanded,
        Self::NoLongerRunning,
        Self::NoVideo,
        Self::NeverFinishedStarting,
        Self::ScreenshotUnreadable,
    ];

    /// The byte this report crosses as.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::BootNeverSurfaced => 0,
            Self::ShutdownNeverLanded => 1,
            Self::NoLongerRunning => 2,
            Self::NoVideo => 3,
            Self::NeverFinishedStarting => 4,
            Self::ScreenshotUnreadable => 5,
        }
    }

    /// The report a byte names, or `None` for one no build wrote.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::BootNeverSurfaced),
            1 => Some(Self::ShutdownNeverLanded),
            2 => Some(Self::NoLongerRunning),
            3 => Some(Self::NoVideo),
            4 => Some(Self::NeverFinishedStarting),
            5 => Some(Self::ScreenshotUnreadable),
            _ => None,
        }
    }

    /// The sentence, with `name` folded in where the report names a device.
    ///
    /// An empty `name` reads as [`UNNAMED_DEVICE`] rather than leaving a hole at the front of the
    /// sentence — see [`subject`].
    #[must_use]
    pub fn sentence(self, name: &str) -> String {
        let subject = subject(name);
        match self {
            Self::BootNeverSurfaced => format!("{subject} did not start."),
            Self::ShutdownNeverLanded => format!("{subject} did not shut down."),
            Self::NoLongerRunning => format!("{subject} is no longer running."),
            Self::NoVideo => "The device is running, but no video has arrived.".to_owned(),
            Self::NeverFinishedStarting => format!("{subject} never finished starting."),
            Self::ScreenshotUnreadable => "The screenshot could not be read.".to_owned(),
        }
    }
}

/// The confirmations this surface shows for an action whose result is not on screen.
///
/// Five, and every one of them is about something that happened to the DEVICE rather than to the
/// panel: the panel cannot show the phone's own screen going dark, or its clipboard filling, so it
/// says so instead. They carry no value, so they cross as one table read once rather than as a door
/// per press.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Notice {
    /// The device's own display was switched back on.
    ScreenOn,
    /// The device's own display was switched off, with the mirror still running.
    ScreenOff,
    /// Text was pushed to the device's clipboard and pasted.
    Pasted,
    /// Text was pushed to the device's clipboard without pasting.
    Copied,
    /// A screenshot reached this machine's pasteboard.
    ScreenshotCopied,
}

impl Notice {
    /// Every notice, in delivery order. The order IS the contract with the words table.
    pub const ALL: [Self; 5] = [
        Self::ScreenOn,
        Self::ScreenOff,
        Self::Pasted,
        Self::Copied,
        Self::ScreenshotCopied,
    ];

    /// The byte this notice crosses as.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::ScreenOn => 0,
            Self::ScreenOff => 1,
            Self::Pasted => 2,
            Self::Copied => 3,
            Self::ScreenshotCopied => 4,
        }
    }

    /// The notice a byte names, or `None` for one no build wrote.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::ScreenOn),
            1 => Some(Self::ScreenOff),
            2 => Some(Self::Pasted),
            3 => Some(Self::Copied),
            4 => Some(Self::ScreenshotCopied),
            _ => None,
        }
    }

    /// What it says. No trailing stop: a confirmation is a label, not a sentence.
    #[must_use]
    pub const fn text(self) -> &'static str {
        match self {
            Self::ScreenOn => "Device screen on",
            Self::ScreenOff => "Device screen off",
            Self::Pasted => "Pasted to device",
            Self::Copied => "Copied to device",
            Self::ScreenshotCopied => "Screenshot copied",
        }
    }
}

// ---------------------------------------------------------------------------------------------- //
// The numbers
// ---------------------------------------------------------------------------------------------- //

/// Every number that decides this surface's shape or its timing.
///
/// Two counts and nine milliseconds in one family, which is deliberate: they are all "how much" or
/// "how long" for the SAME surface, and a caller that reads them through one indexed door cannot
/// pick up eight of the eleven and re-spell the ninth.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Measure {
    /// How many rows the console keeps. Far more than fits on screen, far less than a session — an
    /// Android device under load emits far more than an iOS one, because `logcat` carries the whole
    /// system rather than one process.
    LogCapacity,
    /// The longest edge the mirror is scaled to, in PIXELS. 1024 rather than the device's own
    /// resolution: a 1440×3120 phone at native size is four times the pixels for a rectangle that
    /// occupies at most a third of a sidebar, and `scrcpy`'s own default for the same reason is
    /// 1920. Measured 2026-08-04 at 1024 — a 4 Mbit/s ceiling, 25 frames/s under a continuous drag,
    /// and an idle floor of 547 B/s.
    StreamMaxSize,
    /// How long a freshly-opened mirror may stay silent before the panel stops believing in it.
    /// Eight seconds rather than the simulator's five, measured rather than guessed: the host has
    /// to push the server jar over `adb`, start `app_process`, and wait for the device's encoder to
    /// produce its first IDR. A warm emulator did it in 0.83 s; a cold physical device on USB is
    /// the slow case this covers.
    FirstFrameDeadlineMs,
    /// How long a selection keeps chasing a device that is not ready before the panel declares
    /// failure. Measured 2026-08-07: a cold boot sits `offline` in `adb` for ~21 s and produces its
    /// first video at ~39 s, with `open` refused or stalling throughout; a first-ever boot that
    /// still has dexopt to do runs minutes on a slower machine. The window is generous because
    /// everything inside it stays QUIET — the veil, not an error.
    DeviceGraceMs,
    /// The pause between attempts while the device is coming up. Short enough that the mirror opens
    /// within a beat or two of the device turning ready; long enough that a booting host is not
    /// answering a `list` and an `open` for the same panel every frame.
    ReattemptPauseMs,
    /// How long a launch may stay invisible before the panel calls it failed. Generous on purpose:
    /// the serial itself registers within seconds, but its NAME (the fold) needs the QEMU console,
    /// whose accept-and-greet can lag on a loaded host.
    BootVisibleDeadlineMs,
    /// How long a `kill` may stay invisible. A snapshot save on the way down is the slow case, and
    /// measured runs land well inside this.
    ShutdownVisibleDeadlineMs,
    /// How long a confirmation stays up. Long enough to read one short line, short enough that it
    /// is gone before it can be mistaken for state.
    NoticeLifetimeMs,
    /// The ensure loop's base cadence. The backoff tier on top of it is
    /// [`crate::poll_backoff`]'s.
    EnsurePollMs,
    /// The device catalogue's own, slower cadence. Each round is one `adb devices -l` plus one
    /// `adb shell` per RUNNING device, which is why it is not the ensure loop's.
    DeviceWatchMs,
    /// How often a lifecycle verb re-reads the list while it holds its spinner. Faster than the
    /// ambient watch because this loop runs only while something is in flight, and it is what
    /// carries the change to the screen sooner than the watch would.
    PendingHoldMs,
}

impl Measure {
    /// Every measure, in index order. The order IS the contract with the C index below.
    pub const ALL: [Self; 11] = [
        Self::LogCapacity,
        Self::StreamMaxSize,
        Self::FirstFrameDeadlineMs,
        Self::DeviceGraceMs,
        Self::ReattemptPauseMs,
        Self::BootVisibleDeadlineMs,
        Self::ShutdownVisibleDeadlineMs,
        Self::NoticeLifetimeMs,
        Self::EnsurePollMs,
        Self::DeviceWatchMs,
        Self::PendingHoldMs,
    ];

    /// The index this measure is asked for by.
    #[must_use]
    pub const fn index(self) -> u32 {
        match self {
            Self::LogCapacity => 0,
            Self::StreamMaxSize => 1,
            Self::FirstFrameDeadlineMs => 2,
            Self::DeviceGraceMs => 3,
            Self::ReattemptPauseMs => 4,
            Self::BootVisibleDeadlineMs => 5,
            Self::ShutdownVisibleDeadlineMs => 6,
            Self::NoticeLifetimeMs => 7,
            Self::EnsurePollMs => 8,
            Self::DeviceWatchMs => 9,
            Self::PendingHoldMs => 10,
        }
    }

    /// The measure an index names, or `None` for one no build wrote.
    #[must_use]
    pub const fn from_index(index: u32) -> Option<Self> {
        match index {
            0 => Some(Self::LogCapacity),
            1 => Some(Self::StreamMaxSize),
            2 => Some(Self::FirstFrameDeadlineMs),
            3 => Some(Self::DeviceGraceMs),
            4 => Some(Self::ReattemptPauseMs),
            5 => Some(Self::BootVisibleDeadlineMs),
            6 => Some(Self::ShutdownVisibleDeadlineMs),
            7 => Some(Self::NoticeLifetimeMs),
            8 => Some(Self::EnsurePollMs),
            9 => Some(Self::DeviceWatchMs),
            10 => Some(Self::PendingHoldMs),
            _ => None,
        }
    }

    /// The number itself — rows for the two counts, PIXELS for the mirror's edge, milliseconds for
    /// the rest.
    #[must_use]
    pub const fn value(self) -> u64 {
        match self {
            Self::LogCapacity => 600,
            Self::StreamMaxSize => 1024,
            Self::FirstFrameDeadlineMs => 8_000,
            Self::DeviceGraceMs => 120_000,
            Self::ReattemptPauseMs => 1_500,
            Self::BootVisibleDeadlineMs => 60_000,
            Self::ShutdownVisibleDeadlineMs => 45_000,
            Self::NoticeLifetimeMs => 2_000,
            Self::EnsurePollMs => 900,
            Self::DeviceWatchMs => 4_000,
            Self::PendingHoldMs => 1_000,
        }
    }
}

/// The number at `index`, or `0` for an index this build cannot name.
///
/// Zero is the refusal rather than a member of the family: every measure above is a positive count
/// or a positive duration, so a caller that reads `0` has been told "this build has no such
/// number", never "wait no time at all".
#[must_use]
pub const fn measure(index: u32) -> u64 {
    match Measure::from_index(index) {
        Some(measure) => measure.value(),
        None => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DeviceRow, Measure, Notice, Report, UNNAMED_DEVICE, boot_is_visible, log_overflow, measure,
        row_position, shutdown_is_visible, stream_size_is_news, subject, within_grace,
    };

    /// A row that is nobody's subject and carries nothing.
    const fn blank() -> DeviceRow {
        DeviceRow {
            matches_key: false,
            matches_serial: false,
            has_serial: false,
        }
    }

    #[test]
    fn the_key_lookup_answers_the_first_match_and_nothing_for_a_list_without_one() {
        assert_eq!(row_position(&[]), None);
        assert_eq!(row_position(&[blank(), blank()]), None);
        let mut rows = [blank(), blank(), blank()];
        if let Some(row) = rows.get_mut(1) {
            row.matches_key = true;
        }
        if let Some(row) = rows.get_mut(2) {
            row.matches_key = true;
        }
        assert_eq!(
            row_position(&rows),
            Some(1),
            "the first match is the one every reader took"
        );
    }

    #[test]
    fn a_boot_surfaces_only_once_the_named_row_carries_a_serial() {
        let waiting = DeviceRow {
            matches_key: true,
            ..blank()
        };
        let surfaced = DeviceRow {
            matches_key: true,
            has_serial: true,
            ..blank()
        };
        assert!(
            !boot_is_visible(&[]),
            "a list without the row has not surfaced it"
        );
        assert!(!boot_is_visible(&[waiting]));
        assert!(boot_is_visible(&[surfaced]));
        // A serial on somebody ELSE's row is not this boot.
        let stranger = DeviceRow {
            has_serial: true,
            ..blank()
        };
        assert!(!boot_is_visible(&[stranger, waiting]));
    }

    #[test]
    fn a_shutdown_lands_when_no_row_carries_the_serial_any_more() {
        let carrier = DeviceRow {
            matches_serial: true,
            ..blank()
        };
        assert!(shutdown_is_visible(&[]), "an empty list carries no serial");
        assert!(shutdown_is_visible(&[blank(), blank()]));
        assert!(!shutdown_is_visible(&[blank(), carrier]));
    }

    #[test]
    fn the_console_trims_only_what_is_over_the_cap() {
        let capacity = usize::try_from(Measure::LogCapacity.value()).unwrap_or(usize::MAX);
        assert_eq!(log_overflow(0), 0);
        assert_eq!(log_overflow(capacity), 0, "at the cap is not over it");
        assert_eq!(log_overflow(capacity + 1), 1);
        assert_eq!(log_overflow(capacity + 250), 250);
        assert_eq!(log_overflow(usize::MAX), usize::MAX - capacity);
    }

    #[test]
    fn a_degenerate_stream_size_is_never_news() {
        for (width, height) in [(0.0, 100.0), (100.0, 0.0), (-1.0, 100.0), (100.0, -1.0)] {
            assert!(!stream_size_is_news(None, width, height));
            assert!(!stream_size_is_news(Some((10.0, 20.0)), width, height));
        }
        assert!(
            !stream_size_is_news(None, f64::NAN, 100.0),
            "a NaN fails the positivity test"
        );
        assert!(!stream_size_is_news(None, 100.0, f64::NAN));
    }

    #[test]
    fn a_real_stream_size_is_news_exactly_once() {
        assert!(
            stream_size_is_news(None, 1024.0, 2280.0),
            "the first size is always news"
        );
        assert!(
            !stream_size_is_news(Some((1024.0, 2280.0)), 1024.0, 2280.0),
            "the same packet twice writes the field once",
        );
        assert!(
            stream_size_is_news(Some((1024.0, 2280.0)), 2280.0, 1024.0),
            "a turn is news"
        );
        assert!(stream_size_is_news(Some((1024.0, 2280.0)), 1024.0, 2281.0));
    }

    #[test]
    fn patience_runs_out_only_once_a_campaign_has_started() {
        let grace = Measure::DeviceGraceMs.value();
        assert!(
            within_grace(None),
            "no campaign, nothing to be out of patience with"
        );
        assert!(within_grace(Some(0)));
        assert!(within_grace(Some(grace - 1)));
        assert!(
            !within_grace(Some(grace)),
            "the deadline itself is out of patience"
        );
        assert!(!within_grace(Some(u64::MAX)));
    }

    #[test]
    fn a_sentence_without_a_name_still_names_something() {
        assert_eq!(subject(""), UNNAMED_DEVICE);
        assert_eq!(subject("Pixel 8"), "Pixel 8");
        assert_eq!(
            Report::NoLongerRunning.sentence(""),
            "This device is no longer running."
        );
        assert_eq!(
            Report::NoLongerRunning.sentence("Pixel 8"),
            "Pixel 8 is no longer running."
        );
    }

    #[test]
    fn every_report_says_something_and_only_three_of_them_name_the_device() {
        let named = [
            Report::BootNeverSurfaced,
            Report::ShutdownNeverLanded,
            Report::NoLongerRunning,
            Report::NeverFinishedStarting,
        ];
        for report in Report::ALL {
            let sentence = report.sentence("Pixel 8");
            assert!(!sentence.is_empty());
            assert!(sentence.ends_with('.'), "a report is a sentence: {sentence}");
            assert_eq!(
                sentence.contains("Pixel 8"),
                named.contains(&report),
                "the device is named exactly where the report is about it: {sentence}",
            );
        }
    }

    #[test]
    fn every_report_byte_round_trips_and_no_other_byte_names_one() {
        for report in Report::ALL {
            assert_eq!(Report::from_code(report.code()), Some(report));
        }
        for code in 0..=u8::MAX {
            let named = Report::from_code(code).is_some();
            assert_eq!(named, usize::from(code) < Report::ALL.len(), "byte {code}");
        }
    }

    #[test]
    fn every_notice_says_something_short_and_round_trips() {
        for notice in Notice::ALL {
            assert!(!notice.text().is_empty());
            assert!(
                !notice.text().ends_with('.'),
                "a notice is a label, not a sentence"
            );
            assert_eq!(Notice::from_code(notice.code()), Some(notice));
        }
        for code in 0..=u8::MAX {
            let named = Notice::from_code(code).is_some();
            assert_eq!(named, usize::from(code) < Notice::ALL.len(), "byte {code}");
        }
    }

    #[test]
    fn the_notice_table_has_no_two_entries_saying_the_same_thing() {
        let mut said: Vec<&str> = Notice::ALL.iter().map(|notice| notice.text()).collect();
        said.sort_unstable();
        let before = said.len();
        said.dedup();
        assert_eq!(
            said.len(),
            before,
            "two notices with one wording is one of them unreachable"
        );
    }

    #[test]
    fn every_measure_is_positive_round_trips_and_an_unknown_index_answers_zero() {
        for known in Measure::ALL {
            assert!(known.value() > 0, "zero is this family's refusal, never a member");
            assert_eq!(Measure::from_index(known.index()), Some(known));
            assert_eq!(measure(known.index()), known.value());
        }
        let count = u32::try_from(Measure::ALL.len()).unwrap_or(u32::MAX);
        for index in 0..count {
            assert!(measure(index) > 0, "index {index} is a member");
        }
        assert_eq!(measure(count), 0);
        assert_eq!(measure(u32::MAX), 0);
    }

    #[test]
    fn the_measure_indices_are_dense_and_in_declaration_order() {
        for (position, known) in Measure::ALL.iter().enumerate() {
            assert_eq!(
                usize::try_from(known.index()).unwrap_or(usize::MAX),
                position,
                "the index IS the position, which is what the C door's table promises",
            );
        }
    }
}
