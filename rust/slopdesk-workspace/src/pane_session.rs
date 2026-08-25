//! What a LIVE pane may do next: the agent fold, the inspector's second channel, the video latch.
//!
//! One pane's live session owns three things the workspace layer cannot: a terminal connection, a
//! read-only inspector socket beside it, and — for a desktop pane — a video window. What is here is
//! every DECISION those three make, and none of the handles. A status byte arrives and the rules
//! say whether the pane's reading moved and whether the second channel opens; a lifecycle call
//! arrives and the rules say whether the video window opens, mirrors or closes; a chip's `×` is
//! clicked and the rules say which actuator it drives.
//!
//! ## No handle, no identity, no task
//!
//! Nothing here is told which pane it is reading, and nothing here can start or cancel anything. A
//! gate is handed the three FACTS it reads — is a claude detected, is there a model, is a client
//! already live — and answers whether it opens. The near side still owns the `Task`, the socket and
//! the cancellation, because those are the parts that are not a rule.
//!
//! For the same reason [`InspectorGate::allows`] stops at the three PURE preconditions: the fourth
//! line of the near side's subscribe (`let target, let client = makeInspector(target())`) is a
//! MATERIALIZATION rather than a gate — it builds the thing it tests for — and reading it as a
//! second spelling of [`InspectorFacts::has_model`] is exactly the mistake this paragraph exists to
//! prevent.
//!
//! ## A status crosses as its URGENCY byte
//!
//! [`ClaudeStatus`] has a canonical `u8` — its rollup urgency — which round-trips exactly and is
//! the same byte the wire's type-27 `state` field carries. So the fold takes the pane's current
//! urgency and the frame's raw byte, and answers an urgency: no second spelling of the five-case
//! enum, and the forward-tolerance (an unknown byte degrades to `.none`) is
//! [`ClaudeStatus::from_urgency`]'s, applied once.

use slopdesk_agent::status::ClaudeStatus;

use crate::status_pill::Pill;

// ---------------------------------------------------------------------------------------------- //
// The agent signal fold
// ---------------------------------------------------------------------------------------------- //

/// What one folded status change does to the inspector's second channel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InspectorEffect {
    /// Neither edge: the channel stays exactly as it is.
    Nothing,
    /// A claude just appeared in this terminal — open the read-only second channel.
    Open,
    /// The claude is gone — the pane is a plain terminal again and holds no inspector socket.
    Close,
}

impl InspectorEffect {
    /// Every effect, in discriminant order.
    pub const ALL: [Self; 3] = [Self::Nothing, Self::Open, Self::Close];

    /// Its discriminant, as it crosses.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Nothing => 0,
            Self::Open => 1,
            Self::Close => 2,
        }
    }

    /// The effect a discriminant names, or `None` for one this build does not know.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::Nothing),
            1 => Some(Self::Open),
            2 => Some(Self::Close),
            _ => None,
        }
    }
}

/// What one type-27 frame leaves behind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StatusFold {
    /// The status the pane holds AFTER the fold, as its urgency byte.
    pub urgency: u8,
    /// Whether the status actually moved. `false` ⇒ write nothing: the near side's status is an
    /// observed property, and re-assigning an equal value would re-render every surface reading it
    /// for a frame that said nothing.
    pub changed: bool,
    /// What the move does to the second channel.
    pub effect: InspectorEffect,
}

