//! What a tool card's INPUT reads as: the full flattening, and the one line that collapses it.
//!
//! Both renderings existed in Swift — `JSONValue.displayString` and `PendingToolSummary.line` in
//! `Sources/SlopDeskInspector` — and the first of them was already a second spelling of
//! [`crate::json::display_string`], which `json.rs`'s own module note catalogues as answering
//! DIFFERENTLY for four classes of input. That note ended "the obligation is a differential rather
//! than a deletion" because the Swift half decoded every JSON number to a `Double` before either
//! flattening ran, so the two could not be made to agree without changing what a `JSONValue` number
//! IS.
//!
//! This module is that change, taken from the other end: the renderings are asked for with the tool
//! input's RAW JSON, so serde sees the integer the transcript actually held and the divergence is
//! deleted rather than pinned. There is exactly one flattening in the tree again.
//!
//! ## Why both renderings, in one answer
//!
//! The two overlays that render a pending tool call — `MacPeekReply` and `PeekReplyOverlay` — each
//! want the full flattening AND the collapsed line, from the same input, at the same moment. One
//! call answering both is one parse of the JSON rather than two.

use serde_json::Value;

use crate::json::display_string;

/// The tool names whose input collapses to a `file_path` rather than to its first line.
///
/// The approve/deny read for a file-shaped tool is WHICH FILE, not a diff — so the summary names
/// the path and lets the card body carry the rest.
const FILE_SHAPED: [&str; 4] = ["Edit", "Write", "Read", "NotebookEdit"];

/// One tool card's input, as the two strings a card renders.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolInputRender {
    /// The whole input, flattened for the card body.
    pub display: String,
    /// One line for the collapsed row: the thing to actually read.
    pub summary: String,
}

/// Renders a tool card's input.
///
/// `Bash` summarises to its `command` — the exact text that will run. The file-shaped tools
/// summarise to `file_path`. Anything else, and any of the above whose expected key is missing or
/// is not a string, falls back to the FIRST LINE of the full flattening, so an unrecognised tool
/// never renders blank.
#[must_use]
pub fn tool_input(name: &str, input: &Value) -> ToolInputRender {
    let display = display_string(input);
    let keyed = if name == "Bash" {
        crate::json::string_at(input, "command")
    } else if FILE_SHAPED.contains(&name) {
        crate::json::string_at(input, "file_path")
    } else {
        None
    };
    let summary = keyed.map_or_else(|| first_line(&display).to_owned(), ToOwned::to_owned);
    ToolInputRender { display, summary }
}

/// The renderings for whichever tool card an EVENT's JSON carries, or `None` when it carries none.
///
/// The client asks with the event's raw bytes rather than with a decoded input, and that is the
/// whole point of the door: its own decode turns every JSON number into a `Double` on the way past,
/// so an input that reached this function through it would already have lost the integer this one
/// prints exactly. Reading the two card shapes out of the raw JSON here — `toolCard`'s `_0` and
/// `subagentToolCard`'s labelled `card` — costs one extra parse of an event that arrives per TURN,
/// and buys the tree back its single flattening.
///
/// A malformed body, a non-card event, or a card missing `name`/`input` all answer `None`: this
/// door adds a rendering to an event the caller has already accepted, so it never decides that the
/// event itself is bad.
#[must_use]
pub fn render_event(json: &[u8]) -> Option<ToolInputRender> {
    let value: Value = serde_json::from_slice(json).ok()?;
    let card = value
        .get("toolCard")
        .and_then(|body| body.get("_0"))
        .or_else(|| value.get("subagentToolCard").and_then(|body| body.get("card")))?;
    let name = crate::json::string_at(card, "name")?;
    Some(tool_input(name, card.get("input")?))
}

/// The first line of a possibly-multi-line flattening.
///
/// A multi-key object flattens with `\n` between its pairs, and the collapsed row is one line —
/// so the fallback takes the first pair rather than letting the row grow to the payload's height.
fn first_line(text: &str) -> &str {
    text.split_once('\n').map_or(text, |(head, _)| head)
}

