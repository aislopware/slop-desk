//! # `slopdesk-devicepanel`
//!
//! The two device panels' shared decisions: what one ensure round MEANS, how soon to ask again, and
//! what to do about a selected device that has not produced a frame yet.
//!
//! The Android panel (docs/48) and the simulator panel (docs/47) are separate surfaces over
//! separate transports — `adb` and a scrcpy mirror on one side, `baguette` and a WebSocket on the
//! other — and none of that is here. What IS here is the part that was written twice: both panels
//! poll a host ENSURE verb, both turn its answer into the same four render phases, and both back
//! off on the same rule. The Swift these replace held two byte-identical copies of that ladder.
//!
//! - [`phase`] — one ensure round's endpoint → the phase to render.
//! - [`poll_backoff`] — how many poll intervals that phase waits before asking again.
//! - [`stream_verdict`] — a selection with no video yet, given what the device list just said.
//! - [`video_arrival_is_news`] — whether an arriving frame has anything to tell the observable
//!   layer.
//!
//! ## Answers, not identities
//!
//! Every rule here takes scalars and answers a KIND. A phase's host string and a device's serial
//! stay on the caller's side of the boundary: the panel already holds both, and handing one back
//! across a C ABI would be a copy made only to be compared with the one it came from.
//!
//! ## And where the frame is
//!
//! [`geometry`] is the other half that was written twice: where a device's frame sits in a sidebar,
//! what a point in that sidebar means, and where a synthetic finger may be planted.
//!
//! ## And which key was pressed
//!
//! [`panel_key`] is the third: which keys have no character of their own, what each server calls
//! them, and what to do with the ones that do. It replaced FOUR Swift tables with two, because two
//! of the four were a join `slopdesk-workspace` could already perform.
//!
//! ## And how a wheel becomes a finger
//!
//! [`scroll`] is the fifth: one virtual contact, planted under the cursor, moved by the wheel and
//! re-gripped at the edge. Both panels reached it from different directions — a `swipe` verb that
//! cost 275 ms on one side, a wheel verb with no fling on the other — and the machine they arrived
//! at was the same one, twice.
//!
//! ## And what the simulator's own server speaks
//!
//! [`sim_stream`], [`sim_input`] and [`sim_routes`] are a FOREIGN wire, which is why they are named
//! for the server rather than for a decision: `baguette serve` defines the dialect and this side
//! speaks it. There are no golden vectors to pin and no version byte anyone here controls, so what
//! they owe instead is what every untrusted decoder owes — an optional answer, and not one byte
//! read without a bounds check.
//!
//! ## And what its server SAYS BACK
//!
//! [`sim_chrome`], [`sim_devices`], [`sim_log`] and [`sim_place`] are the same foreign wire read in
//! the other direction: the device body `definition.json` describes, the device set
//! `/simulators.json` answers, the console batch the log socket sends, and the one coordinate the
//! location route takes. They keep that group's rule — an optional answer, and a malformed ROW
//! dropped rather than the envelope refused — and they are here rather than in a client because
//! each is a decision that would otherwise be made twice, once per renderer: which button can be
//! drawn, which row can be acted on, which console line survives, which typed string is a position
//! at all.
//!
//! ## And HOW it asks
//!
//! [`sim_control`] is the last quarter of that wire: the verb, the budget, the cache policy and the
//! body for every non-streaming call the panel makes. [`sim_routes`] answers WHERE a request goes
//! and this answers everything else about it — the pair the near side used to assemble at eleven
//! `URLSession` call sites, four of which spelled the same three values and two of which did not.
//!
//! ## And what the two panels SAY
//!
//! [`android`] and [`simulator`] are the fourth, and the one place the "answers, not identities"
//! rule above is deliberately not the whole story. Each panel is drawn by TWO renderers — `UIKit`
//! on the phone, `AppKit` on the Mac — so its copy, its verb tables and its silhouettes had one
//! speller by accident and now have one on purpose. They are two modules and not one for the
//! reason each header states: the surfaces look alike and share not one byte of protocol.
//!
//! ## And how a flat list becomes a SECTIONED one
//!
//! [`sections`] is the seventh, and the clearest case of all: the running group first, the families
//! in rank order, the fact a whole group agrees on lifted into its heading, and the identity a row
//! animates on. Two Swift files held that machine twice with different nouns — a runtime on one
//! side, an Android version on the other — and each panel is drawn by two renderers, so a drift
//! there would not have been a bug, it would have been two products.
//!
//! ## And what the Android sidebar DECIDES
//!
//! [`android_sidebar`] is the sixth, and the only one so far that is one panel's alone: which row a
//! device key or serial names, whether the boot and shutdown verbs may be offered over that list,
//! the eleven clocks and caps the loop runs on, and the six reports it writes. It keeps the rule
//! above — the lookup answers a POSITION into the list the caller still holds, and neither the key
//! nor the serial crosses.