/// The fold of one type-27 `claudeStatus` frame into a pane's display state.
///
/// The client is a PASSIVE display: the host owns the one status machine, and this trusts its
/// verdict verbatim rather than re-deriving presence. Three rules, in this order:
///
/// 1. A pane that cannot host an agent — a desktop pane, which has no PTY — folds nothing. Its
///    status stays whatever it was, which is `.none`.
/// 2. An identical status is not a change. The dedupe is what keeps a host's reattach re-assert
///    from churning the channel, and it is also why the reconnect edge needs
///    [`InspectorGate::Reconnect`]: the re-assert repeats the byte, so the open edge never re-fires
///    on its own.
/// 3. Only the `.none` BOUNDARY moves the second channel. `idle → working` is a change with no
///    effect; a socket is opened when an agent appears and closed when it leaves.
///
/// An unknown or future `wire_state` degrades to `.none` — a hostile datagram can close a channel
/// but can never trap the client.
#[must_use]
pub fn fold_status(detectable: bool, current: u8, wire_state: u8) -> StatusFold {
    let held = ClaudeStatus::from_urgency(current);
    if !detectable {
        return StatusFold {
            urgency: held.urgency(),
            changed: false,
            effect: InspectorEffect::Nothing,
        };
    }
    let next = ClaudeStatus::from_urgency(wire_state);
    if held == next {
        return StatusFold {
            urgency: held.urgency(),
            changed: false,
            effect: InspectorEffect::Nothing,
        };
    }
    let was_active = held != ClaudeStatus::None;
    let is_active = next != ClaudeStatus::None;
    let effect = if !was_active && is_active {
        InspectorEffect::Open
    } else if was_active && !is_active {
        InspectorEffect::Close
    } else {
        InspectorEffect::Nothing
    };
    StatusFold {
        urgency: next.urgency(),
        changed: true,
        effect,
    }
}

/// Whether a type-26 frame NAMES a foreground process.
///
/// An empty name is the ABSENCE of one, not a process called nothing, and that is the whole rule:
/// type 26 is a coarse display-only hint that may never touch the status, so the only judgement it
/// carries is whether there is anything to show. The name itself never crosses — it is a string the
/// near side already holds and would only be copying to have it handed straight back.
#[must_use]
pub const fn names_foreground(name: &str) -> bool {
    !name.is_empty()
}

// ---------------------------------------------------------------------------------------------- //
// The inspector's second channel
// ---------------------------------------------------------------------------------------------- //

/// The three facts every inspector-channel gate reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InspectorFacts {
    /// Whether a claude is detected in this pane right now — the RUNTIME status, never a stored
    /// pane kind. A plain terminal opens no inspector socket until one appears.
    pub agent_present: bool,
    /// Whether the pane has an inspector MODEL at all. A build-time fact: every terminal has one,
    /// no desktop pane does.
    pub has_model: bool,
    /// Whether a live client is already subscribed.
    pub has_client: bool,
}

/// The three places the second channel is asked whether it may open.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InspectorGate {
    /// The subscribe itself, called on appear and by both re-arms. Idempotent by this gate.
    Subscribe,
    /// The iOS foreground fan-out, which spawns a subscribe when the pane still holds an agent and
    /// the pause closed its client.
    Resume,
    /// The transport-reconnect re-arm (a wifi flap on macOS, where pause/resume never run). The
    /// stale client is torn down by the caller FIRST, so this gate does not read one.
    Reconnect,
}

impl InspectorGate {
    /// Every gate, in discriminant order.
    pub const ALL: [Self; 3] = [Self::Subscribe, Self::Resume, Self::Reconnect];

    /// Its discriminant, as it crosses.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Subscribe => 0,
            Self::Resume => 1,
            Self::Reconnect => 2,
        }
    }

    /// The gate a discriminant names, or `None` for one this build does not know.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::Subscribe),
            1 => Some(Self::Resume),
            2 => Some(Self::Reconnect),
            _ => None,
        }
    }

    /// Whether this gate opens on `facts`.
    ///
    /// [`Subscribe`](Self::Subscribe) and [`Resume`](Self::Resume) are the SAME predicate, and
    /// naming them apart is the point: the resume path spawns a subscribe that re-tests the gate,
    /// so the two agreeing is a property worth pinning rather than a duplication worth collapsing.
    /// [`Reconnect`](Self::Reconnect) is the one that differs, because it drops the stale client
    /// itself — reading `has_client` there would early-out on the very dead socket it exists to
    /// replace, which is the bug the reconnect re-arm was added for.
    #[must_use]
    pub const fn allows(self, facts: InspectorFacts) -> bool {
        match self {
            Self::Subscribe | Self::Resume => facts.agent_present && facts.has_model && !facts.has_client,
            Self::Reconnect => facts.agent_present && facts.has_model,
        }
    }
}

