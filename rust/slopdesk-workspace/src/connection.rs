//! The link island's whole reading: which state the link is in, what each run says, and which
//! readings are allowed to climb.
//!
//! The island is drawn three ways — the navigator's foot (two lines on a bed), the titlebar band
//! (one line, one control tall) and the phone's navigation toolbar (the link line alone, bedless).
//! The first two are `AppKit` and the third is `SwiftUI`, so every decision the three share had to
//! stop being a `static` on a `View`. This is where they went.
//!
//! ## Two channels, and no hue
//!
//! [`Alarm`] is the whole state axis: brightness and weight, never colour. A row of digits has
//! nothing to hang a palette on, and an instrument that lights a different colour per fault asks
//! the eye to learn one before it can read a number. What each rung resolves to is the design
//! floor's job on each side; which rung a reading has earned is here.
//!
//! ## Which readings may climb, and on what evidence
//!
//! * the LINK on its round trip ([`health`]),
//! * MEMORY on the kernel's pressure verdict, never the percent — a high memory percent is ordinary
//!   on a healthy Mac,
//! * DISK on an ABSOLUTE byte threshold, because a percent lies in both directions: 2 % of 4 TB
//!   still builds, 8 % of 128 GB does not,
//! * CPU never. A build pegging the host is what the machine is FOR, and a readout that shouts
//!   every compile teaches the eye to ignore it.
//!
//! ## Why the words are here too
//!
//! [`friendly_failure`] is the reason this module is one subject rather than two. The transport
//! hands up `String(describing:)` dumps of whatever `POSIXErrorCode` or `NWError` it caught, and
//! turning those into something a person can act on is a classifier over hostile input — the
//! crate's own charter case, and a place where two implementations would give the same fault two
//! different remedies on two devices. An unmatched payload passes through verbatim: never hide
//! information that cannot be improved.
//!
//! ## What is NOT here
//!
//! The reconnect ceiling. `ReconnectManager` owns it, in the module that actually runs the
//! campaign, and every rule below that needs it takes it as an argument. Copying it here would be a
//! second source for "attempt 3 of 20" that could drift from the supervisor that decides it.

use std::borrow::Cow;
use std::fmt::Write as _;

/// The connect campaign's state, without the payloads only the words need.
///
/// The Swift enum carries a `Date`, an attempt counter and a raw failure string; the classifiers
/// below read none of them, so what crosses is the discriminant alone. The two rules that DO need a
/// payload take it beside this rather than inside it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum StatusKind {
    /// Deliberately not connected — a fresh launch, or a link the user closed.
    #[default]
    Disconnected = 0,
    /// A first connect in flight.
    Connecting = 1,
    /// Up.
    Connected = 2,
    /// A transport drop the supervisor is retrying on its own.
    Reconnecting = 3,
    /// The reconnect campaign exhausted its attempts — the post-connect give-up.
    Unreachable = 4,
    /// The initial connect timed out or was refused.
    Failed = 5,
}

impl StatusKind {
    /// Every kind, for a caller that wants to score them all.
    pub const ALL: [Self; 6] = [
        Self::Disconnected,
        Self::Connecting,
        Self::Connected,
        Self::Reconnecting,
        Self::Unreachable,
        Self::Failed,
    ];

    /// The kind a byte names. An unknown byte reads as disconnected, which is the state that
    /// promises the least and offers the Connect editor.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Self {
        match byte {
            1 => Self::Connecting,
            2 => Self::Connected,
            3 => Self::Reconnecting,
            4 => Self::Unreachable,
            5 => Self::Failed,
            _ => Self::Disconnected,
        }
    }

    /// The byte a kind reports as.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// How loud one reading is allowed to be — the island's whole state axis, and the only one it has.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, PartialOrd, Ord)]
#[repr(u8)]
pub enum Alarm {
    /// The metadata grey every healthy reading rests in.
    #[default]
    Quiet = 0,
    /// Worth knowing about.
    Raised = 1,
    /// Worth acting on.
    Loud = 2,
}

impl Alarm {
    /// The byte a rung reports as.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// The round trip, classified. Kept apart from [`Led`] because the phone's compact mount reads
/// health directly without ever asking which dial state produced it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum NetworkHealth {
    /// Not connected — there is no round trip to classify.
    #[default]
    Offline = 0,
    /// Under [`PING_GOOD_MS`], or connected with no sample yet.
    Good = 1,
    /// Between the two thresholds.
    Slow = 2,
    /// Over [`PING_SLOW_MS`].
    Bad = 3,
}

/// How the link is doing, as one fused state.
///
/// The name is historical — the lamp itself is gone; this classifies the island's TEXT inks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum Led {
    /// Every settled not-connected state. A stale ping must never brighten it.
    #[default]
    Dim = 0,
    /// A dial in flight — a first connect OR a supervised reconnect.
    Dialing = 1,
    /// Connected, round trip under [`PING_GOOD_MS`].
    Good = 2,
    /// Connected, round trip between the thresholds.
    Slow = 3,
    /// Connected, round trip over [`PING_SLOW_MS`].
    Bad = 4,
}

impl Led {
    /// The byte a state reports as.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// Which of the three machine readings a run is.
///
/// Processor die, memory module, drive — Activity Monitor's own vocabulary, chosen so the three
/// differ in SILHOUETTE, which is the only difference that survives at the island's size. The GLYPH
/// each one resolves to is its framework's; the role is here, so both halves name the same number
/// with the same mark.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Metric {
    /// All-core busy percent.
    Cpu = 0,
    /// In-use percent.
    Memory = 1,
    /// Free space on the work volume.
    Disk = 2,
}

impl Metric {
    /// The byte a role reports as.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// The SF Symbol that names this role. A NAME rather than a typed symbol, because the two
    /// frameworks want different types out of it and the DRAWING is the part that must not differ.
    #[must_use]
    pub const fn symbol_name(self) -> &'static str {
        match self {
            Self::Cpu => "cpu",
            Self::Memory => "memorychip",
            Self::Disk => "internaldrive",
        }
    }
}

