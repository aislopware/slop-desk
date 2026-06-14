import AislopdeskProtocol
import Foundation

/// Drives reconnection for a ``AislopdeskClient`` after the transport drops.
///
/// iOS tears down TCP a few seconds after backgrounding, and any network blip can drop
/// the connection mid-session. On a drop this manager re-`connect`s the same
/// ``AislopdeskClient`` — which presents the preserved `sessionID` + `highestContiguousSeq`
/// in the new channelOpen. On the CURRENT mux path the host does NOT resume that session: it
/// spawns a fresh shell (the ssh model), so the reconnect is a fast re-grab of a NEW shell, not a
/// byte-exact resume — see the reconnect note on ``AislopdeskClient`` for the full story (and the
/// designed-but-unimplemented host-side replay that would make it byte-exact). The client's seq
/// dedup still guarantees a gap-free, dup-free splice should a host ever replay a tail.
///
/// ### Policy
/// - **Trigger:** a `AislopdeskClient.Event.disconnected` (transport FIN/failure) that is not
///   the result of a deliberate ``AislopdeskClient/pause()``/``close()``.
/// - **Backoff:** exponential, starting at ``Backoff/initial`` (250ms),
///   multiplying by ``Backoff/multiplier`` (2.0), capped at ``Backoff/maximum``
///   (**2s** — DECISIONS §reconnect: a coding session wants a *fast* re-grab, not a
///   minutes-long backoff). Each successful reconnect resets the delay.
/// - **Lifecycle:** `start()` launches a supervising task that consumes the client's
///   `events`; `stop()` cancels it. App background/foreground is handled by the client's
///   `pause()`/`resume()` seam (WF-8), not here.
///
/// Lifecycle hooks (UIKit `didEnterBackground` + `beginBackgroundTask`) belong to the
/// client app target; this type owns only the retry policy + supervising task.
///
/// All mutable state is held inside the supervising `Task` closure / actor-isolated
/// ``AislopdeskClient``; this type stores only immutable `let`s, so it is `Sendable`.
public final class ReconnectManager: Sendable {
    /// Exponential-backoff schedule between reconnect attempts.
    public struct Backoff: Sendable, Equatable {
        public var initial: Duration
        public var maximum: Duration
        public var multiplier: Double

        public init(
            initial: Duration = .milliseconds(250),
            maximum: Duration = .seconds(2),
            multiplier: Double = 2.0,
        ) {
            self.initial = initial
            self.maximum = maximum
            self.multiplier = multiplier
        }

        /// The next delay after `current`, capped at ``maximum``.
        func next(after current: Duration) -> Duration {
            let scaled = current * multiplier
            return scaled > maximum ? maximum : scaled
        }

        /// PURE retries→delay schedule (1-indexed): the backoff to wait BEFORE the `attempt`-th
        /// reconnect, capped at ``maximum``. `delay(forAttempt: 1) == initial`; each subsequent attempt
        /// multiplies by ``multiplier`` until it saturates at ``maximum`` (sshx-style capped exponential
        /// backoff — `delay ≈ initial · multiplier^(attempt-1)`, the analogue of `2^min(retries,N)`).
        ///
        /// Equivalent to chaining ``next(after:)`` from ``initial``, but as a CLOSED FORM keyed on the
        /// attempt count so it is deterministically unit-testable (no clock, no client) and the
        /// "reset the counter after a connection has been healthy" rule is just "start a fresh campaign
        /// at attempt 1" — which `ReconnectManager` already does (each new `.disconnected` after a live
        /// session opens a NEW `reconnectLoop` with `attempt = 0`, so the delay resets to `initial`).
        func delay(forAttempt attempt: Int) -> Duration {
            guard attempt > 1 else { return initial }
            // Saturate by stepping (avoids Double pow overflow on a large attempt and keeps the exact
            // same capped sequence as `next(after:)`): stop multiplying once we reach `maximum`.
            var d = initial
            for _ in 1..<attempt {
                let scaled = d * multiplier
                d = scaled > maximum ? maximum : scaled
                if d == maximum { break }
            }
            return d
        }
    }

