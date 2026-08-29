//! What arrives on the simulator server's LOG socket.
//!
//! The third foreign decode in the `sim_*` family, and the last one that was still spelled in
//! Swift. `baguette serve` batches `log stream`'s output into one envelope per ~50 ms rather than
//! sending a message per line, so the socket's message rate is bounded whatever the device is
//! doing — and the envelope it wraps them in is a JSON object with a `type` this side switches on:
//!
//! ```text
//! {"type":"log_started"}
//! {"type":"log","lines":["2026-08-04 13:50:19.565 Df Unity2025Poster[76037] message"]}
//! ```
//!
//! ## Why it is here and not beside the socket
//!
//! It is the same argument [`crate::sim_devices`] makes about `/simulators.json`: the console is
//! drawn by TWO renderers, and a `JSONSerialization` walk on the near side is a decode each of them
//! could have disagreed about. It is also an UNTRUSTED wire — this is a foreign server, not one of
//! slopdesk's own — so it owes what every untrusted decoder owes, and it owes it under
//! `forbid(unsafe_code)`: validate then drop, and never a partial read that becomes a plausible
//! answer.
//!
//! ## `log_started` is not a nicety
//!
//! It is the ONLY signal separating "connected and the device is quiet" from "connected and
//! nothing works". The console renders those differently, so it is its own case rather than an
//! empty batch.
//!
//! ## What is deliberately NOT here
//!
//! The LEVEL set (`debug`/`info`/`notice`/`error`/`fault`) stays on the near side. It is a MENU —
//! what the filter popover offers — rather than a grammar, and it reaches the wire through
//! [`crate::sim_routes::logs`] as a plain string. Parsing one console LINE is
//! `slopdesk_devicelog::unified`'s, which is where both panels' console rows already come from.

use serde_json::Value;

/// One message off the log socket.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    /// The server has the `log stream` child up. Output follows.
    Started,
    /// One batch. Already whole lines: the server splits, so nothing here reassembles.
    Lines(Vec<String>),
    /// Anything else — a `type` this build has no case for, or a payload that is not the envelope.
    ///
    /// A first-class case rather than a refusal: a newer server that adds a message type must
    /// degrade to "ignore that message", never to a dropped console.
    Unknown,
}

/// Decode one text-frame payload.
///
/// [`Message::Unknown`] absorbs every way this can fail, which is the whole shape of the rule: the
/// socket stays up and the message is ignored. `lines` that is absent, or is not an array of
/// strings, decodes as an EMPTY batch rather than as unknown — the server said `log`, and a batch
/// with nothing in it is a thing it legitimately sends between bursts.
///
/// A non-string element inside `lines` is DROPPED rather than failing the batch, for
/// [`crate::sim_devices`]' reason at the row rather than the envelope: one malformed entry must not
/// cost the console the lines around it.
#[must_use]
pub fn decode(text: &str) -> Message {
    let Ok(root) = serde_json::from_str::<Value>(text) else {
        return Message::Unknown;
    };
    let Some(root) = root.as_object() else {
        return Message::Unknown;
    };
    match root.get("type").and_then(Value::as_str) {
        Some("log_started") => Message::Started,
        Some("log") => {
            Message::Lines(
                root.get("lines")
                    .and_then(Value::as_array)
                    .map(|lines| {
                        lines
                            .iter()
                            .filter_map(|line| line.as_str().map(ToOwned::to_owned))
                            .collect()
                    })
                    .unwrap_or_default(),
            )
        },
        _ => Message::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::{Message, decode};

    /// The two envelopes MEASURED off a live `baguette serve`, in the words `docs/47` records.
    #[test]
    fn the_two_envelopes_the_server_sends_decode_as_themselves() {
        assert_eq!(decode(r#"{"type":"log_started"}"#), Message::Started);
        assert_eq!(
            decode(r#"{"type":"log","lines":["one","two"]}"#),
            Message::Lines(vec!["one".to_owned(), "two".to_owned()])
        );
    }

    /// A `log` with nothing in it is an EMPTY BATCH, not an unknown message: the server says `log`
    /// between bursts, and reading that as unknown would make a quiet device look like a broken
    /// one.
    #[test]
    fn a_log_with_no_lines_is_an_empty_batch_rather_than_unknown() {
        assert_eq!(decode(r#"{"type":"log"}"#), Message::Lines(Vec::new()));
        assert_eq!(decode(r#"{"type":"log","lines":[]}"#), Message::Lines(Vec::new()));
        // Not an array at all is the same non-answer as absent — the field the panel wanted is not
        // there, and the message still said `log`.
        assert_eq!(
            decode(r#"{"type":"log","lines":"one"}"#),
            Message::Lines(Vec::new())
        );
    }

    /// A non-string element is dropped and its neighbours survive — the row rule, not the envelope
    /// rule.
    #[test]
    fn one_malformed_entry_does_not_cost_the_console_the_batch() {
        assert_eq!(
            decode(r#"{"type":"log","lines":["one",7,null,"two"]}"#),
            Message::Lines(vec!["one".to_owned(), "two".to_owned()])
        );
    }

    /// Everything this build has no case for degrades to `Unknown` rather than to a refusal that
    /// would take the socket with it.
    #[test]
    fn everything_else_is_ignored_rather_than_refused() {
        // A type a NEWER server added.
        assert_eq!(decode(r#"{"type":"log_ended"}"#), Message::Unknown);
        assert_eq!(decode(r#"{"type":7}"#), Message::Unknown);
        assert_eq!(decode(r#"{"lines":["one"]}"#), Message::Unknown);
        assert_eq!(decode("[]"), Message::Unknown);
        assert_eq!(decode("not json"), Message::Unknown);
        assert_eq!(decode(""), Message::Unknown);
    }

    /// A line's own bytes cross untouched — the console inks the SEVERITY off this text, so a
    /// decoder that trimmed or re-escaped it would change what the row says.
    #[test]
    fn a_line_crosses_verbatim() {
        let compact = r"2026-08-04 13:50:19.565 Df Unity2025Poster[76037:219b94d] [sub:cat] message";
        let json = format!(r#"{{"type":"log","lines":[{}]}}"#, serde_json::json!(compact));
        assert_eq!(decode(&json), Message::Lines(vec![compact.to_owned()]));
    }
}