/// The kernel's memory-pressure verdict, as the wire's own byte names it.
///
/// A classifier over that byte rather than a second copy of the wire's enum: the codec that parses
/// it is `slopdesk_wire`'s, and this crate points DOWN only. An unknown byte reads as normal, which
/// is the rung that says nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum MemoryPressure {
    /// Nothing to say.
    #[default]
    Normal = 0,
    /// The kernel is asking for pages back.
    Warn = 1,
    /// The kernel is taking them.
    Critical = 2,
}

impl MemoryPressure {
    /// The verdict a wire byte names.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Self {
        match byte {
            1 => Self::Warn,
            2 => Self::Critical,
            _ => Self::Normal,
        }
    }

    /// The byte a verdict reports as — the inverse of [`Self::from_byte`], for a boundary handing a
    /// held pulse back the way it received one.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// The host's displayed pulse — what the second line actually says, which is not quite what the
/// last sample said. [`settled`] below is the deadband that holds it still.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Pulse {
    /// All-core CPU busy percent as displayed.
    pub cpu_percent: u32,
    /// Memory-in-use percent as displayed.
    pub memory_percent: u32,
    /// The kernel's verdict, which is the memory run's whole classifier.
    pub memory_pressure: MemoryPressure,
    /// Free MiB on the work volume; `None` is a volume the host could not read, and the run is
    /// omitted rather than guessed.
    pub disk_free_mib: Option<u32>,
}

/// One drawn run of the machine's pulse: its role, its number, and how loud it may be.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MetricRun {
    /// Which reading this is.
    pub metric: Metric,
    /// The figure as drawn.
    pub value: String,
    /// How loud it has earned the right to be.
    pub alarm: Alarm,
}

/// Where the link's reading is mounted — the ONE thing about the trailing slot the two shells
/// genuinely disagree on, named rather than re-derived.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum Mount {
    /// A bed cut out of the chrome. A bed is already on screen, so an empty right edge reads as
    /// broken.
    #[default]
    Bedded = 0,
    /// A bedless run of text in a toolbar. There is no plate for a gap to appear in, so a slot that
    /// has not filled yet reads as nothing at all rather than as a fault.
    Compact = 1,
}

/// What the trailing slot shows, which is a choice between two sources rather than one string.
///
/// The slot is answered as a KIND and not as text on purpose: the status word needs the campaign's
/// attempt count and the ping needs the sample, so a single door would have to carry both payloads
/// to answer with either. The caller already holds them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum TrailingSlot {
    /// Nothing at all — a compact mount, connected, before the first sample lands.
    #[default]
    Absent = 0,
    /// The mono ping figure.
    Ping = 1,
    /// The short status word.
    StatusWord = 2,
}

/// A round trip at or under this is good, in milliseconds.
pub const PING_GOOD_MS: f64 = 80.0;
/// A round trip at or under this is slow; past it is bad.
pub const PING_SLOW_MS: f64 = 180.0;

/// Free space below this is worth a raised run: the machine still works, but the next container
/// pull or clean build is the one that fails.
pub const DISK_WARN_MIB: u32 = 15 * 1024;
/// Below this the host is effectively out of disk — a build will fail, and so will the editor's
/// next save.
pub const DISK_CRITICAL_MIB: u32 = 5 * 1024;

/// At or above this many kbps the figure reads in Mbps.
const MBPS_THRESHOLD_KBPS: i64 = 1000;

/// The round trip, classified. Connected with no sample yet is GOOD, not unknown: the link answered
/// the handshake, so the only honest default is the one that says nothing is wrong yet.
#[must_use]
pub fn health(is_connected: bool, ping_ms: Option<f64>) -> NetworkHealth {
    if !is_connected {
        return NetworkHealth::Offline;
    }
    let Some(ping_ms) = ping_ms else {
        return NetworkHealth::Good;
    };
    if ping_ms <= PING_GOOD_MS {
        NetworkHealth::Good
    } else if ping_ms <= PING_SLOW_MS {
        NetworkHealth::Slow
    } else {
        NetworkHealth::Bad
    }
}

/// Connected rides the ping classifier; a dial in flight is dialing; every settled not-connected
/// state is dim, so a stale sample can never brighten a link that is down.
#[must_use]
pub fn led_state(status: StatusKind, ping_ms: Option<f64>) -> Led {
    match status {
        StatusKind::Connected => {
            match health(true, ping_ms) {
                NetworkHealth::Slow => Led::Slow,
                NetworkHealth::Bad => Led::Bad,
                NetworkHealth::Good | NetworkHealth::Offline => Led::Good,
            }
        },
        StatusKind::Connecting | StatusKind::Reconnecting => Led::Dialing,
        StatusKind::Disconnected | StatusKind::Unreachable | StatusKind::Failed => Led::Dim,
    }
}

/// The LINK's alarm: a slow round trip is worth knowing, a bad one is worth acting on.
///
/// Every not-connected state is quiet — an instrument with nothing to measure has nothing to shout
/// about, and the status WORD in the slot already says so.
#[must_use]
pub const fn link_alarm(led: Led) -> Alarm {
    match led {
        Led::Slow => Alarm::Raised,
        Led::Bad => Alarm::Loud,
        Led::Dim | Led::Dialing | Led::Good => Alarm::Quiet,
    }
}

/// MEMORY takes the kernel's verdict, not the percent — see this module's header.
#[must_use]
pub const fn memory_alarm(pressure: MemoryPressure) -> Alarm {
    match pressure {
        MemoryPressure::Warn => Alarm::Raised,
        MemoryPressure::Critical => Alarm::Loud,
        MemoryPressure::Normal => Alarm::Quiet,
    }
}

/// DISK climbs on BYTES LEFT, the only reading that answers "can I still work here". An unreadable
/// volume is quiet, not alarmed — no reading is not bad news.
#[must_use]
pub const fn disk_alarm(free_mib: Option<u32>) -> Alarm {
    let Some(free_mib) = free_mib else {
        return Alarm::Quiet;
    };
    if free_mib < DISK_CRITICAL_MIB {
        Alarm::Loud
    } else if free_mib < DISK_WARN_MIB {
        Alarm::Raised
    } else {
        Alarm::Quiet
    }
}

/// Whether a run has earned a place on a mount with ONE line to spend.
///
/// The ladder already draws the boundary — quiet is the grey a healthy reading rests in — so the
/// gate is that boundary read as a yes/no, not a second threshold anyone has to keep in step.
#[must_use]
pub fn promotes(alarm: Alarm) -> bool {
    alarm != Alarm::Quiet
}

