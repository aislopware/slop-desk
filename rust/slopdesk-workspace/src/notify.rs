//! When the app is allowed to SPEAK — a banner, a badge, a beep.
//!
//! Every surface here answers the same shape of question: something finished, or asked for
//! attention, and the user has a set of toggles that decide whether it becomes a noise. What makes
//! them one module rather than five is that they disagree on purpose, and the disagreements only
//! read as deliberate side by side: a failure badges however short it was but only notifies while
//! you are looking away; an agent's sound is NOT focus-gated where its card is; a foreground banner
//! is suppressed by default because the OS would have suppressed it anyway.
//!
//! ## Two stages, and only the first one is about the event
//!
//! A delivery is a toggle AND a foreground gate, in that order. The toggle asks what happened —
//! each event maps to exactly one switch, so nothing is double-gated and turning a switch off
//! silences exactly its own event. The gate asks where the user is, which is a fact about the
//! window rather than the command, and it is a pass-through whenever the app is not frontmost:
//! there the OS already shows the banner, and a rule here would be a second policy fighting it.
//!
//! ## Why `exit == None` is a clean exit
//!
//! A completion can arrive with no code at all — a shell that reports the edge without one. Reading
//! that as a failure would badge and notify a pane for every prompt on a shell whose integration is
//! half-installed, so an absent code is exit 0 everywhere in this module. It is one reading,
//! spelled once, rather than a convention each caller has to remember.

/// How a banner behaves while slopdesk is the FRONTMOST app.
///
/// macOS suppresses banners for the foreground app; this is the override, so the default is `Off`
/// — the system's own behaviour — rather than a policy of ours.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ForegroundPolicy {
    /// Let the system suppress the banner while the app is frontmost.
    #[default]
    Off,
    /// Show the banner even when the app is frontmost.
    Always,
    /// Show it only when the source pane is NOT visible — its tab is not the active one. Any split
    /// of the active tab is on screen, so a sibling split counts as visible.
    TabUnfocused,
}

/// The notification-bearing events, each mapping to exactly ONE toggle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    /// A child asked for a notification itself — OSC 9 / 777 / 99.
    ExplicitOsc,
    /// A command finished (OSC 133;D). The code splits it between two toggles.
    CommandFinish {
        /// The exit code, if the completion carried one. `None` reads as a clean 0.
        exit: Option<i32>,
    },
    /// An `slopdesk watch`-wrapped command finished.
    WatchFinish,
    /// A code agent finished its task and went idle.
    AgentTaskComplete,
    /// A code agent is waiting for approval or input.
    AgentAwaitInput,
}

/// The resolved toggles a delivery is decided against — the shipped defaults are [`Default`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "six independently switchable settings, each with its own row in the UI; a bitflag would cost \
              every reader the mapping and buy nothing"
)]
pub struct Settings {
    /// "Allow App Notifications" — the master switch for child-requested notifications.
    pub app_notifications_enabled: bool,
    /// "Notify on Command Finish" — a command that exited 0.
    pub notify_on_finish: bool,
    /// "Notify on Error Exit" — a command that exited non-zero.
    pub notify_on_error: bool,
    /// "Notify on Watch Finish".
    pub notify_on_watch_finish: bool,
    /// "Notify While Foreground".
    pub foreground: ForegroundPolicy,
    /// "Code Agent — Notify When Task Completes".
    pub agent_notify_task_complete: bool,
    /// "Code Agent — Notify When Awaiting Input".
    pub agent_notify_await_input: bool,
}

impl Default for Settings {
    /// What a fresh install carries: everything on but the two that would be noise — a clean
    /// finish, which is most of them, and a foreground banner the OS would have hidden.
    fn default() -> Self {
        Self {
            app_notifications_enabled: true,
            notify_on_finish: false,
            notify_on_error: true,
            notify_on_watch_finish: true,
            foreground: ForegroundPolicy::Off,
            agent_notify_task_complete: true,
            agent_notify_await_input: true,
        }
    }
}

/// Whether `event` becomes a system banner.
///
/// `source_pane_visible` is whether the user can SEE the pane that spoke — it sits in the active
/// session's active tab, or its satellite window is key. Visibility rather than focus: a split you
/// are watching work in needs no banner even while the cursor is in its sibling.
#[must_use]
pub const fn should_deliver(
    event: Event,
    app_active: bool,
    source_pane_visible: bool,
    settings: Settings,
) -> bool {
    event_enabled(event, settings) && foreground_gate(app_active, source_pane_visible, settings.foreground)
}

