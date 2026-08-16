//! Tolerant parse from one raw JSONL line to a typed [`TranscriptLine`].
//!
//! Decode the envelope loosely, branch on `type`, pull the fields we know, and fall back to
//! [`TranscriptLine::Unknown`] for anything we do not — **never failing**. A line that is not valid
//! JSON at all (a half-written last line) also comes back as `Unknown`; the tailer only hands over
//! newline-terminated lines, so that is purely defensive.

use serde_json::Value;

use crate::json::{bool_at, display_string, non_empty, string_at, string_at_any};
use crate::line::{
    AssistantLine, LineIdentity, MetaLine, ThinkingBlock, ToolResultBlock, ToolUseBlock, TranscriptLine,
    UserLine,
};

/// Internal type tags that are recognised and deliberately dropped: bookkeeping, not conversation.
const IGNORED_TYPES: [&str; 3] = ["file-history-snapshot", "queue-operation", "rate_limit_event"];

/// The `type` values that carry session metadata.
const META_TYPES: [&str; 5] = ["system", "summary", "init", "session", "result"];

/// Parses one line. Whitespace-only input yields `None` (nothing to emit). Anything else yields a
/// [`TranscriptLine`] — including `Unknown` for unrecognised or unparseable input.
#[must_use]
pub fn parse(line: &str) -> Option<TranscriptLine> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }

    let Ok(root) = serde_json::from_str::<Value>(trimmed) else {
        return Some(unknown(trimmed));
    };
    if !root.is_object() {
        return Some(unknown(trimmed));
    }

    let line_type = string_at(&root, "type").unwrap_or_default();
    let identity = decode_identity(&root);

    Some(match line_type {
        "user" => TranscriptLine::User(decode_user(&root, identity)),
        "assistant" => TranscriptLine::Assistant(decode_assistant(&root, identity)),
        _ if META_TYPES.contains(&line_type) => TranscriptLine::Meta(decode_meta(&root, identity, line_type)),
        _ if IGNORED_TYPES.contains(&line_type) => {
            TranscriptLine::Ignored {
                line_type: line_type.to_owned(),
            }
        },
        _ => unknown(trimmed),
    })
}

/// The `Unknown` line for `raw`.
fn unknown(raw: &str) -> TranscriptLine {
    TranscriptLine::Unknown { raw: raw.to_owned() }
}

/// Pulls the identity fields, accepting both spellings of the ones a producer varies.
fn decode_identity(root: &Value) -> LineIdentity {
    LineIdentity {
        uuid: string_at(root, "uuid").map(str::to_owned),
        parent_uuid: string_at_any(root, &["parentUuid", "parentUUID"]).map(str::to_owned),
        is_sidechain: bool_at(root, "isSidechain"),
        agent_id: string_at_any(root, &["agentId", "agentID"]).map(str::to_owned),
        timestamp: string_at(root, "timestamp").map(str::to_owned),
    }
}

/// The `message.content` payload, handling both the object-with-content shape and a direct string
/// `message` (which becomes a single text fragment).
fn message_content(root: &Value) -> (Option<String>, &[Value]) {
    const NONE: &[Value] = &[];
    let Some(message) = root.get("message") else {
        return (None, NONE);
    };
    match message {
        Value::String(text) => (Some(text.clone()), NONE),
        Value::Object(_) => {
            match message.get("content") {
                Some(Value::String(text)) => (Some(text.clone()), NONE),
                Some(Value::Array(blocks)) => (None, blocks.as_slice()),
                _ => (None, NONE),
            }
        },
        _ => (None, NONE),
    }
}

/// Appends one more text fragment to the accumulated line text, newline-separated, folding an empty
/// result back to absence.
fn append_text(current: Option<&str>, addition: Option<&str>) -> Option<String> {
    let joined = match (current, addition) {
        (None, None) => return None,
        (Some(existing), None) => existing.to_owned(),
        (None, Some(extra)) => extra.to_owned(),
        (Some(existing), Some(extra)) => format!("{existing}\n{extra}"),
    };
    non_empty(&joined)
}

/// Decodes a `user` line: its text plus any `tool_result` blocks.
fn decode_user(root: &Value, identity: LineIdentity) -> UserLine {
    let (direct_text, blocks) = message_content(root);
    let mut text = direct_text;
    let mut tool_results = Vec::new();
    for block in blocks {
        if !block.is_object() {
            continue;
        }
        match string_at(block, "type") {
            Some("text") => text = append_text(text.as_deref(), string_at(block, "text")),
            Some("tool_result") => tool_results.push(decode_tool_result(block)),
            _ => {},
        }
    }
    UserLine {
        identity,
        text,
        tool_results,
    }
}