/// Whether a manual Retry affordance applies — only the GIVE-UP states. A campaign still in flight
/// has a retry already running, and offering a second one races it.
#[must_use]
pub const fn shows_retry(status: StatusKind) -> bool {
    matches!(status, StatusKind::Failed | StatusKind::Unreachable)
}

/// What the trailing slot shows.
///
/// The one branch the mount decides is CONNECTED-BUT-UNSAMPLED, the beat before the first ping
/// lands: a bedded reading falls back to the status word, because a connected island with an empty
/// right edge reads as broken, and a compact one stays silent. That is a layout ruling about the
/// two mounts, not two answers to what the link says, which is why it is a parameter rather than a
/// second copy of this rule at the pill.
#[must_use]
pub const fn trailing_slot(status: StatusKind, has_ping: bool, mount: Mount) -> TrailingSlot {
    if matches!(status, StatusKind::Connected) {
        if has_ping {
            return TrailingSlot::Ping;
        }
        if matches!(mount, Mount::Compact) {
            return TrailingSlot::Absent;
        }
    }
    TrailingSlot::StatusWord
}

/// The trailing slot's alarm: the ping digits climb as the link degrades; a status WORD is prose,
/// and prose that has already said "disconnected" gains nothing from being shouted.
#[must_use]
pub const fn detail_alarm(slot: TrailingSlot, led: Led) -> Alarm {
    match slot {
        TrailingSlot::Ping => link_alarm(led),
        TrailingSlot::Absent | TrailingSlot::StatusWord => Alarm::Quiet,
    }
}

/// The one visible link metric: the ping, rounded to whole milliseconds.
#[must_use]
pub fn ping_label(ping_ms: f64) -> String {
    format!("{} ms", round_to_i64(ping_ms))
}

/// The stream's bitrate. Past a megabit the figure reads in Mbps with one decimal, because four
/// digits of kbps is a number nobody reads and a magnitude everybody does.
#[must_use]
pub fn bitrate_label(kbps: i64) -> String {
    if kbps >= MBPS_THRESHOLD_KBPS {
        #[expect(
            clippy::cast_precision_loss,
            reason = "a bitrate past 2^53 kbps is not a link this app will ever see, and the figure it \
                      prints carries one decimal"
        )]
        let mbps = kbps as f64 / 1000.0;
        format!("{mbps:.1} Mbps")
    } else {
        format!("{kbps} kbps")
    }
}

/// Free disk in four characters, coarsening with scale (`820M`, `6.4G`, `42G`, `240G`, `2.1T`) —
/// the middle rail has room for a reading, not for a figure.
///
/// The coarseness is deliberate: two significant figures is all a "can I still work here" answer
/// needs, and a number that only names round values cannot twitch between polls.
///
/// THREE NARROW BANDS DRAW FIVE, and they are all the same lip: each branch is chosen on the
/// UNROUNDED value while the text is printed ROUNDED, so a figure just under a threshold can carry
/// into an extra character — `1023M` (not yet a gibibyte), `10.0G` (9.95 GiB rounding up while
/// still under the one-decimal branch's ceiling) and `1024G` (not yet a tebibyte).
///
/// That is the original's arithmetic kept exactly, not a bound tightened during the port. A run one
/// character wider across three thin ranges is a layout question for whoever owns the rail; fixing
/// it here would make this a behaviour change wearing a port's clothes.
#[must_use]
pub fn disk_label(free_mib: u32) -> String {
    let gib = f64::from(free_mib) / 1024.0;
    if free_mib < 1024 {
        format!("{free_mib}M")
    } else if gib < 10.0 {
        format!("{gib:.1}G")
    } else if gib < 1024.0 {
        format!("{}G", round_to_i64(gib))
    } else {
        format!("{:.1}T", gib / 1024.0)
    }
}

/// The stream numbers as tooltip detail (`" · 60 fps · 12.4 Mbps"`), or empty when neither exists.
///
/// They are deliberately absent from every visible row: appending them made the trailing text long
/// enough to truncate the hostname out of its own line — the identity lost to telemetry.
#[must_use]
pub fn tooltip_detail(fps: Option<i64>, kbps: Option<i64>) -> String {
    let mut out = String::new();
    if let Some(fps) = fps {
        let _ = write!(out, " · {fps} fps");
    }
    if let Some(kbps) = kbps {
        let _ = write!(out, " · {}", bitrate_label(kbps));
    }
    out
}

/// The pulse as it is DRAWN, in the order it is drawn — cpu, memory, disk.
///
/// Fastest-moving first, so the eye scans from the reading that is about right now toward the one
/// that is about next week; it also keeps the two PERCENTS adjacent, which is the pair a glance
/// actually compares. A host that could not read its volume drops the DISK run alone, and one
/// missing metric closes its gap.
#[must_use]
pub fn metric_runs(pulse: Pulse) -> Vec<MetricRun> {
    let mut runs = Vec::with_capacity(3);
    // CPU is deliberately never raised — see this module's header.
    runs.push(MetricRun {
        metric: Metric::Cpu,
        value: format!("{}%", pulse.cpu_percent),
        alarm: Alarm::Quiet,
    });
    runs.push(MetricRun {
        metric: Metric::Memory,
        value: format!("{}%", pulse.memory_percent),
        alarm: memory_alarm(pulse.memory_pressure),
    });
    if let Some(free_mib) = pulse.disk_free_mib {
        runs.push(MetricRun {
            metric: Metric::Disk,
            value: disk_label(free_mib),
            alarm: disk_alarm(Some(free_mib)),
        });
    }
    runs
}

/// The pulse as a ONE-LINE mount draws it: the runs that [`promotes`], in [`metric_runs`]' own
/// order, and NOTHING at all while the host is calm.
///
/// The phone's toolbar is one line, and the ambient question — how hard is the host working —
/// really is the desktop's: a mount that cannot afford three resting readings should not carry a
/// worse version of them. What it must never do is go SILENT on a state the bedded island
/// escalates, because a memory verdict of critical or a volume with no room left is not ambient, it
/// is the reason the next build will fail.
#[must_use]
pub fn promoted_runs(pulse: Pulse) -> Vec<MetricRun> {
    let mut runs = metric_runs(pulse);
    runs.retain(|run| promotes(run.alarm));
    runs
}

