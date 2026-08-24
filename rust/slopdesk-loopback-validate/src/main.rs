//! `slopdesk-loopback-validate` — headless closed-loop validation of the real video software loop.
//!
//! ## What it proves, with no capture, no Metal, no window server and no grant
//! A synthetic `CVPixelBuffer` goes into the REAL hardware encoder — the same
//! `VTCompressionSession` join the host drives, with the same rate-control rules — out through the
//! REAL packetizer at a chosen FEC tier, through deterministic index-based fragment loss, through
//! the REAL fragment codec's encode/decode round trip, into the REAL reassembler with its FEC
//! recovery and per-frame tier split, and finally into the REAL hardware decoder. Alongside it,
//! every pure controller — the network estimate, the congestion controller, the adaptive FEC
//! ladder, the jitter estimator, the pacer depth policy, the LTR controller and the recovery
//! policies — runs on synthetic telemetry it cannot tell from a real link's.
//!
//! Hardware HEVC encode and decode run headlessly from a normal executable; they hang only inside
//! `xctest`, and only capture and Metal need a GUI session. The first scenario proves that path is
//! alive on its own, by encoding real frames.
//!
//! ## Why nothing here is random and nothing reads the clock
//! Loss is chosen by fragment INDEX and time advances by a fixed virtual frame interval, so two
//! runs of the same arm produce the same numbers. A harness whose verdicts moved with the machine's
//! load would be a harness whose verdicts nobody could act on.
//!
//! ## Usage
//! ```text
//! slopdesk-loopback-validate              # full run: the scenarios, the sweeps, the suite
//! slopdesk-loopback-validate --smoke      # a ten-frame clean pass plus the controllers
//! slopdesk-loopback-validate --frames N   # override the per-scenario frame count
//! slopdesk-loopback-validate --closed-loop | --ack-ref | --recovery-idr
//! slopdesk-loopback-validate --gradient | --pacer-depth | --recovery-loss
//! SLOPDESK_LV_FRAMES=N slopdesk-loopback-validate
//! ```

// The harness's whole output IS standard output, which is the one place in this repo where that is
// the product rather than a debugging leftover.
#![expect(
    clippy::print_stdout,
    reason = "a validation harness's report is its standard output"
)]

mod ackref;
mod base;
mod bottleneck;
mod closedloop;
mod controllers;
mod fpsgov;
mod gradient;
mod idr;
mod link;
mod pacer;
mod redundancy;
mod rig;
mod suite;
mod wire;

use base::Arm;
use rig::{FPS, HEIGHT, WIDTH};
use slopdesk_video::loopback::{LossModel, ScenarioStats};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let smoke = args.iter().any(|arg| arg == "--smoke");
    let frames = if smoke { 10 } else { resolve_frames(&args) };

    println!("=== slopdesk-loopback-validate :: headless closed-loop video validation ===");
    println!(
        "    mode={}  perScenarioFrames={frames}  size={WIDTH}x{HEIGHT}@{FPS}\n",
        if smoke { "SMOKE" } else { "FULL" },
    );

    // Every standalone flag is one component of the suite, run alone for quick iteration — the same
    // scenario and the same verdict printer the suite uses, never a second copy of either.
    if let Some(only) = args.iter().find_map(|arg| Standalone::parse(arg)) {
        only.run(frames.max(60));
        return;
    }

    let mut all: Vec<ScenarioStats> = Vec::new();
    if smoke {
        println!("=== SMOKE: clean link, FEC OFF (10 frames) ===");
        all.push(base::run("SMOKE clean FEC OFF", Arm {
            frames,
            tier: 1,
            ..Arm::default()
        }));
    } else {
        all.extend(full_run(frames));
    }

    controllers::run();
    base::print_summary(&all);
    println!("\nslopdesk-loopback-validate: COMPLETE — exiting 0");
}