/// Decodes one `tool_result` block.
fn decode_tool_result(block: &Value) -> ToolResultBlock {
    ToolResultBlock {
        tool_use_id: string_at(block, "tool_use_id").unwrap_or_default().to_owned(),
        content: flatten_content(block.get("content")),
        is_error: bool_at(block, "is_error"),
    }
}

/// Decodes an `assistant` line: its text plus any `tool_use` and `thinking` blocks.
fn decode_assistant(root: &Value, identity: LineIdentity) -> AssistantLine {
    let (direct_text, blocks) = message_content(root);
    let mut text = direct_text;
    let mut tool_uses = Vec::new();
    let mut thinking = Vec::new();
    for block in blocks {
        if !block.is_object() {
            continue;
        }
        match string_at(block, "type") {
            Some("text") => text = append_text(text.as_deref(), string_at(block, "text")),
            Some("tool_use") => {
                // A `tool_use` without BOTH an id and a name cannot be paired with its result and
                // cannot be labelled — it is dropped rather than shown as an anonymous card.
                if let (Some(id), Some(name)) = (string_at(block, "id"), string_at(block, "name")) {
                    tool_uses.push(ToolUseBlock {
                        id: id.to_owned(),
                        name: name.to_owned(),
                        input: block
                            .get("input")
                            .cloned()
                            .unwrap_or_else(|| Value::Object(serde_json::Map::new())),
                    });
                }
            },
            Some("thinking") => {
                thinking.push(ThinkingBlock {
                    signature: string_at(block, "signature").map(str::to_owned),
                    // Empty thinking text is ABSENCE, not content — that is the placeholder case.
                    text: string_at(block, "thinking").and_then(non_empty),
                });
            },
            _ => {},
        }
    }
    AssistantLine {
        identity,
        text,
        tool_uses,
        thinking,
    }
}

/// Decodes a metadata line. `model` may live at the top level or inside `message`.
fn decode_meta(root: &Value, identity: LineIdentity, raw_type: &str) -> MetaLine {
    let model = string_at(root, "model")
        .or_else(|| root.get("message").and_then(|msg| string_at(msg, "model")))
        .map(str::to_owned);
    MetaLine {
        identity,
        raw_type: raw_type.to_owned(),
        session_id: string_at_any(root, &["sessionId", "session_id"]).map(str::to_owned),
        model,
        cwd: string_at(root, "cwd").map(str::to_owned),
    }
}

