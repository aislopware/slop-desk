//! The host's side of the window feed: what to list, how to pack it, who to push it to, and when.
//!
//! The enumeration glue reads the window server into [`WindowFeedSourceWindow`]s and everything
//! from there — inclusion, flags, caps, ordering, generations, chunking, subscribers, tick pacing —
//! is deterministic and testable with no window server behind it.
//!
//! No clock lives here either: every rule that needs time takes `now`, so the whole feed is a
//! function of what the caller observed.

use std::collections::BTreeMap;

use crate::video_control::{HostWindowFlags, HostWindowRecord, VideoControlMessage};

/// One raw host window as the enumeration glue sees it.
///
/// Array order is the enumeration's z-order, front to back, and every rule here preserves it.
#[expect(
    clippy::struct_excessive_bools,
    reason = "these ARE the probes the enumeration glue ran, each independently answerable and each \
              independently missing — folding them into enums would invent states nothing reports"
)]
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WindowFeedSourceWindow {
    /// The window server's id.
    pub window_id: u32,
    /// The owning app's name, empty when absent — the inclusion key.
    pub owner_name: String,
    /// The owning app's bundle identifier, empty when the process has none — the icon cache key.
    pub bundle_id: String,
    /// The window layer. Only layer 0, normal app windows, is listable.
    pub layer: i32,
    /// Whether the window server calls it on-screen. False means minimized, another Space, or a
    /// hidden app.
    pub is_on_screen: bool,
    /// The window title, empty when absent.
    pub title: String,
    /// Width in points.
    pub width_pt: i32,
    /// Height in points.
    pub height_pt: i32,
    /// Ordinal of the display whose bounds best contain the window; 0 when unknown or single.
    pub display_index: u8,
    /// Whether the owning app is hidden, best-effort.
    pub is_app_hidden: bool,
    /// Whether the owning app is frontmost.
    pub is_frontmost_app: bool,
    /// Whether accessibility reports the window minimized, best-effort and budgeted.
    pub is_minimized: bool,
    /// Whether the accessibility probe has seen this window in its app's window list, best-effort
    /// and budgeted. Off-screen windows need this evidence to be listed — see [`snapshot_records`].
    pub is_ax_listed: bool,
}

/// Apps whose windows are never useful to stream: desktop chrome and indicators.
///
/// "Cua Driver" is an automation agent's transparent full-display cursor overlay — a real
/// on-screen, layer-0 window with nothing visible in it, so it has to be excluded by name; no
/// visual heuristic would catch it.
pub const EXCLUDED_SYSTEM_APPS: [&str; 8] = [
    "",
    "Window Server",
    "Control Center",
    "Dock",
    "Notification Center",
    "Spotlight",
    "Wallpaper",
    "Cua Driver",
];

/// Phantom utility windows that survive the off-screen evidence gate because their app genuinely
/// lists them, yet they never render: the App Store receipt verifier Finder owns.
///
/// Keyed by owner so it stays surgical — real windows of the same app are untouched.
const JUNK_TITLES_BY_OWNER: [(&str, &str); 1] = [("Finder", "asverify")];

/// Windows smaller than this in either axis are indicators and popups, not streamable windows.
pub const MIN_DIMENSION_PT: i32 = 80;

/// The ONE inclusion verdict, shared by the picker and the feed so the two surfaces cannot drift.
#[must_use]
pub fn includes_window(owner_name: &str, title: &str, width_pt: i32, height_pt: i32) -> bool {
    !EXCLUDED_SYSTEM_APPS.contains(&owner_name)
        && !JUNK_TITLES_BY_OWNER
            .iter()
            .any(|&(owner, junk)| owner == owner_name && junk == title)
        && width_pt >= MIN_DIMENSION_PT
        && height_pt >= MIN_DIMENSION_PT
}

/// The post-filter record cap. Typical desktops list under forty; revisit only on evidence.
pub const MAX_RECORDS: usize = 64;
/// The wire cap for a record's bundle identifier.
pub const BUNDLE_ID_MAX_BYTES: usize = 128;
/// The wire cap for a record's app name.
pub const APP_NAME_MAX_BYTES: usize = 64;

