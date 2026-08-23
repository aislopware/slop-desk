import Foundation

/// The `SLOPDESK_AUTOTYPE` OUT-path proof seam (docs/22 §7).
///
/// `slopdesk-guigate macos --connect` asserts the whole keystroke→host chain by having the app type one
/// command through the REAL OUT path — `TerminalViewModel.sendInput` → the ordered drain → the host
/// PTY — and then reading a computed marker the remote shell wrote to a file. This is the client
/// half: the first leaf to connect while it carries `LivePaneSession.isAutotypeTarget` sends the
/// command, once per launch.
///
/// The latch is the load-bearing part. SwiftUI re-fires the leaf's `.task` on every remount (a tab
/// switch unmounts the inactive subtree and mounts it again on return), so without one the proof
/// command reaches the shell repeatedly. But it is spent on the SEND, not on entry: a pane that is
/// torn down inside the settle wait never typed, and holding the one shot on its behalf would leave
/// whichever pane survives unable to take it — a silent, permanent OUT-path failure with nothing on
/// stderr to point at.
///
/// It lives here rather than inside the view so both halves of that rule are testable without a
/// window.
@MainActor
package enum AutotypeSeam {
    /// What one attempt did.
    package enum Outcome: Equatable {
        /// Not this pane's job, not connected yet, or `SLOPDESK_AUTOTYPE` is unset — the normal case
        /// for every launch that is not the gate.
        case notRequested
        /// The command has already gone out this launch.
        case alreadyFired
        /// The wait was cancelled before the bytes went out, so the one shot is back on offer.
        case rearmed
        /// The command was written to the pane's OUT path.
        case sent
    }

    /// How long to let the remote prompt come up before typing into it.
    package static let promptSettle = Duration.milliseconds(1500)

    /// Once per launch, `@MainActor`-confined (the leaf body and its `.task` both are).
    private static var fired = false

    /// Forgets the latch. A process launches once, so this exists for tests.
    package static func reset() { fired = false }

    /// Runs one attempt for the pane the caller is holding.
    ///
    /// - Parameters:
    ///   - command: `SLOPDESK_AUTOTYPE`, or `nil` in normal use.
    ///   - isTarget: whether this pane carries the store's autotype mark.
    ///   - isConnected: whether its channel actually reached the host — bytes sent into a dialling
    ///     pane go nowhere, and would spend the one shot doing it.
    ///   - send: the pane's OUT path, or `nil` for a leaf that has no terminal model yet.
    @discardableResult
    package static func run(
        command: String?,
        isTarget: Bool,
        isConnected: Bool,
        settle: Duration = promptSettle,
        send: ((Data) -> Void)?,
    ) async -> Outcome {
        guard let command, !command.isEmpty else { return .notRequested }
        // A command is set, so the gate IS running: every attempt from here says what it decided.
        // Silence is the one thing this seam must not fail with — "the auto-typed command never
        // executed" names the symptom and nothing else, and each guess at the cause costs a full
        // GUI round trip to test.
        guard isTarget, isConnected, let send else {
            trace("skipped (target=\(isTarget) connected=\(isConnected) out=\(send != nil))")
            return .notRequested
        }
        guard !fired else {
            trace("already fired")
            return .alreadyFired
        }
        fired = true
        do {
            try await Task.sleep(for: settle)
        } catch {
            // This leaf was torn down inside the wait — the document replaced its pane, or a tab
            // switch unmounted it. Nothing was typed, so nothing is spent.
            fired = false
            trace("re-armed (leaf torn down before the bytes went out)")
            return .rearmed
        }
        send(Data((command + "\n").utf8))
        trace("sent \(command.count + 1) bytes")
        return .sent
    }

    private static func trace(_ message: String) {
        FileHandle.standardError.write(Data("[autotype] \(message)\n".utf8))
    }
}