pub mod android;
pub mod android_bridge;
pub mod android_sidebar;
pub mod geometry;
pub mod panel_key;
pub mod scroll;
pub mod sections;
pub mod sim_chrome;
pub mod sim_control;
pub mod sim_devices;
pub mod sim_input;
pub mod sim_log;
pub mod sim_place;
pub mod sim_routes;
pub mod sim_stream;
pub mod simulator;

use slopdesk_wire::metadata::{ServiceEndpoint, ServiceState};

/// What a device panel renders while it waits for, and then uses, a host-side service.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Phase {
    /// The ensure RPC got no answer — no connected pane channel (the app is offline), or a host too
    /// old to know the verb. Keep polling: the connection may come up.
    Offline = 0,
    /// The host is still bringing the service up — spinner, keep polling.
    Starting = 1,
    /// The tool the service needs is not installed on the host — render the install hint. Still
    /// polled, slowly: an install done mid-session is picked up without a restart.
    Unavailable = 2,
    /// The service is reachable. Everything else a panel does hangs off this.
    Ready = 3,
}

impl Phase {
    /// The byte the C door answers with.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// The phase for `byte`, or `None` for a value no build of this crate wrote.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Offline),
            1 => Some(Self::Starting),
            2 => Some(Self::Unavailable),
            3 => Some(Self::Ready),
            _ => None,
        }
    }
}

/// One ensure round's endpoint → the phase to render.
///
/// `has_address` is whether the CALLER holds a usable host name for the connection it would open —
/// the panel reads it per round, because the connection target can change mid-loop.
///
/// A `Ready` endpoint the caller cannot dial degrades to [`Phase::Offline`], never a trap: a
/// service that says it is listening on port `0`, or one this client has no address for, is a
/// surface that would render a connect button no click could satisfy. Polling continues and the
/// next round can answer differently.
#[must_use]
pub const fn phase(endpoint: Option<ServiceEndpoint>, has_address: bool) -> Phase {
    let Some(endpoint) = endpoint else {
        return Phase::Offline;
    };
    match endpoint.state() {
        ServiceState::Unavailable => Phase::Unavailable,
        ServiceState::Starting => Phase::Starting,
        ServiceState::Ready => {
            if has_address && endpoint.port != 0 {
                Phase::Ready
            } else {
                Phase::Offline
            }
        },
    }
}

/// How many poll intervals to wait before asking the ensure verb again — `0` means stop.
///
/// A reached service stops the loop; the loop is what was looking for it. The not-yet-running phase
/// re-polls at the base cadence, since a boot is seconds away. The other two back off, because they
/// only change on an operator's action — an install, a reconnect — and asking four times as often
/// would not make that action arrive sooner.
#[must_use]
pub const fn poll_backoff(phase: Phase) -> u32 {
    match phase {
        Phase::Ready => 0,
        Phase::Starting => 1,
        Phase::Offline | Phase::Unavailable => 4,
    }
}

/// What to do about a selection with no video yet, given what the device list just said.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum StreamVerdict {
    /// The device is ready — open (or re-open) the mirror now.
    Connect = 0,
    /// Not ready yet, patience left — keep the veil up and look again shortly.
    Wait = 1,
    /// The device left the list entirely. Say so and go back; there is nothing to look at.
    Gone = 2,
    /// Patience ran out on a RUNNING device — the stall message, with the retry button.
    Stalled = 3,
    /// Patience ran out on a device that never reached its running state.
    NeverReady = 4,
}

impl StreamVerdict {
    /// The byte the C door answers with.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// The verdict for `byte`, or `None` for a value no build of this crate wrote.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Connect),
            1 => Some(Self::Wait),
            2 => Some(Self::Gone),
            3 => Some(Self::Stalled),
            4 => Some(Self::NeverReady),
            _ => None,
        }
    }
}

/// The verdict for a selected device, where `is_running` is `None` for a device the latest list no
/// longer carries and `within_grace` is whether the wait's clock still has room.
///
/// This is the rule that turns a boot from a dead end into a wait. Measured 2026-08-07 against a
/// cold Android emulator: the mirror is REFUSED for the first ~21 s (the device lists as
/// `offline`), can stall for ~15 s more the moment the state turns, and succeeds cleanly after that
/// — so a refused or silent attempt while the device is not (yet) running means "again shortly",
/// not "broken". Once patience runs out the two failures are told apart, because they are different
/// sentences to read: a device that IS running and sent nothing has stalled, and one that never got
/// there never started.
#[must_use]
pub const fn stream_verdict(is_running: Option<bool>, within_grace: bool) -> StreamVerdict {
    let Some(is_running) = is_running else {
        return StreamVerdict::Gone;
    };
    match (is_running, within_grace) {
        (true, true) => StreamVerdict::Connect,
        (true, false) => StreamVerdict::Stalled,
        (false, true) => StreamVerdict::Wait,
        (false, false) => StreamVerdict::NeverReady,
    }
}