/// The one-component modes, each its own flag.
#[derive(Clone, Copy, Debug)]
enum Standalone {
    /// The whole closed-loop suite and nothing else.
    ClosedLoop,
    /// The ack-referenced encoding probe.
    AckRef,
    /// Component 2 — the delivery-keyed recovery-IDR cooldown.
    RecoveryIdr,
    /// Component 3 — the delay-gradient early cut.
    Gradient,
    /// Component 4 — the adaptive pacer depth.
    PacerDepth,
    /// Component 5 — recovery-request redundancy.
    RecoveryLoss,
}

impl Standalone {
    /// The flag that selects this mode, if this argument is one.
    const fn parse(arg: &str) -> Option<Self> {
        Some(match arg.as_bytes() {
            b"--closed-loop" => Self::ClosedLoop,
            b"--ack-ref" => Self::AckRef,
            b"--recovery-idr" => Self::RecoveryIdr,
            b"--gradient" => Self::Gradient,
            b"--pacer-depth" => Self::PacerDepth,
            b"--recovery-loss" => Self::RecoveryLoss,
            _ => return None,
        })
    }

    /// How this mode prints when it is the whole run.
    const fn label(self) -> &'static str {
        match self {
            Self::ClosedLoop => "closed-loop only",
            Self::AckRef => "ack-ref probe only",
            Self::RecoveryIdr => "recovery-idr only",
            Self::Gradient => "gradient only",
            Self::PacerDepth => "pacer-depth only",
            Self::RecoveryLoss => "recovery-loss only",
        }
    }

    /// Runs this mode, its own header and its own verdict.
    fn run(self, frames: usize) {
        match self {
            Self::ClosedLoop => suite::run(frames),
            Self::AckRef => ackref::run_probe(frames),
            Self::RecoveryIdr => {
                println!(
                    "\n  [F] RECOVERY-IDR delivery-keyed cooldown (component 2: kfDup double-loss bypass vs \
                     legacy 500ms gate)"
                );
                let result = idr::run(true);
                suite::print_idr_phases(&result);
                suite::print_idr_verdict(&result);
            },
            Self::Gradient => {
                println!(
                    "\n  [G] DELAY-GRADIENT early cut (component 3: capacity step to 40% — client trendline \
                     + raw-RTT one-report cut, A/B in-process)"
                );
                let result = gradient::run(true);
                suite::print_gradient_phases(&result);
                suite::print_gradient_verdict(&result);
            },
            Self::PacerDepth => {
                println!(
                    "\n  [H] ADAPTIVE PACER DEPTH v3 (component 4: owd-late 1↔2 boost — real \
                     OwdLateDetector + policy, virtual clock, phases A-E)"
                );
                suite::print_pacer_verdict(&pacer::run(true));
            },
            Self::RecoveryLoss => {
                println!(
                    "\n  [I] RECOVERY-REQUEST REDUNDANCY (component 5: 3× spaced copies + host dedup + \
                     loss-adaptive halved escalation)"
                );
                let result = redundancy::run(true);
                suite::print_redundancy_phases(&result);
                redundancy::print_verdict(&result);
            },
        }
        println!(
            "\nslopdesk-loopback-validate: COMPLETE ({}) — exiting 0",
            self.label(),
        );
    }
}