/// Truncates to at most `max_bytes` of UTF-8 without ever splitting a scalar.
///
/// A split scalar would decode client-side as a replacement character. The cap also bounds the
/// worst-case record size, so the greedy chunk packer always makes progress.
///
/// The Swift dropped whole grapheme CLUSTERS; this drops whole scalars. Both honour the rule that
/// matters — a truncation is always valid UTF-8 — and they differ only for a cluster straddling the
/// cap, where this leaves the cluster's leading scalars and the row renders them as their parts.
#[must_use]
pub fn truncated_utf8(string: &str, max_bytes: usize) -> String {
    if string.len() <= max_bytes {
        return string.to_owned();
    }
    let mut end = max_bytes;
    while end > 0 && !string.is_char_boundary(end) {
        end -= 1;
    }
    string.get(..end).unwrap_or_default().to_owned()
}

/// Maps raw enumeration windows to one snapshot's wire records, preserving z-order.
///
/// Off-screen windows need accessibility EVIDENCE to be listed: the full enumeration is thick with
/// phantoms — tab caches, panel services, the login window — that would otherwise drown the rail. A
/// REAL off-screen window, minimized or on another Space or belonging to a hidden app, appears in
/// its app's window list; a phantom cache never does. Alpha and sharing state are not usable
/// signals, since phantoms report exactly what real windows report. The cost is cold: a real
/// off-screen window can hide for the probe's first few budgeted ticks before it appears, and
/// junk-free beats instant.
#[must_use]
pub fn snapshot_records(windows: &[WindowFeedSourceWindow]) -> Vec<HostWindowRecord> {
    let mut out = Vec::new();
    // Exactly ONE record carries the focused bit: the frontmost app's first on-screen window in
    // z-order. The enumeration lists front to back, so the first hit IS the focused one.
    let mut focused_assigned = false;
    for window in windows {
        if window.layer != 0
            || !includes_window(
                &window.owner_name,
                &window.title,
                window.width_pt,
                window.height_pt,
            )
        {
            continue;
        }
        if !(window.is_on_screen || window.is_minimized || window.is_ax_listed) {
            continue;
        }
        let mut flags = HostWindowFlags::from_bits(0);
        if window.is_on_screen {
            flags = flags.union(HostWindowFlags::ON_SCREEN);
        }
        if window.is_minimized {
            flags = flags.union(HostWindowFlags::MINIMIZED);
        }
        if window.is_app_hidden {
            flags = flags.union(HostWindowFlags::APP_HIDDEN);
        }
        if window.is_frontmost_app {
            flags = flags.union(HostWindowFlags::FRONTMOST_APP);
        }
        if window.is_frontmost_app && window.is_on_screen && !focused_assigned {
            flags = flags.union(HostWindowFlags::FOCUSED_WINDOW);
            focused_assigned = true;
        }
        out.push(HostWindowRecord {
            window_id: window.window_id,
            width_pt: clamp_to_u16(window.width_pt),
            height_pt: clamp_to_u16(window.height_pt),
            flags,
            display_index: window.display_index,
            bundle_id: truncated_utf8(&window.bundle_id, BUNDLE_ID_MAX_BYTES),
            app_name: truncated_utf8(&window.owner_name, APP_NAME_MAX_BYTES),
            title: truncated_utf8(&window.title, VideoControlMessage::FEED_TITLE_MAX_BYTES),
        });
        if out.len() >= MAX_RECORDS {
            break;
        }
    }
    out
}

/// Saturating, both ways — a negative point size is nonsense the enumeration occasionally reports.
fn clamp_to_u16(value: i32) -> u16 {
    u16::try_from(value.clamp(0, i32::from(u16::MAX))).unwrap_or(u16::MAX)
}

/// The exact encoded size of one record: four bytes of id, two each of width and height, one of
/// flags, one of display, and three length-prefixed strings.
#[must_use]
pub const fn record_encoded_size(record: &HostWindowRecord) -> usize {
    14 + record.bundle_id.len() + record.app_name.len() + record.title.len()
}