/// Flattens a `tool_result.content` value — a string, or an array of blocks — into one string.
fn flatten_content(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(blocks)) => {
            blocks
                .iter()
                .map(|block| {
                    // No `text` key → render the WHOLE object deterministically (sorted keys), never an
                    // arbitrary field: the Swift original's `b.values.first` surfaced a different,
                    // often less informative, value on each process because of hash-order randomisation.
                    string_at(block, "text").map_or_else(|| display_string(block), str::to_owned)
                })
                .collect::<Vec<_>>()
                .join("\n")
        },
        Some(other) => display_string(other),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use serde_json::json;

    use super::parse;
    use crate::line::TranscriptLine;

    #[test]
    fn blank_input_yields_nothing() {
        assert!(parse("").is_none());
        assert!(parse("   \n\t ").is_none());
    }

    #[test]
    fn unparseable_json_becomes_an_unknown_line_carrying_its_raw_text() {
        let Some(TranscriptLine::Unknown { raw }) = parse("  {half-written  ") else {
            panic!("expected Unknown");
        };
        assert_eq!(raw, "{half-written");
    }

    #[test]
    fn a_bare_json_array_is_not_a_transcript_line() {
        assert!(matches!(parse("[1,2,3]"), Some(TranscriptLine::Unknown { .. })));
    }

    #[test]
    fn an_unrecognised_type_is_unknown_but_an_internal_one_is_ignored() {
        assert!(matches!(
            parse(&json!({"type": "from-the-future"}).to_string()),
            Some(TranscriptLine::Unknown { .. })
        ));
        let Some(TranscriptLine::Ignored { line_type }) =
            parse(&json!({"type": "queue-operation"}).to_string())
        else {
            panic!("expected Ignored");
        };
        assert_eq!(line_type, "queue-operation");
    }

    #[test]
    fn a_user_line_carries_text_and_tool_results() {
        let raw = json!({
            "type": "user",
            "uuid": "u1",
            "message": {"content": [
                {"type": "text", "text": "first"},
                {"type": "text", "text": "second"},
                {"type": "tool_result", "tool_use_id": "t1", "content": "out", "is_error": true},
            ]},
        })
        .to_string();
        let Some(TranscriptLine::User(user)) = parse(&raw) else {
            panic!("expected User");
        };
        assert_eq!(user.identity.uuid.as_deref(), Some("u1"));
        assert_eq!(user.text.as_deref(), Some("first\nsecond"));
        assert_eq!(user.tool_results.len(), 1);
        assert_eq!(user.tool_results[0].tool_use_id, "t1");
        assert_eq!(user.tool_results[0].content, "out");
        assert!(user.tool_results[0].is_error);
    }

    #[test]
    fn a_string_message_is_the_whole_text() {
        let raw = json!({"type": "user", "message": "just a string"}).to_string();
        let Some(TranscriptLine::User(user)) = parse(&raw) else {
            panic!("expected User");
        };
        assert_eq!(user.text.as_deref(), Some("just a string"));
    }

    #[test]
    fn an_assistant_line_carries_tool_uses_and_placeholder_thinking() {
        let raw = json!({
            "type": "assistant",
            "uuid": "a1",
            "message": {"content": [
                {"type": "thinking", "thinking": "", "signature": "sig"},
                {"type": "text", "text": "on it"},
                {"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": "/x"}},
                {"type": "tool_use", "name": "NoId"},
            ]},
        })
        .to_string();
        let Some(TranscriptLine::Assistant(assistant)) = parse(&raw) else {
            panic!("expected Assistant");
        };
        assert_eq!(assistant.text.as_deref(), Some("on it"));
        assert_eq!(assistant.thinking.len(), 1);
        assert!(assistant.thinking[0].is_placeholder());
        assert_eq!(assistant.thinking[0].signature.as_deref(), Some("sig"));
        // The id-less `tool_use` is dropped, not shown as an anonymous card.
        assert_eq!(assistant.tool_uses.len(), 1);
        assert_eq!(assistant.tool_uses[0].id, "t1");
        assert_eq!(assistant.tool_uses[0].input["file_path"], json!("/x"));
    }

    #[test]
    fn a_tool_use_without_an_input_still_parses_with_an_empty_object() {
        let raw = json!({
            "type": "assistant",
            "message": {"content": [{"type": "tool_use", "id": "t", "name": "Bash"}]},
        })
        .to_string();
        let Some(TranscriptLine::Assistant(assistant)) = parse(&raw) else {
            panic!("expected Assistant");
        };
        assert_eq!(assistant.tool_uses[0].input, json!({}));
    }

    #[test]
    fn meta_reads_the_model_from_either_level() {
        let top = json!({"type": "system", "sessionId": "s", "model": "opus", "cwd": "/w"});
        let Some(TranscriptLine::Meta(meta)) = parse(&top.to_string()) else {
            panic!("expected Meta");
        };
        assert_eq!(meta.raw_type, "system");
        assert_eq!(meta.session_id.as_deref(), Some("s"));
        assert_eq!(meta.model.as_deref(), Some("opus"));
        assert_eq!(meta.cwd.as_deref(), Some("/w"));
        assert!(meta.defines_session());

        let nested = json!({"type": "summary", "message": {"model": "sonnet"}});
        let Some(TranscriptLine::Meta(meta)) = parse(&nested.to_string()) else {
            panic!("expected Meta");
        };
        assert_eq!(meta.model.as_deref(), Some("sonnet"));
    }

    #[test]
    fn a_meta_line_defining_nothing_says_so() {
        let Some(TranscriptLine::Meta(meta)) = parse(&json!({"type": "result"}).to_string()) else {
            panic!("expected Meta");
        };
        assert!(!meta.defines_session());
    }

    #[test]
    fn a_block_content_array_without_a_text_key_renders_deterministically() {
        let raw = json!({
            "type": "user",
            "message": {"content": [{
                "type": "tool_result", "tool_use_id": "t",
                "content": [{"zeta": 2, "alpha": 1}],
            }]},
        })
        .to_string();
        let Some(TranscriptLine::User(user)) = parse(&raw) else {
            panic!("expected User");
        };
        // Sorted keys, every run.
        assert_eq!(user.tool_results[0].content, "alpha: 1\nzeta: 2");
    }

    #[test]
    fn sidechain_identity_is_read_in_either_spelling() {
        let raw = json!({"type": "user", "isSidechain": true, "agentID": "a9"}).to_string();
        let Some(TranscriptLine::User(user)) = parse(&raw) else {
            panic!("expected User");
        };
        assert!(user.identity.is_sidechain);
        assert_eq!(user.identity.agent_id.as_deref(), Some("a9"));
    }
}
