//! The app-audio lane: a capture tap's buffers become tag-6 datagrams on the shared media socket.
//!
//! Replaces the Swift host's audio stream encoder and the `AudioStreamSender` half of its session
//! actor.
//!
//! ## What this module OWNS versus what it ASKS for
//! It owns a THREAD, a bounded queue, a gate and two counters. Everything else is asked for:
//! `slopdesk-apple-audio` owns every `AudioConverter` call and the read of a `CMSampleBuffer`,
//! [`slopdesk_video::audio_source`] owns the 480-frame block cadence and the codec/bitrate knobs,
//! and [`slopdesk_video::audio_wire`] owns the datagram's eleven-byte header and its config flag.
//! The 640 lines of Swift that stood here were about forty lines of rule wrapped in framework
//! calls; the rule moved and the wrapping was deleted.
//!
//! ## Why there is a thread, when the Swift had none
//! `AudioStreamEncoder` was a synchronous object under an `NSLock`, and Swift promised it was
//! shareable with `@unchecked Sendable`. Rust cannot make that promise and this tree would not
//! accept it: `slopdesk_apple_audio::Encoder` holds an `AudioConverterRef`, which is a raw pointer,
//! so the type is `!Send` and `!Sync` and its own doc says no attempt is made to widen that. An
//! `AudioConverter` is safe from ONE thread at a time, and the Swift satisfied that by confining
//! every call to a serial queue. This module spells the SAME confinement as a thread that OWNS the
//! encoder: it is constructed inside the thread, never leaves it, and reaches it only through the
//! queue below. That is not a workaround for a missing `Send` — it is the discipline written down.
//!
//! The gain is real rather than incidental. `slopdesk_apple_sck` already delivers audio on a second
//! queue so a slow synchronous video encode cannot delay a 10 ms buffer; moving the ENCODE off that
//! queue too means a slow audio encode cannot delay the next audio buffer either.
//! [`AudioSender::handle`] does exactly one piece of work on the delivery queue — reading the
//! sample buffer's samples — and it must, because a `CMSampleBuffer` cannot cross a thread while an
//! interleaved `Vec<f32>` can.
//!
//! ## The queue, and what a full one means
//! [`BACKLOG_BLOCKS`] buffers, and a full queue DROPS the sample rather than blocking the capture
//! tap. Audio is real time: a queue that is full means the encoder is wedged, and buffering behind
//! it would add latency to every frame after it rather than recovering the one that was late.
//! A gate flip is the exception and BLOCKS instead — losing a disable would leave a lane sending
//! after its client asked it to stop, which is a correctness bug where a dropped 10 ms buffer is a
//! click. Both ride ONE queue, so arrival order reproduces the Swift's under-one-lock semantics: a
//! buffer enqueued microseconds before a disable is dropped by the thread's own view of the gate,
//! exactly as the lock would have dropped it.
//!
//! ## The clock
//! ⚠️ The epoch handed to [`AudioSender::spawn`] MUST be the SAME [`Instant`] the video path stamps
//! its fragment headers from. `host_send_ts_millis` shares `FrameFragmentHeader`'s clock contract —
//! host-relative milliseconds, never cross-clock — and a second epoch here would put the audio and
//! video timelines a start-up delay apart, which is a wire bug no test on either side can see.
//!
//! ## The route
//! Datagrams go out IMMEDIATE on [`VideoChannel::Audio`], never through the paced video lane: audio
//! must not queue behind a fat video frame, and at about 2 KB a datagram needs no chunking. No
//! forward error correction and no retransmit — a lost frame is concealed at the client.
//!
//! ## What is untestable by design
//! [`AudioSender::handle`] needs a real `CMSampleBuffer` from a capture tap, and the encoder needs
//! an `AudioConverter`. ⚠️ Neither can be reached headlessly. The WIRE CADENCE can, and is what the
//! `#[cfg(test)] mod tests` below covers: which datagram leads a burst, when the config is
//! re-asserted, and that one sequence counter spans both kinds.

