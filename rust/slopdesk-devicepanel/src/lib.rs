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