// ---------------------------------------------------------------------------------------------- //
// Video activation
// ---------------------------------------------------------------------------------------------- //

/// Everything a video activation reads about the pane it is acting on.
#[expect(
    clippy::struct_excessive_bools,
    reason = "four independent facts about two different objects — the pane's kind, whether it has a window \
              model, and two states of that model; a bitfield would spell four bit positions on both sides \
              of the boundary to save nothing"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VideoFacts {
    /// Whether the pane's kind streams video at all.
    pub is_video: bool,
    /// Whether the pane holds a window model.
    pub has_model: bool,
    /// Whether that model already carries an active descriptor.
    pub is_open: bool,
    /// Whether the model is configured enough to be opened.
    pub can_open: bool,
}

/// What one `setVideoActive` call does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoStep {
    /// Nothing at all: this is not a video pane, or it holds no model. The mirrored flag is not
    /// even re-read — a non-video pane's is always `false`.
    Ignore,
    /// Open the window, then mirror the descriptor the open produced.
    Open,
    /// Do not open — it is already open, or it is not configured — but MIRROR the descriptor as it
    /// stands. An unconfigured pane mirrors its way back to `false`, which is how a request to
    /// stream something that cannot be streamed reports itself.
    Mirror,
    /// Close the window and clear the flag.
    Close,
}

impl VideoStep {
    /// Every step, in discriminant order.
    pub const ALL: [Self; 4] = [Self::Ignore, Self::Open, Self::Mirror, Self::Close];

    /// Its discriminant, as it crosses.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Ignore => 0,
            Self::Open => 1,
            Self::Mirror => 2,
            Self::Close => 3,
        }
    }

    /// The step a discriminant names, or `None` for one this build does not know.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::Ignore),
            1 => Some(Self::Open),
            2 => Some(Self::Mirror),
            3 => Some(Self::Close),
            _ => None,
        }
    }
}

/// What a request to activate or deactivate a pane's video does.
///
/// Deactivation is unconditional for a video pane that has a model: closing an already-closed
/// window is idempotent, and a deactivate that consulted `is_open` first would be trusting a
/// mirrored flag to decide whether to release a UDP stack.
#[must_use]
pub const fn activation_step(facts: VideoFacts, active: bool) -> VideoStep {
    if !facts.is_video || !facts.has_model {
        return VideoStep::Ignore;
    }
    if !active {
        return VideoStep::Close;
    }
    if !facts.is_open && facts.can_open {
        VideoStep::Open
    } else {
        VideoStep::Mirror
    }
}

/// Whether the foreground fan-out re-opens this pane's stream.
///
/// The latch is set on the way into background and read on the way out, so this re-opens AT MOST
/// what was already streaming — which is what makes it cap-safe without consulting the store: a set
/// that already satisfied the live-video cap cannot exceed it by being restored.
#[must_use]
pub const fn resume_reopens_video(is_video: bool, was_active: bool) -> bool {
    is_video && was_active
}

/// Whether a pane closing for good must close a video window on the way out.
///
/// The two facts are deliberately OR-ed rather than reduced to the mirrored flag: a window that
/// opened without the flag ever being mirrored — an open that raced a teardown — would otherwise
/// leave its capture orchestrator running with nothing on screen to say so.
#[must_use]
pub const fn teardown_closes_video(is_active: bool, has_descriptor: bool) -> bool {
    is_active || has_descriptor
}

/// Which shape of video model a pane spec asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoMount {
    /// One host WINDOW, by id — the automation seam only.
    Window,
    /// A whole display, by id, where `0` is the main one.
    Desktop,
}

