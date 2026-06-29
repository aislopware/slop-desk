import AislopdeskProtocol
import Foundation

// `aislopdesk watch <cmd>` (otty-clone E20, WI-7) — the PURE byte vocabulary the watch wrapper
// prints to its controlling terminal so the host's OSC sniffer turns it into a tab spinner/badge.
//
// otty's `watch` shows an indeterminate spinner while the wrapped command runs, then a success or
// error badge on exit, and (unless `-q`/`--quiet`) posts a "Notify on Watch Finish" desktop
// notification. aislopdesk already parses the ConEmu `OSC 9;4` progress protocol on the host
// (`HostOutputSniffer` → `ProgressOSCParser` → `ProgressState`) and the iTerm2 free-text `OSC 9`
// desktop-notification form; `watch` is just a thin wrapper that EMITS those byte sequences. The
// byte construction lives HERE (pure, exhaustively unit-tested) so the only thing left in
// `main.swift` is spawning the subprocess and writing these bytes (hang-safety rule: no subprocess
// in a test).
//
// Why states 3 / 0 / 2 and not otty's `9;4;5;<exit>;watch`: aislopdesk's wire deliberately does NOT
// carry the `5` (finished-with-exit) progress subtype — state ≥ 4 is dropped by `ProgressOSCParser`,
// and the OSC-133-D exit mark already carries the exit code (see `ProgressState` doc). So the BADGE
// rides the canonical indeterminate→clear/error states, and the watch-finish NOTIFICATION rides the
// existing free-text `OSC 9` desktop-notification path (gated CLI-side by `-q`).

public enum WatchProgress {
    // OSC framing bytes.
    private static let esc: UInt8 = 0x1B // ESC
    private static let bel: UInt8 = 0x07 // BEL — the OSC terminator the spec examples use (`\a`)
    private static let rightBracket = UInt8(ascii: "]")
    private static let semicolon = UInt8(ascii: ";")

    /// `ESC ] 9 ; 4 ; 3 BEL` — the INDETERMINATE spinner emitted at the start of a watched command.
    /// Parsed by the host into `.progress(state: 3 = indeterminate)`.
    public static let spinnerBytes: [UInt8] = progressBytes(state: .indeterminate)

    /// Map a finished subprocess exit code to the finish progress state: a clean `0` exit CLEARS the
    /// indicator (`ProgressState.clear`), any non-zero exit holds an `ProgressState.error` badge. A
    /// signal-terminated child is surfaced by the caller as a non-zero (128 + signo) code → error.
    public static func exitToProgress(_ exitCode: Int32) -> ProgressState {
        exitCode == 0 ? .clear : .error
    }

    /// The finish badge bytes for an exit code: `ESC ] 9 ; 4 ; 0 BEL` (success → clear) or
    /// `ESC ] 9 ; 4 ; 2 BEL` (failure → error). Never the determinate `1;<pct>` form — `watch` has
    /// no percentage, only running / done / failed.
    public static func finishBytes(exitCode: Int32) -> [UInt8] {
        progressBytes(state: exitToProgress(exitCode))
    }

    /// `ESC ] 9 ; 4 ; <state> BEL` for one canonical progress state (`watch` only ever uses
    /// indeterminate / clear / error). The state digit is the validated `ProgressState` raw value,
    /// so this can never emit a discriminant the host would drop.
    static func progressBytes(state: ProgressState) -> [UInt8] {
        var out: [UInt8] = [esc, rightBracket]
        out.append(contentsOf: Array("9;4;\(state.rawValue)".utf8))
        out.append(bel)
        return out
    }

    /// The human-readable "Notify on Watch Finish" message. Starts with `watch: ` so the body can
    /// NEVER begin with the `4;`/`4` progress subtype the host carves out of free-text `OSC 9`
    /// (otherwise a notification body like `4;…` would be silently swallowed as a progress update).
    /// The wrapped command is rendered space-joined; the exit code is appended on failure.
    public static func finishMessage(command: [String], exitCode: Int32) -> String {
        let label = command.isEmpty ? "command" : command.joined(separator: " ")
        if exitCode == 0 {
            return "watch: \(label) finished"
        }
        return "watch: \(label) failed (exit \(exitCode))"
    }

    /// `ESC ] 9 ; <message> BEL` — the iTerm2/ConEmu free-text desktop-notification form the host
    /// already parses into a `.notification(title: "", body: message)`. The generic OSC-9 building block
    /// (the watch-FINISH banner uses ``watchFinishNotificationBytes(message:)`` so it can ride the dedicated
    /// "Notify on Watch Finish" toggle, not the master switch).
    ///
    /// An empty message yields NO bytes (the host drops an empty `OSC 9` body anyway, but emitting
    /// nothing keeps the wrapper from writing a no-op escape).
    public static func notificationBytes(message: String) -> [UInt8] {
        guard !message.isEmpty else { return [] }
        var out: [UInt8] = [esc, rightBracket]
        out.append(contentsOf: Array("9;".utf8))
        out.append(contentsOf: Array(message.utf8))
        out.append(bel)
        return out
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
        guard !message.isEmpty else { return [] }
        var out: [UInt8] = [esc, rightBracket]
        out.append(contentsOf: Array("777;notify;".utf8))
        out.append(contentsOf: Array(WatchNotificationMarker.title.utf8))
        out.append(Self.semicolon)
        out.append(contentsOf: Array(message.utf8))
        out.append(bel)
        return out
    }
}
