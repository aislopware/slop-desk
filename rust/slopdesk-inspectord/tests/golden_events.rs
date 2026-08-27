//! The inspector event schema, pinned against `golden/golden_vectors.json`.
//!
//! ## Why this key is HAND-AUTHORED and frozen rather than emitted
//! Every other wire key in that corpus was minted by `Sources/slopdesk-corevectors`, which can only
//! emit what a Swift ENCODER produces. There is no such encoder here: the production client end
//! (`Sources/SlopDeskInspector`) is DECODE-only, and its `ToolCard` does not even hold the wire's
//! `input` — it holds the two RENDERINGS `slopdesk_inspector_tool_input_render` grafts on, both
//! defaulted. Swift's synthesized encode is therefore not the wire, so the vectors were written
//! from the shape THIS crate authors and the key is in `FROZEN_KEYS`.
//!
//! ## What it protects that `event.rs`'s own unit tests cannot
//! Those literals live beside the types they describe: renaming a field and its literal in one edit
//! keeps them green while breaking a shipped client. The corpus is a file neither end owns, read
//! from BOTH — here, and from `Tests/SlopDeskInspectorTests/InspectorEventGoldenVectorTests.swift`
//! through a bare `JSONDecoder`. A rename has to be typed into the corpus too, which is the moment
//! it becomes a wire change instead of a refactor.
//!
//! Each record is pinned in three directions: the value this crate builds SERIALIZES to the pinned
//! JSON, the pinned JSON DESERIALIZES back to that value, and the whole tag-1 frame — the four-byte
//! big-endian prefix that counts the tag, then the tag, then the compact body — matches the pinned
//! hex. The first two bracket the codec so a serializer and deserializer that agreed on a wrong
//! field name cannot round-trip past it; the third is what pins the framing.
//!
//! The corpus is READ here, never written. A vector that disagrees is a wire regression, not a
//! stale expectation to refresh.

#![expect(
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]

use core::fmt::Write as _;
use std::collections::BTreeSet;

use serde_json::{Value, json};
use slopdesk_inspectord::event::{
    InspectorEvent, MessageEvent, MessageRole, SessionInfo, SubagentNode, SubagentStatus, ThinkingMarker,
    TodoItem, TodoStatus, ToolCard, ToolCardStatus, WorkflowMarker, WorkflowState,
};
use slopdesk_inspectord::wire::{WireMessage, encode};

/// The pinned corpus, read at compile time so a missing or renamed file is a build failure rather
/// than a test that silently passes with zero vectors.
const GOLDEN: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../golden/golden_vectors.json"
));

/// Every case the wire carries. Named here so a record the corpus DROPPED fails as loudly as one it
/// changed — the pin is the whole taxonomy, not whichever part of it survived an edit.
const EVERY_CASE: &[&str] = &[
    "historyTruncated",
    "message",
    "sessionStarted",
    "subagentToolCard",
    "subagentUpdated",
    "thinking",
    "todosUpdated",
    "toolCard",
    "unknownLine",
    "workflow",
];

fn to_hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// The card two vectors share: a `Read` still pending, its result not yet in.
fn pending_read() -> ToolCard {
    ToolCard {
        id: "toolu_1".to_owned(),
        name: "Read".to_owned(),
        input: json!({"file_path": "/tmp/a"}),
        output: None,
        status: ToolCardStatus::Pending,
    }
}

/// The value each pinned record describes, built HERE rather than decoded from the record.
///
/// This is what makes the JSON comparison an oracle instead of a round-trip: the value never came
/// from the pinned bytes, so a serializer and a deserializer that agreed with each other on a wrong
/// field name cannot both pass. An unknown case name panics, so a record added to the corpus
/// without a value to check it against fails rather than being skipped.
fn expected(case: &str) -> InspectorEvent {
    match case {
        "toolCard" => InspectorEvent::ToolCard { card: pending_read() },
        "todosUpdated" => {
            InspectorEvent::TodosUpdated {
                todos: vec![TodoItem {
                    content: "port it".to_owned(),
                    status: TodoStatus::InProgress,
                    active_form: Some("porting it".to_owned()),
                }],
            }
        },
        "subagentUpdated" => {
            InspectorEvent::SubagentUpdated {
                node: SubagentNode {
                    id: "a1".to_owned(),
                    parent_id: None,
                    agent_type: Some("Ariadne".to_owned()),
                    description: None,
                    status: SubagentStatus::Stopped,
                    last_assistant_message: Some("done".to_owned()),
                },
            }
        },
        "subagentToolCard" => {
            InspectorEvent::SubagentToolCard {
                agent_id: "a1".to_owned(),
                card: pending_read(),
            }
        },
        "thinking" => {
            InspectorEvent::Thinking {
                marker: ThinkingMarker {
                    is_placeholder: true,
                    signature: Some("sig".to_owned()),
                    text: None,
                },
            }
        },
        "message" => {
            InspectorEvent::Message {
                message: MessageEvent {
                    role: MessageRole::Assistant,
                    text: "hi".to_owned(),
                    agent_id: None,
                },
            }
        },
        "sessionStarted" => {
            InspectorEvent::SessionStarted {
                info: SessionInfo {
                    session_id: Some("s1".to_owned()),
                    model: Some("opus".to_owned()),
                    cwd: None,
                    transcript_path: None,
                },
            }
        },
        "workflow" => {
            InspectorEvent::Workflow {
                marker: WorkflowMarker {
                    state: WorkflowState::Running,
                },
            }
        },
        "unknownLine" => {
            InspectorEvent::UnknownLine {
                raw: "{not json".to_owned(),
            }
        },
        "historyTruncated" => InspectorEvent::HistoryTruncated { dropped_count: 7 },
        other => panic!("the corpus grew a case this test does not check: {other:?}"),
    }
}

/// Every pinned record, from both sides, frame included.
#[test]
fn the_pinned_event_corpus_encodes_and_decodes_to_the_pinned_shapes() {
    let golden: Value = serde_json::from_str(GOLDEN).expect("the golden corpus is valid JSON");
    let vectors = golden["inspectorEvents"]
        .as_array()
        .expect("the corpus pins inspectorEvents as an array");

    let mut seen = BTreeSet::new();
    for vector in vectors {
        let case = vector["case"].as_str().expect("every record names its case");
        let pinned = &vector["json"];
        let event = expected(case);

        assert_eq!(
            &serde_json::to_value(&event).expect("an InspectorEvent always serializes"),
            pinned,
            "{case}: this build encodes a shape the pinned client cannot read"
        );
        assert_eq!(
            serde_json::from_value::<InspectorEvent>(pinned.clone())
                .unwrap_or_else(|error| panic!("{case}: the pinned JSON no longer decodes: {error}")),
            event,
            "{case}: the pinned JSON decodes to a different value than it was written from"
        );

        let frame = encode(&WireMessage::Event(Box::new(event))).expect("a pinned event frames");
        assert_eq!(
            to_hex(&frame),
            vector["frameHex"].as_str().expect("every record pins its frame"),
            "{case}: the tag-1 frame changed"
        );

        assert!(seen.insert(case.to_owned()), "{case} is pinned twice");
    }

    assert_eq!(
        seen,
        EVERY_CASE.iter().map(|case| (*case).to_owned()).collect(),
        "the corpus no longer pins every case of the wire's taxonomy"
    );
}