impl VideoMount {
    /// Every mount, in discriminant order.
    pub const ALL: [Self; 2] = [Self::Window, Self::Desktop];

    /// Its discriminant, as it crosses.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Window => 0,
            Self::Desktop => 1,
        }
    }

    /// The mount a discriminant names, or `None` for one this build does not know.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::Window),
            1 => Some(Self::Desktop),
            _ => None,
        }
    }
}

/// Which model a video pane's spec mounts.
///
/// The window shape is the NARROW one and needs all three: a video block, no display named, and a
/// real window id. Everything else is a desktop — including a spec carrying both a display and a
/// window, because a display named explicitly is the answer to "which screen" and a window id
/// beside it is left over from a seam that served one window at a time.
///
/// A window id of `0` is no window. That is the platform's own convention for an unset id, and
/// carrying it as an `Option` here would make the near side spell a second one.
#[must_use]
pub const fn video_mount(has_video_spec: bool, has_display_id: bool, window_id: u32) -> VideoMount {
    if has_video_spec && !has_display_id && window_id != 0 {
        VideoMount::Window
    } else {
        VideoMount::Desktop
    }
}

// ---------------------------------------------------------------------------------------------- //
// The scrollback capture tail
// ---------------------------------------------------------------------------------------------- //

/// Where a capture of the last `count` lines of `available` STARTS, or `None` when it captures
/// nothing.
///
/// A non-positive count is refused rather than clamped: `--lines 0` asked for nothing and gets
/// nothing, and a negative one is the hostile datagram the control lane already refuses upstream.
/// A count larger than the scrollback starts at the top, which is what taking a suffix means and
/// why the arithmetic saturates rather than wrapping.
#[must_use]
pub fn capture_tail_start(count: i64, available: usize) -> Option<usize> {
    if count <= 0 {
        return None;
    }
    let want = usize::try_from(count).unwrap_or(usize::MAX);
    Some(available.saturating_sub(want))
}

// ---------------------------------------------------------------------------------------------- //
// The status chip's dismiss
// ---------------------------------------------------------------------------------------------- //

/// What the `×` on a status chip actually does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DismissRoute {
    /// Release the pane's read-only lock through its terminal MODEL, whose own hook converges the
    /// store's read-only set. Going to the store directly would leave the model still gating.
    ReadOnly,
    /// Disarm the whole TAB's synchronized input. The mode belongs to the tab, so clearing it on
    /// one pane would leave the siblings still fanning keystrokes out.
    SyncInput,
    /// Nothing: this chip carries no `×`.
    Nothing,
}

impl DismissRoute {
    /// Every route, in discriminant order.
    pub const ALL: [Self; 3] = [Self::ReadOnly, Self::SyncInput, Self::Nothing];

    /// Its discriminant, as it crosses.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::ReadOnly => 0,
            Self::SyncInput => 1,
            Self::Nothing => 2,
        }
    }

    /// The route a discriminant names, or `None` for one this build does not know.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            0 => Some(Self::ReadOnly),
            1 => Some(Self::SyncInput),
            2 => Some(Self::Nothing),
            _ => None,
        }
    }
}

/// Which actuator a chip's `×` drives.
///
/// Every arm is spelled out rather than defaulted, so a fourth chip is a compile error here instead
/// of a silently inert `×` on screen. Secure input is the one that routes nowhere, and that is a
/// DECISION rather than an omission — it is a safety indicator the user does not click away, which
/// is the same reason [`Pill::is_dismissible`] answers `false` for it.
#[must_use]
pub const fn dismiss_route(pill: Pill) -> DismissRoute {
    match pill {
        Pill::ReadOnly => DismissRoute::ReadOnly,
        Pill::SyncInput => DismissRoute::SyncInput,
        Pill::SecureInput => DismissRoute::Nothing,
    }
}

// ---------------------------------------------------------------------------------------------- //
// Tests
// ---------------------------------------------------------------------------------------------- //

