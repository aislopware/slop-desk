//! The client's audio output: a decoded frame goes in, the speakers come out.
//!
//! Read the crate manifest for why this is not a `slopdesk-apple-*` crate and why `cpal` and
//! `rtrb` were chosen over hand-wrapping. In short: `cpal`'s output callback hands out a
//! `&mut [f32]`, which is the one difference that lets this whole path be `forbid(unsafe_code)`.
//!
//! ## The shape
//! ```text
//!   decoded 10 ms frame
//!         │
//!         ▼
//!   AudioJitterBuffer   ← every DECISION: prime, conceal, reorder, high water   (slopdesk-video)
//!         │
//!         ▼
//!   Pump                ← the combined depth bound, and the rate conversion
//!         │
//!         ▼
//!   Handoff  ══════════▶  Render         ← wait-free SPSC, the ONLY shared state
//!                            │
//!                            ▼
//!                        cpal stream     ← its own thread, for its whole life
//! ```
//!
//! ## What a test can and cannot reach
//! Everything above the `cpal` stream is ordinary code and is unit-tested here: the hand-off's
//! flush frontier and shortfall odometer, the pump's priming and reorder and depth bound, the
//! resampler's phase carry. Opening a real output device is the one thing a test never does —
//! same hang-safety class as a capture stream or a compression session — so [`Player::new`] on a
//! machine with no output device answers a player that works and stays mute, and the suite asserts
//! exactly that.

mod device;
mod handoff;
mod pump;
mod resample;

use pump::Pump;
use slopdesk_video::audio_jitter::{AudioJitterBuffer, AudioJitterStats, high_water_samples};

/// Pending frames buffered before playback starts — about two ten-millisecond frames of slack.
pub const TARGET_DEPTH_FRAMES: usize = 2;

/// The pending-frame cap, past which the oldest staged frame is dropped.
pub const HIGH_WATER_FRAMES: usize = 8;

/// One locked `(sample rate, channels)` worth of audio output.
///
/// A config change that moves either rebuilds the player; nothing here reconfigures in place,
/// because the resampler's ratio, the hand-off's capacity and the device's own stream are all
/// derived from the pair.
///
/// ⚠️ ONE OWNER. Every method is confined to the caller's serial audio queue, the same
/// single-owner discipline the decode path already runs under. The render thread never reaches
/// any of this — it holds the hand-off's other half and nothing else.
#[derive(Debug)]
pub struct Player {
    pump: Pump,
    /// `None` when there is no output device at all. The player still accepts frames and still
    /// answers its counters; it simply never makes a sound. A headless machine is the normal way
    /// to arrive here, not a fault.
    device: Option<device::Device>,
    running: bool,
}

impl Player {
    /// A player for `sample_rate` and `channels`, silent until [`Self::start`].
    ///
    /// The device is resolved here rather than at start because the pump has to be built against
    /// the rate the device actually runs at — see `resample`.
    #[must_use]
    pub fn new(sample_rate: f64, channels: usize) -> Self {
        let channels = channels.max(1);
        // A ten-millisecond frame at this rate, which is the unit the stage's frame-count policy
        // converts through. Floored at one so a nonsense rate cannot make it zero.
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "a sample rate divided by a hundred — an audio rate is far inside a usize"
        )]
        let samples_per_frame = ((sample_rate / 100.0).max(1.0) as usize) * channels;
        let stage = AudioJitterBuffer::new(channels, TARGET_DEPTH_FRAMES, HIGH_WATER_FRAMES);
        // Hand-off STORAGE is a high-water's worth of frames, but the pump only tops it up to the
        // target depth. The spare is slack, so a flush's not-yet-skipped span never blocks the
        // re-primed hand-off behind it.
        let capacity = high_water_samples(HIGH_WATER_FRAMES, samples_per_frame);
        let offer = device::offer(sample_rate, channels);
        let (handoff, render) = handoff::pair(capacity);
        let device = offer.map(|offer| device::Device::spawn(offer, render));
        let device_rate = device.as_ref().map_or(sample_rate, |device| device.rate);
        Self {
            pump: Pump::new(stage, handoff, samples_per_frame, sample_rate, device_rate),
            device,
            running: false,
        }
    }

    /// Whether a real output device was found. False means this player is permanently mute.
    #[must_use]
    pub const fn has_device(&self) -> bool {
        self.device.is_some()
    }

    /// The rate the device settled on, which is the wire rate whenever the device offers it.
    #[must_use]
    pub fn device_rate(&self) -> f64 {
        self.device.as_ref().map_or(0.0, |device| device.rate)
    }

    /// One decoded frame, keyed by its wire sequence.
    pub fn enqueue(&mut self, seq: u32, samples: Vec<f32>) {
        self.pump.enqueue(seq, samples);
    }

    /// Drops everything buffered — the pane falls silent on the next render pass, not after the
    /// hand-off drains.
    pub fn flush(&mut self) {
        self.pump.flush();
    }

    /// Starts output. Idempotent.
    pub fn start(&mut self) {
        if self.running {
            return;
        }
        if let Some(device) = self.device.as_ref() {
            device.start();
        }
        self.running = true;
    }

    /// Stops output, keeping the device for a cheap restart. Idempotent.
    pub fn stop(&mut self) {
        if !self.running {
            return;
        }
        if let Some(device) = self.device.as_ref() {
            device.stop();
        }
        self.running = false;
    }

    /// The stage's cumulative policy counters.
    #[must_use]
    pub const fn stats(&self) -> AudioJitterStats {
        self.pump.stats()
    }
}

#[cfg(test)]
mod tests {
    use super::Player;

    #[test]
    fn a_machine_with_no_output_still_gets_a_working_player() {
        // The suite runs headless and on machines with real speakers, so this asserts the
        // INVARIANT rather than which branch was taken: either way the player accepts frames,
        // counts them, and never panics. Nothing here opens a device on purpose — `new` resolves
        // one only to size the resampler, and `start` is what would make a sound.
        let mut player = Player::new(48_000.0, 2);
        player.enqueue(1, vec![0.5; 960]);
        player.enqueue(2, vec![0.5; 960]);
        player.flush();
        assert_eq!(player.stats().frames_pushed, 2);
        if player.has_device() {
            assert!(player.device_rate() > 0.0);
        }
    }

    #[test]
    fn a_nonsense_rate_does_not_divide_by_zero() {
        let mut player = Player::new(0.0, 0);
        player.enqueue(1, vec![0.25; 4]);
        assert_eq!(player.stats().frames_pushed, 1);
    }

    #[test]
    fn start_and_stop_are_idempotent() {
        let mut player = Player::new(48_000.0, 2);
        player.start();
        player.start();
        player.stop();
        player.stop();
        // Dropping joins the device thread; a second stop must not have left it waiting on a
        // command that never comes.
        drop(player);
    }
}