use core::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use slopdesk_apple_audio::{CMSampleBuffer, Encoder, read_stereo};
use slopdesk_video::audio_source::{self, CHANNEL_COUNT};
use slopdesk_video::audio_wire::{AudioChannelMessage, AudioStreamConfig, AudioWireFormat};
use slopdesk_video::recovery_routing::VideoChannel;

use crate::env::Overlay;
use crate::mux_lane::MuxLaneTransport;

/// How often the stream's decode parameters are re-asserted.
///
/// UDP may drop any single copy and a client may lock on late, so the config rides along with a
/// frame about once a second — piggybacked on the encode path as one stamp compare per buffer,
/// never a timer of its own. Client re-application is idempotent, which is what makes a re-send
/// free rather than a re-initialisation.
pub const CONFIG_RESEND_INTERVAL: Duration = Duration::from_secs(1);

/// How many 10 ms blocks may wait for the encoder before a buffer is dropped.
///
/// Sixteen is about 160 ms — long enough to absorb a scheduling hiccup, short enough that the
/// latency a full queue would add is smaller than the gap a dropped buffer leaves. There is no
/// value here that makes a wedged encoder recoverable; the choice is only about which failure the
/// listener hears.
pub const BACKLOG_BLOCKS: usize = 16;

/// Where an audio datagram goes.
///
/// A trait rather than a concrete transport so the lane can be driven without a socket, and so the
/// ONE decision that must not drift — that audio is IMMEDIATE and never paced — is made in the one
/// implementation below rather than at every call site.
pub trait SendsAudio: Send + Sync + fmt::Debug {
    /// Sends one datagram on the audio channel, fire and forget.
    fn send_audio(&self, datagram: &[u8]);
}

impl SendsAudio for MuxLaneTransport {
    /// IMMEDIATE, on the shared media socket — the cursor channel's discipline. Never
    /// `send_paced`: a 10 ms audio buffer behind a fat video frame is a stall the listener hears
    /// and the viewer does not.
    fn send_audio(&self, datagram: &[u8]) {
        self.send(datagram, VideoChannel::Audio);
    }
}

impl<T: SendsAudio + ?Sized> SendsAudio for Arc<T> {
    fn send_audio(&self, datagram: &[u8]) {
        (**self).send_audio(datagram);
    }
}

/// What crosses into the encoder thread.
///
/// One queue for both, so a gate flip and the buffers around it stay in the order the session
/// issued them.
#[derive(Debug)]
enum Message {
    /// The send gate moved. `true` on an OFF→ON edge also rearms the config cadence and resets the
    /// codec.
    Gate(bool),
    /// One capture buffer's interleaved stereo samples.
    Samples(Vec<f32>),
}

/// The two counters a lane carries between buffers: where the sequence is, and when the config was
/// last asserted.
///
/// Split out from the thread's other state because it is the half that has no framework in it, and
/// therefore the half a test can drive. Everything the wire sees is decided here.
#[derive(Clone, Copy, Debug, Default)]
struct Cadence {
    /// ONE monotonic counter for ALL tag-6 datagrams of this session — config and frames share it,
    /// because the client orders and late-drops on it and two counters would make "later"
    /// ambiguous.
    seq: u32,
    /// When the last config went out, measured from the session epoch. `None` means "before the
    /// next frame", which is the state a fresh lane and every re-enable start in.
    last_config_sent: Option<Duration>,
}

impl Cadence {
    /// Forces a config to lead the next burst.
    ///
    /// Called on every OFF→ON edge: a client that turned audio back on may have missed every copy
    /// sent while it was off, and may not be the client that was listening before.
    const fn rearm(&mut self) {
        self.last_config_sent = None;
    }

