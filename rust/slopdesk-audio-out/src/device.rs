//! The `cpal` output stream, and the thread that owns it.
//!
//! ## Why a thread rather than a field
//! `cpal::Stream` is `!Send` on the Apple backends — the unit it wraps belongs to the thread that
//! created it. The caller is Swift, dispatching onto a serial queue, which is a *sequence* of
//! threads rather than one, so holding the stream in the handle would need an `unsafe impl Send`
//! and a promise no compiler checks. A thread that owns the stream for its whole life needs
//! neither: the handle holds a channel, which is `Send` because it genuinely is.
//!
//! The cost is that start and stop are asynchronous. Nothing depends on them being otherwise —
//! audio is an accessory, a start that lands a few milliseconds late is inaudible, and the render
//! callback is already reading a ring that simply answers silence until there is something in it.
//!
//! ## Why a failure here is silent-but-inert
//! No device, no permission, a refused format: each leaves the player alive and mute, and the next
//! start tries again. A coding session must never fail over its audio accessory, and the pane has
//! no way to render an audio error that would help anyone.

// A lint CONFLICT rather than a preference: this is a private module whose items are `pub(crate)`
// because they are the crate's internal vocabulary and no part of its API, so `pub(crate)` is the
// only accurate visibility — and this nursery lint asks for `pub` while rustc's `unreachable_pub`,
// denied by the manifest, refuses exactly that. Clippy's own documentation records the conflict;
// the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use std::sync::mpsc::{Receiver, Sender, channel};
use std::thread::JoinHandle;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

use crate::handoff::Render;

/// What the owning thread is asked to do. It never answers — see the module note.
enum Command {
    Start,
    Stop,
    Shutdown,
}

/// The device thread's handle, plus what it settled on.
#[derive(Debug)]
pub(crate) struct Device {
    commands: Sender<Command>,
    worker: Option<JoinHandle<()>>,
    /// The rate the device actually runs at, which the pump resamples to. Resolved BEFORE the
    /// thread starts, because the pump has to be built against it.
    pub(crate) rate: f64,
}

/// What a device offered, before a stream was built on it.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Offer {
    pub(crate) rate: f64,
    pub(crate) channels: usize,
}

/// Asks the default output what it will run at, preferring the wire's own rate.
///
/// Preferring the wire rate is what keeps the resampler a copy on every machine this has been
/// pointed at. When the device cannot offer it — a unit pinned to 44.1 kHz — the closest supported
/// rate is taken and the pump converts, which is audibly better than the alternative of playing
/// everything sharp.
///
/// `None` when there is no output device at all, which on a headless CI machine is the normal
/// answer rather than a fault.
pub(crate) fn offer(wanted_rate: f64, wanted_channels: usize) -> Option<Offer> {
    let device = cpal::default_host().default_output_device()?;
    let configs: Vec<_> = device.supported_output_configs().ok()?.collect();
    let wanted = wanted_rate.max(1.0);
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "an audio sample rate, and the caller's is one of a handful of fixed integers"
    )]
    let wanted_hz = wanted as u32;

    // Float format only: the whole path downstream is interleaved f32, and a device that cannot
    // take it would mean a second sample-format convert in the render callback for no gain — every
    // Apple output offers f32.
    let float_configs = configs
        .iter()
        .filter(|config| config.sample_format() == cpal::SampleFormat::F32);
    let best = float_configs
        .clone()
        .find(|config| config.min_sample_rate() <= wanted_hz && wanted_hz <= config.max_sample_rate())
        .map(|config| {
            Offer {
                rate: wanted,
                channels: config.channels() as usize,
            }
        });
    best.or_else(|| {
        // Closest supported rate to the wire's, measured on the ceiling each range offers.
        float_configs
            .min_by_key(|config| config.max_sample_rate().abs_diff(wanted_hz))
            .map(|config| {
                Offer {
                    rate: f64::from(config.max_sample_rate()),
                    channels: config.channels() as usize,
                }
            })
    })
    .map(|offer| {
        Offer {
            channels: offer
                .channels
                .max(wanted_channels.max(1))
                .min(offer.channels.max(1)),
            ..offer
        }
    })
}