/// The pulse as words, for the readers that get no glyph.
#[must_use]
pub fn pulse_spoken(pulse: Pulse) -> String {
    let disk = pulse
        .disk_free_mib
        .map_or_else(String::new, |mib| format!(", {} free", disk_label(mib)));
    format!("cpu {}%, mem {}%{disk}", pulse.cpu_percent, pulse.memory_percent)
}

/// The pulse as TOOLTIP prose — the exact numbers plus the pressure verdict the visible line only
/// hints at through ink.
#[must_use]
pub fn pulse_tooltip(pulse: Pulse) -> String {
    let pressure = match pulse.memory_pressure {
        MemoryPressure::Normal => "",
        MemoryPressure::Warn => " (memory pressure)",
        MemoryPressure::Critical => " (memory pressure critical)",
    };
    let disk = pulse
        .disk_free_mib
        .map_or_else(String::new, |mib| format!(" · {} free", disk_label(mib)));
    format!(
        " · cpu {}% · mem {}%{pressure}{disk}",
        pulse.cpu_percent, pulse.memory_percent
    )
}

/// Maps a raw transport failure payload to an actionable message.
///
/// Substring-matched, because the payloads are `String(describing:)` dumps with no stable structure
/// — a `POSIXErrorCode`, an `NWError`, a transport error's own description. An unmatched payload
/// passes through VERBATIM: never hide information that cannot be improved, and a borrowed answer
/// is how the caller can tell it was not rewritten.
///
/// The order matters where two shapes overlap. "connection refused" is checked before the
/// closed-by-peer family so a refusal reads as one, and the bare `"connection failed"` case is last
/// because it is an exact match that any earlier substring rule would have taken first.
#[must_use]
pub fn friendly_failure(raw: &str) -> Cow<'_, str> {
    let lower = raw.to_lowercase();
    let has = |needle: &str| lower.contains(needle);
    if has("refused") {
        return Cow::Borrowed("Connection refused — is slopdesk-hostd running on the host?");
    }
    if has("no route") || has("ehostunreach") {
        return Cow::Borrowed(
            "No route to host — check the address and that both machines share a network or VPN.",
        );
    }
    if has("timed out") || has("etimedout") || has("timeout") {
        return Cow::Borrowed("Timed out — the host didn't answer. Check the port and any firewall.");
    }
    if has("network is down") || has("enetdown") {
        return Cow::Borrowed("Network is down — check Wi-Fi or Ethernet.");
    }
    if has("nosuchrecord") || has("dns") || has("hostname") {
        return Cow::Borrowed("Hostname not found — check the host name.");
    }
    if has("reset") {
        return Cow::Borrowed("Connection reset — the host daemon may have crashed. Restart slopdesk-hostd.");
    }
    // The TCP connected but the slopdesk handshake did not complete — wrong daemon, a version
    // mismatch, or a bad mux preamble. Distinct from "refused": something IS listening, it just is
    // not a compatible host.
    if has("handshake") {
        return Cow::Borrowed(
            "The host answered but isn't a compatible slopdesk host — check it's running slopdesk-hostd and \
             that the versions match.",
        );
    }
    // A clean drop mid-session: the link is gone, not refused. Auto-reconnect handles a transient
    // one; a terminal failure here means it gave up, so say so and offer Retry.
    if has("connection lost")
        || has("connection closed")
        || has("eof")
        || has("not connected")
        || has("enotconn")
        || has("broken pipe")
        || has("epipe")
    {
        return Cow::Borrowed(
            "Connection lost — the host or network dropped. Check the host is up, then Retry.",
        );
    }
    // A bare failure with no more specific cause: enrich it with the first thing to check rather
    // than leaving the terse transport phrase.
    if lower == "connection failed" {
        return Cow::Borrowed(
            "Couldn't reach the host — check the address and port, and that slopdesk-hostd is running.",
        );
    }
    Cow::Borrowed(raw)
}

/// Whether the raw payload is worth a tooltip — true ONLY when [`friendly_failure`] actually
/// rewrote it, since a passthrough would just duplicate the headline.
///
/// It answers a YES/NO and not the payload: the caller already holds the string it passed in, and
/// handing it back would be a copy made only to be compared with the one it came from.
#[must_use]
pub fn has_raw_detail(status: StatusKind, raw: &str) -> bool {
    matches!(status, StatusKind::Failed) && friendly_failure(raw) != raw
}

/// The gate card's status line. Sentence-cased, actionable, and honest about which state this is: a
/// first "Connecting…" is not a "Reconnecting — attempt 3 of 20".
///
/// `max_attempts` is the supervisor's ceiling, passed in because `ReconnectManager` owns it.
#[must_use]
pub fn headline(status: StatusKind, attempt: u32, max_attempts: u32, raw: &str) -> Cow<'_, str> {
    match status {
        StatusKind::Disconnected => Cow::Borrowed("Disconnected"),
        StatusKind::Connecting => Cow::Borrowed("Connecting…"),
        StatusKind::Connected => Cow::Borrowed("Connected"),
        StatusKind::Reconnecting => {
            if attempt > 0 {
                Cow::Owned(format!("Reconnecting — attempt {attempt} of {max_attempts}"))
            } else {
                Cow::Borrowed("Reconnecting…")
            }
        },
        StatusKind::Unreachable => {
            Cow::Borrowed("Unreachable — the host stopped answering. Check it, then Retry.")
        },
        StatusKind::Failed => friendly_failure(raw),
    }
}

/// The plain state name, which is what every compact reading falls back to.
#[must_use]
pub fn status_label(status: StatusKind, attempt: u32, raw: &str) -> String {
    match status {
        StatusKind::Disconnected => "disconnected".into(),
        StatusKind::Connecting => "connecting".into(),
        StatusKind::Connected => "connected".into(),
        StatusKind::Reconnecting => {
            if attempt > 0 {
                format!("reconnecting ({attempt})")
            } else {
                "reconnecting".into()
            }
        },
        StatusKind::Unreachable => "unreachable".into(),
        StatusKind::Failed => format!("failed: {raw}"),
    }
}

