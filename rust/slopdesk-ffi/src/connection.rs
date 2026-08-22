//! The link island's reading, in C.
//!
//! The rules are `slopdesk_workspace::connection`; what is here is the marshalling. Two shapes, and
//! the split between them is the point.
//!
//! ## The classifiers are scalars, and cross as scalars
//!
//! Health, the LED, the three alarms, the retry gate and the trailing slot are a handful of numbers
//! in and one code out. Nothing allocates and nothing goes through a buffer, so the readings the
//! island recomputes on every pulse — three per second, in a `SwiftUI` body and an `AppKit`
//! `layout()` — cost a call and no more.
//!
//! ## The words cross as GROUPS, for the reason `settings_options` states
//!
//! A door per string would have meant the island paying `1 + n` crossings to draw one line. The two
//! that a caller always wants together — the headline and the short label, the pulse's two prose
//! registers — come back in one delivery under `docs/55` §4's retry protocol, length-prefixed the
//! same way the settings catalogue's groups are, and cut by the same `wsRuns` on the near
//! side.
//!
//! ## What does NOT come back
//!
//! The raw failure payload. [`slopdesk_connection_has_raw_detail`] answers whether it was rewritten
//! — a yes/no — because the caller is holding the string it just passed in, and handing it back
//! would be a copy made only to be compared with the one it came from. Same for the host name: the
//! island's help text is `"Connection: {host} — "` plus what these doors answer, so the host never
//! needs to make the trip.
//!
//! ## The reconnect ceiling is an ARGUMENT
//!
//! `ReconnectManager` owns it, in the module that runs the campaign. Every door that prints
//! "attempt 3 of 20" takes it, rather than this side keeping a second copy free to drift from the
//! supervisor that decides it.

use core::ffi::c_uchar;

use slopdesk_workspace::connection::{
    self, Alarm, Led, MemoryPressure, Metric, Mount, NetworkHealth, Pulse, StatusKind, TrailingSlot,
};

use crate::{borrow, deliver};

/// Deliberately not connected — a fresh launch, or a link the user closed.
pub const SLOPDESK_CONNECTION_STATUS_DISCONNECTED: u32 = 0;
/// A first connect in flight.
pub const SLOPDESK_CONNECTION_STATUS_CONNECTING: u32 = 1;
/// Up.
pub const SLOPDESK_CONNECTION_STATUS_CONNECTED: u32 = 2;
/// A transport drop the supervisor is retrying on its own.
pub const SLOPDESK_CONNECTION_STATUS_RECONNECTING: u32 = 3;
/// The reconnect campaign exhausted its attempts.
pub const SLOPDESK_CONNECTION_STATUS_UNREACHABLE: u32 = 4;
/// The initial connect timed out or was refused.
pub const SLOPDESK_CONNECTION_STATUS_FAILED: u32 = 5;

/// Not connected — no round trip to classify.
pub const SLOPDESK_CONNECTION_HEALTH_OFFLINE: u32 = 0;
/// Under the good threshold, or connected with no sample yet.
pub const SLOPDESK_CONNECTION_HEALTH_GOOD: u32 = 1;
/// Between the two thresholds.
pub const SLOPDESK_CONNECTION_HEALTH_SLOW: u32 = 2;
/// Past the slow threshold.
pub const SLOPDESK_CONNECTION_HEALTH_BAD: u32 = 3;

/// Every settled not-connected state.
pub const SLOPDESK_CONNECTION_LED_DIM: u32 = 0;
/// A dial in flight.
pub const SLOPDESK_CONNECTION_LED_DIALING: u32 = 1;
/// Connected, round trip good.
pub const SLOPDESK_CONNECTION_LED_GOOD: u32 = 2;
/// Connected, round trip slow.
pub const SLOPDESK_CONNECTION_LED_SLOW: u32 = 3;
/// Connected, round trip bad.
pub const SLOPDESK_CONNECTION_LED_BAD: u32 = 4;

/// The metadata grey a healthy reading rests in.
pub const SLOPDESK_CONNECTION_ALARM_QUIET: u32 = 0;
/// Worth knowing about.
pub const SLOPDESK_CONNECTION_ALARM_RAISED: u32 = 1;
/// Worth acting on.
pub const SLOPDESK_CONNECTION_ALARM_LOUD: u32 = 2;