    /// Turns one encode's payloads into the datagrams to put on the wire, in order.
    ///
    /// Empty payloads produce nothing AND stamp nothing — a buffer that completed no block must not
    /// consume the config's turn, or a re-send lands a second later than it was meant to for as
    /// long as the source is quiet.
    ///
    /// One timestamp for the whole burst rather than one per datagram: the payloads came out of a
    /// single encode of a single capture buffer, and giving them different send times would claim a
    /// spread the host never had.
    fn datagrams(
        &mut self,
        since_epoch: Duration,
        config: &AudioStreamConfig,
        payloads: Vec<Vec<u8>>,
    ) -> Vec<Vec<u8>> {
        if payloads.is_empty() {
            return Vec::new();
        }
        let host_send_ts_millis = millis(since_epoch);
        let mut out = Vec::with_capacity(payloads.len() + 1);
        let due = self
            .last_config_sent
            .is_none_or(|last| since_epoch.saturating_sub(last) >= CONFIG_RESEND_INTERVAL);
        if due {
            self.last_config_sent = Some(since_epoch);
            out.push(
                AudioChannelMessage::Config {
                    seq: self.seq,
                    host_send_ts_millis,
                    config: config.clone(),
                }
                .encode(),
            );
            self.seq = self.seq.wrapping_add(1);
        }
        for payload in payloads {
            out.push(
                AudioChannelMessage::Frame {
                    seq: self.seq,
                    host_send_ts_millis,
                    payload,
                }
                .encode(),
            );
            self.seq = self.seq.wrapping_add(1);
        }
        out
    }
}

/// The session-relative send timestamp, in milliseconds, wrapped into the wire's 32 bits.
///
/// The mask is the wrap the Swift got from `UInt32(truncatingIfNeeded:)`, written as an operation
/// that cannot fail rather than a cast that could. The `unwrap_or` is unreachable — a value masked
/// to 32 bits fits in a `u32` — and is there because the fallible conversion is the honest spelling
/// of "take the low half".
fn millis(since_epoch: Duration) -> u32 {
    u32::try_from(since_epoch.as_millis() & u128::from(u32::MAX)).unwrap_or(u32::MAX)
}

/// One session's audio lane: a gate, a queue, and the thread that owns the encoder.
///
/// Shared across the session's threads — the capture tap's delivery queue calls
/// [`Self::handle`], the control path calls [`Self::set_enabled`] — which is why nothing here
/// holds the `!Send` encoder directly.
#[derive(Debug)]
pub struct AudioSender {
    /// The FAST gate, read on the delivery queue before any work. Advisory: the authoritative gate
    /// is the encoder thread's own view, which the ordered queue keeps consistent with the buffers
    /// around it. `Relaxed` is right for both reasons — a flip that lands one buffer late costs one
    /// 10 ms block, and no other memory is published through it.
    enabled: AtomicBool,
    /// `None` once the lane has been stopped. Taking it is what closes the queue, and closing the
    /// queue is what ends the thread.
    outbox: Mutex<Option<SyncSender<Message>>>,
    /// `None` if the thread could not be spawned at all, in which case the queue is already
    /// disconnected and every buffer is dropped at the send.
    worker: Mutex<Option<JoinHandle<()>>>,
    format: AudioWireFormat,
    bitrate_bps: u32,
}

