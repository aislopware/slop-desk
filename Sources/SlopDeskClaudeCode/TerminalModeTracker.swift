// The terminal-mode tracker, as the Swift face of `rust/slopdesk-terminal`'s `tracker`, reached
// through `rust/slopdesk-ffi`'s `terminal_mode` door.
//
// ## What is not here any more
//
// The grammar. Seven states, two hard caps, the DCS/SOS/PM/APC body opacity that stops a spoofed
// `ESC[?1049h` inside a string from flipping the mode, the `memchr` skim that keeps the ingest hot
// path linear, and the lossy decode both parameter paths depend on — all Rust's, in a crate that
// forbids `unsafe`. This file owns one thing: an opaque handle's lifetime.
//
// ## Why a handle rather than a pure call
//
// Because an escape sequence arrives in pieces. TCP gives no alignment, so `ESC` at the end of one
// read and `[` at the start of the next is the NORMAL case; a parser that could not remember would
// have to be handed its own partial state back on every call, which is the handle convention
// written out the long way. The obligation that comes with it — one free per new, no two calls on
// one handle overlapping — is discharged here by `deinit` and by this being a plain class that one
// pane's output path drives.
//
// ## Why the events come back through a slot
//
// One chunk can carry a prompt start, a command start and a finish. Returning that run across the
// boundary would mean either allocating there (which the door never does) or sizing a buffer for a
// count the caller cannot know in advance. So `consume` parks the run on the handle and answers how
// many, and this file reads them out.

import CSlopDeskFFI
import Foundation

/// Incrementally parses the host->client OUTPUT byte stream and tracks the terminal
/// mode (`shellPrompt` vs `altScreen`) + emits OSC 133 command-boundary events.
///
/// Feeding the same stream one byte at a time produces byte-for-byte identical events to feeding it
/// in one chunk — the machine holds its partial state between ``consume(_:)`` calls and only fires a
/// marker once the full sequence has arrived. Unknown CSI / OSC sequences are consumed cleanly up to
/// their terminator and ignored; an unterminated OSC is bounded by a cap, so a malformed or hostile
/// stream cannot wedge the parser.
///
/// The 16 cases under `terminalModeTracker` in `golden/golden_vectors.json` pin this behaviour
/// end-to-end through the door — see `TerminalModeGoldenVectorTests`.
public final class TerminalModeTracker {
    /// The Rust-owned parser. Non-optional: `new` only fails by allocation failure, which is not a
    /// condition this process survives anyway.
    private let handle: OpaquePointer

    public init() {
        guard let created = slopdesk_mode_tracker_new() else {
            preconditionFailure("slopdesk_mode_tracker_new returned null — allocation failed")
        }
        handle = created
    }

    deinit { slopdesk_mode_tracker_free(handle) }

    /// The current terminal mode.
    public var mode: TerminalMode {
        slopdesk_mode_tracker_mode(handle) == UInt32(SLOPDESK_TERMINAL_MODE_ALT_SCREEN)
            ? .altScreen
            : .shellPrompt
    }

    /// TRUE while the foreground program has bracketed-paste mode (DECSET `?2004h`) enabled — set on
    /// `ESC[?2004h`, cleared on `ESC[?2004l`. Independent of ``mode`` (a shell prompt enables it; a TUI
    /// may too). It emits NO event: it is a passive flag the E8 paste-protection pre-check reads to skip
    /// the sheet when the program frames the paste as an inert bracketed block (matching libghostty's
    /// own `clipboard-paste-bracketed-safe` config key).
    public var bracketedPasteActive: Bool { slopdesk_mode_tracker_bracketed_paste_active(handle) }

    /// TRUE while the foreground program has DECCKM (application cursor keys, DECSET `?1h`) enabled —
    /// set on `ESC[?1h`, cleared on `ESC[?1l`. Same passive-flag contract as ``bracketedPasteActive``.
    /// Read by the iOS hand-rolled key encoder to pick SS3 (`ESC O A`) over CSI (`ESC [ A`) arrows —
    /// the macOS path never needs it (`libghostty-vt`'s session owns true DECCKM there); see docs/29.
    public var cursorKeysApplication: Bool { slopdesk_mode_tracker_cursor_keys_application(handle) }

    /// Returns the tracker to its initial state (`.shellPrompt`, ground, empty buffers), emitting no
    /// events.
    ///
    /// Call at a SESSION boundary: a reconnect always brings a fresh host shell, so a mode (or partial-
    /// sequence parse state) carried over from the dead session is a lie — a session that dropped inside
    /// vim leaves `.altScreen` latched (a fresh shell never emits DECRST 1049), and a drop mid-DCS leaves
    /// the string-consume state swallowing the new session's real markers.
    public func reset() {
        slopdesk_mode_tracker_reset(handle)
    }

    /// Feeds a chunk of output bytes and returns the marker events produced by this chunk (in order).
    /// Safe to call with chunks split at any byte boundary.
    @discardableResult
    public func consume(_ bytes: Data) -> [TerminalModeEvent] {
        let count = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            slopdesk_mode_tracker_consume(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count)
        }
        guard count > 0 else { return [] }
        return (0..<count).compactMap { TerminalModeEvent(slopdesk_mode_tracker_event(handle, $0)) }
    }

    /// Convenience overload for raw byte arrays.
    @discardableResult
    public func consume(_ bytes: [UInt8]) -> [TerminalModeEvent] {
        consume(Data(bytes))
    }
}
