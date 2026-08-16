import CSlopDeskFFI
import Foundation
import SlopDeskArena
import SlopDeskProtocol

// `slopdesk watch <cmd>` — the Swift face of `rust/slopdesk-wire`'s `osc`: the byte vocabulary the
// watch wrapper prints to its controlling terminal so the host's OSC sniffer turns it into a tab
// spinner/badge.
//
// `watch` shows an indeterminate spinner while the wrapped command runs, then a success or
// error badge on exit, and (unless `-q`/`--quiet`) posts a "Notify on Watch Finish" desktop
// notification. slopdesk already parses the ConEmu `OSC 9;4` progress protocol on the host
// (`HostOutputSniffer` → `ProgressOSCParser` → `ProgressState`) and the iTerm2 free-text `OSC 9`
// desktop-notification form; `watch` is just a thin wrapper that EMITS those byte sequences. The
// byte construction is the crate's — the same crate the host's sniffer parses with, so the wrapper
// cannot emit a sequence the host would drop — and the only thing left in `main.swift` is spawning
// the subprocess and writing these bytes (hang-safety rule: no subprocess in a test).
//
// Why states 3 / 0 / 2 and not a `9;4;5;<exit>;watch` finished-with-exit form: slopdesk's wire
// deliberately does NOT carry the `5` (finished-with-exit) progress subtype — state ≥ 4 is dropped by
// `ProgressOSCParser`, and the OSC-133-D exit mark already carries the exit code (see `ProgressState`
// doc). So the BADGE rides the canonical indeterminate→clear/error states, and the watch-finish
// NOTIFICATION rides the existing free-text `OSC 9` desktop-notification path (gated CLI-side by `-q`).

public enum WatchProgress {
    /// `ESC ] 9 ; 4 ; 3 BEL` — the INDETERMINATE spinner emitted at the start of a watched command.
    /// Parsed by the host into `.progress(state: 3 = indeterminate)`.
    public static let spinnerBytes: [UInt8] = bytes { out, cap in slopdesk_watch_spinner_bytes(out, cap) }

    /// Map a finished subprocess exit code to the finish progress state: a clean `0` exit CLEARS the
    /// indicator (`ProgressState.clear`), any non-zero exit holds an `ProgressState.error` badge. A
    /// signal-terminated child is surfaced by the caller as a non-zero (128 + signo) code → error.
    public static func exitToProgress(_ exitCode: Int32) -> ProgressState {
        ProgressState(wire: slopdesk_watch_exit_progress_state(exitCode)) ?? .error
    }

    /// The finish badge bytes for an exit code: `ESC ] 9 ; 4 ; 0 BEL` (success → clear) or
    /// `ESC ] 9 ; 4 ; 2 BEL` (failure → error). Never the determinate `1;<pct>` form — `watch` has
    /// no percentage, only running / done / failed.
    public static func finishBytes(exitCode: Int32) -> [UInt8] {
        bytes { out, cap in slopdesk_watch_finish_bytes(exitCode, out, cap) }
    }

    /// `ESC ] 9 ; 4 ; <state> BEL` for one canonical progress state (`watch` only ever uses
    /// indeterminate / clear / error). The state digit is the validated ``ProgressState`` raw value, so
    /// this can never emit a discriminant the host would drop.
    ///
    /// No Swift caller: ``spinnerBytes`` and ``finishBytes(exitCode:)`` are the two shapes `watch`
    /// actually emits, and each has its own door. The face stays because `check-supervisor` pins it —
    /// the byte framing is `rust/slopdesk-wire`'s `osc`, the same crate the HOST's sniffer parses with,
    /// and an uncalled face is what stops the next arbitrary state from being framed in Swift instead.
    static func progressBytes(state: ProgressState) -> [UInt8] {
        bytes { out, cap in slopdesk_watch_progress_bytes(state.rawValue, out, cap) }
    }

    /// The human-readable "Notify on Watch Finish" message. Starts with `watch: ` so the body can
    /// NEVER begin with the `4;`/`4` progress subtype the host carves out of free-text `OSC 9`
    /// (otherwise a notification body like `4;…` would be silently swallowed as a progress update).
    /// The wrapped command is rendered space-joined; the exit code is appended on failure.
    public static func finishMessage(command: [String], exitCode: Int32) -> String {
        var arena = [UInt8]()
        let spans = command.map { token -> SlopDeskByteSpan in
            let span = ArenaText.intern(token, into: &arena)
            return SlopDeskByteSpan(offset: span.offset, length: span.length)
        }
        let said = spans.withUnsafeBufferPointer { spans in
            arena.withUnsafeBufferPointer { pool in
                bytes { out, cap in
                    slopdesk_watch_finish_message(
                        spans.baseAddress, spans.count, pool.baseAddress, pool.count, exitCode, out, cap,
                    )
                }
            }
        }
        return String(bytes: said, encoding: .utf8) ?? ""
    }

    /// `ESC ] 9 ; <message> BEL` — the iTerm2/ConEmu free-text desktop-notification form the host
    /// already parses into a `.notification(title: "", body: message)`. The generic OSC-9 building block
    /// (the watch-FINISH banner uses ``watchFinishNotificationBytes(message:)`` so it can ride the dedicated
    /// "Notify on Watch Finish" toggle, not the master switch).
    ///
    /// An empty message yields NO bytes (the host drops an empty `OSC 9` body anyway, but emitting
    /// nothing keeps the wrapper from writing a no-op escape).
    public static func notificationBytes(message: String) -> [UInt8] {
        said(message) { text, out, cap in
            slopdesk_osc_notification_bytes(text.baseAddress, text.count, out, cap)
        }
    }

    /// The watch-FINISH banner bytes: `ESC ] 777 ; notify ; <marker> ; <message> BEL`, where `<marker>` is the
    /// private ``WatchNotificationMarker/title`` sentinel. The host parses this into a plain
    /// `.notification(title: marker, body: message)` (no new wire); the client's `NotificationEvent.classifyExplicit`
    /// recognises the marker, STRIPS it, and routes the banner to `NotificationEvent.watchFinish` (gated by the
    /// dedicated "Notify on Watch Finish" toggle) rather than the generic `.explicitOSC` master switch — so the
    /// toggle works as documented (reference__cli.md:40). The OSC-777 `;`-split (maxSplits 3) keeps any `;` in
    /// `<message>` inside the body, and the marker carries no `;`, so the title field stays exactly the marker.
    ///
    /// An empty message yields NO bytes (a watch-finish notification always carries a message; this guards the
    /// degenerate case so the wrapper never writes a content-less escape). `-q`/`--quiet` suppresses LOCALLY by
    /// not calling this at all.
    public static func watchFinishNotificationBytes(message: String) -> [UInt8] {
        said(message) { text, out, cap in
            slopdesk_watch_finish_notification_bytes(text.baseAddress, text.count, out, cap)
        }
    }

    // MARK: - Private helpers

    /// One lent-buffer answer: ask for the size, then ask again with the room.
    private static func bytes(_ ask: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> [UInt8] {
        let needed = ask(nil, 0)
        guard needed > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: needed)
        let written = out.withUnsafeMutableBufferPointer { room in ask(room.baseAddress, room.count) }
        return written == needed ? out : []
    }

    /// The same, for an answer built from one message.
    private static func said(
        _ message: String,
        _ ask: (UnsafeBufferPointer<UInt8>, UnsafeMutablePointer<UInt8>?, Int) -> Int,
    ) -> [UInt8] {
        let text = Array(message.utf8)
        return text.withUnsafeBufferPointer { text in
            bytes { out, cap in ask(text, out, cap) }
        }
    }
}
