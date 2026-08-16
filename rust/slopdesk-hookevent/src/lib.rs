//! What one Claude Code hook body says, in the vocabulary `slopdesk_agent::ClaudeHookEvent` speaks.
//!
//! ## One step, not two
//! This used to be two: a typed `HookPayload` enum that modelled the wire shape, and an adapter
//! beside it that turned a payload into the event the status machine folds. Splitting identity from
//! meaning is what let them drift — a payload case could gain a field the adapter never read, and
//! an adapter rule (`AskUserQuestion` is a BLOCK, an interrupt is a FINISHED TURN) lived a file
//! away from the case it governed. One function now: bytes in, the event and its wire byte out.
//!
//! ## Everything is optional and nothing throws
//! The body arrives from a process nobody here launched. A missing field, a wrong type, a truncated
//! write and a hostile object all mean the same thing — the answer this crate can defend — and the
//! only outright refusal is [`parse`] returning `None`, which the caller drops.

use serde_json::Value;

/// Which hook this body is, as [`slopdesk_agent::ClaudeHookEvent`]'s discriminant.
///
/// The numbers are the FFI contract (`Signal::hook`), not an internal detail: `rust/slopdesk-ffi`
/// reads them straight into the event the machine folds.
pub mod hook {
    /// `SessionStart` — a session began.
    pub const SESSION_START: u8 = 0;
    /// `UserPromptSubmit` — the human sent a turn.
    pub const USER_PROMPT_SUBMIT: u8 = 1;
    /// `PreToolUse` — a call is about to run.
    pub const PRE_TOOL_USE: u8 = 2;
    /// `PostToolUse` — a call ended, however it ended.
    pub const POST_TOOL_USE: u8 = 3;
    /// A block: something is waiting on the human.
    pub const NOTIFICATION: u8 = 4;
    /// `Stop` — the turn ended.
    pub const STOP: u8 = 5;
    /// `SubagentStop` — a subagent ended. Changes no status.
    pub const SUBAGENT_STOP: u8 = 6;
    /// The human interrupted the turn. No `Stop` follows one.
    pub const INTERRUPTED: u8 = 7;
    /// `SessionEnd` — the agent is gone.
    pub const SESSION_END: u8 = 8;
    /// `PreCompact` — a compaction is starting; the next `Stop` may be its end, not a task's.
    pub const PRE_COMPACT: u8 = 9;
}

/// The class of a block, as `ClaudeHookEvent::NotificationKind`'s discriminant.
pub mod notification {
    /// Claude needs explicit approval to proceed.
    pub const PERMISSION: u8 = 0;
    /// Something is blocked on the human answering.
    pub const WAITING_FOR_INPUT: u8 = 1;
    /// Informational only.
    pub const OTHER: u8 = 2;
}

/// One hook body, read.
///
/// `session_id` is already ATTRIBUTED: the envelope's `session_id` rides every hook, but only some
/// cases model it, so the events that describe a CALL rather than a session take the envelope's.
/// That attribution is what tells this pane's agent apart from a nested `claude -p` that inherited
/// `SLOPDESK_PANE_ID`, and doing it here means there is one place it can be got wrong.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HookEvent {
    /// Which event this is — one of the [`hook`] constants.
    pub hook: u8,
    /// The block class when `hook` is [`hook::NOTIFICATION`] — one of the [`notification`] ones.
    pub notification: u8,
    /// The type-27 `kind` byte the client reads: 0 none · 1 permission · 2 waiting · 3 other.
    pub kind_byte: u8,
    /// Whose session this is, attributed from the envelope when the case does not carry one.
    pub session_id: Option<String>,
    /// The tool a pre/post-tool event names.
    pub tool: Option<String>,
    /// The id that pairs a block with the event that resolves it. `None` when the producer sent no
    /// `tool_use_id`: a synthesised one would be a DIFFERENT string on the two halves of a pair,
    /// which is a ledger entry nothing can ever resolve.
    pub tool_use_id: Option<String>,
    /// The human-readable text: a stop's last message, a notification's message, a question.
    pub label: Option<String>,
    /// The raw prompt a `UserPromptSubmit` carried, and nothing else's.
    ///
    /// The status machine never reads it — a turn beginning is a turn beginning. The host's SESSION
    /// INTENT does (wire type 36): each titleable prompt re-titles the session, which is why it
    /// rides here rather than in `label`, where the client would print it as a status.
    pub prompt: Option<String>,
}