/// Packs one snapshot's records into ready-to-send chunk payloads for `generation`.
///
/// The budget is BYTES, not records, because real titles run from fourteen to three hundred bytes a
/// row and a record count would either waste a datagram or overflow one. Every chunk's record bytes
/// fit [`VideoControlMessage::FEED_RECORD_BYTES_PER_CHUNK`], so every encoded chunk fits one
/// datagram.
///
/// ZERO records still yield ONE empty chunk: an empty desktop is a real snapshot, and the client
/// has to be able to assemble it.
#[must_use]
pub fn encoded_chunks(generation: u32, records: &[HostWindowRecord]) -> Vec<Vec<u8>> {
    let mut groups: Vec<Vec<HostWindowRecord>> = Vec::new();
    let mut current: Vec<HostWindowRecord> = Vec::new();
    let mut current_bytes = 0;
    for record in records {
        let size = record_encoded_size(record);
        if !current.is_empty() && current_bytes + size > VideoControlMessage::FEED_RECORD_BYTES_PER_CHUNK {
            groups.push(std::mem::take(&mut current));
            current_bytes = 0;
        }
        current.push(record.clone());
        current_bytes += size;
    }
    if !current.is_empty() || groups.is_empty() {
        groups.push(current);
    }
    // Sixty-four records cannot exceed sixty-four chunks; the clamp is a bound that never bites.
    let chunk_count = u8::try_from(groups.len()).unwrap_or(u8::MAX);
    groups
        .into_iter()
        .enumerate()
        .map(|(index, chunk_records)| {
            VideoControlMessage::WindowFeedSnapshot {
                generation,
                chunk_index: u8::try_from(index).unwrap_or(u8::MAX),
                chunk_count,
                records: chunk_records,
            }
            .encode()
        })
        .collect()
}

/// The host's ONE snapshot cache.
///
/// A time-to-live gates the build, so renewals, re-requests and several clients at once are all
/// answered from the same encoded bytes — the guard against amplifying one enumeration into many.
/// The generation bumps ONLY when the records actually changed, so an unchanged desktop answers
/// with the five-byte "you are current" reply instead of a snapshot.
#[derive(Debug, Clone, PartialEq)]
pub struct WindowFeedCache {
    generation: u32,
    records: Vec<HostWindowRecord>,
    encoded_chunks: Vec<Vec<u8>>,
    built_at: Option<f64>,
    ttl: f64,
}

/// What one subscribe is answered with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FeedReply {
    /// Whether these payloads are a full snapshot, which the sender duplicates on the wire.
    pub is_snapshot: bool,
    /// The payloads to send, empty only in the impossible never-built case.
    pub payloads: Vec<Vec<u8>>,
}

impl WindowFeedCache {
    /// A cache that has never built anything, answering subscribes for `ttl` seconds per build.
    #[must_use]
    pub const fn new(ttl: f64) -> Self {
        Self {
            // Zero is the wire's "the client has nothing" sentinel, so it is never published: the
            // counter starts at one and skips zero on wrap.
            generation: 0,
            records: Vec::new(),
            encoded_chunks: Vec::new(),
            built_at: None,
            ttl,
        }
    }

    /// The last published generation, zero when nothing has been built.
    #[must_use]
    pub const fn generation(&self) -> u32 {
        self.generation
    }

    /// The cached records.
    #[must_use]
    pub fn records(&self) -> &[HostWindowRecord] {
        &self.records
    }

    /// Whether the caller must enumerate and [`Self::fold`] before answering.
    #[must_use]
    pub fn needs_rebuild(&self, now: f64) -> bool {
        self.generation == 0 || self.built_at.is_none_or(|built| now - built >= self.ttl)
    }

    /// Folds a freshly built record set.
    ///
    /// The generation bumps and the chunks re-encode ONLY when the records differ from the cached
    /// set, or nothing was ever built; an identical set just refreshes the staleness stamp.
    pub fn fold(&mut self, fresh: Vec<HostWindowRecord>, now: f64) {
        self.built_at = Some(now);
        if self.generation != 0 && fresh == self.records {
            return;
        }
        self.generation = self.generation.wrapping_add(1);
        if self.generation == 0 {
            self.generation = 1;
        }
        self.encoded_chunks = encoded_chunks(self.generation, &fresh);
        self.records = fresh;
    }