/// A bed cut out of the chrome — an empty right edge inside it reads as broken.
pub const SLOPDESK_CONNECTION_MOUNT_BEDDED: u32 = 0;
/// A bedless run of text in a toolbar — an unfilled slot reads as nothing at all.
pub const SLOPDESK_CONNECTION_MOUNT_COMPACT: u32 = 1;

/// The trailing slot shows nothing.
pub const SLOPDESK_CONNECTION_TRAILING_ABSENT: u32 = 0;
/// It shows the mono ping figure.
pub const SLOPDESK_CONNECTION_TRAILING_PING: u32 = 1;
/// It shows the short status word.
pub const SLOPDESK_CONNECTION_TRAILING_STATUS_WORD: u32 = 2;

/// The all-core busy percent.
pub const SLOPDESK_CONNECTION_METRIC_CPU: u32 = 0;
/// The in-use percent.
pub const SLOPDESK_CONNECTION_METRIC_MEMORY: u32 = 1;
/// Free space on the work volume.
pub const SLOPDESK_CONNECTION_METRIC_DISK: u32 = 2;

/// The caller saying it could not read its volume, so the disk run is omitted.
///
/// An absence FLAG rather than a sentinel of this module's invention: free space is a real `0` when
/// a volume is genuinely full, and reading that as "unknown" would hide a full disk behind a
/// missing run.
#[cfg(test)]
const DISK_ABSENT: bool = false;

/// The host's pulse as the island holds it.
///
/// `disk_free_mib` is read only when `has_disk`, which is §4b's presence-flag rule: zero free bytes
/// is the loudest real reading there is, so it cannot double as "no reading".
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SlopDeskHostPulse {
    /// All-core CPU busy percent as displayed.
    pub cpu_percent: u32,
    /// Memory-in-use percent as displayed.
    pub memory_percent: u32,
    /// The kernel's verdict, as the wire's own byte.
    pub memory_pressure: u8,
    /// Free MiB on the work volume; read only when `has_disk`.
    pub disk_free_mib: u32,
    /// Whether `disk_free_mib` means anything.
    pub has_disk: bool,
}

impl SlopDeskHostPulse {
    /// The crate's pulse.
    const fn of(self) -> Pulse {
        Pulse {
            cpu_percent: self.cpu_percent,
            memory_percent: self.memory_percent,
            memory_pressure: MemoryPressure::from_byte(self.memory_pressure),
            disk_free_mib: if self.has_disk {
                Some(self.disk_free_mib)
            } else {
                None
            },
        }
    }
}

/// The status a code names. An unknown code reads as disconnected.
const fn status(code: u32) -> StatusKind {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the wrapped `from_byte` is total, and every legal code is under 256"
    )]
    let byte = code as u8;
    if code > 255 {
        StatusKind::Disconnected
    } else {
        StatusKind::from_byte(byte)
    }
}

/// The mount a code names. An unknown code reads as bedded, the mount that always says something.
const fn mount(code: u32) -> Mount {
    if code == SLOPDESK_CONNECTION_MOUNT_COMPACT {
        Mount::Compact
    } else {
        Mount::Bedded
    }
}

/// The LED a code names. An unknown code reads as dim, which is the rung that stays quiet.
const fn led(code: u32) -> Led {
    match code {
        SLOPDESK_CONNECTION_LED_DIALING => Led::Dialing,
        SLOPDESK_CONNECTION_LED_GOOD => Led::Good,
        SLOPDESK_CONNECTION_LED_SLOW => Led::Slow,
        SLOPDESK_CONNECTION_LED_BAD => Led::Bad,
        _ => Led::Dim,
    }
}

/// The code an alarm reports as.
const fn alarm_code(alarm: Alarm) -> u32 {
    alarm.as_byte() as u32
}

/// The code a health reading reports as.
const fn health_code(health: NetworkHealth) -> u32 {
    match health {
        NetworkHealth::Offline => SLOPDESK_CONNECTION_HEALTH_OFFLINE,
        NetworkHealth::Good => SLOPDESK_CONNECTION_HEALTH_GOOD,
        NetworkHealth::Slow => SLOPDESK_CONNECTION_HEALTH_SLOW,
        NetworkHealth::Bad => SLOPDESK_CONNECTION_HEALTH_BAD,
    }
}