impl HookEvent {
    /// The event that only names a session — every case whose whole content is "this happened".
    const fn plain(hook: u8, session_id: Option<String>) -> Self {
        Self {
            hook,
            notification: notification::OTHER,
            kind_byte: 0,
            session_id,
            tool: None,
            tool_use_id: None,
            label: None,
            prompt: None,
        }
    }

    /// A block, with the class that decides both what the machine does and what the client shows.
    const fn blocked(
        kind: u8,
        label: Option<String>,
        tool_use_id: Option<String>,
        session_id: Option<String>,
    ) -> Self {
        Self {
            hook: hook::NOTIFICATION,
            notification: kind,
            kind_byte: kind_byte(kind),
            session_id,
            tool: None,
            tool_use_id,
            label,
            prompt: None,
        }
    }

    /// A call starting or ending: what resolves a block, and what says the turn is still moving.
    const fn call(
        hook: u8,
        tool: Option<String>,
        tool_use_id: Option<String>,
        session_id: Option<String>,
    ) -> Self {
        Self {
            hook,
            notification: notification::OTHER,
            kind_byte: 0,
            session_id,
            tool,
            tool_use_id,
            label: None,
            prompt: None,
        }
    }
}

/// The type-27 `kind` byte for a block class. `0` is "no block class", which is why these are
/// one-based and the [`notification`] discriminants are not.
const fn kind_byte(kind: u8) -> u8 {
    match kind {
        notification::PERMISSION => 1,
        notification::WAITING_FOR_INPUT => 2,
        _ => 3,
    }
}