    /// The datagrams answering one subscribe carrying the client's known generation.
    #[must_use]
    pub fn reply(&self, known_generation: u32) -> FeedReply {
        if self.generation == 0 {
            return FeedReply {
                is_snapshot: false,
                payloads: Vec::new(),
            };
        }
        if known_generation == self.generation {
            return FeedReply {
                is_snapshot: false,
                payloads: vec![
                    VideoControlMessage::WindowFeedCurrent {
                        generation: self.generation,
                    }
                    .encode(),
                ],
            };
        }
        FeedReply {
            is_snapshot: true,
            payloads: self.encoded_chunks.clone(),
        }
    }
}

/// Who is subscribed to the feed: a channel id against its last renewal stamp.
///
/// A subscriber lives its time-to-live past the last renewal — three missed renewals — and expiry
/// hands the caller the ids to retire. The table is BOUNDED: a spray of distinct channel ids is
/// capped and the newest refused, quietly.
#[derive(Debug, Clone, PartialEq)]
pub struct WindowFeedSubscriberTable {
    last_renewal: BTreeMap<u32, f64>,
    ttl: f64,
    capacity: usize,
}

impl WindowFeedSubscriberTable {
    /// An empty table.
    #[must_use]
    pub const fn new(ttl: f64, capacity: usize) -> Self {
        Self {
            last_renewal: BTreeMap::new(),
            ttl,
            capacity: if capacity > 1 { capacity } else { 1 },
        }
    }

    /// Whether nobody is subscribed.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.last_renewal.is_empty()
    }

    /// How many entries the table holds, expired ones included until they are reaped.
    #[must_use]
    pub fn len(&self) -> usize {
        self.last_renewal.len()
    }

    /// Records a renewal.
    ///
    /// False means the table was full of FRESH subscribers and this id is new, so it was refused.
    /// An existing id always refreshes.
    pub fn renew(&mut self, channel_id: u32, now: f64) -> bool {
        if let Some(stamp) = self.last_renewal.get_mut(&channel_id) {
            *stamp = now;
            return true;
        }
        if self.last_renewal.len() >= self.capacity {
            self.last_renewal.retain(|_, stamp| now - *stamp < self.ttl);
            if self.last_renewal.len() >= self.capacity {
                return false;
            }
        }
        self.last_renewal.insert(channel_id, now);
        true
    }

    /// Drops every expired subscriber and returns their ids, so the caller can retire those lanes.
    pub fn reap_expired(&mut self, now: f64) -> Vec<u32> {
        let expired: Vec<u32> = self
            .last_renewal
            .iter()
            .filter(|&(_, &stamp)| now - stamp >= self.ttl)
            .map(|(&id, _)| id)
            .collect();
        for id in &expired {
            self.last_renewal.remove(id);
        }
        expired
    }

    /// The live subscriber ids — the push targets.
    #[must_use]
    pub fn subscribers(&self, now: f64) -> Vec<u32> {
        self.last_renewal
            .iter()
            .filter(|&(_, &stamp)| now - stamp < self.ttl)
            .map(|(&id, _)| id)
            .collect()
    }
}

/// What changed between the cached records and a freshly built set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FeedChange {
    /// Nothing at all.
    None,
    /// The window set, a visibility bit or a size moved — fold NOW and open the burst.
    Structural,
    /// Only what the client renders volatile moved: titles, focus bits, z-order, display ordinals.
    VolatileOnly {
        /// Whether a title was among them, which coalesces on the slower gate.
        title_changed: bool,
    },
}

/// The idle tick, in seconds.
pub const IDLE_TICK: f64 = 1.0;
/// The tick inside a structural burst, in seconds.
pub const BURST_TICK: f64 = 0.25;
/// How long a structural change keeps the differ in burst, in seconds.
pub const BURST_WINDOW: f64 = 3.0;
/// The coalesce gate for a title-only change, in seconds.
pub const TITLE_COALESCE: f64 = 2.0;
/// The coalesce gate for a focus- or order-only change, in seconds.
pub const FOCUS_COALESCE: f64 = 1.0;