/// The code a slot reports as.
const fn slot_code(slot: TrailingSlot) -> u32 {
    match slot {
        TrailingSlot::Absent => SLOPDESK_CONNECTION_TRAILING_ABSENT,
        TrailingSlot::Ping => SLOPDESK_CONNECTION_TRAILING_PING,
        TrailingSlot::StatusWord => SLOPDESK_CONNECTION_TRAILING_STATUS_WORD,
    }
}

/// The code a metric role reports as.
const fn metric_code(metric: Metric) -> u8 {
    metric.as_byte()
}

/// One `[u32 big-endian length][UTF-8 bytes]` run, appended.
fn push_run(out: &mut Vec<u8>, text: &str) {
    let bytes = text.as_bytes();
    #[expect(
        clippy::cast_possible_truncation,
        reason = "every string here is a formatted reading of at most a few hundred bytes"
    )]
    let length = bytes.len() as u32;
    out.extend_from_slice(&length.to_be_bytes());
    out.extend_from_slice(bytes);
}

/// The round trip, classified.
///
/// `ping_ms` is read only when `has_ping`. Connected-with-no-sample is GOOD rather than a fourth
/// state: the link answered the handshake, so the only honest default is the one that says nothing
/// is wrong yet.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_connection_health(is_connected: bool, has_ping: bool, ping_ms: f64) -> u32 {
    health_code(connection::health(is_connected, has_ping.then_some(ping_ms)))
}

/// The link's fused state. A stale sample can never brighten a link that is down.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_connection_led(status_code: u32, has_ping: bool, ping_ms: f64) -> u32 {
    u32::from(connection::led_state(status(status_code), has_ping.then_some(ping_ms)).as_byte())
}

/// The LINK's alarm, from its fused state.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_connection_link_alarm(led_code: u32) -> u32 {
    alarm_code(connection::link_alarm(led(led_code)))
}

/// MEMORY's alarm, from the KERNEL's verdict byte and never from the percent.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_connection_memory_alarm(pressure: u8) -> u32 {
    alarm_code(connection::memory_alarm(MemoryPressure::from_byte(pressure)))
}

/// DISK's alarm, from BYTES LEFT. An unreadable volume (`has_disk` false) is quiet, not alarmed.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_connection_disk_alarm(has_disk: bool, free_mib: u32) -> u32 {
    alarm_code(connection::disk_alarm(if has_disk {
        Some(free_mib)
    } else {
        None
    }))
}

/// The trailing slot's alarm: the ping digits climb, a status word never does.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_connection_detail_alarm(slot_code_in: u32, led_code: u32) -> u32 {
    let slot = match slot_code_in {
        SLOPDESK_CONNECTION_TRAILING_PING => TrailingSlot::Ping,
        SLOPDESK_CONNECTION_TRAILING_STATUS_WORD => TrailingSlot::StatusWord,
        _ => TrailingSlot::Absent,
    };
    alarm_code(connection::detail_alarm(slot, led(led_code)))
}

/// Whether a manual Retry affordance applies — only the give-up states.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_connection_shows_retry(status_code: u32) -> bool {
    connection::shows_retry(status(status_code))
}

/// What the trailing slot shows — a source, not the text, because the two sources want different
/// payloads and the caller is already holding both.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_connection_trailing_slot(
    status_code: u32,
    has_ping: bool,
    mount_code: u32,
) -> u32 {
    slot_code(connection::trailing_slot(
        status(status_code),
        has_ping,
        mount(mount_code),
    ))
}

/// The ping figure, in whole milliseconds.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[expect(
    unsafe_code,
    reason = "delivering into the caller's buffer IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_connection_ping_label(
    ping_ms: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, forwarded unchanged.
    unsafe { deliver(connection::ping_label(ping_ms).as_bytes(), out, cap) }
}

/// The bitrate figure, which changes unit at a megabit.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[expect(
    unsafe_code,
    reason = "delivering into the caller's buffer IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_connection_bitrate_label(
    kbps: i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, forwarded unchanged.
    unsafe { deliver(connection::bitrate_label(kbps).as_bytes(), out, cap) }
}

/// Free disk, coarsened to fit the rail.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[expect(
    unsafe_code,
    reason = "delivering into the caller's buffer IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_connection_disk_label(
    free_mib: u32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, forwarded unchanged.
    unsafe { deliver(connection::disk_label(free_mib).as_bytes(), out, cap) }
}