/// Stage one — the per-event toggle.
#[must_use]
const fn event_enabled(event: Event, settings: Settings) -> bool {
    match event {
        Event::ExplicitOsc => settings.app_notifications_enabled,
        Event::CommandFinish { exit } => {
            if is_clean(exit) {
                settings.notify_on_finish
            } else {
                settings.notify_on_error
            }
        },
        Event::WatchFinish => settings.notify_on_watch_finish,
        Event::AgentTaskComplete => settings.agent_notify_task_complete,
        Event::AgentAwaitInput => settings.agent_notify_await_input,
    }
}

/// Stage two — the foreground gate, a pass whenever the app is not frontmost.
#[must_use]
const fn foreground_gate(app_active: bool, source_pane_visible: bool, policy: ForegroundPolicy) -> bool {
    if !app_active {
        return true;
    }
    match policy {
        ForegroundPolicy::Off => false,
        ForegroundPolicy::Always => true,
        ForegroundPolicy::TabUnfocused => !source_pane_visible,
    }
}

/// A completion that carried no code is a clean one.
const fn is_clean(exit: Option<i32>) -> bool {
    match exit {
        Some(code) => code == 0,
        None => true,
    }
}

// MARK: The long command

/// Below this, a finished command is not worth a desktop alert. iTerm2 and Warp both land near ten
/// seconds; a quick `ls` is three orders of magnitude under it and stays silent.
pub const LONG_RUNNING_THRESHOLD_MS: u32 = 10_000;

/// Whether a host-measured C→D duration counts as long. `>=`, so a command that took exactly the
/// threshold notifies.
#[must_use]
pub const fn is_long_running(duration_ms: u32) -> bool {
    duration_ms >= LONG_RUNNING_THRESHOLD_MS
}

/// The mark a BACKGROUND pane carries until you look at it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Badge {
    /// The command exited 0, or carried no code.
    Success,
    /// The command exited non-zero.
    Failure,
}

/// The completion badge for a finished command, or `None` for no badge.
///
/// A focused pane never badges — you watched it happen. A failure badges however short it was,
/// because a quick failing `make` on a backgrounded pane is exactly what a badge is for; a success
/// badges only when it was long, so a background `ls` leaves no mark.
#[must_use]
pub const fn badge(
    exit: Option<i32>,
    duration_ms: u32,
    pane_focused: bool,
    long_threshold_ms: u32,
) -> Option<Badge> {
    if pane_focused {
        return None;
    }
    if !is_clean(exit) {
        return Some(Badge::Failure);
    }
    if duration_ms >= long_threshold_ms {
        Some(Badge::Success)
    } else {
        None
    }
}

/// The focus gate for the long-command banner: an UNFOCUSED pane, a LONG command, and the toggle
/// on.
///
/// Stricter than [`badge`] on purpose — a badge is a mark you find later, a banner interrupts, so a
/// short failure earns the first and not the second.
#[must_use]
pub const fn should_notify_completion(
    duration_ms: u32,
    pane_focused: bool,
    enabled: bool,
    long_threshold_ms: u32,
) -> bool {
    enabled && !pane_focused && duration_ms >= long_threshold_ms
}

// MARK: What the banner says

/// The `(title, body)` an explicit child notification is shown as.
///
/// OSC 777 carries its own title. OSC 9 carries only a body, so the pane's title becomes the title;
/// and when the pane has no title either the body is promoted, because a blank alert is worse than
/// a title-only one.
#[must_use]
pub fn explicit_content(pane_title: &str, explicit_title: &str, body: &str) -> (String, String) {
    let explicit = explicit_title.trim();
    if !explicit.is_empty() {
        return (explicit.to_owned(), body.to_owned());
    }
    let pane = pane_title.trim();
    if !pane.is_empty() {
        return (pane.to_owned(), body.to_owned());
    }
    (body.to_owned(), String::new())
}

// MARK: The in-app card's headline

/// Which of the workspace's two status speakers raised a notification.
///
/// Not a style knob: it picks the headline's VERB, so it names a real distinction. An agent has a
/// LIFECYCLE — its clean outcome is "finished a turn" — while a command has an OUTCOME, and its
/// clean one is "exited zero". Fusing the two and letting the surface guess is how a card comes to
/// say "make check is done" about a build.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Speaker {
    /// A living agent session.
    Agent,
    /// A command's outcome, or any other one-off event at a pane.
    Command,
}

