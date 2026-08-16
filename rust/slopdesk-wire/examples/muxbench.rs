//! Parity benchmark for the mux envelope: `cargo run --release --example muxbench`.
//!
//! Kept in the tree on the `slopdesk-sniffbench` precedent — the numbers a port is justified by go
//! stale, and a bench that is still here lets the next person RE-ASK instead of re-guessing. That
//! is not hypothetical in this repo: re-running the sniff bench is what found a 3.3× defect that a
//! port would otherwise have carried across and credited to Rust.
//!
//! The Swift side it was compared against is `Sources/SlopDeskProtocol/Mux/MuxEnvelope.swift`,
//! driven by an equivalent `-Ounchecked` program. Both take the best of five runs so a scheduler
//! blip inflates neither. Numbers are recorded in `docs/DECISIONS.md`.
//!
//! An example rather than a `#[bench]`: this crate has no nightly dependency and no bench harness,
//! and an example costs the library build nothing.

#![expect(
    clippy::print_stdout,
    reason = "a benchmark's entire output is a table on stdout"
)]
#![expect(
    clippy::cast_precision_loss,
    reason = "nanosecond counts are far below f64's exact-integer range; this is a timing report"
)]

use std::hint::black_box;
use std::time::Instant;

use slopdesk_wire::{MuxCloseReason, MuxFrame, MuxFrameDecoder};

fn ns_per_op(iterations: u32, mut block: impl FnMut() -> usize) -> f64 {
    for _ in 0..iterations.min(2000) {
        black_box(block());
    }
    let mut best = f64::MAX;
    for _ in 0..5 {
        let start = Instant::now();
        for _ in 0..iterations {
            black_box(block());
        }
        let elapsed = start.elapsed().as_nanos() as f64 / f64::from(iterations);
        best = best.min(elapsed);
    }
    best
}

fn main() {
    let sid: [u8; 16] = [
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
    ];
    let scenarios: Vec<(&str, MuxFrame, u32)> = vec![
        (
            "channelOpen",
            MuxFrame::ChannelOpen {
                channel_id: 9,
                session_id: sid,
                last_received_seq: 7,
                channel_class: 0,
                initial_cwd: Some("/Users/x/projects/slop-desk".to_owned()),
            },
            200_000,
        ),
        (
            "channelOpenAck",
            MuxFrame::ChannelOpenAck {
                channel_id: 3,
                accepted: true,
                resume_from_seq: 42,
            },
            400_000,
        ),
        (
            "channelClose",
            MuxFrame::ChannelClose {
                channel_id: 6,
                reason: MuxCloseReason::Retired,
            },
            400_000,
        ),
        (
            "windowAdjust",
            MuxFrame::WindowAdjust {
                channel_id: 7,
                bytes_to_add: 262_144,
            },
            400_000,
        ),
        (
            "channelData 1 KiB",
            MuxFrame::ChannelData {
                channel_id: 1,
                payload: vec![0xAB; 1024],
            },
            200_000,
        ),
        (
            "channelData 32 KiB",
            MuxFrame::ChannelData {
                channel_id: 1,
                payload: vec![0xAB; 32 * 1024],
            },
            40_000,
        ),
    ];

    println!("scenario,encode_ns,decode_ns");
    for (name, frame, iters) in &scenarios {
        let enc = ns_per_op(*iters, || frame.encode().len());
        let encoded = frame.encode();
        // The decoder is fed an INNER run, the way `MuxFrameDecoder` hands one over: the length
        // prefix is framing, not part of what `decode` reads.
        let inner = encoded.get(4..).unwrap_or_default();
        let dec = ns_per_op(*iters, || {
            MuxFrame::decode(inner).map_or(0, |f| usize::try_from(f.channel_id()).unwrap_or(0))
        });
        println!("{name},{enc:.1},{dec:.1}");
    }

    let payload = vec![0xCD_u8; 1024];
    let mut stream = Vec::new();
    for _ in 0..2000 {
        stream.extend_from_slice(
            &MuxFrame::ChannelData {
                channel_id: 1,
                payload: payload.clone(),
            }
            .encode(),
        );
    }
    let chunks: Vec<&[u8]> = stream.chunks(64 * 1024).collect();
    let stream_ns = ns_per_op(200, || {
        let mut d = MuxFrameDecoder::new();
        let mut n = 0;
        for c in &chunks {
            d.append(c);
            while let Ok(Some(_)) = d.next_frame() {
                n += 1;
            }
        }
        n
    }) / 2000.0;
    println!("streaming decode 1 KiB frames,,{stream_ns:.1}");
}