/// The stream numbers as tooltip detail, or nothing when neither exists.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[expect(
    unsafe_code,
    reason = "delivering into the caller's buffer IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_connection_tooltip_detail(
    has_fps: bool,
    fps: i64,
    has_kbps: bool,
    kbps: i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let answer = connection::tooltip_detail(has_fps.then_some(fps), has_kbps.then_some(kbps));
    // SAFETY: the caller's obligation, forwarded unchanged.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// The status in WORDS — the gate card's headline, the compact toolbar form, and the plain state
/// name — in one delivery.
///
/// Three runs, `[u32 big-endian length][UTF-8 bytes]` each, in that order. One door because the two
/// surfaces that draw a status draw it beside its own fallback, and three doors would have been
/// three crossings for one line of text.
///
/// `raw` is the transport's own failure payload, read only for the failed status; `max_attempts` is
/// the supervisor's ceiling, which this side does not own.
///
/// # Safety
/// `raw` must be null, or describe `raw_len` live bytes for the call; `out` must be null, or
/// writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "borrowing the caller's text and delivering into its buffer IS this module's boundary"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_connection_words(
    status_code: u32,
    attempt: u32,
    max_attempts: u32,
    raw: *const c_uchar,
    raw_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation for `raw`, forwarded unchanged.
    let raw = std::str::from_utf8(unsafe { borrow(raw, raw_len) }).unwrap_or_default();
    let kind = status(status_code);
    let mut answer = Vec::new();
    push_run(
        &mut answer,
        &connection::headline(kind, attempt, max_attempts, raw),
    );
    push_run(&mut answer, &connection::short_label(kind, attempt, max_attempts));
    push_run(&mut answer, &connection::status_label(kind, attempt, raw));
    // SAFETY: the caller's obligation for `out`, forwarded unchanged.
    unsafe { deliver(&answer, out, cap) }
}

/// Whether the raw payload is worth a tooltip — true only where the classifier actually rewrote it.
///
/// A yes/no rather than the string, because the caller already holds what it passed in.
///
/// # Safety
/// `raw` must be null, or describe `raw_len` live bytes for the call.
#[expect(
    unsafe_code,
    reason = "borrowing the caller's text IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_connection_has_raw_detail(
    status_code: u32,
    raw: *const c_uchar,
    raw_len: usize,
) -> bool {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let raw = std::str::from_utf8(unsafe { borrow(raw, raw_len) }).unwrap_or_default();
    connection::has_raw_detail(status(status_code), raw)
}

/// The pulse as DRAWN runs, in the order it is drawn.
///
/// `promoted_only` is the one-line mount's gate: it keeps the runs that have earned a place and
/// answers with nothing at all while the host is calm.
///
/// ```text
/// [u16 big-endian run_count]
/// run_count × [u8 metric][u8 alarm][u32 big-endian length][UTF-8 value]
/// ```
///
/// A pulse with no runs still delivers its two-byte header, so §4's `0` keeps its literal meaning:
/// nothing was written because the buffer was null, not because there was nothing to say.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[expect(
    unsafe_code,
    reason = "delivering into the caller's buffer IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_connection_metric_runs(
    pulse: SlopDeskHostPulse,
    promoted_only: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let runs = if promoted_only {
        connection::promoted_runs(pulse.of())
    } else {
        connection::metric_runs(pulse.of())
    };
    let mut answer = Vec::new();
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the pulse has exactly three readings and the list can only shrink"
    )]
    let count = runs.len() as u16;
    answer.extend_from_slice(&count.to_be_bytes());
    for run in &runs {
        answer.push(metric_code(run.metric));
        answer.push(run.alarm.as_byte());
        push_run(&mut answer, &run.value);
    }
    // SAFETY: the caller's obligation, forwarded unchanged.
    unsafe { deliver(&answer, out, cap) }
}

/// The pulse's two prose registers — spoken, then tooltip — in one delivery.
///
/// Two runs, length-prefixed like the words above. One door for the same reason: the surfaces that
/// want prose want a hover string and an accessibility label from the same sample.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[expect(
    unsafe_code,
    reason = "delivering into the caller's buffer IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_connection_pulse_prose(
    pulse: SlopDeskHostPulse,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let sample = pulse.of();
    let mut answer = Vec::new();
    push_run(&mut answer, &connection::pulse_spoken(sample));
    push_run(&mut answer, &connection::pulse_tooltip(sample));
    // SAFETY: the caller's obligation, forwarded unchanged.
    unsafe { deliver(&answer, out, cap) }
}