/// What KIND of thing happened — the same four rungs the card's status mark is drawn from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Flavour {
    /// A routine notice: an OSC 9/777 line, an advisory. It speaks its own words.
    Notice,
    /// It ended well.
    Success,
    /// It ended badly.
    Failure,
    /// It is waiting on a human.
    Attention,
}

/// The sentence-case phrase that leads an in-app notification card.
///
/// Resolved from the speaker and the flavour TOGETHER, never from either alone — `Success` is "the
/// agent finished its turn" for an agent and "the command exited 0" for a command, which are two
/// different speakers saying two different words.
///
/// A NOTICE from a command is the one case that takes the subject verbatim: an OSC line or a cwd
/// advisory is already a sentence someone else wrote, and prefixing an event verb onto it garbles
/// it. Attention from a command is the same — nothing generic can be added to a message that came
/// with its own wording.
///
/// The subject is trimmed and, when it is empty, the phrase falls back to a bare speaker noun
/// rather than opening with a space — a card whose pane never set a title still has to read as a
/// sentence.
#[must_use]
pub fn toast_headline(speaker: Speaker, flavour: Flavour, subject: &str) -> String {
    let subject = subject.trim();
    let suffix = match (speaker, flavour) {
        (Speaker::Agent, Flavour::Attention) => "needs input",
        (Speaker::Agent, Flavour::Success) => "is done",
        (Speaker::Agent | Speaker::Command, Flavour::Failure) => "failed",
        (Speaker::Agent, Flavour::Notice) => "is working",
        (Speaker::Command, Flavour::Success) => "finished",
        // The subject IS the message. Nothing is appended, and an empty one is honestly empty.
        (Speaker::Command, Flavour::Notice | Flavour::Attention) => return subject.to_owned(),
    };
    if subject.is_empty() {
        let noun = match speaker {
            Speaker::Agent => "The agent",
            Speaker::Command => "The command",
        };
        return format!("{noun} {suffix}");
    }
    format!("{subject} {suffix}")
}

// MARK: Sounds

/// Which system sound announces an agent attention edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentSound {
    /// The agent finished its task and went idle.
    TaskComplete,
    /// The agent is blocked waiting for approval or input.
    AwaitInput,
}

/// The cue for an agent attention edge, or `None` for silence.
///
/// **The sound is NOT focus-gated where the card is.** The two answer different questions: a card
/// is a pane speaking from off-screen, so it is suppressed for the pane you are looking at, but the
/// cue is what tells you an edge happened at all — and "the pane is focused" is not evidence anyone
/// was looking at it. A focused pane is routinely the one left running in a background window, on a
/// second display, or behind the browser the user switched to while the turn ran.
#[must_use]
pub const fn agent_sound(
    needs_input: bool,
    sound_task_complete: bool,
    sound_await_input: bool,
) -> Option<AgentSound> {
    if needs_input {
        if sound_await_input {
            return Some(AgentSound::AwaitInput);
        }
        return None;
    }
    if sound_task_complete {
        Some(AgentSound::TaskComplete)
    } else {
        None
    }
}

/// Whether a `BEL` rings the system alert sound. Audio only — there is no visual bell.
#[must_use]
pub const fn should_ring_bell(sound_shell_controlled: bool) -> bool {
    sound_shell_controlled
}

/// Whether a finished command beeps: the toggle, and a non-zero exit.
#[must_use]
pub const fn should_beep_on_error(exit: Option<i32>, sound_on_error: bool) -> bool {
    sound_on_error && !is_clean(exit)
}

// MARK: The flood bound

/// A token bucket bounding how many explicit notifications one remote shell can post.
///
/// Deterministic — the caller passes a monotonic `now`, so the rule is testable without a clock. It
/// exists because the notifications it bounds are requested by a REMOTE process: a buggy or hostile
/// child can ask for one per line of output, and Notification Center has no bound of its own.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RateLimiter {
    /// Tokens available immediately, and the ceiling refilling cannot pass.
    pub capacity: f64,
    /// Tokens returned per second.
    pub refill_per_second: f64,
    /// Tokens left right now.
    pub tokens: f64,
    /// When `tokens` was last brought up to date.
    pub last_refill: f64,
}

