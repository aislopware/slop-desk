import Foundation
import RworkClient
import RworkTerminal

/// The terminal screen's view-model: it consumes a ``RworkClient``'s `output` byte stream +
/// `events` and projects connection / title / exit / byte-count state for the SwiftUI views.
///
/// It is the bridge between the actor world (`RworkClient`) and the UI: a `.task` calls
/// ``observe(client:)`` which drains both streams and folds them into `@Observable`
/// properties SwiftUI tracks. The terminal **pixels** are produced by the
/// ``RworkTerminal/TerminalSurface`` the view-model feeds (the libghostty `GhosttySurface` in
/// the app target, or `nil` in the headless/placeholder case) — the view-model never parses
/// VT itself (libghostty-only).
///
/// `@MainActor` so it is safe to mutate from SwiftUI and to drive a `@MainActor`
/// `GhosttySurface`; `@Observable` so the views update automatically.
@MainActor
@Observable
public final class TerminalViewModel {
    /// High-level connection lifecycle the UI surfaces (terminal screen + status chrome).
    public enum ConnectionStatus: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case reconnecting
        case disconnected(reason: String)
        case exited(code: Int32)

        public var label: String {
            switch self {
            case .idle: return "idle"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .reconnecting: return "reconnecting"
            case .disconnected: return "disconnected"
            case .exited(let code): return "exited(\(code))"
            }
        }

        /// True while we believe the byte pipeline is live.
        public var isLive: Bool { self == .connected }
    }

    // MARK: Observable state

    /// The connection lifecycle (drives the status chrome + placeholder telemetry).
    public private(set) var connectionStatus: ConnectionStatus = .idle
    /// The window/terminal title (OSC 0/2), if the host sent one.
    public private(set) var title: String?
    /// Authoritative session id, learned on first connect / preserved across reconnects.
    public private(set) var sessionID: UUID?
    /// Total bytes of `output` delivered (build-status telemetry; not a render).
    public private(set) var bytesReceived: Int = 0
    /// Most recent resume point surfaced by a `.reconnected` event (diagnostics).
    public private(set) var lastResumeSeq: Int64 = 0
    /// Set when the remote rang the bell since the last clear (the view can flash).
    public private(set) var bellPending: Bool = false

    // MARK: Wiring

    /// The terminal renderer the model feeds inbound bytes to. `nil` in the headless /
    /// placeholder case; the app target sets it to a libghostty ``GhosttySurface``.
    public weak var surface: (any TerminalSurface)?

    public init(surface: (any TerminalSurface)? = nil) {
        self.surface = surface
    }

    // MARK: Stream observation

    /// Drains the client's `output` + `events` streams, folding them into observable state.
    /// Call from a SwiftUI `.task { await model.observe(client: client) }`; it returns when
    /// both streams finish (client closed / child exited).
    ///
    /// The two streams are consumed concurrently (`async let`) so output (high-volume) never
    /// starves events (low-volume) and vice-versa. Both helpers are `@MainActor`, so feeding
    /// the `@MainActor` surface is contract-safe. (Two `async let` helpers are used instead of
    /// a `withTaskGroup` of `@MainActor` closures, which trips the Swift-6 region-isolation
    /// checker on this toolchain.)
    public func observe(client: RworkClient) async {
        connectionStatus = .connecting
        async let outputDone: Void = pumpOutput(client.output)
        async let eventsDone: Void = pumpEvents(client.events)
        _ = await (outputDone, eventsDone)
    }

    private func pumpOutput(_ output: AsyncStream<Data>) async {
        for await chunk in output {
            ingestOutput(chunk)
        }
    }

    private func pumpEvents(_ events: AsyncStream<RworkClient.Event>) async {
        for await event in events {
            handle(event)
        }
    }

    /// Folds one `output` chunk: feed the renderer + bump telemetry. The first byte flips
    /// `.connecting`/`.reconnecting` → `.connected` (we are receiving from the host).
    public func ingestOutput(_ chunk: Data) {
        if connectionStatus == .connecting || connectionStatus == .reconnecting {
            connectionStatus = .connected
        }
        bytesReceived += chunk.count
        surface?.feed(chunk)
    }

    /// Folds one `RworkClient.Event` into observable state.
    public func handle(_ event: RworkClient.Event) {
        switch event {
        case let .title(text):
            title = text
        case .bell:
            bellPending = true
        case let .exit(code):
            connectionStatus = .exited(code: code)
        case let .disconnected(reason):
            // A drop while we still want to be connected reads as "reconnecting" (the
            // ReconnectManager is retrying); the ConnectionViewModel owns the authoritative
            // "user asked to disconnect" distinction.
            connectionStatus = .disconnected(reason: reason)
        case let .reconnected(sessionID, resumeFromSeq):
            self.sessionID = sessionID
            self.lastResumeSeq = resumeFromSeq
            connectionStatus = .connected
        }
    }

    /// Marks that the reconnect campaign has begun (the chrome shows "reconnecting" rather
    /// than a bare "disconnected"). Called by the ConnectionViewModel on a non-deliberate drop.
    public func markReconnecting() {
        connectionStatus = .reconnecting
    }

    /// Clears the pending-bell flag once the view has flashed.
    public func clearBell() {
        bellPending = false
    }

    /// Resets to idle (a fresh connect target). Keeps no stale title / byte count.
    public func reset() {
        connectionStatus = .idle
        title = nil
        bytesReceived = 0
        bellPending = false
        lastResumeSeq = 0
    }
}