/// Reads one hook body.
///
/// `None` for anything this cannot defend an answer for: a body that is not a JSON object, an event
/// name nothing here knows, and a tool event without a `tool_name` (a call with no identity
/// resolves nothing and starts nothing).
#[must_use]
pub fn parse(body: &[u8]) -> Option<HookEvent> {
    let root: Value = serde_json::from_slice(body).ok()?;
    let obj = root.as_object()?;
    // Claude Code sends `hook_event_name`; a foreign producer may say `event` or `type`.
    let event = text(obj.get("hook_event_name"))
        .or_else(|| text(obj.get("event")))
        .or_else(|| text(obj.get("type")))
        .unwrap_or_default();
    // The envelope's session id rides EVERY body, and is what the cases below fall back to.
    let session = session_id(&root);

    match event.as_str() {
        "SessionStart" => Some(HookEvent::plain(hook::SESSION_START, session)),
        "UserPromptSubmit" => {
            let mut event = HookEvent::plain(hook::USER_PROMPT_SUBMIT, session);
            event.prompt = text(obj.get("prompt"));
            Some(event)
        },
        "SessionEnd" => Some(HookEvent::plain(hook::SESSION_END, session)),
        // Carries `trigger` and `custom_instructions`; the machine needs neither, only that a
        // compaction is starting in THIS session.
        "PreCompact" => Some(HookEvent::plain(hook::PRE_COMPACT, session)),
        // A subagent belongs to whichever session owns it and changes no status, so it is neither
        // attributed nor identified — the agent id the payload carries has no reader.
        "SubagentStop" => Some(HookEvent::plain(hook::SUBAGENT_STOP, None)),

        "PreToolUse" => {
            let (name, id) = tool_call(obj)?;
            // `AskUserQuestion` is Claude ASKING, not working: the call BLOCKS on the human, so it
            // is a waiting block with the question as its label. Its own id rides along — that is
            // what the answering `PostToolUse` resolves, and what keeps a sibling call in the same
            // batch from resolving it instead.
            if name == "AskUserQuestion" {
                return Some(HookEvent::blocked(
                    notification::WAITING_FOR_INPUT,
                    question_label(obj),
                    id,
                    session,
                ));
            }
            Some(HookEvent::call(hook::PRE_TOOL_USE, Some(name), id, session))
        },

        // A call that ended, however it ended: a result, a denial, or a failure. All three resolve
        // the same ledger entry, because Claude Code sends them INSTEAD of one another with the
        // same `tool_use_id`.
        "PostToolUse" | "PermissionDenied" => {
            let (name, id) = tool_call(obj)?;
            Some(HookEvent::call(hook::POST_TOOL_USE, Some(name), id, session))
        },

        "PostToolUseFailure" => {
            let (name, id) = tool_call(obj)?;
            // An INTERRUPT is not a failed call, it is a FINISHED TURN. Claude Code emits no `Stop`
            // when the human presses Esc, so reading this as "a tool ended, carry on working" pins
            // the pane working with the spinner up until a watchdog turns it into a false finish.
            if flag(obj.get("is_interrupt")).or_else(|| flag(obj.get("isInterrupt"))) == Some(true) {
                return Some(HookEvent::plain(hook::INTERRUPTED, session));
            }
            Some(HookEvent::call(hook::POST_TOOL_USE, Some(name), id, session))
        },

        // The structured permission dialog — the same authoritative block as a
        // `Notification(permission_prompt)`, except no message-text heuristic can miss it. The id is
        // the GATED call's, so the `PreToolUse` that follows an approval resolves exactly it.
        "PermissionRequest" => {
            let (name, id) = tool_call(obj)?;
            Some(HookEvent::blocked(
                notification::PERMISSION,
                Some(format!("Permission needed: {name}")),
                id,
                session,
            ))
        },

        // An MCP server asking the human is the same authoritative block a permission dialog is.
        "Elicitation" => {
            let server = text(obj.get("mcp_server_name")).or_else(|| text(obj.get("mcpServerName")));
            let label = text(obj.get("message"))
                .or_else(|| server.as_ref().map(|name| format!("{name} needs input")));
            Some(HookEvent::blocked(
                notification::WAITING_FOR_INPUT,
                label,
                elicitation_key(obj, server.as_deref()),
                session,
            ))
        },
        // Answered or dismissed — either way that dialog is gone, which is the same resolution a
        // tool result gives.
        "ElicitationResult" => {
            let server = text(obj.get("mcp_server_name")).or_else(|| text(obj.get("mcpServerName")));
            Some(HookEvent::call(
                hook::POST_TOOL_USE,
                None,
                elicitation_key(obj, server.as_deref()),
                session,
            ))
        },

        "Notification" => {
            let message = text(obj.get("message")).or_else(|| text(obj.get("body")));
            let kind = classify(
                message.as_deref(),
                text(obj.get("matcher")).as_deref(),
                text(obj.get("notification_type"))
                    .or_else(|| text(obj.get("notificationType")))
                    .as_deref(),
            );
            Some(HookEvent::blocked(kind, message, None, session))
        },

        "Stop" => {
            let mut event = HookEvent::plain(hook::STOP, session);
            event.label = stop_label(
                text(obj.get("last_assistant_message")).or_else(|| text(obj.get("lastAssistantMessage"))),
                live_task_count(obj.get("background_tasks").or_else(|| obj.get("backgroundTasks"))),
            );
            Some(event)
        },
        // An API-error termination ends the turn like a `Stop`, with the error text in the label
        // seat. Without it a mid-turn API death leaves the pane working until presence finally wins.
        "StopFailure" => {
            let mut event = HookEvent::plain(hook::STOP, session);
            event.label = text(obj.get("error_message"))
                .or_else(|| text(obj.get("errorMessage")))
                .or_else(|| text(obj.get("error_type")));
            Some(event)
        },

        _ => None,
    }
}

/// The `session_id` on ANY body, whichever case it parses as.
///
/// Public because the caller needs it even for a body [`parse`] refuses — a record it cannot read
/// still belongs to somebody, and the receiver logs by session.
#[must_use]
pub fn session_id(root: &Value) -> Option<String> {
    let obj = root.as_object()?;
    text(obj.get("session_id")).or_else(|| text(obj.get("sessionId")))
}