/// The compact toolbar form: campaign progress without the prose, and a failure never dumps its raw
/// payload into a menu-bar label — the gate card carries the actionable copy.
#[must_use]
pub fn short_label(status: StatusKind, attempt: u32, max_attempts: u32) -> String {
    match status {
        StatusKind::Reconnecting if attempt > 0 => {
            format!("reconnecting {attempt}/{max_attempts}")
        },
        StatusKind::Failed => "failed".into(),
        _ => status_label(status, attempt, ""),
    }
}

/// The points a metric must move before the footer redraws it.
///
/// Three is the smallest step that clears idle jitter on a real machine while still tracking a
/// genuine climb within one poll of it.
pub const PULSE_DEADBAND: u32 = 3;

/// Folds a fresh sample into the SHOWN pulse.
///
/// The rail has no animation by design, and a raw CPU percent polled every few seconds fails that
/// test on its own: it twitches 31 → 29 → 33 on an idle machine and pulls the eye to the corner for
/// nothing. So each metric HOLDS its displayed number until the sample is at least
/// [`PULSE_DEADBAND`] points away, then snaps to the sample EXACTLY — never to a midpoint, because
/// the row must always show a percent the host really reported. That keeps the reading honest (no
/// smoothing, no lag) while refusing to redraw for noise.
///
/// The first sample (`previous` is `None`) is shown as-is. Pressure and free disk are exempt and
/// pass straight through: a pressure LEVEL change is a state change and never noise, and the disk
/// figure is drawn so coarsely that its own format is already a deadband.
#[must_use]
pub const fn settled(previous: Option<Pulse>, sample: Pulse) -> Pulse {
    let Some(previous) = previous else { return sample };
    Pulse {
        cpu_percent: held(previous.cpu_percent, sample.cpu_percent),
        memory_percent: held(previous.memory_percent, sample.memory_percent),
        memory_pressure: sample.memory_pressure,
        disk_free_mib: sample.disk_free_mib,
    }
}

/// One metric's hold: the sample once it has earned the redraw, the shown figure until then.
const fn held(shown: u32, sample: u32) -> u32 {
    let distance = sample.abs_diff(shown);
    if distance >= PULSE_DEADBAND { sample } else { shown }
}

/// How loud a workspace-wide connection alert is, ascending.
///
/// Only three of the six [`StatusKind`]s raise the collapsed-sidebar indicator at all: a
/// `Connecting` first dial, a deliberate `Disconnected`, and a live `Connected` are not alarms.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum AlertSeverity {
    /// A transport drop the supervisor is retrying — recovering, not down.
    Reconnecting = 0,
    /// The initial connect refused or timed out.
    Failed = 1,
    /// The reconnect campaign gave up after the dead-host timeout.
    Unreachable = 2,
}

impl AlertSeverity {
    /// The byte a severity reports as.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// The word the chip says this severity with.
    ///
    /// `Failed` reads as "disconnected" rather than "failed": to the user an initial connect that
    /// never landed IS being disconnected, and the distinction between it and a mid-session drop is
    /// carried by the fact that this one is not counting attempts.
    #[must_use]
    pub const fn word(self) -> &'static str {
        match self {
            Self::Reconnecting => "reconnecting",
            Self::Failed => "disconnected",
            Self::Unreachable => "unreachable",
        }
    }
}

/// The compact fold of every live pane's connection status — "is anything wrong, how bad, and which
/// pane is the click target".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Alert {
    /// How many panes are unhealthy, at any severity.
    pub count: usize,
    /// The most salient severity across them, which is the indicator's ink.
    pub worst: AlertSeverity,
    /// The position, in the caller's own order, of the pane the indicator focuses on click.
    pub worst_index: usize,
}

/// One status's alert severity, or `None` when it is healthy or simply not an alarm.
#[must_use]
pub const fn alert_severity(status: StatusKind) -> Option<AlertSeverity> {
    match status {
        StatusKind::Reconnecting => Some(AlertSeverity::Reconnecting),
        StatusKind::Failed => Some(AlertSeverity::Failed),
        StatusKind::Unreachable => Some(AlertSeverity::Unreachable),
        StatusKind::Disconnected | StatusKind::Connecting | StatusKind::Connected => None,
    }
}

/// Folds live per-pane statuses into an alert, or `None` when no pane is unhealthy.
///
/// `statuses` must be in a STABLE order — the store passes tree DFS order — because the tie-break
/// is positional: a strictly higher severity supersedes the current worst, and a tie keeps the
/// EARLIER pane, so a click lands on the first pane at the worst severity rather than on whichever
/// one the iteration happened to reach last.
#[must_use]
pub fn alert(statuses: &[StatusKind]) -> Option<Alert> {
    let mut count = 0;
    let mut found: Option<(AlertSeverity, usize)> = None;
    for (index, status) in statuses.iter().enumerate() {
        let Some(severity) = alert_severity(*status) else {
            continue;
        };
        count += 1;
        if found.is_none_or(|(worst, _)| severity > worst) {
            found = Some((severity, index));
        }
    }
    let (worst, worst_index) = found?;
    Some(Alert {
        count,
        worst,
        worst_index,
    })
}

/// The chip's whole label: the unhealthy count and the worst severity's word.
#[must_use]
pub fn alert_label(alert: Alert) -> String {
    format!("{} {}", alert.count, alert.worst.word())
}