impl AudioSender {
    /// Starts the lane's encoder thread and answers the handle the session drives.
    ///
    /// The lane starts DISABLED. The encoder is built lazily on the first enabled buffer, inside
    /// the thread, so a session whose client never turns audio on never constructs an
    /// `AudioConverter` — and could not build one here anyway, because the encoder is `!Send`.
    ///
    /// ⚠️ `epoch` must be the session's own — the same [`Instant`] the video fragment headers are
    /// stamped from. See the module's clock note.
    ///
    /// The codec and the bitrate are resolved ONCE, here, exactly as the Swift resolved them into
    /// `static let`s: a knob that could change mid-session would change the wire format of a stream
    /// a client has already locked on to.
    #[must_use]
    pub fn spawn<T: SendsAudio + 'static>(transport: T, epoch: Instant, overlay: &Overlay) -> Self {
        let lookup = reader(overlay);
        let format = audio_source::wire_format(&lookup);
        let bitrate_bps = audio_source::bitrate_bps(&lookup);
        let (outbox, inbox) = sync_channel(BACKLOG_BLOCKS);
        let worker = thread::Builder::new()
            .name("slopdesk-audio".to_owned())
            .spawn(move || encode_loop(transport, epoch, format, bitrate_bps, &inbox))
            .ok();
        Self {
            enabled: AtomicBool::new(false),
            outbox: Mutex::new(Some(outbox)),
            worker: Mutex::new(worker),
            format,
            bitrate_bps,
        }
    }

    /// The wire codec this lane locked at spawn.
    #[must_use]
    pub const fn format(&self) -> AudioWireFormat {
        self.format
    }

    /// The AAC-ELD target bitrate this lane locked at spawn. The PCM arm ignores it.
    #[must_use]
    pub const fn bitrate_bps(&self) -> u32 {
        self.bitrate_bps
    }

    /// Whether the lane is sending.
    #[must_use]
    pub fn is_enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    /// Moves the send gate: streaming AND the client's wish, which the session maintains.
    ///
    /// An OFF→ON edge rearms the config cadence and resets the encoder, and both halves matter for
    /// the same reason: the sub-block remainder left by the last pre-disable buffer is stale by
    /// re-enable, and so is the bit reservoir the codec would splice it into. Resetting either
    /// alone emits a fresh block continuing audio from before the gap.
    ///
    /// BLOCKS if the queue is full — bounded by [`BACKLOG_BLOCKS`] blocks of encode, and only on a
    /// user-driven toggle. A dropped gate flip would leave the lane sending after its client asked
    /// it to stop, so this is the one message that is never dropped.
    pub fn set_enabled(&self, on: bool) {
        self.enabled.store(on, Ordering::Relaxed);
        let outbox = self.outbox.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(outbox) = outbox.as_ref() {
            drop(outbox.send(Message::Gate(on)));
        }
    }

    /// The capture tap's audio sink.
    ///
    /// ⚠️ Runs on the capture tap's own audio delivery queue, which is NOT the frame queue — that
    /// separation is `slopdesk_apple_sck`'s and must be preserved by whoever starts the stream, or
    /// a slow video encode delays every 10 ms buffer behind it.
    ///
    /// Does exactly two things there: the gate read, and the sample read. The sample read cannot
    /// move — a `CMSampleBuffer` is lent for the duration of the call and cannot cross a thread —
    /// and everything after it does, which is what keeps this call far under a buffer interval.
    /// Never blocks: a full queue drops the buffer.
    pub fn handle(&self, sample: &CMSampleBuffer) {
        if !self.enabled.load(Ordering::Relaxed) {
            return;
        }
        let Some(interleaved) = read_stereo(sample) else {
            return;
        };
        if interleaved.len() < CHANNEL_COUNT {
            return;
        }
        let outbox = self.outbox.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(outbox) = outbox.as_ref() {
            drop(outbox.try_send(Message::Samples(interleaved)));
        }
    }

    /// Stops the lane and JOINS its thread. Idempotent.
    ///
    /// Drop the sender, then wait — never a cancel-and-run-on. The encoder's `AudioConverter` is
    /// disposed when the thread's last `Encoder` drops, and a thread still inside a `push` when the
    /// process tore down its transport would be disposing it under a socket that is already gone.
    /// Waiting costs at most one block's encode.
    pub fn stop(&self) {
        drop(self.outbox.lock().unwrap_or_else(PoisonError::into_inner).take());
        let worker = self.worker.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(worker) = worker {
            drop(worker.join());
        }
    }
}

impl Drop for AudioSender {
    /// The join cannot be optional: a lane dropped without one leaves a thread holding a transport
    /// whose session has ended.
    fn drop(&mut self) {
        self.stop();
    }
}

