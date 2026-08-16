import CSlopDeskFFI
import Foundation

// MARK: - ClaudeHookBody (one hook POST, read)

/// What one Claude Code hook body says, as the event ``ClaudeStatusMachine`` folds.
///
/// ## This is a call, not an implementation
/// The reading is `rust/slopdesk-hookevent`. What used to be here was a typed `HookPayload` enum
/// modelling the wire shape, and a `mapToHookEvent` adapter a module away in `AgentHookListener`
/// turning a payload into an event — ~700 lines across two targets for one question. Splitting an
/// event's IDENTITY from its MEANING is what let them drift: a payload case could gain a field the
/// adapter never read, and the rules that matter most (`AskUserQuestion` is a BLOCK, an interrupt
/// is a FINISHED TURN, an idle nudge is not a raised hand) lived nowhere near the case they
/// governed. One door now, and the rules are documented where they are decided.
///
/// ## Validate-then-drop
/// The body is written by whatever forked the agent's hook — possibly a nested `claude -p`, a
/// foreign producer, or a truncated write. `nil` is the only refusal, and the caller drops it.
public enum ClaudeHookBody {
    /// First guess at the answer's size: the 12-byte header plus a kilobyte of fields. A label past
    /// that is clamped on the wire anyway; the retry below exists to be correct, not to be used.
    private static let firstGuessBytes = 1024

    /// The fixed header — three discriminants, a presence mask, five big-endian lengths.
    private static let headerBytes = 14

    /// How many optional strings the answer carries: session id, tool, tool-use id, label, prompt.
    private static let fieldCount = 5

    /// Reads `body`, returning the event to fold and the type-27 `kind` byte to announce it with.
    ///
    /// `nil` when the body is not a hook this codebase answers: not JSON, not an object, an event
    /// name nothing knows, or a tool event with no `tool_name` (a call with no identity starts
    /// nothing and resolves nothing).
    ///
    /// The session id arrives already ATTRIBUTED — the envelope's `session_id` rides every body,
    /// and the events that describe a CALL rather than a session take it. That attribution is what
    /// tells this pane's agent apart from a nested `claude -p` that inherited `SLOPDESK_PANE_ID`.
    public static func read(_ body: Data) -> Reading? { ask(body) }

    /// One body, read: what to fold, what to announce it with, and the prompt behind it.
    public struct Reading: Sendable {
        /// The event ``ClaudeStatusMachine`` folds.
        public let event: ClaudeHookEvent
        /// The type-27 `kind` byte that announces the block class this event puts the pane in.
        public let kindByte: UInt8
        /// The raw text of a `UserPromptSubmit`, and `nil` for every other event.
        ///
        /// The status fold never reads it — a turn beginning is a turn beginning. The host's SESSION
        /// INTENT does (wire type 36), which is why it rides beside the event rather than inside it.
        public let prompt: String?
    }

    // MARK: The door

    private typealias Answer = Reading

    private static func ask(_ body: Data) -> Answer? {
        body.withUnsafeBytes { raw in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: firstGuessBytes) { out in
                let needed = call(raw, into: out)
                guard needed > 0 else { return nil }
                guard needed > out.count else { return decode(out, needed) }
                // The answer outgrew the guess. Nothing was written, so this is a clean retry; the
                // wrapped function is pure, so the second call cannot disagree.
                return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: needed) { wide in
                    let again = call(raw, into: wide)
                    guard again > 0, again <= wide.count else { return nil }
                    return decode(wide, again)
                }
            }
        }
    }

    /// One invocation of the C entry point. Returns how many bytes the answer needs; see
    /// `rust/slopdesk-ffi/include/slopdesk_ffi.h` for the convention.
    private static func call(
        _ body: UnsafeRawBufferPointer,
        into out: UnsafeMutableBufferPointer<UInt8>,
    ) -> Int {
        slopdesk_hook_event_parse(
            body.baseAddress?.assumingMemoryBound(to: UInt8.self),
            body.count,
            out.baseAddress,
            out.count,
        )
    }

    /// Reads `[u8 hook][u8 notification][u8 kind][u8 present][u16 BE len]×5[bytes]×present`.
    ///
    /// The presence mask is what keeps ABSENT and EMPTY apart: a session id nobody sent must not
    /// read as the empty string, which would attribute the record to a pane rather than to nobody.
    private static func decode(_ bytes: UnsafeMutableBufferPointer<UInt8>, _ count: Int) -> Answer? {
        guard count >= headerBytes, count <= bytes.count else { return nil }
        let present = bytes[3]
        var cursor = headerBytes
        var fields: [String?] = []
        for index in 0..<fieldCount {
            let at = 4 + index * 2
            let length = Int(bytes[at]) << 8 | Int(bytes[at + 1])
            guard cursor + length <= count else { return nil }
            defer { cursor += length }
            guard present & (1 << UInt8(index)) != 0 else {
                fields.append(nil)
                continue
            }
            let slice = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(bytes)[cursor..<(cursor + length)])
            // The repairing initialiser rather than the failable one: the bytes came back from a
            // Rust `String`, so no failure arm is reachable, and answering `nil` for a field the far
            // side considered a string would drop the whole record over one character.
            // swiftlint:disable:next optional_data_string_conversion
            fields.append(String(decoding: slice, as: UTF8.self))
        }
        guard let event = event(
            hook: bytes[0], notification: bytes[1],
            session: fields[0], tool: fields[1], toolUseID: fields[2], label: fields[3],
        ) else { return nil }
        return Answer(event: event, kindByte: bytes[2], prompt: fields[4])
    }

    /// The discriminant → the case. Total over the byte: an event this build does not know is
    /// dropped rather than folded as something else, because a wrong fold moves a real pane.
    private static func event(
        hook: UInt8, notification: UInt8,
        session: String?, tool: String?, toolUseID: String?, label: String?,
    ) -> ClaudeHookEvent? {
        switch hook {
        case 0: .sessionStart(sessionID: session)
        case 1: .userPromptSubmit(sessionID: session)
        case 2: .preToolUse(sessionID: session, tool: tool, toolUseID: toolUseID)
        case 3: .postToolUse(sessionID: session, tool: tool, toolUseID: toolUseID)
        case 4: .notification(
                kind: notificationKind(notification), label: label,
                toolUseID: toolUseID, sessionID: session,
            )
        case 5: .stop(sessionID: session, label: label)
        case 6: .subagentStop(agentID: nil)
        case 7: .interrupted(sessionID: session)
        case 8: .sessionEnd(sessionID: session)
        case 9: .preCompact(sessionID: session)
        default: nil
        }
    }

    private static func notificationKind(_ byte: UInt8) -> ClaudeHookEvent.NotificationKind {
        switch byte {
        case 0: .permission
        case 1: .waitingForInput
        default: .other
        }
    }
}