#[cfg(test)]
mod tests {
    use super::{
        DismissRoute, InspectorEffect, InspectorFacts, InspectorGate, Pill, VideoFacts, VideoMount,
        VideoStep, activation_step, capture_tail_start, dismiss_route, fold_status, names_foreground,
        resume_reopens_video, teardown_closes_video, video_mount,
    };

    /// The five urgency bytes, by name, so a test reads as the status it means.
    const NONE: u8 = 0;
    const IDLE: u8 = 1;
    const DONE: u8 = 2;
    const WORKING: u8 = 3;
    const BLOCKED: u8 = 4;

    // -- the agent signal fold ------------------------------------------------------------------

    #[test]
    fn a_an_agent_appearing_opens_the_second_channel() {
        let fold = fold_status(true, NONE, WORKING);
        assert_eq!(fold.urgency, WORKING);
        assert!(fold.changed);
        assert_eq!(fold.effect, InspectorEffect::Open);
    }

    #[test]
    fn an_agent_leaving_closes_the_second_channel() {
        let fold = fold_status(true, BLOCKED, NONE);
        assert_eq!(fold.urgency, NONE);
        assert!(fold.changed);
        assert_eq!(fold.effect, InspectorEffect::Close);
    }

    #[test]
    fn a_move_inside_the_active_band_touches_no_socket() {
        for (from, to) in [(IDLE, WORKING), (WORKING, DONE), (DONE, BLOCKED)] {
            let fold = fold_status(true, from, to);
            assert!(fold.changed, "{from} -> {to}");
            assert_eq!(fold.effect, InspectorEffect::Nothing, "{from} -> {to}");
            assert_eq!(fold.urgency, to);
        }
    }

    #[test]
    fn a_repeated_status_is_not_a_change() {
        // The host's reattach re-assert repeats the byte verbatim; this is the guard that eats it,
        // and the reason the reconnect gate exists at all.
        for byte in [NONE, IDLE, DONE, WORKING, BLOCKED] {
            let fold = fold_status(true, byte, byte);
            assert!(!fold.changed, "{byte}");
            assert_eq!(fold.effect, InspectorEffect::Nothing, "{byte}");
            assert_eq!(fold.urgency, byte);
        }
    }

    #[test]
    fn an_undetectable_pane_folds_nothing() {
        let fold = fold_status(false, NONE, BLOCKED);
        assert_eq!(fold.urgency, NONE);
        assert!(!fold.changed);
        assert_eq!(fold.effect, InspectorEffect::Nothing);
    }

    #[test]
    fn an_unknown_wire_byte_degrades_to_no_agent() {
        // Forward-tolerant: a future or hostile state byte reads as `.none` rather than trapping.
        let fold = fold_status(true, WORKING, 200);
        assert_eq!(fold.urgency, NONE);
        assert!(fold.changed);
        assert_eq!(fold.effect, InspectorEffect::Close);
        let quiet = fold_status(true, NONE, u8::MAX);
        assert!(!quiet.changed, "an unknown byte over `.none` is still `.none`");
    }

    #[test]
    fn every_fold_answers_a_byte_that_round_trips() {
        for current in 0_u8..=8 {
            for wire in 0_u8..=8 {
                let fold = fold_status(true, current, wire);
                assert_eq!(
                    fold_status(true, fold.urgency, fold.urgency).urgency,
                    fold.urgency,
                    "{current} -> {wire}",
                );
            }
        }
    }

    #[test]
    fn every_inspector_effect_round_trips_through_its_code() {
        for effect in InspectorEffect::ALL {
            assert_eq!(InspectorEffect::from_code(effect.code()), Some(effect));
        }
        let codes: Vec<u8> = InspectorEffect::ALL.iter().map(|e| e.code()).collect();
        assert_eq!(codes, vec![0, 1, 2]);
        assert_eq!(InspectorEffect::from_code(3), None);
    }