/// The `i/n · activeForm` line for a todo list, or `None` when nothing is in flight.
///
/// `i` is the 1-based position of the FIRST in-progress item, `n` the total count, and the text is
/// that item's imperative `activeForm` — falling back to its plain `content` when the producer sent
/// none. Whether the caller is allowed to SHOW it is a separate question the caller's own live-feed
/// gate answers; this only says whether there is one and what it reads.
#[must_use]
pub fn todo_scent(todos: &[crate::event::TodoItem]) -> Option<String> {
    let position = todos
        .iter()
        .position(|item| item.status == crate::event::TodoStatus::InProgress)?;
    let item = todos.get(position)?;
    let text = item.active_form.as_ref().unwrap_or(&item.content);
    Some(format!("{}/{} · {text}", position + 1, todos.len()))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{render_event, todo_scent, tool_input};
    use crate::event::{TodoItem, TodoStatus};

    #[test]
    fn bash_summarises_to_the_command_it_will_run() {
        let render = tool_input("Bash", &json!({"command": "ls -la", "description": "list"}));
        assert_eq!(render.summary, "ls -la");
        assert_eq!(render.display, "command: ls -la\ndescription: list");
    }

    #[test]
    fn a_file_shaped_tool_summarises_to_its_path() {
        for name in ["Edit", "Write", "Read", "NotebookEdit"] {
            let render = tool_input(name, &json!({"file_path": "/tmp/a.txt", "old_string": "x"}));
            assert_eq!(render.summary, "/tmp/a.txt", "{name}");
        }
    }

    #[test]
    fn an_unrecognised_tool_falls_back_to_the_first_line_of_the_flattening() {
        let render = tool_input("Sparkle", &json!({"zeta": 1, "alpha": "a"}));
        // Sorted, so `alpha` leads — which is the whole reason the flattening sorts.
        assert_eq!(render.summary, "alpha: a");
        assert_eq!(render.display, "alpha: a\nzeta: 1");
    }

    #[test]
    fn a_missing_expected_key_falls_back_rather_than_rendering_blank() {
        let render = tool_input("Bash", &json!({"description": "no command here"}));
        assert_eq!(render.summary, "description: no command here");
    }

    /// The row the Swift flattening got wrong, now unreachable: an integer past `f64`'s exact range
    /// reaches the renderer as an integer, because the raw JSON is what crosses.
    #[test]
    fn a_large_integer_input_renders_exactly() {
        let render = tool_input("Sparkle", &json!({"n": 9_007_199_254_740_993_i64}));
        assert_eq!(render.summary, "n: 9007199254740993");
    }

    #[test]
    fn a_non_string_at_the_expected_key_is_not_coerced() {
        let render = tool_input("Read", &json!({"file_path": 7}));
        assert_eq!(render.summary, "file_path: 7");
    }

    fn todo(content: &str, status: TodoStatus, active: Option<&str>) -> TodoItem {
        TodoItem {
            content: content.to_owned(),
            status,
            active_form: active.map(ToOwned::to_owned),
        }
    }

    #[test]
    fn the_scent_names_the_first_item_in_flight() {
        let todos = [
            todo("done it", TodoStatus::Completed, None),
            todo("do it", TodoStatus::InProgress, Some("Doing it")),
            todo("later", TodoStatus::Pending, None),
        ];
        assert_eq!(todo_scent(&todos).as_deref(), Some("2/3 · Doing it"));
    }

    #[test]
    fn the_scent_falls_back_to_the_plain_content() {
        let todos = [todo("do it", TodoStatus::InProgress, None)];
        assert_eq!(todo_scent(&todos).as_deref(), Some("1/1 · do it"));
    }

    #[test]
    fn nothing_in_flight_is_no_scent() {
        let todos = [todo("later", TodoStatus::Pending, None)];
        assert_eq!(todo_scent(&todos), None);
    }

    #[test]
    fn both_card_shapes_are_read_out_of_a_raw_event() {
        let main =
            br#"{"toolCard":{"_0":{"id":"t1","name":"Bash","input":{"command":"ls"},"status":"pending"}}}"#;
        assert_eq!(render_event(main).map(|r| r.summary).as_deref(), Some("ls"));

        let sub = br#"{"subagentToolCard":{"agentID":"a1","card":{"id":"s1","name":"Read","input":{"file_path":"/x"},"status":"pending"}}}"#;
        assert_eq!(render_event(sub).map(|r| r.summary).as_deref(), Some("/x"));
    }

    /// The whole reason the raw bytes cross: an integer that a `Double` decode would have rounded
    /// reaches the flattening intact.
    #[test]
    fn a_raw_event_keeps_an_integer_a_decode_through_double_would_lose() {
        let json = br#"{"toolCard":{"_0":{"id":"t","name":"Sparkle","input":{"n":9007199254740993},"status":"pending"}}}"#;
        assert_eq!(
            render_event(json).map(|r| r.summary).as_deref(),
            Some("n: 9007199254740993")
        );
    }

    #[test]
    fn an_event_that_carries_no_card_answers_nothing() {
        assert!(render_event(br#"{"message":{"_0":{"role":"user","text":"hi"}}}"#).is_none());
        assert!(render_event(b"not json at all").is_none());
        assert!(render_event(br#"{"toolCard":{"_0":{"id":"t","status":"pending"}}}"#).is_none());
    }
}
