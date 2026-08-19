//! When the app is allowed to speak.
//!
//! The rules are `slopdesk_workspace::notify`; what is here is the marshalling. Every one of these
//! answers is a handful of booleans and an integer, so nothing allocates and nothing but the banner
//! text crosses through a buffer.
//!
//! ## An enum crosses as its case index, and an unknown one degrades quietly
//!
//! The two settings enums cross as `u8`. A byte the crate does not recognise reads as the QUIET
//! case — the system's own foreground behaviour, no cue — because a disagreement between the two
//! sides should cost a notification rather than produce one nobody asked for. That is a floor, not
//! a licence: the two maps are written beside each other in the header.

use core::ffi::c_uchar;

use slopdesk_workspace::notify::{
    self, AgentSound, Badge, Event, Flavour, ForegroundPolicy, RateLimiter, Settings, Speaker,
};

use crate::{borrow, deliver};

/// A notification-bearing event, flattened: the case index, plus the exit code the only case that
/// carries one needs.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CNotifyEvent {
    /// `0` explicit OSC · `1` command finish · `2` watch finish · `3` agent task complete ·
    /// `4` agent await input. Anything else reads as an explicit OSC, the case behind the master
    /// switch.
    pub kind: u8,
    /// The exit code, when `kind` is a command finish and `exit_present` is set.
    pub exit: i32,
    /// Whether the completion carried a code at all. False reads as a clean exit.
    pub exit_present: bool,
}

/// The resolved notification toggles.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CNotifySettings {
    /// "Allow App Notifications".
    pub app_notifications_enabled: bool,
    /// "Notify on Command Finish".
    pub notify_on_finish: bool,
    /// "Notify on Error Exit".
    pub notify_on_error: bool,
    /// "Notify on Watch Finish".
    pub notify_on_watch_finish: bool,
    /// "Notify While Foreground": `0` off · `1` always · `2` only while the source tab is
    /// unfocused.
    pub foreground: u8,
    /// "Code Agent — Notify When Task Completes".
    pub agent_notify_task_complete: bool,
    /// "Code Agent — Notify When Awaiting Input".
    pub agent_notify_await_input: bool,
}

/// A token bucket, crossing by value in both directions.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CNotifyRateLimiter {
    /// The burst size, and the ceiling refilling cannot pass.
    pub capacity: f64,
    /// Tokens returned per second.
    pub refill_per_second: f64,
    /// Tokens left.
    pub tokens: f64,
    /// When `tokens` was last brought up to date.
    pub last_refill: f64,
}

impl From<CNotifyEvent> for Event {
    fn from(event: CNotifyEvent) -> Self {
        match event.kind {
            1 => {
                Self::CommandFinish {
                    exit: event.exit_present.then_some(event.exit),
                }
            },
            2 => Self::WatchFinish,
            3 => Self::AgentTaskComplete,
            4 => Self::AgentAwaitInput,
            _ => Self::ExplicitOsc,
        }
    }
}

impl From<CNotifySettings> for Settings {
    fn from(settings: CNotifySettings) -> Self {
        Self {
            app_notifications_enabled: settings.app_notifications_enabled,
            notify_on_finish: settings.notify_on_finish,
            notify_on_error: settings.notify_on_error,
            notify_on_watch_finish: settings.notify_on_watch_finish,
            foreground: match settings.foreground {
                1 => ForegroundPolicy::Always,
                2 => ForegroundPolicy::TabUnfocused,
                _ => ForegroundPolicy::Off,
            },
            agent_notify_task_complete: settings.agent_notify_task_complete,
            agent_notify_await_input: settings.agent_notify_await_input,
        }
    }
}

impl From<CNotifyRateLimiter> for RateLimiter {
    fn from(limiter: CNotifyRateLimiter) -> Self {
        Self {
            capacity: limiter.capacity,
            refill_per_second: limiter.refill_per_second,
            tokens: limiter.tokens,
            last_refill: limiter.last_refill,
        }
    }
}