/// The `{ tool_name, tool_use_id }` pair every tool event carries. `None` without a name: a call
/// with no identity starts nothing and resolves nothing, so the body is dropped.
fn tool_call(obj: &serde_json::Map<String, Value>) -> Option<(String, Option<String>)> {
    let name = text(obj.get("tool_name")).or_else(|| text(obj.get("toolName")))?;
    let id = text(obj.get("tool_use_id")).or_else(|| text(obj.get("toolUseId")));
    Some((name, id))
}

/// The first question inside an `AskUserQuestion` input (`tool_input.questions[0].question`).
/// `None` for any other shape — the block then stands without a label rather than with a guess.
fn question_label(obj: &serde_json::Map<String, Value>) -> Option<String> {
    let input = obj.get("tool_input").or_else(|| obj.get("toolInput"))?;
    let question = input.get("questions")?.as_array()?.first()?.get("question")?;
    let text = question.as_str()?;
    if text.is_empty() {
        None
    } else {
        Some(text.to_owned())
    }
}

/// The ledger key for an elicitation pair.
///
/// Falls back to the SERVER name when the payload names no `elicitation_id`. An id-less entry is
/// swept by any unrelated call's `PostToolUse` — the documented rule for an entry that names
/// nothing — so a missing key would hand the pane back as working while the prompt was still up,
/// and the mirror case would wipe somebody else's id-less block. The server name is stable across
/// the pair and unique enough in practice: one server does not stack two prompts on one human.
fn elicitation_key(obj: &serde_json::Map<String, Value>, server: Option<&str>) -> Option<String> {
    if let Some(id) = text(obj.get("elicitation_id")).or_else(|| text(obj.get("elicitationId")))
        && !id.is_empty()
    {
        return Some(id);
    }
    let server = server?;
    if server.is_empty() {
        return None;
    }
    Some(format!("elicitation:{server}"))
}

/// The done-chip text for a finished turn: what the turn SAID, or — when it said nothing — what it
/// left RUNNING. A `Stop` carrying live `background_tasks` is a turn whose work outlives it, and
/// "3 background tasks running" is a truer thing for the row to read than nothing at all.
/// Deliberately only the fallback: a turn that spoke keeps its own words.
fn stop_label(message: Option<String>, live_tasks: usize) -> Option<String> {
    if let Some(message) = message
        && !message.trim().is_empty()
    {
        return Some(message);
    }
    if live_tasks == 0 {
        return None;
    }
    let noun = if live_tasks == 1 {
        "background task"
    } else {
        "background tasks"
    };
    Some(format!("{live_tasks} {noun} running"))
}

/// Counts a `background_tasks`-shaped value. Anything that is not an array — absent, null, an
/// object, a hostile scalar — counts 0: an undocumented nice-to-have never decides by failing.
fn live_task_count(value: Option<&Value>) -> usize {
    value.and_then(Value::as_array).map_or(0, Vec::len)
}

/// Classifies a `Notification` into a block class.
///
/// In priority order: the structured `notification_type` decides outright for the classes we know;
/// an UNKNOWN type falls through, because a future blocking class must not be demoted to
/// informational while its text still matches. Then an explicit matcher token. Then the message
/// text. Then informational — only a positive match promotes to a block.
///
/// `idle_prompt` — Claude Code's "waiting for your input" nudge, fired about a minute after a turn
/// ends with the agent simply RESTING — is deliberately NOT a block: it re-raised the act-now hand
/// on every pane the person had already read. An agent genuinely blocked still says so through its
/// own signals (`PermissionRequest`, `permission_prompt`, `AskUserQuestion`, `agent_needs_input`,
/// `elicitation_dialog`); an idle prompt is presence, nothing more.
fn classify(message: Option<&str>, matcher: Option<&str>, notification_type: Option<&str>) -> u8 {
    match notification_type.map(str::to_lowercase).as_deref() {
        Some("permission_prompt") => return notification::PERMISSION,
        Some("agent_needs_input" | "elicitation_dialog") => return notification::WAITING_FOR_INPUT,
        Some(
            "idle_prompt"
            | "auth_success"
            | "elicitation_complete"
            | "elicitation_response"
            | "agent_completed",
        ) => return notification::OTHER,
        _ => {},
    }
    if matcher.is_some_and(|token| token.to_lowercase().contains("permission")) {
        return notification::PERMISSION;
    }
    let Some(text) = message.map(str::to_lowercase) else {
        return notification::OTHER;
    };
    if text.contains("permission")
        || text.contains("approval")
        || text.contains("needs your approval")
        || text.contains("wants to")
        || text.contains("would like to")
    {
        return notification::PERMISSION;
    }
    notification::OTHER
}