/// The whole scenario battery, in the order it was written.
fn full_run(frames: usize) -> Vec<ScenarioStats> {
    let mut all = Vec::new();

    println!("=== 1. clean link, FEC OFF ===");
    all.push(base::run("1. clean link, FEC OFF", Arm {
        frames,
        tier: 1,
        ..Arm::default()
    }));
    println!("=== 2. clean link, FEC g5 ===");
    all.push(base::run("2. clean link, FEC g5", Arm {
        frames,
        ..Arm::default()
    }));
    println!("=== 3. 2% loss, FEC g5 (expect most frames FEC-recovered) ===");
    all.push(base::run("3. 2% loss, FEC g5", Arm {
        frames,
        loss: LossModel::EveryN(50),
        ..Arm::default()
    }));
    println!("=== 4. 10% loss, FEC g3 (heavier redundancy) ===");
    all.push(base::run("4. 10% loss, FEC g3", Arm {
        frames,
        tier: 3,
        loss: LossModel::EveryN(10),
        ..Arm::default()
    }));

    println!("=== FEC tier sweep: drop 1 data fragment per group (OFF must NOT recover; others must) ===");
    all.extend(base::tier_sweep(frames.clamp(10, 30)));

    // The interleave investigation: prove the column-major send reorder decodes cleanly through the
    // real hardware with NO loss — a protocol or codec fault would surface here — and that it turns
    // an adjacent-datagram burst single-hole parity cannot recover in consecutive order into a fully
    // recoverable, decodable stream.
    println!("=== 7. INTERLEAVE, clean link (tier g5) — must decode ALL through real HW ===");
    all.push(base::run("7. interleave clean g5", Arm {
        frames,
        interleave: true,
        ..Arm::default()
    }));
    println!("=== 8. burst-2 adjacent, NO interleave (tier g5) — 2 in one group → expect UNRECOVERED ===");
    all.push(base::run("8. burst-2 NO interleave g5", Arm {
        frames,
        loss: LossModel::WireBurst { start: 1, len: 2 },
        ..Arm::default()
    }));
    println!("=== 9. burst-2 adjacent, WITH interleave (tier g5) — spread 1/group → expect FEC RECOVERS ===");
    all.push(base::run("9. burst-2 interleave g5", Arm {
        frames,
        loss: LossModel::WireBurst { start: 1, len: 2 },
        interleave: true,
        ..Arm::default()
    }));
    println!("=== 9b. burst-3 adjacent, WITH interleave (tier g5) — deeper burst still recovers ===");
    all.push(base::run("9b. burst-3 interleave g5", Arm {
        frames,
        loss: LossModel::WireBurst { start: 1, len: 3 },
        interleave: true,
        ..Arm::default()
    }));

    // Reed-Solomon DEPTH: the same adjacent burst as scenario 8, which single-hole parity cannot
    // recover, now healed by parity depth alone rather than by spreading the holes across groups.
    println!("=== RS m=2 burst-2, NO interleave (g5) — 2 holes/group, RS DEPTH recovers ===");
    all.push(base::run("RS m=2 burst-2 NO interleave g5", Arm {
        frames,
        loss: LossModel::WireBurst { start: 1, len: 2 },
        parity: 2,
        ..Arm::default()
    }));
    println!("=== RS m=3 burst-3, NO interleave (g5) — 3 holes/group, RS DEPTH recovers ===");
    all.push(base::run("RS m=3 burst-3 NO interleave g5", Arm {
        frames,
        loss: LossModel::WireBurst { start: 1, len: 3 },
        parity: 3,
        ..Arm::default()
    }));
    println!("=== RS m=2 burst-3, NO interleave (g5) — 3 holes > m=2 budget → expect GRACEFUL DROP ===");
    all.push(base::run("RS m=2 burst-3 NO interleave g5", Arm {
        frames,
        loss: LossModel::WireBurst { start: 1, len: 3 },
        parity: 2,
        ..Arm::default()
    }));

    println!("=== 6. LTR HW (record -> ack -> ForceLTRRefresh -> decode) ===");
    all.push(base::run_ltr_hardware(frames.clamp(6, 12)));

    // The suite's phase length is fixed rather than taken from `--frames`: its verdict thresholds
    // are calibrated against a 90-frame phase, so a shorter run would move the bar rather than the
    // measurement.
    suite::run(90);

    all
}

/// The per-scenario frame count: the flag, then the environment, then the default.
fn resolve_frames(args: &[String]) -> usize {
    if let Some(index) = args.iter().position(|arg| arg == "--frames")
        && let Some(value) = args.get(index + 1).and_then(|raw| raw.parse::<usize>().ok())
    {
        return value;
    }
    std::env::var("SLOPDESK_LV_FRAMES")
        .ok()
        .and_then(|raw| raw.parse::<usize>().ok())
        .unwrap_or(120)
}
