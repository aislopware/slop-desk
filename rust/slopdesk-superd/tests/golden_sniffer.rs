//! The frozen `hostOutputSniffer` corpus, replayed through the sniffer that now produces it.
//!
//! ## What this closes
//! `golden/golden_vectors.json` holds keys `slopdesk-corevectors` does not emit;
//! `slopdesk-gate golden` prints those as "frozen keys are XCTest-pinned, not emitted". This is
//! one of them, and it sits directly on the title path (docs/45 §5.7, "The golden blind spot,
//! named"). Without a replay, a change to the type-21/22/23/32 emission produces no signal at all
//! and the committed vectors rot silently.
//!
//! ## Why it lives here rather than in Swift
//! It used to be `HostOutputSnifferGoldenGuardTests`, and it could be Swift because both halves —
//! the byte scan and the frame encoding — were. The scan is superd's now, so the guard came with
//! it. `slopdesk-wire` is a DEV-dependency for exactly this: superd does not know the protocol and
//! must not, but a test that pins "these bytes produce these frames" has to know both ends, and no
//! single crate owns both. The corpus is the contract, and each side is pinned against it.
//!
//! REVERT-TO-FAIL: change any emission in `sniffer.rs` and this fails with the case name and the
//! diverged frame. If the change was INTENTIONAL, hand-merge the new bytes into
//! `golden/golden_vectors.json` — never `>`-redirect the generator, which does not emit this key.

#![expect(
    clippy::expect_used,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]

use slopdesk_superd::sniffer::{CommandStatus, OutputSniffer, SniffEvent};
use slopdesk_wire::message::{CommandStatus as WireCommandStatus, WireMessage};
use slopdesk_wire::osc;

/// The corpus sits beside `rust/`, in the package root.
fn corpus() -> serde_json::Value {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../golden/golden_vectors.json");
    let raw = std::fs::read_to_string(path).expect("the committed corpus must be readable");
    serde_json::from_str(&raw).expect("golden_vectors.json must be an object")
}

fn from_hex(hex: &str) -> Vec<u8> {
    assert!(hex.len().is_multiple_of(2), "odd-length hex in the corpus: {hex}");
    hex.as_bytes()
        .chunks(2)
        .map(|pair| {
            let text = std::str::from_utf8(pair).expect("hex is ASCII");
            u8::from_str_radix(text, 16).expect("bad hex byte")
        })
        .collect()
}

fn to_hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;

    bytes.iter().fold(String::new(), |mut text, byte| {
        let _ignored = write!(text, "{byte:02x}");
        text
    })
}

/// One sniffed event as the frame hostd puts on the wire for it.
///
/// The same translation `MuxChannelSession.wireMessages(from:)` makes in Swift, and the reason both
/// exist is the reason the whole wire is written twice: the corpus is what keeps them honest. An
/// OSC 9;4 body that will not parse is dropped — it was progress either way, never a notification.
fn wire_message(event: &SniffEvent) -> Option<WireMessage> {
    Some(match *event {
        SniffEvent::Title(ref text) => WireMessage::Title(text.clone()),
        SniffEvent::Bell => WireMessage::Bell,
        SniffEvent::Status(CommandStatus::Running) => WireMessage::CommandStatus(WireCommandStatus::Running),
        SniffEvent::Status(CommandStatus::Idle {
            exit_code,
            duration_ms,
        }) => {
            WireMessage::CommandStatus(WireCommandStatus::Idle {
                exit_code,
                duration_ms,
            })
        },
        SniffEvent::Cwd(ref path) => WireMessage::Cwd(path.clone()),
        SniffEvent::Notification { ref title, ref body } => {
            WireMessage::Notification {
                title: title.clone(),
                body: body.clone(),
            }
        },
        SniffEvent::ProgressBody(ref body) => {
            let update = osc::parse_progress(body)?;
            WireMessage::Progress {
                state: update.state.to_wire(),
                percent: update.percent,
            }
        },
        // Unreachable from a sniffer: the variant exists only on the DECODING side, for a kind a
        // newer superd invented. It has no wire message because this build does not know what the
        // event was — which is the point of keeping it rather than dropping it.
        SniffEvent::Unknown { .. } => return None,
    })
}

#[test]
fn the_frozen_sniffer_vectors_still_produce_the_pinned_frames() {
    let corpus = corpus();
    let cases = corpus
        .get("hostOutputSniffer")
        .and_then(serde_json::Value::as_array)
        .expect("the frozen `hostOutputSniffer` key must exist in the corpus");
    assert!(
        !cases.is_empty(),
        "an empty frozen key would make this suite vacuous"
    );

    for case in cases {
        let name = case["name"].as_str().unwrap_or("<unnamed>");
        // ONE sniffer per case: the steps are a SEQUENCE through the state machine, and an OSC
        // split across two chunks is exactly what these vectors exist to pin. The clock comes from
        // the step's own `nowMs`, so the type-23 duration is deterministic.
        let mut sniffer = OutputSniffer::new(vec![String::new(), "localhost".to_owned()]);
        for (index, step) in case["steps"]
            .as_array()
            .expect("steps is an array")
            .iter()
            .enumerate()
        {
            let now_ms = step["nowMs"].as_i64().expect("nowMs is a number");
            let input = from_hex(step["inputHex"].as_str().expect("inputHex is a string"));
            let produced: Vec<String> = sniffer
                .observe(&input, now_ms)
                .iter()
                .filter_map(wire_message)
                .map(|message| to_hex(&message.encode()))
                .collect();
            let expected: Vec<String> = step["messagesHex"]
                .as_array()
                .expect("messagesHex is an array")
                .iter()
                .map(|hex| hex.as_str().expect("messagesHex members are strings").to_owned())
                .collect();
            assert_eq!(
                produced, expected,
                "frozen vector `{name}` step {index} diverged — the committed corpus and the live sniffer \
                 disagree"
            );
        }
    }
}

/// The corpus must keep covering the title path specifically — a future trim that dropped the
/// OSC-0/2 cases would leave the guard above green while re-opening the exact hole it closes.
#[test]
fn the_frozen_vectors_still_cover_the_title_path() {
    let corpus = corpus();
    let names: Vec<&str> = corpus["hostOutputSniffer"]
        .as_array()
        .expect("the frozen key is an array")
        .iter()
        .filter_map(|case| case["name"].as_str())
        .collect();
    assert!(
        names.contains(&"osc0Title"),
        "the BEL-terminated title case must stay pinned"
    );
    assert!(
        names.contains(&"osc2TitleST"),
        "the ST-terminated title case must stay pinned"
    );
}
