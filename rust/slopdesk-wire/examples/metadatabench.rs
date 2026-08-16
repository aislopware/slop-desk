//! Parity benchmark for the metadata payload codecs:
//! `cargo run --release --example metadatabench`.
//!
//! Kept in the tree on the `muxbench` / `slopdesk-sniffbench` precedent — the numbers a port is
//! justified by go stale, and a bench that is still here lets the next person RE-ASK instead of
//! re-guessing.
//!
//! These are COLD-path codecs: a metadata poll runs about once a second per pane, not once per
//! byte, so nothing here is on the latency budget the terminal wire is. The bench exists anyway
//! because "perf parity" is the port's stated condition, and an unmeasured claim of parity is not
//! one. Sizes are the realistic worst cases the host actually produces — a monorepo's `git status`,
//! a fat directory expand — not synthetic maxima.
//!
//! The Swift side it was compared against is
//! `Sources/SlopDeskProtocol/Metadata/MetadataCodec.swift` driven by an equivalent `-Ounchecked`
//! program. (Not an `XCTest`: `swift test -c release` cannot build this package's test tree at all,
//! because `ConnectionViewModel.foldEventForTesting` is `#if DEBUG`-gated and several suites call
//! it. So the Swift half runs as a throwaway `SwiftPM` executable that depends on the
//! `SlopDeskProtocol` product by path.) Both take the best of five runs so a scheduler blip
//! inflates neither. Numbers are recorded in `docs/DECISIONS.md`.
//!
//! Both sides print the encoded byte count of every scenario first. That is the cheap check that
//! the two are doing the SAME work before their timings are compared at all — five matching sizes
//! is not proof of identical bytes, but a mismatch would mean the tables were never comparable.

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

use slopdesk_wire::metadata::{
    AgentSessionInfo, DirEntry, GitFileChange, GitStatusPayload, PortInfo, ProcessInfo,
    decode_agent_session_list, decode_dir_listing, decode_git_status, decode_port_list, decode_process_list,
    encode_agent_session_list, encode_dir_listing, encode_git_status, encode_port_list, encode_process_list,
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

fn main() {
    let processes: Vec<ProcessInfo> = (0..200)
        .map(|i| {
            ProcessInfo {
                pid: 1000 + i,
                uptime_sec: i * 7,
                name: format!("worker-{i}"),
            }
        })
        .collect();
    let ports: Vec<PortInfo> = (0..100)
        .map(|i| {
            PortInfo {
                port: u16::try_from(3000 + i).unwrap_or(u16::MAX),
                proto: u8::try_from(i % 2).unwrap_or(0),
                proc_name: "node".to_owned(),
            }
        })
        .collect();
    let entries: Vec<DirEntry> = (0..2000)
        .map(|i| {
            DirEntry {
                is_dir: i % 4 == 0,
                name: format!("Component{i}.swift"),
            }
        })
        .collect();
    let status = GitStatusPayload {
        has_repo: true,
        branch: "main".to_owned(),
        remote_url: "git@github.com:aislopware/slop-desk.git".to_owned(),
        repo_root: "/Volumes/Lacie/Workspace/oss/slop-desk".to_owned(),
        ahead: 3,
        behind: 0,
        stash_count: 1,
        files: (0..500)
            .map(|i| {
                GitFileChange {
                    status_code: u8::try_from(i % 256).unwrap_or(0),
                    path: format!("Sources/SlopDeskHost/File{i}.swift"),
                }
            })
            .collect(),
    };
    let sessions: Vec<AgentSessionInfo> = (0..300)
        .map(|i| {
            AgentSessionInfo {
                agent_kind_byte: u8::try_from(i % 3).unwrap_or(0),
                id: format!("9f3c-{i}"),
                title: "Port the metadata codec to Rust".to_owned(),
                cwd: "/Volumes/Lacie/Workspace/oss/slop-desk".to_owned(),
                mtime_ms: 1_749_700_000_123 + i64::from(i),
            }
        })
        .collect();
    let encoded_processes = encode_process_list(&processes);
    let encoded_ports = encode_port_list(&ports);
    let encoded_entries = encode_dir_listing(&entries);
    let encoded_status = encode_git_status(&status);
    let encoded_sessions = encode_agent_session_list(&sessions);

    // Every payload is a compile-time-known constant here, so the INPUTS go through `black_box`
    // too. Without that, LLVM is entitled to fold a whole encode away — the 7-byte `hostVitals`
    // row read 0.3 ns before this line existed, which is a measurement of nothing.
    println!(
        "payload bytes: processList={} portList={} dirListing={} gitStatus={} agentSessionList={}",
        encoded_processes.len(),
        encoded_ports.len(),
        encoded_entries.len(),
        encoded_status.len(),
        encoded_sessions.len()
    );
    println!("scenario,encode_ns,decode_ns");
    row(
        "processList 200",
        20_000,
        || encode_process_list(black_box(&processes)).len(),
        || decode_process_list(black_box(&encoded_processes)).map_or(0, |v| v.len()),
    );
    row(
        "portList 100",
        40_000,
        || encode_port_list(black_box(&ports)).len(),
        || decode_port_list(black_box(&encoded_ports)).map_or(0, |v| v.len()),
    );
    row(
        "dirListing 2000",
        4000,
        || encode_dir_listing(black_box(&entries)).len(),
        || decode_dir_listing(black_box(&encoded_entries)).map_or(0, |v| v.len()),
    );
    row(
        "gitStatus 500 files",
        10_000,
        || encode_git_status(black_box(&status)).len(),
        || decode_git_status(black_box(&encoded_status)).map_or(0, |s| s.files.len()),
    );
    row(
        "agentSessionList 300",
        10_000,
        || encode_agent_session_list(black_box(&sessions)).len(),
        || decode_agent_session_list(black_box(&encoded_sessions)).map_or(0, |v| v.len()),
    );
    // No `hostVitals` row, deliberately. Its payload is SEVEN fixed bytes with no loop and no
    // variable-length field, so there is nothing in it a compiler cannot fold flat: measured at
    // 400k iterations it read 0.3 ns/op, which is not a fast codec but an absent one. Both
    // `first()` and `.len()` sinks were tried and folded the same way. A row that reports a
    // number nobody can defend is worse than a row that is not there, so this states the gap
    // instead of printing it.
}