/// Whether an arriving frame has anything to tell the observable layer.
///
/// The FIRST one does — it ends the wait and turns the stage from a veil into a screen. Every one
/// after it says only what the layer already knows, and saying it anyway is a full invalidation per
/// frame. Both flags are read because they can disagree: a retry re-arms the wait, so a stream that
/// is awaited again is news again.
#[must_use]
pub const fn video_arrival_is_news(has_video: bool, is_awaiting_stream: bool) -> bool {
    !has_video || is_awaiting_stream
}

#[cfg(test)]
mod tests {
    use slopdesk_wire::metadata::{ServiceEndpoint, ServiceState};

    use super::{Phase, StreamVerdict, phase, poll_backoff, stream_verdict, video_arrival_is_news};

    const fn endpoint(state: ServiceState, port: u16) -> ServiceEndpoint {
        ServiceEndpoint {
            state_byte: state.as_byte(),
            port,
        }
    }

    #[test]
    fn a_reachable_endpoint_with_an_address_is_the_only_ready_phase() {
        assert_eq!(
            phase(Some(endpoint(ServiceState::Ready, 7421)), true),
            Phase::Ready
        );
    }

    #[test]
    fn an_unanswered_round_is_offline_rather_than_a_failure() {
        assert_eq!(phase(None, true), Phase::Offline);
    }

    #[test]
    fn the_two_waiting_states_cross_as_themselves() {
        assert_eq!(
            phase(Some(endpoint(ServiceState::Starting, 0)), true),
            Phase::Starting
        );
        assert_eq!(
            phase(Some(endpoint(ServiceState::Unavailable, 0)), true),
            Phase::Unavailable
        );
    }

    #[test]
    fn a_ready_service_nobody_can_dial_degrades_rather_than_traps() {
        // No port to connect to, and no address to connect it to: both are the same non-answer.
        assert_eq!(
            phase(Some(endpoint(ServiceState::Ready, 0)), true),
            Phase::Offline
        );
        assert_eq!(
            phase(Some(endpoint(ServiceState::Ready, 7421)), false),
            Phase::Offline
        );
    }

    #[test]
    fn a_state_byte_from_a_newer_host_keeps_the_panel_polling() {
        // The wire's own forward-tolerant read: an unknown byte is `Starting`, never the install
        // hint this build could not justify rendering.
        let future = ServiceEndpoint {
            state_byte: 200,
            port: 0,
        };
        assert_eq!(phase(Some(future), true), Phase::Starting);
    }

    #[test]
    fn the_loop_stops_on_the_phase_it_was_looking_for_and_backs_off_on_operator_ones() {
        assert_eq!(poll_backoff(Phase::Ready), 0);
        assert_eq!(poll_backoff(Phase::Starting), 1);
        assert_eq!(poll_backoff(Phase::Offline), 4);
        assert_eq!(poll_backoff(Phase::Unavailable), 4);
    }

    #[test]
    fn a_device_that_left_the_list_is_gone_whatever_the_clock_says() {
        assert_eq!(stream_verdict(None, true), StreamVerdict::Gone);
        assert_eq!(stream_verdict(None, false), StreamVerdict::Gone);
    }

    #[test]
    fn a_booting_device_is_a_wait_and_a_running_one_is_a_connect() {
        assert_eq!(stream_verdict(Some(false), true), StreamVerdict::Wait);
        assert_eq!(stream_verdict(Some(true), true), StreamVerdict::Connect);
    }

    #[test]
    fn the_two_ways_patience_runs_out_stay_apart() {
        assert_eq!(stream_verdict(Some(true), false), StreamVerdict::Stalled);
        assert_eq!(stream_verdict(Some(false), false), StreamVerdict::NeverReady);
    }

    #[test]
    fn only_the_first_frame_of_a_wait_is_news() {
        assert!(video_arrival_is_news(false, true));
        assert!(!video_arrival_is_news(true, false));
        // A retry re-armed the wait, so this stream is news again.
        assert!(video_arrival_is_news(true, true));
        // Neither video nor a wait outstanding is a stream the panel gave up on; its late frame
        // still ends the failure state.
        assert!(video_arrival_is_news(false, false));
    }

    #[test]
    fn every_answer_survives_the_byte_it_crosses_as() {
        for kind in [Phase::Offline, Phase::Starting, Phase::Unavailable, Phase::Ready] {
            assert_eq!(Phase::from_byte(kind.as_byte()), Some(kind));
        }
        for verdict in [
            StreamVerdict::Connect,
            StreamVerdict::Wait,
            StreamVerdict::Gone,
            StreamVerdict::Stalled,
            StreamVerdict::NeverReady,
        ] {
            assert_eq!(StreamVerdict::from_byte(verdict.as_byte()), Some(verdict));
        }
        assert_eq!(Phase::from_byte(4), None);
        assert_eq!(StreamVerdict::from_byte(5), None);
    }
}