    #[test]
    fn a_named_foreground_process_is_a_non_empty_one() {
        assert!(names_foreground("claude"));
        assert!(names_foreground(" "), "a blank name is still a name to show");
        assert!(!names_foreground(""));
    }

    // -- the inspector gates --------------------------------------------------------------------

    const fn facts(agent_present: bool, has_model: bool, has_client: bool) -> InspectorFacts {
        InspectorFacts {
            agent_present,
            has_model,
            has_client,
        }
    }

    #[test]
    fn b_a_subscribe_needs_an_agent_a_model_and_no_client() {
        assert!(InspectorGate::Subscribe.allows(facts(true, true, false)));
        assert!(!InspectorGate::Subscribe.allows(facts(false, true, false)));
        assert!(!InspectorGate::Subscribe.allows(facts(true, false, false)));
        assert!(!InspectorGate::Subscribe.allows(facts(true, true, true)));
    }

    #[test]
    fn the_resume_gate_is_the_subscribe_gate() {
        for agent in [false, true] {
            for model in [false, true] {
                for client in [false, true] {
                    let read = facts(agent, model, client);
                    assert_eq!(
                        InspectorGate::Subscribe.allows(read),
                        InspectorGate::Resume.allows(read),
                        "{read:?}",
                    );
                }
            }
        }
    }

    #[test]
    fn the_reconnect_gate_ignores_a_stale_client() {
        // The dead socket is exactly what it is there to replace.
        assert!(InspectorGate::Reconnect.allows(facts(true, true, true)));
        assert!(InspectorGate::Reconnect.allows(facts(true, true, false)));
        assert!(!InspectorGate::Reconnect.allows(facts(false, true, true)));
        assert!(!InspectorGate::Reconnect.allows(facts(true, false, true)));
    }

    #[test]
    fn every_inspector_gate_round_trips_through_its_code() {
        for gate in InspectorGate::ALL {
            assert_eq!(InspectorGate::from_code(gate.code()), Some(gate));
        }
        let codes: Vec<u8> = InspectorGate::ALL.iter().map(|g| g.code()).collect();
        assert_eq!(codes, vec![0, 1, 2]);
        assert_eq!(InspectorGate::from_code(3), None);
    }

    // -- video activation -----------------------------------------------------------------------