/// The bits whose movement makes a change structural.
const STRUCTURAL_BITS: u8 = HostWindowFlags::ON_SCREEN.bits()
    | HostWindowFlags::MINIMIZED.bits()
    | HostWindowFlags::APP_HIDDEN.bits();

/// Classifies the difference between two record sets.
///
/// Structural means the id SET, any window's visibility, or any window's size changed. Everything
/// else the client treats as volatile.
#[must_use]
pub fn classify_change(old: &[HostWindowRecord], new: &[HostWindowRecord]) -> FeedChange {
    if old == new {
        return FeedChange::None;
    }
    if skeleton(old) != skeleton(new) {
        return FeedChange::Structural;
    }
    FeedChange::VolatileOnly {
        title_changed: titles(old) != titles(new),
    }
}

/// Each window's structural identity: its size and its visibility bits, keyed by id.
fn skeleton(records: &[HostWindowRecord]) -> BTreeMap<u32, (u16, u16, u8)> {
    records
        .iter()
        .map(|record| {
            (
                record.window_id,
                (
                    record.width_pt,
                    record.height_pt,
                    record.flags.bits() & STRUCTURAL_BITS,
                ),
            )
        })
        .collect()
}

/// Each window's title, keyed by id.
fn titles(records: &[HostWindowRecord]) -> BTreeMap<u32, &str> {
    records
        .iter()
        .map(|record| (record.window_id, record.title.as_str()))
        .collect()
}

/// The differ's tick and fold policy.
///
/// Idle at 1 Hz, four times that for three seconds after a structural change, with title-only and
/// focus-only changes coalesced so churn can neither enter the burst nor flood generations.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct WindowFeedPushPolicy {
    burst_until: Option<f64>,
    last_volatile_fold: Option<f64>,
}

/// A policy's two stamps, so a caller that has to hold it flat can put it back exactly.
///
/// Absence is spelled with `Option` rather than a sentinel: `now` is the caller's clock and a
/// negative one is legal, so any sentinel would read as a live burst on some clock.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct PushPolicyState {
    /// When the structural burst ends, if one is open.
    pub burst_until: Option<f64>,
    /// When the last volatile change folded, if one has.
    pub last_volatile_fold: Option<f64>,
}