/// A JSON string field, and only a string: a producer that stringifies its whole payload sends
/// `"true"` where a bool belongs, and guessing at that is how a heuristic becomes a bug.
fn text(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::to_owned)
}

/// A JSON boolean field, and only a boolean. Same rule as [`text`].
fn flag(value: Option<&Value>) -> Option<bool> {
    value.and_then(Value::as_bool)
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a body a test asserts fields of has nothing to assert if it did not parse"
)]
mod tests {
    use super::{HookEvent, hook, notification, parse};

    fn read(json: &str) -> HookEvent {
        parse(json.as_bytes()).expect("the fixture is a body this crate answers")
    }

    #[test]
    fn a_body_that_is_not_a_known_hook_is_refused() {
        assert_eq!(parse(b"not json"), None);
        assert_eq!(parse(b"[1,2,3]"), None, "a body must be an object");
        assert_eq!(parse(br#"{"hook_event_name":"Whatever"}"#), None);
        assert_eq!(parse(b"{}"), None, "no event name is no event");
    }

    #[test]
    fn a_session_event_carries_only_its_session() {
        let event = read(r#"{"hook_event_name":"SessionStart","session_id":"s1","model":"opus"}"#);
        assert_eq!(event.hook, hook::SESSION_START);
        assert_eq!(event.session_id.as_deref(), Some("s1"));
        assert_eq!(event.kind_byte, 0);
    }

    #[test]
    fn the_envelope_session_attributes_an_event_that_describes_a_call() {
        let event = read(
            r#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_use_id":"t7"}"#,
        );
        assert_eq!(event.hook, hook::PRE_TOOL_USE);
        assert_eq!(event.tool.as_deref(), Some("Bash"));
        assert_eq!(event.tool_use_id.as_deref(), Some("t7"));
        assert_eq!(
            event.session_id.as_deref(),
            Some("s1"),
            "a call is attributed to the session that made it",
        );
    }

    #[test]
    fn a_tool_event_without_a_name_is_dropped_rather_than_guessed_at() {
        for event in [
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "PostToolUseFailure",
        ] {
            let body = format!(r#"{{"hook_event_name":"{event}","session_id":"s1"}}"#);
            assert_eq!(parse(body.as_bytes()), None, "{event} without a tool name");
        }
    }

    #[test]
    fn a_missing_tool_use_id_stays_missing_rather_than_becoming_a_fresh_one() {
        let event = read(r#"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#);
        assert_eq!(
            event.tool_use_id, None,
            "a synthesised id would differ across the pair it is supposed to join",
        );
    }

    #[test]
    fn asking_the_human_a_question_is_a_block_and_not_work() {
        let event = read(
            r#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"q1",
                "tool_input":{"questions":[{"question":"Which one?"}]}}"#,
        );
        assert_eq!(event.hook, hook::NOTIFICATION);
        assert_eq!(event.notification, notification::WAITING_FOR_INPUT);
        assert_eq!(event.kind_byte, 2);
        assert_eq!(event.label.as_deref(), Some("Which one?"));
        assert_eq!(
            event.tool_use_id.as_deref(),
            Some("q1"),
            "its own answer resolves it"
        );
    }

    #[test]
    fn a_question_of_an_unexpected_shape_blocks_without_a_label() {
        let event = read(
            r#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#,
        );
        assert_eq!(event.notification, notification::WAITING_FOR_INPUT);
        assert_eq!(event.label, None);
    }

    #[test]
    fn a_permission_request_names_the_gated_tool_and_keeps_its_id() {
        let event = read(r#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_use_id":"g1"}"#);
        assert_eq!(event.notification, notification::PERMISSION);
        assert_eq!(event.kind_byte, 1);
        assert_eq!(event.label.as_deref(), Some("Permission needed: Bash"));
        assert_eq!(event.tool_use_id.as_deref(), Some("g1"));
    }

    #[test]
    fn an_interrupt_ends_the_turn_and_a_failure_only_ends_the_call() {
        let interrupted =
            read(r#"{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","is_interrupt":true}"#);
        assert_eq!(interrupted.hook, hook::INTERRUPTED);
        let failed = read(
            r#"{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"t1","is_interrupt":false}"#,
        );
        assert_eq!(failed.hook, hook::POST_TOOL_USE);
        assert_eq!(
            failed.tool_use_id.as_deref(),
            Some("t1"),
            "it resolves the call it names"
        );
        let stringified =
            read(r#"{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","is_interrupt":"true"}"#);
        assert_eq!(
            stringified.hook,
            hook::POST_TOOL_USE,
            "a stringified bool is not a bool, and guessing is how a heuristic becomes a bug",
        );
    }

    #[test]
    fn a_denial_resolves_the_call_it_denied() {
        let event = read(r#"{"hook_event_name":"PermissionDenied","tool_name":"Bash","tool_use_id":"g1"}"#);
        assert_eq!(event.hook, hook::POST_TOOL_USE);
        assert_eq!(event.tool_use_id.as_deref(), Some("g1"));
    }

    #[test]
    fn an_elicitation_pairs_by_id_and_falls_back_to_the_server() {
        let asked = read(
            r#"{"hook_event_name":"Elicitation","elicitation_id":"e1","mcp_server_name":"linear",
                "message":"Pick a project"}"#,
        );
        assert_eq!(asked.notification, notification::WAITING_FOR_INPUT);
        assert_eq!(asked.label.as_deref(), Some("Pick a project"));
        assert_eq!(asked.tool_use_id.as_deref(), Some("e1"));

        let answered = read(r#"{"hook_event_name":"ElicitationResult","elicitation_id":"e1"}"#);
        assert_eq!(answered.hook, hook::POST_TOOL_USE);
        assert_eq!(answered.tool_use_id.as_deref(), Some("e1"));
        assert_eq!(answered.tool, None, "nothing was called; a dialog closed");

        let no_id = read(r#"{"hook_event_name":"Elicitation","mcp_server_name":"linear"}"#);
        assert_eq!(no_id.tool_use_id.as_deref(), Some("elicitation:linear"));
        assert_eq!(no_id.label.as_deref(), Some("linear needs input"));

        let anonymous = read(r#"{"hook_event_name":"Elicitation"}"#);
        assert_eq!(anonymous.tool_use_id, None);
        assert_eq!(anonymous.label, None);
    }

    #[test]
    fn a_structured_notification_type_decides_before_any_text_does() {
        for (kind, expected, byte) in [
            ("permission_prompt", notification::PERMISSION, 1_u8),
            ("agent_needs_input", notification::WAITING_FOR_INPUT, 2),
            ("elicitation_dialog", notification::WAITING_FOR_INPUT, 2),
            ("idle_prompt", notification::OTHER, 3),
            ("auth_success", notification::OTHER, 3),
        ] {
            // The message text says "permission" in every one of these; the type still wins.
            let body = format!(
                r#"{{"hook_event_name":"Notification","notification_type":"{kind}",
                    "message":"needs your approval"}}"#,
            );
            let event = read(&body);
            assert_eq!(event.notification, expected, "{kind}");
            assert_eq!(event.kind_byte, byte, "{kind}");
        }
    }

    #[test]
    fn an_unknown_notification_type_falls_through_to_the_text_rather_than_being_demoted() {
        let event = read(
            r#"{"hook_event_name":"Notification","notification_type":"some_future_block",
                "message":"Claude needs your approval to run"}"#,
        );
        assert_eq!(event.notification, notification::PERMISSION);
    }

    #[test]
    fn an_idle_nudge_is_presence_and_not_a_raised_hand() {
        let event =
            read(r#"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#);
        assert_eq!(
            event.notification,
            notification::OTHER,
            "the nudge does not block"
        );
        assert_eq!(event.kind_byte, 3);
    }

    #[test]
    fn a_matcher_promotes_when_no_type_says_otherwise() {
        let event = read(r#"{"hook_event_name":"Notification","matcher":"permission_prompt","body":"hi"}"#);
        assert_eq!(event.notification, notification::PERMISSION);
        assert_eq!(
            event.label.as_deref(),
            Some("hi"),
            "`body` is read as the message"
        );
    }

    #[test]
    fn a_turn_that_spoke_keeps_its_words_and_one_that_did_not_reports_what_it_left_running() {
        let spoke = read(
            r#"{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Done.",
                "background_tasks":[{"id":"a"},{"id":"b"}]}"#,
        );
        assert_eq!(spoke.label.as_deref(), Some("Done."));

        let silent =
            read(r#"{"hook_event_name":"Stop","background_tasks":[{"id":"a"},{"id":"b"},{"id":"c"}]}"#);
        assert_eq!(silent.label.as_deref(), Some("3 background tasks running"));

        let one = read(r#"{"hook_event_name":"Stop","background_tasks":[{"id":"a"}]}"#);
        assert_eq!(one.label.as_deref(), Some("1 background task running"));

        let blank = read(r#"{"hook_event_name":"Stop","last_assistant_message":"   "}"#);
        assert_eq!(blank.label, None, "whitespace is not words");

        let hostile = read(r#"{"hook_event_name":"Stop","background_tasks":{"not":"an array"}}"#);
        assert_eq!(hostile.label, None, "a shape it cannot count counts zero");
    }

    #[test]
    fn an_api_error_ends_the_turn_with_the_error_in_the_label_seat() {
        let event =
            read(r#"{"hook_event_name":"StopFailure","session_id":"s1","error_message":"overloaded"}"#);
        assert_eq!(event.hook, hook::STOP);
        assert_eq!(event.label.as_deref(), Some("overloaded"));

        let typed = read(r#"{"hook_event_name":"StopFailure","error_type":"api_error"}"#);
        assert_eq!(typed.label.as_deref(), Some("api_error"));
    }

    #[test]
    fn a_subagent_is_neither_attributed_nor_identified() {
        let event = read(r#"{"hook_event_name":"SubagentStop","session_id":"s1","agent_id":"a1"}"#);
        assert_eq!(event.hook, hook::SUBAGENT_STOP);
        assert_eq!(
            event.session_id, None,
            "attributing it would let a nested run's subagent claim a free pane",
        );
    }

    #[test]
    fn camel_case_is_tolerated_wherever_snake_case_is_read() {
        let event = read(r#"{"event":"PostToolUse","sessionId":"s1","toolName":"Bash","toolUseId":"t1"}"#);
        assert_eq!(event.hook, hook::POST_TOOL_USE);
        assert_eq!(event.session_id.as_deref(), Some("s1"));
        assert_eq!(event.tool.as_deref(), Some("Bash"));
        assert_eq!(event.tool_use_id.as_deref(), Some("t1"));
    }

    #[test]
    fn a_prompt_rides_beside_the_event_rather_than_in_the_label() {
        let event =
            read(r#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"fix the bug"}"#);
        assert_eq!(event.prompt.as_deref(), Some("fix the bug"));
        assert_eq!(
            event.label, None,
            "a prompt is the session's intent, not a status to print"
        );
        let bare = read(r#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#);
        assert_eq!(bare.prompt, None);
    }

    #[test]
    fn the_remaining_session_events_carry_their_session_and_nothing_else() {
        for (name, expected) in [
            ("UserPromptSubmit", hook::USER_PROMPT_SUBMIT),
            ("SessionEnd", hook::SESSION_END),
            ("PreCompact", hook::PRE_COMPACT),
        ] {
            let body = format!(r#"{{"hook_event_name":"{name}","session_id":"s1"}}"#);
            let event = read(&body);
            assert_eq!(event.hook, expected, "{name}");
            assert_eq!(event.session_id.as_deref(), Some("s1"), "{name}");
            assert_eq!(event.kind_byte, 0, "{name}");
        }
    }
}