/// Half-away-from-zero, the rounding `Foundation` does, kept out of the `as` cast lints' way.
fn round_to_i64(value: f64) -> i64 {
    let rounded = value.round();
    if rounded.is_finite() && rounded.abs() < 9.0e18 {
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the magnitude was just bounded well inside i64"
        )]
        let out = rounded as i64;
        out
    } else {
        0
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Alarm, Alert, AlertSeverity, DISK_CRITICAL_MIB, DISK_WARN_MIB, Led, MemoryPressure, Metric, Mount,
        NetworkHealth, PING_GOOD_MS, PING_SLOW_MS, PULSE_DEADBAND, Pulse, StatusKind, TrailingSlot, alert,
        alert_label, bitrate_label, detail_alarm, disk_alarm, disk_label, friendly_failure, has_raw_detail,
        headline, health, led_state, link_alarm, memory_alarm, metric_runs, ping_label, promoted_runs,
        promotes, pulse_spoken, pulse_tooltip, settled, short_label, shows_retry, status_label,
        tooltip_detail, trailing_slot,
    };

    fn pulse(cpu: u32, memory: u32, pressure: MemoryPressure, disk: Option<u32>) -> Pulse {
        Pulse {
            cpu_percent: cpu,
            memory_percent: memory,
            memory_pressure: pressure,
            disk_free_mib: disk,
        }
    }

    #[test]
    fn the_round_trip_is_classified_at_its_two_thresholds() {
        assert_eq!(health(false, Some(5.0)), NetworkHealth::Offline);
        assert_eq!(
            health(true, None),
            NetworkHealth::Good,
            "connected with no sample says nothing is wrong YET, not that nothing is known"
        );
        assert_eq!(health(true, Some(PING_GOOD_MS)), NetworkHealth::Good);
        assert_eq!(health(true, Some(PING_GOOD_MS + 0.1)), NetworkHealth::Slow);
        assert_eq!(health(true, Some(PING_SLOW_MS)), NetworkHealth::Slow);
        assert_eq!(health(true, Some(PING_SLOW_MS + 0.1)), NetworkHealth::Bad);
    }

    #[test]
    fn a_stale_ping_cannot_brighten_a_link_that_is_down() {
        for status in [
            StatusKind::Disconnected,
            StatusKind::Unreachable,
            StatusKind::Failed,
        ] {
            assert_eq!(led_state(status, Some(1.0)), Led::Dim);
        }
        for status in [StatusKind::Connecting, StatusKind::Reconnecting] {
            assert_eq!(led_state(status, Some(1.0)), Led::Dialing);
        }
    }

    #[test]
    fn a_connected_link_rides_the_ping_classifier() {
        assert_eq!(led_state(StatusKind::Connected, None), Led::Good);
        assert_eq!(led_state(StatusKind::Connected, Some(10.0)), Led::Good);
        assert_eq!(led_state(StatusKind::Connected, Some(100.0)), Led::Slow);
        assert_eq!(led_state(StatusKind::Connected, Some(500.0)), Led::Bad);
    }

    #[test]
    fn only_a_degraded_link_climbs() {
        assert_eq!(link_alarm(Led::Slow), Alarm::Raised);
        assert_eq!(link_alarm(Led::Bad), Alarm::Loud);
        for led in [Led::Dim, Led::Dialing, Led::Good] {
            assert_eq!(
                link_alarm(led),
                Alarm::Quiet,
                "an instrument with nothing to measure has nothing to shout about"
            );
        }
    }

    #[test]
    fn memory_climbs_on_the_kernels_verdict_and_never_on_the_percent() {
        assert_eq!(memory_alarm(MemoryPressure::Normal), Alarm::Quiet);
        assert_eq!(memory_alarm(MemoryPressure::Warn), Alarm::Raised);
        assert_eq!(memory_alarm(MemoryPressure::Critical), Alarm::Loud);
        // 97 % in use with a calm kernel is an ordinary Mac, and the run stays grey.
        let runs = metric_runs(pulse(20, 97, MemoryPressure::Normal, None));
        assert_eq!(runs.get(1).map(|run| run.alarm), Some(Alarm::Quiet));
    }

    #[test]
    fn disk_climbs_on_bytes_left_and_an_unreadable_volume_is_quiet() {
        assert_eq!(disk_alarm(None), Alarm::Quiet);
        assert_eq!(disk_alarm(Some(DISK_CRITICAL_MIB - 1)), Alarm::Loud);
        assert_eq!(disk_alarm(Some(DISK_CRITICAL_MIB)), Alarm::Raised);
        assert_eq!(disk_alarm(Some(DISK_WARN_MIB - 1)), Alarm::Raised);
        assert_eq!(disk_alarm(Some(DISK_WARN_MIB)), Alarm::Quiet);
    }

    #[test]
    fn the_cpu_run_never_climbs() {
        let runs = metric_runs(pulse(100, 10, MemoryPressure::Normal, None));
        assert_eq!(
            runs.first().map(|run| run.alarm),
            Some(Alarm::Quiet),
            "a build pegging the host is what the machine is FOR"
        );
    }

    #[test]
    fn the_disk_figure_is_four_characters_at_every_scale() {
        assert_eq!(disk_label(820), "820M");
        assert_eq!(disk_label(1024), "1.0G");
        assert_eq!(disk_label(6 * 1024 + 410), "6.4G");
        assert_eq!(disk_label(42 * 1024), "42G");
        assert_eq!(disk_label(240 * 1024), "240G");
        assert_eq!(disk_label(2150 * 1024), "2.1T");
        // The two lips, pinned as the FIVE they are: asserting four everywhere would be a claim the
        // original never made either, and the port's job is to be indistinguishable from it.
        // The three lips, pinned as the FIVE they are: asserting four everywhere would be a claim
        // the original never made either, and the port's job is to be indistinguishable from it.
        assert_eq!(disk_label(1023), "1023M");
        assert_eq!(disk_label(10_239), "10.0G");
        assert_eq!(disk_label(1_048_575), "1024G");
        // A u32 of MiB reaches four PEBIbytes, which no rail was ever sized for and no volume this
        // app will meet reports. Pinned rather than excluded so the top of the range has a stated
        // answer instead of an assumed one — and it is the original's answer.
        assert_eq!(disk_label(u32::MAX), "4096.0T");
        for mib in [0_u32, 1, 999, 1024, 10_240, 1_048_576] {
            let drawn = disk_label(mib);
            assert!(
                drawn.len() <= 4,
                "{mib} MiB drew {drawn} — away from the rounding lips the rail gets four"
            );
        }
    }

    #[test]
    fn the_bitrate_changes_unit_at_a_megabit() {
        assert_eq!(bitrate_label(0), "0 kbps");
        assert_eq!(bitrate_label(999), "999 kbps");
        assert_eq!(bitrate_label(1000), "1.0 Mbps");
        assert_eq!(bitrate_label(12_400), "12.4 Mbps");
    }

    #[test]
    fn the_ping_reads_in_whole_milliseconds() {
        assert_eq!(ping_label(0.4), "0 ms");
        assert_eq!(ping_label(12.5), "13 ms");
        assert_eq!(ping_label(180.0), "180 ms");
    }

    #[test]
    fn the_pulse_draws_fastest_moving_first_and_drops_an_unreadable_volume() {
        let runs = metric_runs(pulse(31, 62, MemoryPressure::Normal, Some(42 * 1024)));
        assert_eq!(runs.iter().map(|run| run.metric).collect::<Vec<_>>(), vec![
            Metric::Cpu,
            Metric::Memory,
            Metric::Disk
        ]);
        assert_eq!(runs.get(2).map(|run| run.value.as_str()), Some("42G"));
        let no_volume = metric_runs(pulse(31, 62, MemoryPressure::Normal, None));
        assert_eq!(no_volume.len(), 2, "one missing metric closes its gap");
    }

    #[test]
    fn a_one_line_mount_shows_nothing_while_the_host_is_calm() {
        assert!(promoted_runs(pulse(99, 99, MemoryPressure::Normal, Some(500 * 1024))).is_empty());
        // …and never goes silent on a state the bedded island escalates.
        let alarmed = promoted_runs(pulse(10, 10, MemoryPressure::Critical, Some(100)));
        assert_eq!(alarmed.iter().map(|run| run.metric).collect::<Vec<_>>(), vec![
            Metric::Memory,
            Metric::Disk
        ]);
        assert!(alarmed.iter().all(|run| promotes(run.alarm)));
    }

    /// The gate may only DROP. If it could ever produce a reading of its own, the two mounts would
    /// be free to disagree about what the host is doing — which is the whole reason it is the
    /// ladder read as a yes/no rather than a second threshold beside it.
    #[test]
    fn the_one_line_mount_is_a_subsequence_of_the_two_line_one() {
        for pressure in [
            MemoryPressure::Normal,
            MemoryPressure::Warn,
            MemoryPressure::Critical,
        ] {
            for disk in [None, Some(0), Some(3072), Some(15360), Some(245_760)] {
                let sample = pulse(42, 77, pressure, disk);
                let kept: Vec<_> = metric_runs(sample)
                    .into_iter()
                    .filter(|run| promotes(run.alarm))
                    .collect();
                assert_eq!(promoted_runs(sample), kept);
            }
        }
    }

    #[test]
    fn only_a_compact_mount_may_stay_silent_before_the_first_sample() {
        assert_eq!(
            trailing_slot(StatusKind::Connected, false, Mount::Compact),
            TrailingSlot::Absent
        );
        assert_eq!(
            trailing_slot(StatusKind::Connected, false, Mount::Bedded),
            TrailingSlot::StatusWord,
            "a bed with an empty right edge reads as broken"
        );
        for mount in [Mount::Bedded, Mount::Compact] {
            assert_eq!(
                trailing_slot(StatusKind::Connected, true, mount),
                TrailingSlot::Ping
            );
            assert_eq!(
                trailing_slot(StatusKind::Disconnected, true, mount),
                TrailingSlot::StatusWord,
                "never a stale ping"
            );
        }
    }

    #[test]
    fn only_the_ping_digits_climb_and_never_the_status_word() {
        assert_eq!(detail_alarm(TrailingSlot::Ping, Led::Bad), Alarm::Loud);
        assert_eq!(detail_alarm(TrailingSlot::StatusWord, Led::Bad), Alarm::Quiet);
        assert_eq!(detail_alarm(TrailingSlot::Absent, Led::Bad), Alarm::Quiet);
    }

    #[test]
    fn retry_is_offered_only_where_no_campaign_is_running() {
        assert!(shows_retry(StatusKind::Failed));
        assert!(shows_retry(StatusKind::Unreachable));
        for status in [
            StatusKind::Disconnected,
            StatusKind::Connecting,
            StatusKind::Connected,
            StatusKind::Reconnecting,
        ] {
            assert!(
                !shows_retry(status),
                "a campaign in flight already has a retry, and a second one races it"
            );
        }
    }

    #[test]
    fn every_failure_shape_gets_its_own_remedy() {
        let cases = [
            ("POSIXErrorCode(rawValue: 61): Connection refused", "refused"),
            ("No route to host", "No route"),
            ("The request timed out.", "Timed out"),
            ("Network is down", "Network is down"),
            ("NSURLErrorDomain nosuchrecord", "Hostname not found"),
            ("Connection reset by peer", "Connection reset"),
            ("handshakeFailed: bad preamble", "compatible slopdesk host"),
            ("Connection lost", "Connection lost —"),
            ("Connection failed", "Couldn't reach the host"),
        ];
        for (raw, expected) in cases {
            let answer = friendly_failure(raw);
            assert!(
                answer.contains(expected),
                "{raw:?} answered {answer:?}, which does not name {expected:?}"
            );
            assert_ne!(answer, raw, "{raw:?} should have been rewritten");
        }
    }

    #[test]
    fn an_unrecognised_payload_passes_through_verbatim() {
        let raw = "SomeFutureError(code: 4211)";
        assert_eq!(friendly_failure(raw), raw, "never hide what cannot be improved");
        assert!(
            !has_raw_detail(StatusKind::Failed, raw),
            "a passthrough tooltip would just duplicate the headline"
        );
        assert!(has_raw_detail(StatusKind::Failed, "Connection refused"));
        assert!(
            !has_raw_detail(StatusKind::Connected, "Connection refused"),
            "only a FAILED status has a raw payload to show"
        );
    }

    #[test]
    fn a_refusal_reads_as_one_even_though_it_also_says_connection() {
        // "Connection refused" contains neither "connection lost" nor equals "connection failed",
        // but the ordering is what keeps the overlapping families apart at all.
        assert!(friendly_failure("Connection refused").contains("refused"));
        assert!(friendly_failure("Connection closed by peer").contains("Connection lost —"));
    }

    #[test]
    fn the_campaign_reads_honestly_in_both_registers() {
        assert_eq!(headline(StatusKind::Reconnecting, 0, 20, ""), "Reconnecting…");
        assert_eq!(
            headline(StatusKind::Reconnecting, 3, 20, ""),
            "Reconnecting — attempt 3 of 20"
        );
        assert_eq!(short_label(StatusKind::Reconnecting, 3, 20), "reconnecting 3/20");
        assert_eq!(short_label(StatusKind::Reconnecting, 0, 20), "reconnecting");
        assert_eq!(status_label(StatusKind::Reconnecting, 3, ""), "reconnecting (3)");
    }

    #[test]
    fn a_failure_never_dumps_its_payload_into_a_menu_bar_label() {
        let raw = "POSIXErrorCode(rawValue: 61): Connection refused";
        assert_eq!(short_label(StatusKind::Failed, 0, 20), "failed");
        assert!(headline(StatusKind::Failed, 0, 20, raw).contains("slopdesk-hostd"));
        assert_eq!(status_label(StatusKind::Failed, 0, raw), format!("failed: {raw}"));
    }

    #[test]
    fn the_prose_registers_agree_about_what_the_pulse_says() {
        let sample = pulse(31, 62, MemoryPressure::Critical, Some(42 * 1024));
        assert_eq!(pulse_spoken(sample), "cpu 31%, mem 62%, 42G free");
        assert_eq!(
            pulse_tooltip(sample),
            " · cpu 31% · mem 62% (memory pressure critical) · 42G free"
        );
        let no_volume = pulse(31, 62, MemoryPressure::Normal, None);
        assert_eq!(pulse_spoken(no_volume), "cpu 31%, mem 62%");
        assert_eq!(pulse_tooltip(no_volume), " · cpu 31% · mem 62%");
    }

    #[test]
    fn the_stream_numbers_are_a_tooltip_and_each_one_is_optional() {
        assert_eq!(tooltip_detail(None, None), "");
        assert_eq!(tooltip_detail(Some(60), None), " · 60 fps");
        assert_eq!(tooltip_detail(None, Some(12_400)), " · 12.4 Mbps");
        assert_eq!(tooltip_detail(Some(60), Some(12_400)), " · 60 fps · 12.4 Mbps");
    }

    #[test]
    fn every_status_byte_round_trips() {
        for status in StatusKind::ALL {
            assert_eq!(StatusKind::from_byte(status.as_byte()), status);
        }
        assert_eq!(StatusKind::from_byte(200), StatusKind::Disconnected);
    }

    #[test]
    fn the_three_roles_differ_in_name_as_well_as_in_silhouette() {
        let names = [Metric::Cpu, Metric::Memory, Metric::Disk].map(Metric::symbol_name);
        assert_eq!(names, ["cpu", "memorychip", "internaldrive"]);
    }

    #[test]
    fn the_first_sample_is_shown_exactly_as_it_arrived() {
        let sample = pulse(31, 62, MemoryPressure::Warn, Some(900));
        assert_eq!(settled(None, sample), sample);
    }

    #[test]
    fn a_move_under_the_deadband_leaves_the_shown_figure_alone() {
        let shown = pulse(31, 62, MemoryPressure::Normal, Some(900));
        let jitter = pulse(
            31 + PULSE_DEADBAND - 1,
            62 - PULSE_DEADBAND + 1,
            MemoryPressure::Normal,
            Some(880),
        );
        let held = settled(Some(shown), jitter);
        assert_eq!(held.cpu_percent, 31);
        assert_eq!(held.memory_percent, 62);
    }

    /// The deadband decides WHETHER to redraw, never WHAT to draw: once a metric has earned its
    /// redraw it prints the sample itself, so the row can only ever show a percent the host sent.
    #[test]
    fn a_move_at_the_deadband_snaps_to_the_sample_and_never_to_a_midpoint() {
        let shown = pulse(31, 62, MemoryPressure::Normal, None);
        let climbed = pulse(
            31 + PULSE_DEADBAND,
            62 - PULSE_DEADBAND,
            MemoryPressure::Normal,
            None,
        );
        let held = settled(Some(shown), climbed);
        assert_eq!(held.cpu_percent, 31 + PULSE_DEADBAND);
        assert_eq!(held.memory_percent, 62 - PULSE_DEADBAND);
    }

    /// A pressure LEVEL is a state, and a state change is never noise — it lands on the sample that
    /// carried it even while both percents are being held still.
    #[test]
    fn pressure_and_disk_cross_the_deadband_untouched() {
        let shown = pulse(31, 62, MemoryPressure::Normal, Some(900));
        let sample = pulse(32, 61, MemoryPressure::Critical, Some(120));
        let held = settled(Some(shown), sample);
        assert_eq!(held.cpu_percent, 31, "the percent is still being held");
        assert_eq!(held.memory_pressure, MemoryPressure::Critical);
        assert_eq!(held.disk_free_mib, Some(120));
    }

    #[test]
    fn a_healthy_workspace_raises_nothing() {
        let statuses = [
            StatusKind::Connected,
            StatusKind::Connecting,
            StatusKind::Disconnected,
        ];
        assert!(alert(&statuses).is_none());
        assert!(alert(&[]).is_none());
    }

    #[test]
    fn the_alert_counts_every_unhealthy_pane_and_names_the_loudest() {
        let statuses = [
            StatusKind::Connected,
            StatusKind::Reconnecting,
            StatusKind::Unreachable,
            StatusKind::Failed,
        ];
        assert_eq!(
            alert(&statuses),
            Some(Alert {
                count: 3,
                worst: AlertSeverity::Unreachable,
                worst_index: 2
            }),
        );
    }

    /// The click target has to be stable across a redraw that changed nothing, so a tie keeps the
    /// pane the caller listed first rather than the one the walk reached last.
    #[test]
    fn a_tie_at_the_worst_severity_keeps_the_earlier_pane() {
        let statuses = [StatusKind::Connected, StatusKind::Failed, StatusKind::Failed];
        assert_eq!(
            alert(&statuses),
            Some(Alert {
                count: 2,
                worst: AlertSeverity::Failed,
                worst_index: 1
            }),
        );
    }

    #[test]
    fn the_chip_counts_panes_and_speaks_the_worst_severitys_word() {
        let one = |kind| alert(&[kind]).map(alert_label).unwrap_or_default();
        assert_eq!(one(StatusKind::Reconnecting), "1 reconnecting");
        assert_eq!(
            one(StatusKind::Failed),
            "1 disconnected",
            "a connect that never landed IS disconnected"
        );
        assert_eq!(one(StatusKind::Unreachable), "1 unreachable");
        let two = alert(&[StatusKind::Reconnecting, StatusKind::Reconnecting]);
        assert_eq!(two.map(alert_label).unwrap_or_default(), "2 reconnecting");
    }
}
