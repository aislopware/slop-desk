//! The transcript corpus, folded end to end: tailer → parser → builder → replay → subscriber.
//!
//! `tests/fixtures/` is the corpus that used to live beside the Swift inspector tests
//! (`Tests/SlopDeskInspectorTests/Fixtures/`) and moved here with the code that reads it. It is a
//! deliberately awkward session: a thinking placeholder, a tool call whose result arrives two lines
//! later, a `TodoWrite`, a FAILED tool call, an internal type that must be ignored, a type from a
//! future version that must be surfaced rather than dropped — plus a subagent transcript in the
//! `subagents/` sibling, which native `claude` does not interleave into the main file.
//!
//! The unit tests in `src/` pin each stage against hand-built input. This one pins the whole
//! pipeline against a real session, through the same public API the daemon uses, which is the part
//! no single module's tests can prove.

#![expect(
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use slopdesk_inspectord::engine::{Engine, Sources};
use slopdesk_inspectord::event::{InspectorEvent, MessageRole, TodoStatus, ToolCardStatus};
use slopdesk_inspectord::replay::{Pull, ReplayLog};

/// The fixture directory, resolved from the crate root so the test does not care about the cwd.
fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

/// Runs the engine over the corpus and returns every event it produced, in order.
///
/// The corpus is finite, so "done" is "the history stopped growing across several polls". Bounded
/// by a deadline, so a regression that stalls the engine fails the test rather than hanging it.
fn fold_corpus() -> Vec<InspectorEvent> {
    let poll = Duration::from_millis(5);
    let log = Arc::new(ReplayLog::default());
    // The engine is held for the whole fold; dropping it stops the thread.
    let _engine = Engine::start(
        Sources::from_transcript(fixtures().join("main-session.jsonl")),
        Arc::clone(&log),
        poll,
    );

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut settled = 0_u32;
    let mut last = log.history_count();
    while settled < 20 && Instant::now() < deadline {
        std::thread::sleep(poll);
        let now = log.history_count();
        if now == last && now > 0 {
            settled += 1;
        } else {
            settled = 0;
            last = now;
        }
    }
    assert!(last > 0, "the engine produced nothing from a non-empty corpus");

    // Replay from the top: the same request a cold client makes.
    let subscription = log.subscribe(0);
    let mut events = Vec::new();
    while let Pull::Event(event) = subscription.subscriber.pull(Duration::from_millis(200)) {
        events.push(*event);
    }
    log.unsubscribe(subscription.id);
    events
}

/// Only the events from the main session file, in the order the transcript implies.
///
/// A subagent's turns are excluded by ATTRIBUTION, not by type: its prompt arrives as an ordinary
/// [`InspectorEvent::Message`] carrying an `agent_id`, and that field is the whole point — it is
/// what keeps a subagent's conversation out of the main one.
fn main_session(events: &[InspectorEvent]) -> Vec<&InspectorEvent> {
    events
        .iter()
        .filter(|event| {
            match event {
                InspectorEvent::SubagentUpdated { .. } | InspectorEvent::SubagentToolCard { .. } => false,
                InspectorEvent::Message { message } => message.agent_id.is_none(),
                _ => true,
            }
        })
        .collect()
}