/// Whether an event becomes a system banner.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_notify_should_deliver(
    event: CNotifyEvent,
    app_active: bool,
    source_pane_visible: bool,
    settings: CNotifySettings,
) -> bool {
    notify::should_deliver(event.into(), app_active, source_pane_visible, settings.into())
}

/// The duration below which a finished command is not worth a desktop alert, in milliseconds.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_notify_long_threshold_ms() -> u32 {
    notify::LONG_RUNNING_THRESHOLD_MS
}

/// Whether a host-measured duration counts as long.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_notify_is_long_running(duration_ms: u32) -> bool {
    notify::is_long_running(duration_ms)
}

/// The mark a background pane keeps: `0` none · `1` success · `2` failure.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_notify_badge(
    exit: i32,
    exit_present: bool,
    duration_ms: u32,
    pane_focused: bool,
    long_threshold_ms: u32,
) -> u8 {
    let code = if exit_present { Some(exit) } else { None };
    match notify::badge(code, duration_ms, pane_focused, long_threshold_ms) {
        None => 0,
        Some(Badge::Success) => 1,
        Some(Badge::Failure) => 2,
    }
}

/// Whether a finished command interrupts with a banner.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_notify_should_notify_completion(
    duration_ms: u32,
    pane_focused: bool,
    enabled: bool,
    long_threshold_ms: u32,
) -> bool {
    notify::should_notify_completion(duration_ms, pane_focused, enabled, long_threshold_ms)
}

/// The cue an agent attention edge rings: `0` silence · `1` task complete · `2` awaiting input.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_notify_agent_sound(
    needs_input: bool,
    sound_task_complete: bool,
    sound_await_input: bool,
) -> u8 {
    match notify::agent_sound(needs_input, sound_task_complete, sound_await_input) {
        None => 0,
        Some(AgentSound::TaskComplete) => 1,
        Some(AgentSound::AwaitInput) => 2,
    }
}

/// Whether a `BEL` rings the system alert sound.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_notify_should_ring_bell(sound_shell_controlled: bool) -> bool {
    notify::should_ring_bell(sound_shell_controlled)
}

/// Whether a finished command beeps.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_notify_should_beep_on_error(
    exit: i32,
    exit_present: bool,
    sound_on_error: bool,
) -> bool {
    let code = if exit_present { Some(exit) } else { None };
    notify::should_beep_on_error(code, sound_on_error)
}

/// The `(title, body)` an explicit child notification is shown as, written back to back.
///
/// Returns the total bytes both need; `title_len` receives how many of them are the title, so the
/// caller splits the answer without a separator that a title could contain. A blank body writes
/// nothing past the title, which is the case where the body was promoted INTO it.
///
/// # Safety
/// Each `(ptr, len)` must be null or point to that many initialised bytes; `out` must be null or
/// writable for `cap` bytes; `title_len` null or one writable `usize`. All live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_notify_explicit_content(
    pane_title: *const c_uchar,
    pane_title_len: usize,
    explicit_title: *const c_uchar,
    explicit_title_len: usize,
    body: *const c_uchar,
    body_len: usize,
    out: *mut c_uchar,
    cap: usize,
    title_len: *mut usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let text = |ptr, len| core::str::from_utf8(borrow(ptr, len)).unwrap_or_default();
        let (title, body) = notify::explicit_content(
            text(pane_title, pane_title_len),
            text(explicit_title, explicit_title_len),
            text(body, body_len),
        );
        if !title_len.is_null() {
            title_len.write(title.len());
        }
        let mut joined = title.into_bytes();
        joined.extend_from_slice(body.as_bytes());
        deliver(&joined, out, cap)
    }
}