/// How many explicit notifications a shell may post back to back before the bucket empties.
///
/// A burst is what a legitimate build script produces — a handful of OSC 9s as it finishes stages —
/// so the bound has to let that through and still stop a loop. Five is that line.
pub const EXPLICIT_BURST: f64 = 5.0;

/// How fast the burst comes back: one notification every two seconds.
pub const EXPLICIT_REFILL_PER_SECOND: f64 = 0.5;

impl RateLimiter {
    /// A full bucket at the burst and refill rate the caller names.
    ///
    /// Resting means FULL: the tokens start at the capacity rather than at zero, so the first
    /// notification after a fresh attach is delivered rather than swallowed while the bucket fills.
    /// That is the half of this constructor which is a rule and not an assignment, and it crosses
    /// as `slopdesk_ws_notify_rate_limiter` for exactly that reason — the near side used to fill
    /// the four fields itself, which meant one side of the boundary decided what "a new bucket"
    /// starts with.
    #[must_use]
    pub const fn new(capacity: f64, refill_per_second: f64, now: f64) -> Self {
        Self {
            capacity,
            refill_per_second,
            tokens: capacity,
            last_refill: now,
        }
    }

    /// The bucket the explicit (OSC 9/777) path ships with, at [`EXPLICIT_BURST`] and
    /// [`EXPLICIT_REFILL_PER_SECOND`].
    ///
    /// The numbers live here rather than in a caller's default argument, the way
    /// [`crate::chrome`]'s dwell gate does: they are the anti-flood POLICY, and a second spelling
    /// of them would be a second opinion about how much a hostile shell may post.
    #[must_use]
    pub const fn explicit(now: f64) -> Self {
        Self::new(EXPLICIT_BURST, EXPLICIT_REFILL_PER_SECOND, now)
    }

    /// Refills by elapsed time, then spends a token if there is one.
    ///
    /// The two comparisons are [`f64::min`]/[`f64::max`], which are IEEE-ordered: a clock that
    /// jumped backwards contributes no tokens rather than a negative count, and a `NaN` elapsed
    /// cannot decide the branch.
    pub fn allow(&mut self, now: f64) -> bool {
        let elapsed = f64::max(0.0, now - self.last_refill);
        self.tokens = f64::min(self.capacity, self.tokens + elapsed * self.refill_per_second);
        self.last_refill = now;
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        AgentSound, Badge, EXPLICIT_BURST, EXPLICIT_REFILL_PER_SECOND, Event, Flavour, ForegroundPolicy,
        LONG_RUNNING_THRESHOLD_MS, RateLimiter, Settings, Speaker, agent_sound, badge, explicit_content,
        is_long_running, should_beep_on_error, should_deliver, should_notify_completion, should_ring_bell,
        toast_headline,
    };

    #[test]
    fn a_fresh_install_is_quiet_about_success_and_loud_about_failure() {
        let shipped = Settings::default();
        assert!(!shipped.notify_on_finish, "a clean finish is most of them");
        assert!(shipped.notify_on_error);
        assert!(shipped.notify_on_watch_finish);
        assert!(shipped.app_notifications_enabled);
        assert!(shipped.agent_notify_task_complete);
        assert!(shipped.agent_notify_await_input);
        assert_eq!(shipped.foreground, ForegroundPolicy::Off);
    }

    #[test]
    fn a_completion_with_no_code_is_gated_as_a_clean_one() {
        let settings = Settings {
            notify_on_finish: false,
            notify_on_error: true,
            ..Settings::default()
        };
        let event = Event::CommandFinish { exit: None };
        assert!(
            !should_deliver(event, false, false, settings),
            "an absent code rides Notify on Finish, not Notify on Error"
        );
        assert!(should_deliver(
            Event::CommandFinish { exit: Some(1) },
            false,
            false,
            settings
        ));
    }

    #[test]
    fn the_foreground_gate_only_gates_while_the_app_is_frontmost() {
        let event = Event::ExplicitOsc;
        for policy in [
            ForegroundPolicy::Off,
            ForegroundPolicy::Always,
            ForegroundPolicy::TabUnfocused,
        ] {
            let settings = Settings {
                foreground: policy,
                ..Settings::default()
            };
            assert!(
                should_deliver(event, false, true, settings),
                "backgrounded, the OS shows it whatever the policy says"
            );
        }
    }

    #[test]
    fn tab_unfocused_reads_visibility_rather_than_focus() {
        let settings = Settings {
            foreground: ForegroundPolicy::TabUnfocused,
            ..Settings::default()
        };
        assert!(!should_deliver(Event::ExplicitOsc, true, true, settings));
        assert!(should_deliver(Event::ExplicitOsc, true, false, settings));
    }

