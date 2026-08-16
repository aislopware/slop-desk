//! What one Claude Code hook body says — the door over `rust/slopdesk-hookevent`.
//!
//! ## Why the answer is one blob
//! A hook event is three discriminants and five optional strings, and the strings are a session id,
//! a tool name, a call id, a label and a prompt written by whatever forked the agent's hook. A
//! `#[repr(C)]` record cannot carry them without either a cap (a truncated label is a lie the
//! client would show) or an allocation crossing the boundary. So the answer takes §4's shape:
//!
//! ```text
//! [u8 hook][u8 notification][u8 kind][u8 present]  [u16 BE len]×5  [bytes]×present
//! ```
//!
//! `present` is a bitmask — bit 0 session, 1 tool, 2 tool-use id, 3 label, 4 prompt — because
//! ABSENT and EMPTY are different answers here: a session id nobody sent must not read as one that
//! is the empty string, which would attribute the record to a pane rather than to nobody.
//!
//! A refusal is 0 bytes, which no answer can be: the header alone is fourteen.

use std::ffi::c_uchar;

use crate::{borrow, deliver};

/// The fixed header: three discriminants, the presence mask, and five big-endian lengths.
const HEADER: usize = 4 + 5 * 2;

/// Reads one hook body into the detection vocabulary.
///
/// Returns 0 when the body is not a hook this codebase answers — not JSON, not an object, an
/// unknown event name, or a tool event with no `tool_name`. The caller drops those.
///
/// # Safety
/// `(body, len)` and `(out, cap)` must describe live memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_hook_event_parse(
    body: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above.
    let bytes = unsafe { borrow(body, len) };
    let Some(event) = slopdesk_hookevent::parse(bytes) else {
        return 0;
    };
    let fields = [
        event.session_id.as_deref(),
        event.tool.as_deref(),
        event.tool_use_id.as_deref(),
        event.label.as_deref(),
        event.prompt.as_deref(),
    ];
    let mut present = 0_u8;
    let mut payload = 0_usize;
    for (index, field) in fields.iter().enumerate() {
        if let Some(text) = field {
            present |= 1 << index;
            payload += text.len();
        }
    }
    let mut answer = Vec::with_capacity(HEADER + payload);
    answer.push(event.hook);
    answer.push(event.notification);
    answer.push(event.kind_byte);
    answer.push(present);
    for field in fields {
        // A length is `u16` because the caller clamps every one of these long before it is shown;
        // a field past 64 KiB is a producer misbehaving, and truncating it here is the same answer
        // as truncating it there.
        let length = u16::try_from(field.map_or(0, str::len)).unwrap_or(u16::MAX);
        answer.extend_from_slice(&length.to_be_bytes());
    }
    for field in fields.into_iter().flatten() {
        let clamped = field.get(..usize::from(u16::MAX)).unwrap_or(field);
        answer.extend_from_slice(clamped.as_bytes());
    }
    // SAFETY: the caller's obligation above.
    unsafe { deliver(&answer, out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::expect_used,
    reason = "calling the door is the thing under test, and a fixture that does not answer has nothing to \
              assert"
)]
mod tests {
    use super::{HEADER, slopdesk_hook_event_parse};

    #[derive(Debug, PartialEq, Eq)]
    struct Answer {
        hook: u8,
        notification: u8,
        kind: u8,
        fields: [Option<String>; 5],
    }

    fn ask(body: &str) -> Option<Answer> {
        let mut buffer = [0_u8; 1024];
        // SAFETY: both pointers name a live local for the duration of the call.
        let needed = unsafe {
            slopdesk_hook_event_parse(body.as_ptr(), body.len(), buffer.as_mut_ptr(), buffer.len())
        };
        if needed == 0 {
            return None;
        }
        let answer = buffer.get(..needed)?;
        let header = answer.get(..HEADER)?;
        let present = *header.get(3)?;
        let mut cursor = HEADER;
        let mut fields: [Option<String>; 5] = [None, None, None, None, None];
        for (index, slot) in fields.iter_mut().enumerate() {
            let at = 4 + index * 2;
            let length = usize::from(u16::from_be_bytes([*header.get(at)?, *header.get(at + 1)?]));
            if present & (1 << index) == 0 {
                continue;
            }
            *slot = Some(String::from_utf8_lossy(answer.get(cursor..cursor + length)?).into_owned());
            cursor += length;
        }
        Some(Answer {
            hook: *header.first()?,
            notification: *header.get(1)?,
            kind: *header.get(2)?,
            fields,
        })
    }

    #[test]
    fn a_call_crosses_with_its_session_its_tool_and_its_id() {
        let answer = ask(
            r#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_use_id":"t7"}"#,
        );
        assert_eq!(
            answer,
            Some(Answer {
                hook: 2,
                notification: 2,
                kind: 0,
                fields: [
                    Some("s1".to_owned()),
                    Some("Bash".to_owned()),
                    Some("t7".to_owned()),
                    None,
                    None,
                ],
            })
        );
    }

    #[test]
    fn an_absent_field_is_not_an_empty_one() {
        let answer = ask(r#"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#)
            .expect("a named call is an answer");
        assert_eq!(answer.fields[2], None, "no id was sent");
        let empty = ask(r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":""}"#)
            .expect("a named call is an answer");
        assert_eq!(empty.fields[2], Some(String::new()), "an empty id WAS sent");
    }

    #[test]
    fn a_prompt_crosses_in_its_own_field() {
        let answer = ask(r#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"ship it"}"#)
            .expect("a prompt submission is an answer");
        assert_eq!(answer.fields[4], Some("ship it".to_owned()));
        assert_eq!(answer.fields[3], None, "a prompt is not a label");
    }

    #[test]
    fn a_body_this_codebase_does_not_answer_writes_nothing() {
        assert_eq!(ask("not json"), None);
        assert_eq!(ask(r#"{"hook_event_name":"Whatever"}"#), None);
        assert_eq!(ask(r#"{"hook_event_name":"PreToolUse"}"#), None, "no tool name");
    }

    #[test]
    fn a_buffer_too_small_writes_nothing_and_asks_for_the_size_it_needs() {
        let body = r#"{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Done."}"#;
        let mut buffer = [0xAA_u8; 8];
        // SAFETY: both pointers name a live local for the duration of the call.
        let needed = unsafe {
            slopdesk_hook_event_parse(body.as_ptr(), body.len(), buffer.as_mut_ptr(), buffer.len())
        };
        assert_eq!(needed, HEADER + 2 + 5, "the header, the session and the label");
        assert_eq!(buffer, [0xAA; 8], "an undersized buffer is left untouched");
    }
}