    public let backoff: Backoff
    private let client: AislopdeskClient
    private let onLog: (@Sendable (String) -> Void)?
    /// Per-attempt progress: the 1-based `attempt` about to be tried and the `nextRetryAt` instant the
    /// loop will wait until BEFORE that attempt (`nil` for the first attempt, which fires immediately).
    /// Threaded exactly like ``onLog`` so the UI layer can publish an attempt-aware "reconnecting"
    /// state with a live countdown — the attempt counter + the computed delay live only inside
    /// ``reconnectLoop``, so a callback is the clean way to surface them (parsing them back out of the
    /// log strings would be fragile). Optional; nil in the headless / test paths that do not observe it.
    private let onProgress: (@Sendable (_ attempt: Int, _ nextRetryAt: Date?) -> Void)?
    /// Fired ONCE when a reconnect campaign exhausts ``maxReconnectAttempts`` without reconnecting —
    /// the terminal "could not reach the host" signal. The UI flips to a terminal `.unreachable` state
    /// instead of a frozen "reconnecting" dot (the previously-invisible WF3 give-up path).
    private let onGaveUp: (@Sendable () -> Void)?

    @preconcurrency
    public init(
        client: AislopdeskClient,
        backoff: Backoff = Backoff(),
        onLog: (@Sendable (String) -> Void)? = nil,
        onProgress: (@Sendable (_ attempt: Int, _ nextRetryAt: Date?) -> Void)? = nil,
        onGaveUp: (@Sendable () -> Void)? = nil,
    ) {
        self.client = client
        self.backoff = backoff
        self.onLog = onLog
        self.onProgress = onProgress
        self.onGaveUp = onGaveUp
    }

    /// Launches the supervising task that watches the client's `events` and reconnects
    /// on a disconnect. Returns the `Task` so the caller can `await`/cancel it; also
    /// retain it via ``stop()``-able handle if preferred.
    @discardableResult
    public func start(host: String, port: UInt16) -> Task<Void, Never> {
        let client = client
        let backoff = backoff
        let onLog = onLog
        let onProgress = onProgress
        let onGaveUp = onGaveUp
        // Subscribe to the event stream SYNCHRONOUSLY here — `EventBroadcaster.subscribe()` registers the
        // child continuation eagerly at call time — so the subscription is live the instant `start()`
        // returns, BEFORE the caller drives `connect()`. Evaluating `client.events` lazily inside the
        // Task instead would leave a window between connect-success and the Task's first iteration in
        // which a `.disconnected` (a fast drop) is yielded to no subscriber and LOST (the broadcaster is
        // live-not-replay) — stranding the pane at "reconnecting" with no retry campaign ever running.
        let events = client.events
        return Task {
            for await event in events {
                guard case let .disconnected(reason) = event else { continue }
                // Only reconnect if the client still WANTS to be connected. The two deliberate-shutdown
                // paths are asymmetric: `pause()` yields its own `.disconnected` (and sets `paused`),
                // while `close()` sets `closed` and finishes the stream WITHOUT yielding `.disconnected`.
                // So a REAL drop's `.disconnected`, yielded just before `close()`, can sit BUFFERED in
                // this subscription ahead of the finish and be popped here AFTER the client is closed —
                // gating on `isPaused` alone would then launch a doomed `connect`-after-close campaign.
                // Check `isClosed` too so a closed (or paused) client never triggers a reconnect.
                // (Two awaits, not `||` with an autoclosure: an actor-isolated read can't sit in the
                // short-circuit operand's nonisolated autoclosure.)
                let paused = await client.isPaused
                let closed = await client.isClosed
                if paused || closed { continue }
                onLog?("reconnect: transport dropped (\(reason)) — retrying")
                await Self.reconnectLoop(
                    client: client, host: host, port: port, backoff: backoff,
                    onLog: onLog, onProgress: onProgress, onGaveUp: onGaveUp,
                )
            }
        }
    }

    /// Maximum number of reconnect attempts in a single campaign before giving up — the SINGLE source of
    /// truth for the give-up ceiling. The app-global supervisor (`AppConnection`) and the UI's
    /// "attempt N of M" copy (`ConnectionPresenter.maxReconnectAttempts`) both mirror this value, so the
    /// per-pane transport campaign and the displayed cap can never diverge (they used to: 30 here vs a
    /// displayed 20, so a per-pane campaign would render an impossible "attempt 25 of 20"). It lives here,
    /// in the lower module, because `ConnectionPresenter` (upper) can read down but not vice-versa.
    /// With the default backoff (initial 250ms, max 2s, multiplier 2.0) this is roughly 35s of wall-clock:
    /// 250+500+1000+2000+… ≈ 35s for 20 attempts.
    public static let maxReconnectAttempts = 20