    #[expect(
        clippy::fn_params_excessive_bools,
        reason = "the four bools ARE `VideoFacts` — a fixture that renamed them would be a second \
                  vocabulary for the same record"
    )]
    const fn video(is_video: bool, has_model: bool, is_open: bool, can_open: bool) -> VideoFacts {
        VideoFacts {
            is_video,
            has_model,
            is_open,
            can_open,
        }
    }

    #[test]
    fn c_a_configured_closed_window_opens() {
        assert_eq!(
            activation_step(video(true, true, false, true), true),
            VideoStep::Open
        );
    }

    #[test]
    fn an_already_open_window_only_mirrors() {
        assert_eq!(
            activation_step(video(true, true, true, true), true),
            VideoStep::Mirror
        );
    }

    #[test]
    fn an_unconfigured_window_mirrors_its_way_back_to_false() {
        assert_eq!(
            activation_step(video(true, true, false, false), true),
            VideoStep::Mirror
        );
    }

    #[test]
    fn a_deactivate_closes_whatever_the_state_was() {
        for open in [false, true] {
            for configured in [false, true] {
                assert_eq!(
                    activation_step(video(true, true, open, configured), false),
                    VideoStep::Close,
                );
            }
        }
    }

    #[test]
    fn a_pane_with_no_video_or_no_model_is_untouched() {
        for active in [false, true] {
            assert_eq!(
                activation_step(video(false, true, false, true), active),
                VideoStep::Ignore,
            );
            assert_eq!(
                activation_step(video(true, false, false, true), active),
                VideoStep::Ignore,
            );
        }
    }

    #[test]
    fn every_video_step_round_trips_through_its_code() {
        for step in VideoStep::ALL {
            assert_eq!(VideoStep::from_code(step.code()), Some(step));
        }
        let codes: Vec<u8> = VideoStep::ALL.iter().map(|s| s.code()).collect();
        assert_eq!(codes, vec![0, 1, 2, 3]);
        assert_eq!(VideoStep::from_code(4), None);
    }

    #[test]
    fn only_a_latched_video_pane_re_opens_on_resume() {
        assert!(resume_reopens_video(true, true));
        assert!(!resume_reopens_video(true, false));
        assert!(!resume_reopens_video(false, true));
        assert!(!resume_reopens_video(false, false));
    }

    #[test]
    fn a_teardown_closes_on_either_evidence_of_a_window() {
        assert!(teardown_closes_video(true, false));
        assert!(teardown_closes_video(false, true));
        assert!(teardown_closes_video(true, true));
        assert!(!teardown_closes_video(false, false));
    }

    #[test]
    fn d_a_window_spec_needs_an_id_and_no_display() {
        assert_eq!(video_mount(true, false, 42), VideoMount::Window);
        assert_eq!(video_mount(true, false, 0), VideoMount::Desktop);
        assert_eq!(video_mount(true, true, 42), VideoMount::Desktop);
        assert_eq!(video_mount(false, false, 42), VideoMount::Desktop);
    }

    #[test]
    fn every_video_mount_round_trips_through_its_code() {
        for mount in VideoMount::ALL {
            assert_eq!(VideoMount::from_code(mount.code()), Some(mount));
        }
        let codes: Vec<u8> = VideoMount::ALL.iter().map(|m| m.code()).collect();
        assert_eq!(codes, vec![0, 1]);
        assert_eq!(VideoMount::from_code(2), None);
    }

    // -- the capture tail -----------------------------------------------------------------------

    #[test]
    fn e_a_capture_takes_the_last_lines() {
        assert_eq!(capture_tail_start(10, 100), Some(90));
        assert_eq!(capture_tail_start(1, 1), Some(0));
    }

    #[test]
    fn a_capture_wider_than_the_scrollback_starts_at_the_top() {
        assert_eq!(capture_tail_start(1000, 10), Some(0));
        assert_eq!(capture_tail_start(i64::MAX, 10), Some(0));
        assert_eq!(capture_tail_start(1, 0), Some(0));
    }

    #[test]
    fn a_non_positive_capture_takes_nothing() {
        assert_eq!(capture_tail_start(0, 100), None);
        assert_eq!(capture_tail_start(-1, 100), None);
        assert_eq!(capture_tail_start(i64::MIN, 100), None);
    }

    // -- the dismiss route ----------------------------------------------------------------------

    #[test]
    fn f_each_chip_dismisses_through_its_own_actuator() {
        assert_eq!(dismiss_route(Pill::ReadOnly), DismissRoute::ReadOnly);
        assert_eq!(dismiss_route(Pill::SyncInput), DismissRoute::SyncInput);
        assert_eq!(dismiss_route(Pill::SecureInput), DismissRoute::Nothing);
    }

    /// The tie that keeps a chip's `×` and its route from drifting apart: a chip routes somewhere
    /// exactly when it says it carries one.
    #[test]
    fn a_chip_routes_somewhere_exactly_when_it_carries_a_cross() {
        for pill in Pill::ALL {
            assert_eq!(
                dismiss_route(pill) != DismissRoute::Nothing,
                pill.is_dismissible(),
                "{pill:?}",
            );
        }
    }

    #[test]
    fn every_dismiss_route_round_trips_through_its_code() {
        for route in DismissRoute::ALL {
            assert_eq!(DismissRoute::from_code(route.code()), Some(route));
        }
        let codes: Vec<u8> = DismissRoute::ALL.iter().map(|r| r.code()).collect();
        assert_eq!(codes, vec![0, 1, 2]);
        assert_eq!(DismissRoute::from_code(3), None);
    }
}
