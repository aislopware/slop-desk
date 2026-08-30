//! Parity benchmark for the workspace document codec:
//! `cargo run --release --example documentbench`.
//!
//! Kept in the tree on the `muxbench` / `metadatabench` precedent — the numbers a port is justified
//! by go stale, and a bench that is still here lets the next person RE-ASK instead of re-guessing.
//!
//! ## Why this one is not optional
//! The metadata bench measured a straight transliteration. This port changed a DATA STRUCTURE:
//! Swift held the document in a `Dictionary` and sorted its keys at every snapshot, diff and object
//! query; the Rust side holds a `BTreeMap` whose iteration order already IS the wire's canonical
//! order. That is a real algorithmic difference — `O(n log n)` per call against `O(n)` per call
//! over worse constants — and "perf parity" stops being a formality when the shapes differ. The
//! `diffFrom` and `applying` rows exist specifically to answer it; the pure encode/decode rows are
//! the control.
//!
//! Sizes are the realistic worst cases the host actually produces — a 2000-cell document is a large
//! session with tens of panes — not synthetic maxima.
//!
//! The Swift side it was compared against is `Sources/SlopDeskWorkspaceModel/Codec/` driven by an
//! equivalent `-Ounchecked` program. (Not an `XCTest`: `swift test -c release` cannot build this
//! package's test tree at all, because `ConnectionViewModel.foldEventForTesting` is `#if
//! DEBUG`-gated and several suites call it. So the Swift half runs as a throwaway `SwiftPM`
//! executable that depends on the `SlopDeskWorkspaceModel` product by path.) Both take the best of
//! five runs so a scheduler blip inflates neither. Numbers are recorded in `docs/DECISIONS.md`.
//!
//! Both sides print the encoded byte count of every scenario first. That is the cheap check that
//! the two are doing the SAME work before their timings are compared at all.

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

use slopdesk_wire::document::{
    HostWorkspaceState, SplitAxis, WorkspaceEntry, WorkspaceKey, WorkspaceLayoutNode, decode_diff,
    decode_layout, decode_snapshot, encode_diff, encode_layout, encode_snapshot,
};

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

fn row(name: &str, iterations: u32, encode: impl FnMut() -> usize, decode: impl FnMut() -> usize) {
    let mut encode = encode;
    let mut decode = decode;
    let enc = ns_per_op(iterations, &mut encode);
    let dec = ns_per_op(iterations, &mut decode);
    println!("{name},{enc:.1},{dec:.1}");
}

/// A document of `count` cells spread over `count / 4` pane objects, which is the shape a real
/// session has: a handful of fields per object rather than one fat object.
fn document(count: u32) -> HostWorkspaceState {
    HostWorkspaceState::from_entries(
        (0..count)
            .map(|i| {
                let mut object = [0_u8; 16];
                object[..4].copy_from_slice(&i.div_euclid(4).to_be_bytes());
                WorkspaceEntry::new(
                    WorkspaceKey::new(3, object, u8::try_from(i % 4).unwrap_or(0)),
                    format!("value-{i}-main.go - NVIM").into_bytes(),
                )
            })
            .collect(),
    )
}

/// A balanced binary layout of `2^depth` leaves — 32 panes at depth 5, well past any real tab.
fn balanced_layout(depth: usize, seed: u8) -> WorkspaceLayoutNode {
    if depth == 0 {
        return WorkspaceLayoutNode::Leaf([seed; 16]);
    }
    WorkspaceLayoutNode::Split {
        id: [seed.wrapping_add(0x40); 16],
        axis: if depth.is_multiple_of(2) {
            SplitAxis::Horizontal
        } else {
            SplitAxis::Vertical
        },
        children: vec![
            balanced_layout(depth - 1, seed.wrapping_mul(2).wrapping_add(1)),
            balanced_layout(depth - 1, seed.wrapping_mul(2).wrapping_add(2)),
        ],
    }
}

fn main() {
    let state = document(2000);
    // The base a subscriber last ACKED: the same document with 200 cells holding a STALE value (so
    // the diff carries 200 sets) plus 50 cells this state no longer has (so it carries 50 deletes).
    let mut base = state.clone();
    for key in state.sorted_entries().iter().map(|entry| entry.key).take(200) {
        base.set(key, b"stale".to_vec());
    }
    for i in 0..50_u32 {
        let mut object = [0xEE_u8; 16];
        object[..4].copy_from_slice(&i.to_be_bytes());
        base.set(WorkspaceKey::new(3, object, 0), b"retired".to_vec());
    }
    let diff = state.diff_from(&base);
    let layout = balanced_layout(5, 1);

    let encoded_snapshot = encode_snapshot(&state);
    let encoded_diff = encode_diff(&diff);
    let encoded_layout = encode_layout(&layout);

    println!(
        "payload bytes: snapshot={} diff={} layout={} (diff carries {} sets / {} deletes)",
        encoded_snapshot.len(),
        encoded_diff.len(),
        encoded_layout.len(),
        diff.sets.len(),
        diff.deletes.len()
    );
    println!("scenario,encode_ns,decode_ns");
    row(
        "snapshot 2000 cells",
        2000,
        || encode_snapshot(black_box(&state)).len(),
        || decode_snapshot(black_box(&encoded_snapshot)).map_or(0, |s| s.len()),
    );
    row(
        "diff 200 sets / 50 deletes",
        20_000,
        || encode_diff(black_box(&diff)).len(),
        || decode_diff(black_box(&encoded_diff)).map_or(0, |d| d.sets.len()),
    );
    row(
        "layout 32 leaves",
        50_000,
        || encode_layout(black_box(&layout)).len(),
        || decode_layout(black_box(&encoded_layout)).map_or(0, |_| 1),
    );
    // The two columns mean something different on this row, which is why it is labelled: the
    // "encode" side computes the diff, the "decode" side applies it. Neither touches a byte. This
    // is the row the Dictionary-plus-sort → BTreeMap change actually lands on.
    row(
        "diffFrom / applying 2000 cells",
        2000,
        || black_box(&state).diff_from(black_box(&base)).sets.len(),
        || black_box(&base).applying(black_box(&diff)).len(),
    );
}