/// The phrase an in-app notification card leads with.
///
/// `speaker` is `0` agent · `1` command, and `flavour` is `0` notice · `1` success · `2` failure ·
/// `3` attention. An unrecognised byte reads as the plainest case on each axis — a command, and a
/// notice — which is the pair that says the subject back verbatim rather than inventing a verb for
/// an event the two sides disagree about.
///
/// Returns the phrase's byte length; the bytes are written when `cap` allows.
///
/// # Safety
/// `subject` must be null or point to `subject_len` initialised bytes, and `out` null or writable
/// for `cap` bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_notify_toast_headline(
    speaker: u8,
    flavour: u8,
    subject: *const c_uchar,
    subject_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let speaker = match speaker {
        0 => Speaker::Agent,
        _ => Speaker::Command,
    };
    let flavour = match flavour {
        1 => Flavour::Success,
        2 => Flavour::Failure,
        3 => Flavour::Attention,
        _ => Flavour::Notice,
    };
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let subject = core::str::from_utf8(borrow(subject, subject_len)).unwrap_or_default();
        deliver(
            notify::toast_headline(speaker, flavour, subject).as_bytes(),
            out,
            cap,
        )
    }
}

/// Spends a token if the bucket has one, writing the refilled bucket back through `limiter`.
///
/// # Safety
/// `limiter` must be null or point to one live [`CNotifyRateLimiter`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_notify_rate_limit_allow(
    limiter: *mut CNotifyRateLimiter,
    now: f64,
) -> bool {
    if limiter.is_null() {
        return false;
    }
    // SAFETY: the caller's obligation, checked non-null above.
    unsafe {
        let mut bucket: RateLimiter = limiter.read().into();
        let allowed = bucket.allow(now);
        limiter.write(CNotifyRateLimiter {
            capacity: bucket.capacity,
            refill_per_second: bucket.refill_per_second,
            tokens: bucket.tokens,
            last_refill: bucket.last_refill,
        });
        allowed
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        CNotifyEvent, CNotifyRateLimiter, CNotifySettings, slopdesk_ws_notify_agent_sound,
        slopdesk_ws_notify_badge, slopdesk_ws_notify_explicit_content, slopdesk_ws_notify_long_threshold_ms,
        slopdesk_ws_notify_rate_limit_allow, slopdesk_ws_notify_should_deliver,
        slopdesk_ws_notify_toast_headline,
    };

    const SHIPPED: CNotifySettings = CNotifySettings {
        app_notifications_enabled: true,
        notify_on_finish: false,
        notify_on_error: true,
        notify_on_watch_finish: true,
        foreground: 0,
        agent_notify_task_complete: true,
        agent_notify_await_input: true,
    };

    #[test]
    fn an_unknown_case_byte_lands_on_the_quiet_reading() {
        let unknown = CNotifyEvent {
            kind: 200,
            exit: 0,
            exit_present: false,
        };
        assert!(
            slopdesk_ws_notify_should_deliver(unknown, false, false, SHIPPED),
            "an unrecognised event rides the master switch"
        );
        let loud = CNotifySettings {
            foreground: 99,
            ..SHIPPED
        };
        assert!(
            !slopdesk_ws_notify_should_deliver(unknown, true, false, loud),
            "an unrecognised foreground policy suppresses rather than shows"
        );
    }

    #[test]
    fn a_command_finish_carries_its_code_across() {
        let failed = CNotifyEvent {
            kind: 1,
            exit: 2,
            exit_present: true,
        };
        let clean = CNotifyEvent { exit: 0, ..failed };
        let codeless = CNotifyEvent {
            exit_present: false,
            ..failed
        };
        assert!(slopdesk_ws_notify_should_deliver(failed, false, false, SHIPPED));
        assert!(!slopdesk_ws_notify_should_deliver(clean, false, false, SHIPPED));
        assert!(
            !slopdesk_ws_notify_should_deliver(codeless, false, false, SHIPPED),
            "no code at all is a clean exit, whatever `exit` happens to hold"
        );
    }

    #[test]
    fn the_badge_and_the_threshold_agree_about_what_long_means() {
        let long = slopdesk_ws_notify_long_threshold_ms();
        assert_eq!(slopdesk_ws_notify_badge(0, true, long, false, long), 1);
        assert_eq!(slopdesk_ws_notify_badge(0, true, long - 1, false, long), 0);
        assert_eq!(slopdesk_ws_notify_badge(1, true, 0, false, long), 2);
        assert_eq!(slopdesk_ws_notify_badge(1, true, long, true, long), 0);
    }

    #[test]
    fn the_cue_is_a_case_index_and_silence_is_zero() {
        assert_eq!(slopdesk_ws_notify_agent_sound(true, true, true), 2);
        assert_eq!(slopdesk_ws_notify_agent_sound(false, true, true), 1);
        assert_eq!(slopdesk_ws_notify_agent_sound(false, false, true), 0);
    }

    #[test]
    fn the_banner_text_comes_back_as_one_run_split_by_the_title_length() {
        let mut out = [0_u8; 64];
        let mut title_len = 0_usize;
        // SAFETY: three live literals and one live local buffer, borrowed for the call.
        let needed = unsafe {
            slopdesk_ws_notify_explicit_content(
                b"make".as_ptr(),
                4,
                core::ptr::null(),
                0,
                b"build done".as_ptr(),
                10,
                out.as_mut_ptr(),
                out.len(),
                &raw mut title_len,
            )
        };
        assert_eq!(needed, 14);
        assert_eq!(title_len, 4);
        assert_eq!(out.get(..title_len), Some(b"make".as_slice()));
        assert_eq!(
            out.get(title_len..needed),
            Some(b"build done".as_slice()),
            "the body picks up exactly where the title stopped"
        );
    }

    #[test]
    fn the_headline_reads_its_two_axes_as_case_bytes() {
        let phrase = |speaker: u8, flavour: u8, subject: &str| {
            let mut out = [0_u8; 64];
            // SAFETY: one live literal and one live local buffer, borrowed for the call.
            let needed = unsafe {
                slopdesk_ws_notify_toast_headline(
                    speaker,
                    flavour,
                    subject.as_ptr(),
                    subject.len(),
                    out.as_mut_ptr(),
                    out.len(),
                )
            };
            String::from_utf8_lossy(out.get(..needed).unwrap_or_default()).into_owned()
        };
        assert_eq!(phrase(0, 1, "claude"), "claude is done");
        assert_eq!(phrase(1, 1, "make check"), "make check finished");
        assert_eq!(phrase(0, 3, "codex"), "codex needs input");
        assert_eq!(
            phrase(1, 0, "Build succeeded"),
            "Build succeeded",
            "a command's notice is its own words"
        );
    }

    #[test]
    fn an_unknown_axis_byte_lands_on_the_verbatim_pair() {
        let mut out = [0_u8; 32];
        // SAFETY: one live literal and one live local buffer, borrowed for the call.
        let needed = unsafe {
            slopdesk_ws_notify_toast_headline(200, 200, b"raw".as_ptr(), 3, out.as_mut_ptr(), out.len())
        };
        assert_eq!(out.get(..needed), Some(b"raw".as_slice()));
    }

    #[test]
    fn a_short_buffer_is_told_the_length_it_should_have_lent() {
        // SAFETY: one live literal; the answer is deliberately not written anywhere.
        let needed = unsafe {
            slopdesk_ws_notify_toast_headline(0, 1, b"claude".as_ptr(), 6, core::ptr::null_mut(), 0)
        };
        assert_eq!(needed, "claude is done".len());
    }

    #[test]
    fn the_bucket_crosses_by_value_and_comes_back_spent() {
        let mut limiter = CNotifyRateLimiter {
            capacity: 2.0,
            refill_per_second: 0.5,
            tokens: 2.0,
            last_refill: 10.0,
        };
        // SAFETY: one live local, borrowed for each call.
        let spend = |limiter: &mut CNotifyRateLimiter, now: f64| unsafe {
            slopdesk_ws_notify_rate_limit_allow(&raw mut *limiter, now)
        };
        assert!(spend(&mut limiter, 10.0));
        assert!(spend(&mut limiter, 10.0));
        assert!(!spend(&mut limiter, 10.0), "the burst is the capacity");
        assert!(spend(&mut limiter, 12.0), "two seconds buys one back");
    }
}