/// The thread that owns the encoder, from the first enabled buffer to the queue's close.
///
/// Every framework object in this module lives inside this function. It ends when the queue
/// disconnects — which is [`AudioSender::stop`] taking the sender, and nothing else.
#[expect(
    clippy::needless_pass_by_value,
    reason = "the thread OWNS the transport for its whole life; a borrow would tie it to a caller frame \
              that ends first"
)]
fn encode_loop<T: SendsAudio>(
    transport: T,
    epoch: Instant,
    format: AudioWireFormat,
    bitrate_bps: u32,
    inbox: &Receiver<Message>,
) {
    let mut enabled = false;
    let mut encoder: Option<Encoder> = None;
    let mut cadence = Cadence::default();

    while let Ok(message) = inbox.recv() {
        match message {
            Message::Gate(on) => {
                if on && !enabled {
                    cadence.rearm();
                    if let Some(encoder) = encoder.as_mut() {
                        encoder.reset();
                    }
                }
                enabled = on;
            },
            Message::Samples(samples) => {
                // The thread's OWN view of the gate, not the atomic: a buffer that was enqueued
                // before a disable arrives after it and must be dropped, which is what the Swift's
                // single lock did for free.
                if !enabled {
                    continue;
                }
                let encoder = encoder.get_or_insert_with(|| Encoder::new(format, bitrate_bps));
                #[expect(
                    clippy::integer_division,
                    reason = "interleaved stereo: the sample count IS two per frame, and a remainder would \
                              mean a buffer that lies about its own layout, which the encoder drops rather \
                              than truncates"
                )]
                let frames = samples.len() / CHANNEL_COUNT;
                let payloads = encoder.push(&samples, frames);
                // `config` is non-nil once the encoder can produce — always for PCM, and for AAC
                // once the converter is built. Payloads imply it; the check is the honest order.
                let Some(config) = encoder.config() else {
                    continue;
                };
                for datagram in cadence.datagrams(epoch.elapsed(), config, payloads) {
                    transport.send_audio(&datagram);
                }
            },
        }
    }
}