#[test]
fn the_main_session_folds_into_the_events_the_transcript_implies() {
    let events = fold_corpus();
    let main = main_session(&events);

    let mut index = 0;
    let mut next = || {
        let event = main.get(index).unwrap_or_else(|| {
            panic!(
                "the corpus ran out at event {index}; got {} in total: {main:#?}",
                main.len()
            )
        });
        index += 1;
        *event
    };

    // 1. `{type: system, subtype: init}` — the only meta line that DEFINES the session.
    let InspectorEvent::SessionStarted { info } = next() else {
        panic!("expected the session to be announced first")
    };
    assert_eq!(
        info.session_id.as_deref(),
        Some("11111111-2222-3333-4444-555555555555")
    );
    assert_eq!(info.model.as_deref(), Some("claude-opus-4-8"));
    assert_eq!(info.cwd.as_deref(), Some("/Users/dev/slop-desk"));

    // 2. The user's prompt.
    let InspectorEvent::Message { message } = next() else {
        panic!("expected the user's prompt")
    };
    assert_eq!(message.role, MessageRole::User);
    assert_eq!(message.text, "Please list the files and write a todo.");

    // 3. The assistant line carries a thinking block, text, and a tool call — three events, in the
    //    order the content array had them.
    let InspectorEvent::Thinking { marker } = next() else {
        panic!("expected the thinking marker")
    };
    assert!(
        marker.is_placeholder,
        "Claude 4 persists no thinking text — presence only"
    );
    assert_eq!(
        marker.signature.as_deref(),
        Some("ABCDEF0123456789signature-fingerprint"),
        "the signature proves the block existed",
    );

    let InspectorEvent::Message { message } = next() else {
        panic!("expected the assistant's text")
    };
    assert_eq!(message.role, MessageRole::Assistant);
    assert_eq!(message.text, "I'll list the files first.");

    let InspectorEvent::ToolCard { card } = next() else {
        panic!("expected the Bash call")
    };
    assert_eq!(card.id, "toolu_001");
    assert_eq!(card.name, "Bash");
    assert_eq!(card.status, ToolCardStatus::Pending);
    assert_eq!(card.input.get("command").and_then(|v| v.as_str()), Some("ls -la"));

    // 4. The result arrives on the NEXT line and completes the SAME card — the pairing contract.
    let InspectorEvent::ToolCard { card } = next() else {
        panic!("expected the Bash call to complete")
    };
    assert_eq!(card.id, "toolu_001", "the same card, updated in place");
    assert_eq!(card.status, ToolCardStatus::Completed);
    assert!(
        card.output
            .as_deref()
            .unwrap_or_default()
            .contains("Package.swift")
    );

    // 5. `file-history-snapshot` sits between them in the file and emits NOTHING — it is classified
    //    internal bookkeeping, not an unknown line. (If it leaked, the next assertion fails.)

    // 6. `TodoWrite` becomes the todo panel, not a tool card.
    let InspectorEvent::TodosUpdated { todos } = next() else {
        panic!("expected TodoWrite to become todos, not a card")
    };
    assert_eq!(todos.len(), 3);
    assert_eq!(todos[0].status, TodoStatus::Completed);
    assert_eq!(todos[1].status, TodoStatus::InProgress);
    assert_eq!(todos[1].active_form.as_deref(), Some("Implementing the parser"));
    assert_eq!(todos[2].status, TodoStatus::Pending);

    // 7. A call that FAILS: pending, then errored — not completed with error text.
    let InspectorEvent::ToolCard { card } = next() else {
        panic!("expected the Read call")
    };
    assert_eq!(card.id, "toolu_003");
    assert_eq!(card.status, ToolCardStatus::Pending);

    let InspectorEvent::ToolCard { card } = next() else {
        panic!("expected the Read call to fail")
    };
    assert_eq!(card.id, "toolu_003");
    assert_eq!(card.status, ToolCardStatus::Errored);
    assert_eq!(card.output.as_deref(), Some("Error: file not found"));

    // 8. A type this build has never seen is SURFACED, verbatim — the schema-evolution valve. It must
    //    not be dropped (silence is indistinguishable from a bug) and must not be guessed at.
    let InspectorEvent::UnknownLine { raw } = next() else {
        panic!("expected the future line to surface")
    };
    assert!(raw.contains("some-future-event-we-do-not-know"));
    assert!(
        raw.contains("\"nested\":[1,2,3]"),
        "the raw text is preserved, not re-serialised"
    );

    // 9. The closing assistant message.
    let InspectorEvent::Message { message } = next() else {
        panic!("expected the closing message")
    };
    assert_eq!(message.role, MessageRole::Assistant);
    assert_eq!(message.text, "Done. The file list is above and one read failed.");

    assert_eq!(
        index,
        main.len(),
        "nothing else came out of the main session: {main:#?}"
    );
}

#[test]
fn the_subagent_file_is_discovered_and_its_work_is_attributed() {
    let events = fold_corpus();

    // The node is asserted BEFORE any of its cards: a card for an agent the UI has never heard of
    // has nowhere to go.
    let first_subagent = events
        .iter()
        .position(|event| {
            matches!(
                event,
                InspectorEvent::SubagentUpdated { .. } | InspectorEvent::SubagentToolCard { .. }
            )
        })
        .expect("the subagents/ sibling was never discovered");
    let InspectorEvent::SubagentUpdated { node } = &events[first_subagent] else {
        panic!("a subagent's first event must be the node itself, not one of its cards")
    };
    assert_eq!(node.id, "deadbeef", "the id is the filename hash");

    let cards: Vec<_> = events
        .iter()
        .filter_map(|event| {
            match event {
                InspectorEvent::SubagentToolCard { agent_id, card } => Some((agent_id, card)),
                _ => None,
            }
        })
        .collect();
    assert_eq!(cards.len(), 2, "the Grep call, then its result: {cards:#?}");
    assert!(cards.iter().all(|(agent_id, _)| *agent_id == "deadbeef"));
    assert_eq!(cards[0].1.name, "Grep");
    assert_eq!(cards[0].1.status, ToolCardStatus::Pending);
    assert_eq!(cards[1].1.status, ToolCardStatus::Completed);
    assert!(
        cards[1]
            .1
            .output
            .as_deref()
            .unwrap_or_default()
            .contains("src/a.swift:10")
    );

    // A subagent's own turns must NOT leak into the main conversation — the panel shows them
    // under the node, and a main-session reader that saw them would double-count the session.
    assert!(
        !events.iter().any(|event| {
            matches!(event, InspectorEvent::Message { message } if message.agent_id.is_none()
                && message.text.contains("Find all callers"))
        }),
        "a subagent's prompt must be attributed, never folded into the main transcript",
    );
}