    #[test]
    fn each_event_rides_exactly_one_toggle() {
        let all_off = Settings {
            app_notifications_enabled: false,
            notify_on_finish: false,
            notify_on_error: false,
            notify_on_watch_finish: false,
            foreground: ForegroundPolicy::Always,
            agent_notify_task_complete: false,
            agent_notify_await_input: false,
        };
        for event in [
            Event::ExplicitOsc,
            Event::CommandFinish { exit: Some(0) },
            Event::CommandFinish { exit: Some(2) },
            Event::WatchFinish,
            Event::AgentTaskComplete,
            Event::AgentAwaitInput,
        ] {
            assert!(!should_deliver(event, true, false, all_off));
        }
        let only_watch = Settings {
            notify_on_watch_finish: true,
            ..all_off
        };
        assert!(should_deliver(Event::WatchFinish, true, false, only_watch));
        assert!(!should_deliver(Event::ExplicitOsc, true, false, only_watch));
    }

    #[test]
    fn a_short_failure_badges_but_does_not_interrupt() {
        assert_eq!(
            badge(Some(1), 5, false, LONG_RUNNING_THRESHOLD_MS),
            Some(Badge::Failure)
        );
        assert!(
            !should_notify_completion(5, false, true, LONG_RUNNING_THRESHOLD_MS),
            "a badge is found later; a banner interrupts"
        );
    }

    #[test]
    fn a_focused_pane_neither_badges_nor_interrupts() {
        assert_eq!(badge(Some(1), 60_000, true, LONG_RUNNING_THRESHOLD_MS), None);
        assert!(!should_notify_completion(
            60_000,
            true,
            true,
            LONG_RUNNING_THRESHOLD_MS
        ));
    }

    #[test]
    fn the_long_threshold_is_inclusive_at_ten_seconds() {
        assert!(!is_long_running(LONG_RUNNING_THRESHOLD_MS - 1));
        assert!(is_long_running(LONG_RUNNING_THRESHOLD_MS));
        assert_eq!(
            badge(None, LONG_RUNNING_THRESHOLD_MS, false, LONG_RUNNING_THRESHOLD_MS),
            Some(Badge::Success)
        );
        assert_eq!(
            badge(
                None,
                LONG_RUNNING_THRESHOLD_MS - 1,
                false,
                LONG_RUNNING_THRESHOLD_MS
            ),
            None,
            "a quick background success leaves no mark"
        );
    }

    #[test]
    fn a_titleless_notification_promotes_its_body_rather_than_showing_blank() {
        assert_eq!(
            explicit_content("  ", "  ", "build done"),
            ("build done".to_owned(), String::new())
        );
        assert_eq!(
            explicit_content("make", "  ", "build done"),
            ("make".to_owned(), "build done".to_owned())
        );
        assert_eq!(
            explicit_content("make", " deploy ", "build done"),
            ("deploy".to_owned(), "build done".to_owned())
        );
    }

    #[test]
    fn the_agent_cue_ignores_focus_and_answers_its_own_toggle() {
        assert_eq!(agent_sound(true, false, true), Some(AgentSound::AwaitInput));
        assert_eq!(agent_sound(false, true, false), Some(AgentSound::TaskComplete));
        assert_eq!(agent_sound(true, true, false), None);
        assert_eq!(agent_sound(false, false, true), None);
    }

    #[test]
    fn a_beep_needs_its_toggle_and_a_failure() {
        assert!(should_ring_bell(true));
        assert!(!should_ring_bell(false));
        assert!(should_beep_on_error(Some(1), true));
        assert!(!should_beep_on_error(Some(0), true));
        assert!(!should_beep_on_error(None, true));
        assert!(!should_beep_on_error(Some(1), false));
    }

    #[test]
    fn the_bucket_bursts_to_capacity_then_refills_by_elapsed_time() {
        let mut limiter = RateLimiter::new(5.0, 0.5, 100.0);
        assert_eq!(
            (0..7).filter(|_| limiter.allow(100.0)).count(),
            5,
            "the burst is the capacity"
        );
        assert!(!limiter.allow(101.0), "half a token is not one");
        assert!(limiter.allow(102.0), "two seconds buys one back");
    }