/// The SF Symbol that names a metric role, by code. A NAME, so each framework resolves it through
/// its own image type.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[expect(
    unsafe_code,
    reason = "delivering into the caller's buffer IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub const unsafe extern "C" fn slopdesk_connection_metric_symbol(
    metric_code_in: u32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let metric = match metric_code_in {
        SLOPDESK_CONNECTION_METRIC_MEMORY => Metric::Memory,
        SLOPDESK_CONNECTION_METRIC_DISK => Metric::Disk,
        _ => Metric::Cpu,
    };
    // SAFETY: the caller's obligation, forwarded unchanged.
    unsafe { deliver(metric.symbol_name().as_bytes(), out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use super::{
        DISK_ABSENT, SLOPDESK_CONNECTION_ALARM_LOUD, SLOPDESK_CONNECTION_ALARM_QUIET,
        SLOPDESK_CONNECTION_HEALTH_GOOD, SLOPDESK_CONNECTION_HEALTH_OFFLINE, SLOPDESK_CONNECTION_LED_DIM,
        SLOPDESK_CONNECTION_METRIC_DISK, SLOPDESK_CONNECTION_MOUNT_COMPACT,
        SLOPDESK_CONNECTION_STATUS_CONNECTED, SLOPDESK_CONNECTION_STATUS_FAILED,
        SLOPDESK_CONNECTION_TRAILING_ABSENT, SlopDeskHostPulse, slopdesk_connection_disk_alarm,
        slopdesk_connection_has_raw_detail, slopdesk_connection_health, slopdesk_connection_led,
        slopdesk_connection_metric_runs, slopdesk_connection_trailing_slot, slopdesk_connection_words,
    };

    /// Cuts a `[u32 length][bytes]` delivery back into its runs.
    fn split(bytes: &[u8]) -> Vec<String> {
        let mut runs = Vec::new();
        let mut cursor = 0;
        while cursor + 4 <= bytes.len() {
            let Some(header) = bytes.get(cursor..cursor + 4) else {
                break;
            };
            let mut width = [0_u8; 4];
            width.copy_from_slice(header);
            let length = u32::from_be_bytes(width) as usize;
            cursor += 4;
            let Some(body) = bytes.get(cursor..cursor + length) else {
                break;
            };
            runs.push(String::from_utf8_lossy(body).into_owned());
            cursor += length;
        }
        runs
    }

    /// Runs a delivery door under §4's retry protocol and hands back the bytes.
    fn collect(mut door: impl FnMut(*mut u8, usize) -> usize) -> Vec<u8> {
        let needed = door(std::ptr::null_mut(), 0);
        let mut buffer = vec![0_u8; needed];
        let written = door(buffer.as_mut_ptr(), buffer.len());
        assert_eq!(written, needed, "the retry must fit what the probe promised");
        buffer
    }

    #[test]
    fn an_unknown_code_lands_on_the_rung_that_says_least() {
        // A garbled status must not brighten anything, and a garbled LED must not shout.
        assert_eq!(
            slopdesk_connection_led(9999, true, 5.0),
            SLOPDESK_CONNECTION_LED_DIM
        );
        assert_eq!(
            super::slopdesk_connection_link_alarm(9999),
            SLOPDESK_CONNECTION_ALARM_QUIET
        );
        assert_eq!(
            super::slopdesk_connection_memory_alarm(200),
            SLOPDESK_CONNECTION_ALARM_QUIET
        );
    }

    #[test]
    fn the_ping_is_read_only_when_the_flag_says_so() {
        assert_eq!(
            slopdesk_connection_health(true, false, 9999.0),
            SLOPDESK_CONNECTION_HEALTH_GOOD,
            "a ping the caller did not send must not classify the link as bad"
        );
        assert_eq!(
            slopdesk_connection_health(false, true, 1.0),
            SLOPDESK_CONNECTION_HEALTH_OFFLINE
        );
    }

    #[test]
    fn a_full_volume_is_not_an_absent_one() {
        assert_eq!(
            slopdesk_connection_disk_alarm(true, 0),
            SLOPDESK_CONNECTION_ALARM_LOUD,
            "zero free bytes is the loudest real reading there is"
        );
        assert_eq!(
            slopdesk_connection_disk_alarm(DISK_ABSENT, 0),
            SLOPDESK_CONNECTION_ALARM_QUIET,
            "…and a volume the host could not read is not bad news"
        );
    }

    #[test]
    fn a_compact_mount_stays_silent_before_the_first_sample() {
        assert_eq!(
            slopdesk_connection_trailing_slot(
                SLOPDESK_CONNECTION_STATUS_CONNECTED,
                false,
                SLOPDESK_CONNECTION_MOUNT_COMPACT,
            ),
            SLOPDESK_CONNECTION_TRAILING_ABSENT
        );
    }

    #[test]
    fn the_words_come_back_as_three_runs_in_a_fixed_order() {
        let raw = b"Connection refused";
        let bytes = collect(|out, cap| unsafe {
            slopdesk_connection_words(
                SLOPDESK_CONNECTION_STATUS_FAILED,
                0,
                20,
                raw.as_ptr(),
                raw.len(),
                out,
                cap,
            )
        });
        let runs = split(&bytes);
        assert_eq!(runs.len(), 3);
        assert!(
            runs.first().is_some_and(|run| run.contains("slopdesk-hostd")),
            "the headline is the ACTIONABLE copy"
        );
        assert_eq!(runs.get(1).map(String::as_str), Some("failed"));
        assert!(
            runs.get(2).is_some_and(|run| run.contains("Connection refused")),
            "the plain label keeps the payload the short one drops"
        );
    }

    #[test]
    fn a_null_payload_is_an_empty_one_and_never_a_read() {
        let bytes = collect(|out, cap| unsafe {
            slopdesk_connection_words(
                SLOPDESK_CONNECTION_STATUS_FAILED,
                0,
                20,
                std::ptr::null(),
                12,
                out,
                cap,
            )
        });
        assert_eq!(split(&bytes).len(), 3, "a null payload still answers three runs");
        assert!(!unsafe {
            slopdesk_connection_has_raw_detail(SLOPDESK_CONNECTION_STATUS_FAILED, std::ptr::null(), 9)
        });
    }

    #[test]
    fn the_runs_carry_their_role_and_rung_beside_their_figure() {
        let pulse = SlopDeskHostPulse {
            cpu_percent: 31,
            memory_percent: 62,
            memory_pressure: 0,
            disk_free_mib: 100,
            has_disk: true,
        };
        let bytes = collect(|out, cap| unsafe { slopdesk_connection_metric_runs(pulse, false, out, cap) });
        assert_eq!(bytes.get(0..2), Some([0, 3].as_slice()), "three runs");
        // Walk the runs rather than counting bytes by hand: each is a role, a rung, a
        // length and that many bytes of figure, and the figures are not a fixed width.
        let mut cursor = 2;
        let mut roles = Vec::new();
        while let (Some(&role), Some(&rung), Some(len)) = (
            bytes.get(cursor),
            bytes.get(cursor + 1),
            bytes
                .get(cursor + 2..cursor + 6)
                .and_then(|four| <[u8; 4]>::try_from(four).ok())
                .map(u32::from_be_bytes),
        ) {
            roles.push((u32::from(role), u32::from(rung)));
            cursor += 6 + len as usize;
        }
        assert_eq!(cursor, bytes.len(), "the runs account for every byte");
        assert_eq!(
            roles.last().map(|pair| pair.0),
            Some(SLOPDESK_CONNECTION_METRIC_DISK),
            "the disk is the last role in the row"
        );
        assert_eq!(
            roles.last().map(|pair| pair.1),
            Some(SLOPDESK_CONNECTION_ALARM_LOUD),
            "100 MiB left is the loud rung, and it rides beside its own figure"
        );
        let calm = collect(|out, cap| unsafe {
            slopdesk_connection_metric_runs(
                SlopDeskHostPulse {
                    has_disk: false,
                    ..pulse
                },
                true,
                out,
                cap,
            )
        });
        assert_eq!(
            calm,
            vec![0, 0],
            "a calm host on a one-line mount still delivers its header, and says nothing in it"
        );
    }
}