impl Device {
    /// Spawns the thread that will own the stream. Does not start it — [`Self::start`] does.
    pub(crate) fn spawn(offer: Offer, render: Render) -> Self {
        let (commands, inbox) = channel();
        let config = cpal::StreamConfig {
            channels: u16::try_from(offer.channels.max(1)).unwrap_or(u16::MAX),
            sample_rate: {
                #[expect(
                    clippy::cast_possible_truncation,
                    clippy::cast_sign_loss,
                    reason = "an audio sample rate, resolved from the device's own u32 range"
                )]
                let hz = offer.rate as u32;
                hz
            },
            // The device's own default. A smaller buffer would lower latency and raise the risk of
            // a missed deadline; the ring already absorbs jitter, so there is nothing to buy here.
            buffer_size: cpal::BufferSize::Default,
        };
        let worker = std::thread::Builder::new()
            .name("slopdesk-audio-out".to_owned())
            .spawn(move || own_the_stream(&inbox, config, render))
            .ok();
        Self {
            commands,
            worker,
            rate: offer.rate,
        }
    }

    /// Asks for playback. Idempotent on the far side.
    pub(crate) fn start(&self) {
        let _sent = self.commands.send(Command::Start);
    }

    /// Asks for silence, keeping the stream for a cheap restart.
    pub(crate) fn stop(&self) {
        let _sent = self.commands.send(Command::Stop);
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        let _sent = self.commands.send(Command::Shutdown);
        // JOIN, rather than detach: the render half moved into that thread, and this drop is what
        // makes it safe for the hand-off's storage to go away. A detached thread would be reading
        // it while this one returned.
        if let Some(worker) = self.worker.take() {
            let _joined = worker.join();
        }
    }
}

/// The thread body: build the stream on the first start, then follow the commands until shutdown.
///
/// Rebuilding on every start would cost a device open per pane toggle; keeping a stopped stream
/// costs an idle I/O proc, which is what `cpal`'s pause is for.
fn own_the_stream(inbox: &Receiver<Command>, config: cpal::StreamConfig, render: Render) {
    let mut stream: Option<cpal::Stream> = None;
    // The render half moves into the callback on the first start, and the callback outlives this
    // frame — so it waits in a slot here until there is a callback to move it into.
    let mut lent = Some(render);
    while let Ok(command) = inbox.recv() {
        match command {
            Command::Start => {
                // The device is resolved BEFORE the render half is moved into the callback. That
                // ordering is what preserves the retry: the realistic transient failure is "no
                // default output yet" — a Bluetooth unit still connecting, a device being switched
                // — and checking it first leaves `lent` untouched so the next start tries again.
                // Past that point a refusal is terminal for this player, because `cpal` drops the
                // callback on error and the render half goes with it; the session rebuilds the
                // whole player on the next config change, which is the only retry that can help.
                if stream.is_none()
                    && let Some(device) = cpal::default_host().default_output_device()
                    && let Some(mut render) = lent.take()
                {
                    stream = build(&device, config, move |out| render.fill(out));
                }
                if let Some(stream) = stream.as_ref() {
                    let _played = stream.play();
                }
            },
            Command::Stop => {
                if let Some(stream) = stream.as_ref() {
                    let _paused = stream.pause();
                }
            },
            Command::Shutdown => break,
        }
    }
    drop(stream);
}

/// Builds one output stream around `fill`. `None` on any refusal — see the module note.
fn build<F>(device: &cpal::Device, config: cpal::StreamConfig, mut fill: F) -> Option<cpal::Stream>
where
    F: FnMut(&mut [f32]) + Send + 'static,
{
    device
        .build_output_stream(
            config,
            move |out: &mut [f32], _: &cpal::OutputCallbackInfo| fill(out),
            // A device error tears the stream down on `cpal`'s side; the next start rebuilds. There
            // is nothing useful to say here that the silence does not already say.
            |_error| {},
            None,
        )
        .ok()
}