impl WindowFeedPushPolicy {
    /// A policy that has seen no change yet.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            burst_until: None,
            last_volatile_fold: None,
        }
    }

    /// The two stamps this policy is carrying.
    #[must_use]
    pub const fn state(&self) -> PushPolicyState {
        PushPolicyState {
            burst_until: self.burst_until,
            last_volatile_fold: self.last_volatile_fold,
        }
    }

    /// The policy those two stamps describe.
    #[must_use]
    pub const fn restored(state: PushPolicyState) -> Self {
        Self {
            burst_until: state.burst_until,
            last_volatile_fold: state.last_volatile_fold,
        }
    }

    /// Whether this change may fold into the cache NOW, bumping the generation and so pushing.
    ///
    /// A structural change always folds and opens the burst window. A volatile-only change folds
    /// only once its coalesce gate has elapsed since the last volatile fold.
    pub fn should_fold(&mut self, change: FeedChange, now: f64) -> bool {
        match change {
            FeedChange::None => false,
            FeedChange::Structural => {
                self.burst_until = Some(now + BURST_WINDOW);
                true
            },
            FeedChange::VolatileOnly { title_changed } => {
                let gate = if title_changed {
                    TITLE_COALESCE
                } else {
                    FOCUS_COALESCE
                };
                if self.last_volatile_fold.is_some_and(|last| now - last < gate) {
                    return false;
                }
                self.last_volatile_fold = Some(now);
                true
            },
        }
    }

    /// The differ's next tick interval. At most one fold per tick, so the push pacing follows.
    #[must_use]
    pub fn tick_interval(&self, now: f64) -> f64 {
        if self.burst_until.is_some_and(|until| now < until) {
            BURST_TICK
        } else {
            IDLE_TICK
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "the tick intervals are the pinned constants themselves, and an out-of-range index in a \
                  test is the failure report rather than a runtime fault"
    )]

    use super::{
        APP_NAME_MAX_BYTES, BURST_TICK, FeedChange, IDLE_TICK, MAX_RECORDS, WindowFeedCache,
        WindowFeedPushPolicy, WindowFeedSourceWindow, WindowFeedSubscriberTable, classify_change,
        encoded_chunks, includes_window, snapshot_records, truncated_utf8,
    };
    use crate::video_control::{HostWindowFlags, HostWindowRecord, VideoControlMessage};

    /// A listable window: layer 0, on screen, big enough, with a title.
    fn source(window_id: u32, owner: &str, title: &str) -> WindowFeedSourceWindow {
        WindowFeedSourceWindow {
            window_id,
            owner_name: owner.to_owned(),
            bundle_id: format!("com.example.{owner}"),
            layer: 0,
            is_on_screen: true,
            title: title.to_owned(),
            width_pt: 800,
            height_pt: 600,
            ..WindowFeedSourceWindow::default()
        }
    }

    fn record(window_id: u32, title: &str) -> HostWindowRecord {
        HostWindowRecord {
            window_id,
            width_pt: 800,
            height_pt: 600,
            flags: HostWindowFlags::ON_SCREEN,
            display_index: 0,
            bundle_id: "com.example.app".to_owned(),
            app_name: "App".to_owned(),
            title: title.to_owned(),
        }
    }

    #[test]
    fn desktop_chrome_and_indicators_never_reach_the_rail() {
        assert!(includes_window("Safari", "Home", 800, 600));
        assert!(!includes_window("Dock", "", 800, 600));
        assert!(!includes_window("Cua Driver", "", 3000, 2000));
        assert!(!includes_window("Safari", "Home", 40, 600), "too narrow");
        assert!(!includes_window("Finder", "asverify", 800, 600));
        assert!(
            includes_window("Finder", "Documents", 800, 600),
            "the junk rule is keyed to one owner and one title",
        );
    }

    /// The phantom flood the evidence gate exists to stop.
    #[test]
    fn an_off_screen_window_needs_evidence_that_it_is_real() {
        let phantom = WindowFeedSourceWindow {
            is_on_screen: false,
            ..source(1, "Chrome", "a tab cache")
        };
        assert!(snapshot_records(std::slice::from_ref(&phantom)).is_empty());
        let minimized = WindowFeedSourceWindow {
            is_minimized: true,
            ..phantom.clone()
        };
        assert_eq!(snapshot_records(&[minimized]).len(), 1);
        let ax_listed = WindowFeedSourceWindow {
            is_ax_listed: true,
            ..phantom
        };
        assert_eq!(snapshot_records(&[ax_listed]).len(), 1);
    }

    #[test]
    fn exactly_one_record_carries_the_focused_bit() {
        let frontmost = |window_id| {
            WindowFeedSourceWindow {
                is_frontmost_app: true,
                ..source(window_id, "Safari", "a window")
            }
        };
        let records = snapshot_records(&[frontmost(1), frontmost(2), source(3, "Notes", "not frontmost")]);
        let focused: Vec<u32> = records
            .iter()
            .filter(|record| record.flags.contains(HostWindowFlags::FOCUSED_WINDOW))
            .map(|record| record.window_id)
            .collect();
        assert_eq!(focused, vec![1], "the frontmost app's FIRST window in z-order");
    }

    /// A frontmost app whose front window is off-screen must not hand the bit to a hidden window.
    #[test]
    fn the_focused_bit_needs_the_window_itself_to_be_on_screen() {
        let hidden = WindowFeedSourceWindow {
            is_frontmost_app: true,
            is_on_screen: false,
            is_minimized: true,
            ..source(1, "Safari", "minimized")
        };
        let visible = WindowFeedSourceWindow {
            is_frontmost_app: true,
            ..source(2, "Safari", "visible")
        };
        let records = snapshot_records(&[hidden, visible]);
        assert!(!records[0].flags.contains(HostWindowFlags::FOCUSED_WINDOW));
        assert!(records[1].flags.contains(HostWindowFlags::FOCUSED_WINDOW));
    }

    #[test]
    fn the_record_cap_stops_the_walk_rather_than_trimming_afterwards() {
        let windows: Vec<WindowFeedSourceWindow> = (0..100)
            .map(|index| source(index, "Safari", "a window"))
            .collect();
        let records = snapshot_records(&windows);
        assert_eq!(records.len(), MAX_RECORDS);
        assert_eq!(records[0].window_id, 0, "z-order is preserved");
    }

    #[test]
    fn a_truncated_string_is_always_valid_utf8() {
        let name = "é".repeat(50); // two bytes each
        let truncated = truncated_utf8(&name, 5);
        assert_eq!(truncated.len(), 4, "the split scalar is dropped whole");
        assert!(truncated.chars().all(|character| character == 'é'));
        assert_eq!(truncated_utf8("short", APP_NAME_MAX_BYTES), "short");
    }

    #[test]
    fn an_empty_desktop_is_a_real_snapshot_the_client_can_assemble() {
        let chunks = encoded_chunks(4, &[]);
        assert_eq!(chunks.len(), 1);
        let decoded = VideoControlMessage::decode(&chunks[0]).expect("one empty chunk");
        assert_eq!(decoded, VideoControlMessage::WindowFeedSnapshot {
            generation: 4,
            chunk_index: 0,
            chunk_count: 1,
            records: Vec::new(),
        });
    }

    /// The packing budget is bytes, because real titles vary by more than twenty times.
    #[test]
    fn a_chunk_splits_on_bytes_rather_than_on_a_record_count() {
        let fat: Vec<HostWindowRecord> = (0..8).map(|index| record(index, &"t".repeat(400))).collect();
        let chunks = encoded_chunks(1, &fat);
        assert!(chunks.len() > 1, "eight fat records do not fit one datagram");
        for chunk in &chunks {
            assert!(
                chunk.len() <= VideoControlMessage::FEED_RECORD_BYTES_PER_CHUNK + 64,
                "every chunk stays inside one datagram",
            );
        }
    }

    #[test]
    fn an_unchanged_desktop_keeps_its_generation_and_answers_short() {
        let mut cache = WindowFeedCache::new(1.0);
        assert!(cache.needs_rebuild(0.0));
        cache.fold(vec![record(1, "a")], 0.0);
        assert_eq!(cache.generation(), 1);
        assert!(!cache.needs_rebuild(0.5));

        cache.fold(vec![record(1, "a")], 1.0);
        assert_eq!(cache.generation(), 1, "identical records do not bump");
        assert!(!cache.needs_rebuild(1.5), "but the stamp did refresh");

        let reply = cache.reply(1);
        assert!(!reply.is_snapshot);
        assert_eq!(
            VideoControlMessage::decode(&reply.payloads[0]).expect("a current reply"),
            VideoControlMessage::WindowFeedCurrent { generation: 1 },
        );
        assert!(cache.reply(0).is_snapshot, "a behind client gets the chunks");
    }

    /// Zero is the wire's "the client has nothing" sentinel, so it is never published.
    #[test]
    fn the_generation_skips_zero_on_wrap() {
        let mut cache = WindowFeedCache::new(1.0);
        cache.fold(vec![record(1, "a")], 0.0);
        for _ in 0..2 {
            // Walk it to the wrap by hand rather than folding four billion times.
            cache.generation = u32::MAX;
            cache.fold(vec![record(1, "b")], 1.0);
            assert_eq!(cache.generation(), 1);
            cache.fold(vec![record(1, "a")], 2.0);
        }
    }

    #[test]
    fn a_never_built_cache_answers_nothing_rather_than_a_wrong_generation() {
        let cache = WindowFeedCache::new(1.0);
        assert_eq!(cache.reply(0).payloads, Vec::<Vec<u8>>::new());
    }

    #[test]
    fn a_subscriber_lives_its_ttl_past_its_last_renewal() {
        let mut table = WindowFeedSubscriberTable::new(6.0, 32);
        assert!(table.is_empty());
        assert!(table.renew(1, 0.0));
        assert!(table.renew(2, 0.0));
        assert!(table.renew(1, 4.0), "a renewal refreshes");
        assert_eq!(table.subscribers(7.0), vec![1], "2 is three renewals stale");
        assert_eq!(table.reap_expired(7.0), vec![2]);
        assert_eq!(table.len(), 1);
    }

    /// A hostile spray of distinct ids must not grow the table without bound.
    #[test]
    fn the_table_refuses_a_new_id_once_it_is_full_of_fresh_subscribers() {
        let mut table = WindowFeedSubscriberTable::new(6.0, 2);
        assert!(table.renew(1, 0.0));
        assert!(table.renew(2, 0.0));
        assert!(!table.renew(3, 0.0), "refused, quietly");
        assert!(table.renew(1, 0.0), "an existing id always refreshes");
        assert!(
            table.renew(3, 7.0),
            "once the fresh ones went stale the slot is reclaimed",
        );
    }

    #[test]
    fn a_moved_window_is_structural_and_a_retitled_one_is_not() {
        let base = vec![record(1, "a"), record(2, "b")];
        assert_eq!(classify_change(&base, &base), FeedChange::None);

        let resized = vec![
            HostWindowRecord {
                width_pt: 640,
                ..record(1, "a")
            },
            record(2, "b"),
        ];
        assert_eq!(classify_change(&base, &resized), FeedChange::Structural);

        let closed = vec![record(1, "a")];
        assert_eq!(classify_change(&base, &closed), FeedChange::Structural);

        let minimized = vec![
            HostWindowRecord {
                flags: HostWindowFlags::MINIMIZED,
                ..record(1, "a")
            },
            record(2, "b"),
        ];
        assert_eq!(classify_change(&base, &minimized), FeedChange::Structural);

        let retitled = vec![record(1, "a new title"), record(2, "b")];
        assert_eq!(classify_change(&base, &retitled), FeedChange::VolatileOnly {
            title_changed: true
        },);

        let refocused = vec![
            HostWindowRecord {
                flags: HostWindowFlags::ON_SCREEN.union(HostWindowFlags::FOCUSED_WINDOW),
                ..record(1, "a")
            },
            record(2, "b"),
        ];
        assert_eq!(classify_change(&base, &refocused), FeedChange::VolatileOnly {
            title_changed: false
        },);
    }

    #[test]
    fn a_structural_change_folds_at_once_and_opens_the_burst() {
        let mut policy = WindowFeedPushPolicy::new();
        assert_eq!(policy.tick_interval(0.0), IDLE_TICK);
        assert!(policy.should_fold(FeedChange::Structural, 10.0));
        assert_eq!(policy.tick_interval(12.0), BURST_TICK);
        assert_eq!(policy.tick_interval(13.0), IDLE_TICK, "the burst expires");
    }

    /// Title churn must neither enter the burst nor flood generations.
    #[test]
    fn a_volatile_change_waits_out_its_own_coalesce_gate() {
        let mut policy = WindowFeedPushPolicy::new();
        let title = FeedChange::VolatileOnly { title_changed: true };
        let focus = FeedChange::VolatileOnly { title_changed: false };
        assert!(policy.should_fold(title, 0.0));
        assert_eq!(policy.tick_interval(0.0), IDLE_TICK, "never the burst");
        assert!(!policy.should_fold(title, 1.9));
        assert!(policy.should_fold(title, 2.0));
        assert!(!policy.should_fold(focus, 2.9), "one gate, last fold wins");
        assert!(policy.should_fold(focus, 3.0));
    }

    #[test]
    fn nothing_changed_folds_nothing() {
        let mut policy = WindowFeedPushPolicy::new();
        assert!(!policy.should_fold(FeedChange::None, 0.0));
        assert_eq!(policy.tick_interval(0.0), IDLE_TICK);
    }
}