/// How this daemon reads a knob: the real environment FIRST, then the settings overlay.
///
/// That order is `docs/58`'s precedence, and it is why the audio knobs are resolved through a
/// reader rather than through `std::env` directly. Swift got here by folding `video-prefs.json`
/// into the process environment with `setenv` before launch; a Rust daemon cannot, because
/// `std::env::set_var` is `unsafe` and this crate forbids it. Composing the two lookups is the same
/// precedence with none of the mutation — and it is a REACH: `SLOPDESK_AUDIO_CODEC` and
/// `SLOPDESK_AUDIO_BITRATE` now honour `video-prefs.json`, which under the Swift they did only
/// because the launcher had already flattened it into the environment.
fn reader(overlay: &Overlay) -> impl Fn(&str) -> Option<String> + '_ {
    |key| std::env::var(key).ok().or_else(|| overlay.get(key))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a datagram this module just encoded must decode, and a panic in a test is the failure \
                  report"
    )]

    use core::time::Duration;

    use slopdesk_video::audio_source::{CHANNEL_COUNT, SAMPLE_RATE};
    use slopdesk_video::audio_wire::{AudioStreamConfig, AudioWireFormat, decode_parts};

    use super::{CONFIG_RESEND_INTERVAL, Cadence, millis};

    fn config() -> AudioStreamConfig {
        AudioStreamConfig::new(
            AudioWireFormat::AacEld,
            SAMPLE_RATE,
            u8::try_from(CHANNEL_COUNT).unwrap_or(2),
            vec![0xF8, 0xE8, 0x50, 0x00],
        )
    }

    /// Every datagram as `(seq, timestamp, is_config)`.
    fn read(datagrams: &[Vec<u8>]) -> Vec<(u32, u32, bool)> {
        datagrams
            .iter()
            .map(|datagram| {
                let (seq, ts, is_config, _) =
                    decode_parts(datagram).expect("this module encoded it a line ago");
                (seq, ts, is_config)
            })
            .collect()
    }

    #[test]
    fn a_fresh_lane_leads_with_the_config_and_shares_one_counter() {
        // The client orders and late-drops on ONE sequence, so the config must occupy a number of
        // its own rather than sitting outside the run.
        let mut cadence = Cadence::default();
        let burst = cadence.datagrams(Duration::from_millis(40), &config(), vec![vec![1, 2, 3], vec![
            4, 5, 6,
        ]]);
        assert_eq!(
            read(&burst),
            vec![(0, 40, true), (1, 40, false), (2, 40, false)],
            "config first, then the frames, all stamped with the burst's one send time"
        );
    }

    #[test]
    fn the_config_is_not_repeated_inside_the_resend_interval() {
        let mut cadence = Cadence::default();
        drop(cadence.datagrams(Duration::ZERO, &config(), vec![vec![1]]));
        let next = cadence.datagrams(Duration::from_millis(10), &config(), vec![vec![2]]);
        assert_eq!(read(&next), vec![(2, 10, false)], "one frame, no config");
    }

    #[test]
    fn the_config_is_reasserted_once_the_interval_has_elapsed() {
        // UDP may drop any single copy and a client may attach late, so the parameters come round
        // again about once a second. Re-application is idempotent at the client.
        let mut cadence = Cadence::default();
        drop(cadence.datagrams(Duration::ZERO, &config(), vec![vec![1]]));
        let due = cadence.datagrams(CONFIG_RESEND_INTERVAL, &config(), vec![vec![2]]);
        assert_eq!(
            read(&due),
            vec![(2, 1000, true), (3, 1000, false)],
            "the config leads again and takes the next number"
        );
    }

    #[test]
    fn a_reenable_forces_a_fresh_config_even_mid_interval() {
        // The client that turns audio back on may not be the one that was listening before, and
        // certainly missed every copy sent while the lane was off.
        let mut cadence = Cadence::default();
        drop(cadence.datagrams(Duration::ZERO, &config(), vec![vec![1]]));
        cadence.rearm();
        let after = cadence.datagrams(Duration::from_millis(10), &config(), vec![vec![2]]);
        assert_eq!(read(&after), vec![(2, 10, true), (3, 10, false)]);
    }

    #[test]
    fn a_silent_buffer_sends_nothing_and_does_not_spend_the_configs_turn() {
        // A capture buffer that completes no block must not push the next re-send a second later
        // than it was meant to — a quiet source would otherwise starve a late client of parameters.
        let mut cadence = Cadence::default();
        assert!(
            cadence
                .datagrams(Duration::from_millis(500), &config(), Vec::new())
                .is_empty()
        );
        let first = cadence.datagrams(Duration::from_millis(600), &config(), vec![vec![1]]);
        assert_eq!(
            read(&first),
            vec![(0, 600, true), (1, 600, false)],
            "the config still leads the first burst that carries anything"
        );
    }

    #[test]
    fn the_send_timestamp_wraps_into_the_wires_thirty_two_bits() {
        // The Swift's `UInt32(truncatingIfNeeded:)`, as an operation that cannot fail. A session
        // that runs past 49.7 days wraps rather than saturating, which is what the client's own
        // wrapping arithmetic expects.
        assert_eq!(millis(Duration::from_millis(0)), 0);
        assert_eq!(millis(Duration::from_millis(u64::from(u32::MAX))), u32::MAX);
        assert_eq!(millis(Duration::from_millis(u64::from(u32::MAX) + 1)), 0);
        assert_eq!(millis(Duration::from_millis(u64::from(u32::MAX) + 7)), 6);
    }

    #[test]
    fn the_sequence_wraps_rather_than_stopping() {
        // Every wire counter in this tree wraps; a lane that ran out of numbers would otherwise
        // stall a session that is only long.
        let mut cadence = Cadence {
            seq: u32::MAX,
            last_config_sent: Some(Duration::ZERO),
        };
        let burst = cadence.datagrams(Duration::from_millis(5), &config(), vec![vec![1], vec![2]]);
        assert_eq!(read(&burst), vec![(u32::MAX, 5, false), (0, 5, false)]);
    }
}