    /// One reconnect campaign: retry `connect` with exponential backoff until it succeeds, the
    /// task is cancelled, or the attempt cap (``maxReconnectAttempts``) is exhausted. On
    /// exhaustion the campaign logs a "gave up" message via `onLog` so the UI layer (which
    /// receives every `onLog` call) can surface a terminal "could not reconnect" state instead of
    /// keeping the pane in a perpetual reconnecting limbo. The client preserves `sessionID` + seq,
    /// so each attempt is a RETURNING_CLIENT resume.
    static func reconnectLoop(
        client: AislopdeskClient,
        host: String,
        port: UInt16,
        backoff: Backoff,
        onLog: (@Sendable (String) -> Void)?,
        onProgress: (@Sendable (_ attempt: Int, _ nextRetryAt: Date?) -> Void)? = nil,
        onGaveUp: (@Sendable () -> Void)? = nil,
    ) async {
        var delay = backoff.initial
        var attempt = 0
        while !Task.isCancelled {
            // Stop retrying if the client no longer wants to be connected. `isPaused`: the app paused
            // mid-campaign — resume() will reconnect. `isClosed`: the client was permanently closed
            // (either before this campaign began — a buffered drop popped after close — or DURING it,
            // e.g. the user closed the pane mid-reconnect). Either way every `connect` would throw
            // `invalidState("connect after close")`, so without this guard the loop burns the full
            // maxReconnectAttempts of doomed retries and fires a spurious `onGaveUp` against a dead client.
            // (Two awaits, not `||`: an actor-isolated read can't sit in a short-circuit autoclosure.)
            let paused = await client.isPaused
            let closed = await client.isClosed
            if paused || closed { return }
            attempt += 1
            // Cap: stop after maxReconnectAttempts so a permanently-gone host does not
            // keep the pane stuck in "reconnecting" forever. Surface a log line so
            // ConnectionViewModel.lastLog (shown in the chrome) escapes the loop, AND fire
            // `onGaveUp` so the UI flips to a terminal `.unreachable` state (the WF3 give-up
            // path that was previously invisible).
            if attempt > maxReconnectAttempts {
                onLog?("reconnect: gave up after \(maxReconnectAttempts) attempt(s) — could not reach \(host):\(port)")
                onGaveUp?()
                return
            }
            // Surface this attempt to the UI (attempt-aware "reconnecting" + countdown). The first
            // attempt fires immediately (no wait yet), so `nextRetryAt` is nil; a later attempt is
            // preceded by the `delay` sleep below, so the UI can render "retrying in Ns".
            onProgress?(attempt, nil)
            do {
                try await client.connect(host: host, port: port)
                onLog?("reconnect: resumed after \(attempt) attempt(s)")
                return
            } catch {
                onLog?("reconnect: attempt \(attempt) failed (\(error)); backing off \(delay)")
                // Publish the next fire instant so the UI shows a live "retrying in Ns" countdown
                // (derived in a TimelineView tick — no per-second store mutation).
                let delaySeconds = Double(delay.components.seconds)
                    + Double(delay.components.attoseconds) / 1e18
                onProgress?(attempt, Date().addingTimeInterval(delaySeconds))
                try? await Task.sleep(for: delay)
                delay = backoff.next(after: delay)
            }
        }
    }

    /// Drives a single reconnect campaign synchronously (used by tests and callers that
    /// want to await the resume rather than run the supervising loop). Reuses the
    /// client's preserved `sessionID` + seq.
    public func reconnect(host: String, port: UInt16) async throws {
        var delay = backoff.initial
        var lastError: Error?
        for attempt in 1...64 {
            if Task.isCancelled { throw CancellationError() }
            do {
                try await client.connect(host: host, port: port)
                onLog?("reconnect: resumed after \(attempt) attempt(s)")
                return
            } catch {
                lastError = error
                onLog?("reconnect: attempt \(attempt) failed (\(error)); backing off \(delay)")
                try? await Task.sleep(for: delay)
                delay = backoff.next(after: delay)
            }
        }
        throw lastError ?? ClientError.reconnectExhausted
    }
}
