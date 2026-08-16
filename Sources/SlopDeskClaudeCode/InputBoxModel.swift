// The external input surface, as the Swift face of `rust/slopdesk-terminal`'s `inputbox`, reached
// through `rust/slopdesk-ffi`'s `input_box` door.
//
// ## What is not here any more
//
// Both halves of the logic. The A/B1 affordance derived from the terminal mode, and the
// hold-and-confirm dedup ring that suppresses the PTY's echo of what the compose box just wrote —
// with the eviction rule that flushes a held-but-unconfirmed run rather than eating it, and the
// newline normalisation that keeps `\n` sent matching `\r\n` echoed. All Rust's, in a crate that
// forbids `unsafe`. This file owns one thing: an opaque handle's lifetime.
//
// ## Why the ring is gone rather than ported beside this
//
// `InputDedupRing` was `public` and separately tested, but nothing outside this type ever built
// one. Exporting it through its own door would have been a second entrance to one state machine,
// with the ordering rule — record BEFORE the echo arrives, reset on every mode flip — restated on
// the Swift side of the boundary. It crosses as this model's interior; its behaviour is pinned by
// `rust/slopdesk-terminal/src/dedup.rs`'s own tests, which are a superset of the ones deleted here.
//
// ## Why the events come back through a slot
//
// Same reason as ``TerminalModeTracker``: one chunk can carry a prompt start, a command start and a
// finish. The rendered bytes are parked the same way, and for a reason the marks do not have — the
// ring may ADD bytes to a chunk (a run it held for an earlier one and has now given up on), so the
// count is not knowable before the call, and re-running the filter to learn it would consume the
// chunk twice.

import CSlopDeskFFI
import Foundation

/// What the external input box should offer the user right now — derived from the terminal mode
/// (doc 14 § external input box, decision **A + B1**).
public enum InputAffordance: Sendable, Equatable {
    /// **A — shell command box.** At a shell prompt: the box sends a whole line on Enter and a
    /// block boundary is marked at the prompt (OSC 133). Echo flows normally in the surface above.
    case shellCommand
    /// **B1 — TUI compose-box.** A fullscreen TUI (Claude Code interactive) owns the screen:
    /// overlay a compose-box, write bytes to the PTY on submit with DelayedEnter, and dedup the
    /// PTY's echo.
    case tuiCompose
}

/// Mode, affordance, command state and echo suppression for one pane's input surface.
///
/// Feed it output with ``ingestOutput(_:)`` and it answers the bytes to actually render: in **B1**
/// the compose-box's own echo is stripped, in **A** the output passes through untouched, because
/// there echo is what the user is meant to see.
public final class InputBoxModel {
    /// The Rust-owned model. Non-optional: `new` only fails by allocation failure, which is not a
    /// condition this process survives anyway.
    private let handle: OpaquePointer

    /// The last state read out of the door. Refreshed by every call that can change it, so the
    /// properties below are plain reads rather than a round trip each.
    private var state: SlopDeskInputBoxState

    /// The current input affordance. `.shellCommand` while at a shell prompt, `.tuiCompose` while a
    /// fullscreen TUI owns the alternate screen.
    public var affordance: InputAffordance {
        state.affordance == UInt32(SLOPDESK_INPUT_AFFORDANCE_TUI_COMPOSE) ? .tuiCompose : .shellCommand
    }

    /// Whether a shell command appears to be running (between OSC 133 `C` and `D`). Used by the
    /// A-mode block model; the box may surface a "running" state here.
    public var commandRunning: Bool { state.command_running }

    /// The exit code of the most recently finished shell command, if any.
    public var lastExitCode: Int? { state.has_exit_code ? Int(state.exit_code) : nil }

    /// The current terminal mode.
    public var mode: TerminalMode {
        state.mode == UInt32(SLOPDESK_TERMINAL_MODE_ALT_SCREEN) ? .altScreen : .shellPrompt
    }

    /// Optional sink the UI can observe for every tracker event (mode + command marks).
    public var onEvent: ((TerminalModeEvent) -> Void)?

    public init() {
        guard let created = slopdesk_input_box_new() else {
            preconditionFailure("slopdesk_input_box_new returned null — allocation failed")
        }
        handle = created
        state = slopdesk_input_box_state(created)
    }

    deinit { slopdesk_input_box_free(handle) }

    // MARK: Output ingestion

    /// Feeds an output chunk through the model, updates affordance + command state, and returns the
    /// bytes to actually render.
    @discardableResult
    public func ingestOutput(_ output: Data) -> Data {
        let counts = output.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            slopdesk_input_box_ingest(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count)
        }
        state = slopdesk_input_box_state(handle)

        // The marks first, and the whole run before any byte is handed back: an observer that flips
        // a UI mode on `enteredAltScreen` must have done so before the chunk that carried the flip
        // is rendered under it.
        if counts.event_count > 0, let sink = onEvent {
            for index in 0..<counts.event_count {
                if let event = TerminalModeEvent(slopdesk_input_box_event(handle, index)) { sink(event) }
            }
        }

        guard counts.rendered_len > 0 else { return Data() }
        var rendered = Data(count: counts.rendered_len)
        let written = rendered.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            slopdesk_input_box_take_rendered(
                handle,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                raw.count,
            )
        }
        // The door answers the size it parked; a short read would mean the two calls disagreed
        // about one slot, which is a broken artifact rather than a runtime condition.
        precondition(written == counts.rendered_len, "the render slot answered a size it would not fill")
        return rendered
    }

    @discardableResult
    public func ingestOutput(_ output: [UInt8]) -> [UInt8] {
        Array(ingestOutput(Data(output)))
    }

    // MARK: Compose-box send (B1)

    /// Records bytes the compose-box wrote to the PTY so their echo can be suppressed. A no-op
    /// outside `.tuiCompose`, decided inside the door — at a shell prompt the echo is meant to show.
    public func recordComposeSent(_ bytes: Data) {
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            slopdesk_input_box_record_compose_sent(
                handle,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                raw.count,
            )
        }
    }

    public func recordComposeSent(_ bytes: [UInt8]) { recordComposeSent(Data(bytes)) }

    /// Returns the model to a fresh session's state: shell prompt, ground parse state, empty ring.
    ///
    /// Call at a SESSION boundary, for the reason ``TerminalModeTracker/reset()`` documents — a
    /// reconnect always brings a fresh host shell, so a latched `.altScreen` (or a half-matched
    /// echo) carried over from the dead session is a lie.
    public func reset() {
        slopdesk_input_box_reset(handle)
        state = slopdesk_input_box_state(handle)
    }
}