    #[test]
    fn a_clock_that_went_backwards_neither_refills_nor_drains() {
        let mut limiter = RateLimiter::new(5.0, 0.5, 100.0);
        assert!(limiter.allow(50.0));
        assert!(
            (limiter.tokens - 4.0).abs() < f64::EPSILON,
            "elapsed floors at zero rather than removing tokens"
        );
    }

    #[test]
    fn an_agent_and_a_command_say_different_words_about_the_same_flavour() {
        assert_eq!(
            toast_headline(Speaker::Agent, Flavour::Success, "claude"),
            "claude is done"
        );
        assert_eq!(
            toast_headline(Speaker::Command, Flavour::Success, "make check"),
            "make check finished"
        );
    }

    #[test]
    fn every_agent_rung_gets_its_own_verb() {
        assert_eq!(
            toast_headline(Speaker::Agent, Flavour::Attention, "codex"),
            "codex needs input"
        );
        assert_eq!(
            toast_headline(Speaker::Agent, Flavour::Failure, "codex"),
            "codex failed"
        );
        assert_eq!(
            toast_headline(Speaker::Agent, Flavour::Notice, "codex"),
            "codex is working"
        );
    }

    #[test]
    fn a_commands_own_words_are_left_alone() {
        // An OSC line and a waiting prompt both arrive already phrased.
        assert_eq!(
            toast_headline(Speaker::Command, Flavour::Notice, "Build succeeded in 4s"),
            "Build succeeded in 4s"
        );
        assert_eq!(
            toast_headline(Speaker::Command, Flavour::Attention, "Overwrite file?"),
            "Overwrite file?"
        );
    }

    #[test]
    fn a_subject_is_trimmed_before_the_verb_is_hung_on_it() {
        assert_eq!(
            toast_headline(Speaker::Agent, Flavour::Success, "  claude \n"),
            "claude is done",
            "a pane title carrying whitespace must not open a gap before the verb"
        );
    }

    #[test]
    fn a_nameless_pane_still_reads_as_a_sentence() {
        assert_eq!(
            toast_headline(Speaker::Agent, Flavour::Success, "   "),
            "The agent is done"
        );
        assert_eq!(
            toast_headline(Speaker::Command, Flavour::Failure, ""),
            "The command failed"
        );
    }

    #[test]
    fn a_verbatim_flavour_with_nothing_to_say_says_nothing() {
        assert!(
            toast_headline(Speaker::Command, Flavour::Notice, "  ").is_empty(),
            "no noun can be invented for a message that was supposed to carry its own"
        );
    }

    /// A new bucket is FULL, not empty. Starting it at zero would swallow the first explicit
    /// notification of every attach while it filled, which is the one nobody would suspect a rate
    /// limiter of.
    #[test]
    fn a_fresh_bucket_rests_full_and_spends_exactly_its_burst() {
        let mut bucket = RateLimiter::new(3.0, 1.0, 100.0);
        assert_eq!(
            bucket.tokens.to_bits(),
            3.0_f64.to_bits(),
            "a resting bucket starts at its capacity"
        );
        assert_eq!(bucket.last_refill.to_bits(), 100.0_f64.to_bits());
        assert!(bucket.allow(100.0));
        assert!(bucket.allow(100.0));
        assert!(bucket.allow(100.0));
        assert!(!bucket.allow(100.0), "the burst IS the capacity");
        assert!(bucket.allow(101.0), "a second buys one back at this rate");
    }

    /// Two separate claims. That the constructor wires the two constants to the two fields — which
    /// is asserted against the constants, not against literals, so a retune moves the test with it.
    /// And that those values still describe a bucket a build script gets through and a loop does
    /// not, which is the only thing the numbers were chosen for; a retune that broke THAT should
    /// have to say so here.
    #[test]
    fn the_explicit_bucket_lets_a_build_script_through_and_stops_a_loop() {
        let mut bucket = RateLimiter::explicit(0.0);
        assert_eq!(bucket.capacity.to_bits(), EXPLICIT_BURST.to_bits());
        assert_eq!(
            bucket.refill_per_second.to_bits(),
            EXPLICIT_REFILL_PER_SECOND.to_bits()
        );
        let burst = (0..6).filter(|_| bucket.allow(0.0)).count();
        assert_eq!(burst, 5, "five back to back, and the sixth is dropped");
        assert!(!bucket.allow(1.9), "under two seconds buys nothing back");
        assert!(bucket.allow(2.0), "two seconds buys exactly one");
    }
}
