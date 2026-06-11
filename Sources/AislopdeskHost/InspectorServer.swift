import Foundation
import Network
import AislopdeskInspector

/// Host-side server for the inspector's **second** TCP connection (NWConnection #2, doc
/// 00 ③ / doc 16 §3): the read-only structured-event channel that rides beside the
/// terminal PTY stream on the same NetBird tunnel.
///
/// It is deliberately independent of ``HostServer`` (the terminal byte pipeline): a
/// separate ``NWListener`` on `terminalPort + 1`, a separate ``InspectorReplayLog``
/// fan-out, and the inspector's own framed wire (``InspectorSource`` /
/// ``InspectorCodec``). The two share no state — the inspector observes, it never drives
/// the agent.
///
/// ## Lifecycle (mirrors ``HostServer``'s NSLock / ReadyBox / Task discipline)
/// `start()` binds one ``NWListener`` built from ``NWByteChannel/parameters()`` and
/// suspends until it is `.ready` (so the caller can read ``boundPort()``). For every
/// accepted connection it wraps the `NWConnection` in a host-side ``NWByteChannel``,
/// starts it, builds an ``InspectorSource``, and spawns a per-connection serve task. The
/// connection bookkeeping (`connections`, `acceptTask`) is guarded by `lock`; no
/// `assumeIsolated` / `nonisolated(unsafe)`.
///
/// ## Per-connection protocol (gated on subscribe)
/// The serve task reads `source.controls()` and does NOTHING until the **first**
/// `.subscribe(fromSeq:)` arrives (the stream does not start on connect — it starts on
/// subscribe). It then pumps `replayLog.subscribe(fromSeq:)` — a full (or resumed) replay
/// followed by the live tail — sending each event to the client, plus a periodic
/// keep-alive so a quiet workflow run still reads as alive. The replay-log subscription
/// does NOT finish on a client disconnect (only on host shutdown / cancellation), so the
/// serve task ALSO drains the same inbound control stream concurrently as a disconnect
/// observer: when the client goes away (inbound finishes/fails) the drain returns, the
/// pump is cancelled, the replay-log subscriber is detached, the keep-alive timer stops,
/// and the source is closed — no per-client task / timer / subscriber leak.
///
/// ## Replay-then-live (resolves BUG-B)
/// The client always subscribes `fromSeq: 0` (full replay then live); the `fromSeq` is
/// honoured by ``InspectorReplayLog`` so a reconnecting client gets its history back
/// rather than a blank panel after any drop.
///
/// ## Testability (PIECE A+B are fully loopback-testable)
/// Construct with an injected ``InspectorReplayLog`` (already fed by an engine, or fed
/// directly in a test) and an injected transcript path, so NO real `claude` process is
/// needed. A test drives the accept path directly via ``serve(channel:)`` with a
/// ``LoopbackByteChannel`` and an ``InspectorClient`` on the other end — the `NWListener`
/// is never bound.
///
/// PIECE C is DEFERRED: the live transcript-path discovery (SessionStart-hook HTTP
/// listener + per-PTY lifecycle that creates the ``InspectorEngine`` / tailer for a real
/// `claude` session). Until that lands, `transcriptPath` is injected and the replay log
/// is fed by the caller. See `docs` / handoff.
///
/// `@unchecked Sendable`: mutable state (`connections`, `acceptTask`, `listener`) is
/// guarded by `lock`.
public final class InspectorServer: @unchecked Sendable {
    /// The terminal port the companion ``HostServer`` is on. The inspector binds
    /// `terminalPort + 1` (doc 16 §3: the second connection is the next port).
    public let terminalPort: UInt16

    /// The inspector port = `terminalPort + 1`. (`UInt16` overflow at 65535 is a
    /// misconfiguration; the daemon never assigns 65535 to the terminal port.)
    public var inspectorPort: UInt16 { terminalPort &+ 1 }

    /// Injected transcript path for the (deferred PIECE C) live tailer. Held so the
    /// constructed server is self-describing for the daemon's log line; the replay log is
    /// fed by the caller until PIECE C wires the per-PTY tailer.
    public let transcriptPath: String?

    /// The replay-then-live fan-out. Injected so a test can feed it directly (no engine,
    /// no `claude`); production feeds it from an ``InspectorEngine``.
    private let replayLog: InspectorReplayLog

    /// Interval between keep-alive frames on an idle subscription. Injectable so a test
    /// can assert keep-alives are sent without a long wall-clock wait (and so it does not
    /// surface as an event on the client).
    private let keepAliveInterval: Duration

    private let lock = NSLock()
    private var listener: NWListener?
    private var acceptTask: Task<Void, Never>?
    /// Per-connection serve tasks, so `stop()` can cancel them.
    private var connections: [UUID: Task<Void, Never>] = [:]
    private let queue = DispatchQueue(label: "aislopdesk.inspector.listener")

    /// A hook the daemon can set to log inspector lifecycle to stderr.
    public var onLog: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - terminalPort: the companion terminal port; the inspector binds `+ 1`.
    ///   - replayLog: the replay-then-live fan-out (already wired to an engine, or fed
    ///     directly in a test).
    ///   - transcriptPath: injected transcript path for the deferred live tailer (PIECE C).
    ///   - keepAliveInterval: idle keep-alive cadence (default 15s; tests inject a tiny
    ///     value).
    public init(
        terminalPort: UInt16,
        replayLog: InspectorReplayLog,
        transcriptPath: String? = nil,
        keepAliveInterval: Duration = .seconds(15)
    ) {
        self.terminalPort = terminalPort
        self.replayLog = replayLog
        self.transcriptPath = transcriptPath
        self.keepAliveInterval = keepAliveInterval
    }

    /// The port the listener actually bound to (`inspectorPort`, unless `terminalPort`
    /// was `0` → OS-assigned `+ 1` is still 1; in practice the daemon binds a real port).
    /// `nil` until ``start()`` resolves.
    public func boundPort() -> UInt16? {
        lock.lock(); defer { lock.unlock() }
        return listener?.port?.rawValue
    }

    /// Binds the inspector listener on `inspectorPort` and begins accepting connections.
    /// Suspends until the listener is `.ready`. Mirrors ``HostTransport``'s ReadyBox
    /// continuation discipline so the bound port is resolvable on return.
    public func start() async throws {
        let nwPort = NWEndpoint.Port(rawValue: inspectorPort) ?? .any
        let listener = try NWListener(using: NWByteChannel.parameters(), on: nwPort)
        storeListener(listener)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.accept(connection: connection)
        }

        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let box = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let portValue = listener.port?.rawValue ?? self.inspectorPort
                    box.tryResume { continuation.resume(returning: portValue) }
                case let .failed(error):
                    box.tryResume {
                        continuation.resume(throwing: InspectorServerError.listenerFailed(String(describing: error)))
                    }
                case .cancelled:
                    box.tryResume {
                        continuation.resume(throwing: InspectorServerError.listenerFailed("cancelled during start"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        onLog?("inspector listening on 0.0.0.0:\(inspectorPort) (terminalPort=\(terminalPort))")
    }

    /// Stops the listener and cancels every per-connection serve task.
    public func stop() {
        lock.lock()
        acceptTask?.cancel()
        acceptTask = nil
        listener?.cancel()
        listener = nil
        let tasks = connections.values
        connections.removeAll()
        lock.unlock()
        for task in tasks { task.cancel() }
    }

    /// Sync lock-guarded listener store (keeps `NSLock` out of the async ``start()``).
    private func storeListener(_ listener: NWListener) {
        lock.lock(); defer { lock.unlock() }
        self.listener = listener
    }

    // MARK: - Accept (production)

    /// Wraps a freshly-accepted `NWConnection` in a host-side ``NWByteChannel``, starts
    /// it, and spawns the serve task. (Production accept path.)
    private func accept(connection: NWConnection) {
        let channel = NWByteChannel(connection: connection)
        Task { await channel.start() }
        spawnServe(channel: channel)
    }

    // MARK: - Serve (production + test seam)

    /// Spawns the per-connection serve task and records it for ``stop()``. Used by the
    /// production accept path and the test seam alike.
    private func spawnServe(channel: ByteChannel) {
        let id = UUID()
        let task = Task { [weak self] () -> Void in
            await self?.serve(channel: channel, id: id)
        }
        lock.lock()
        connections[id] = task
        lock.unlock()
    }

    /// Test seam: serve one already-built ``ByteChannel`` (e.g. one end of
    /// ``LoopbackByteChannel/pair()``) exactly as a real accepted connection would be —
    /// WITHOUT binding an `NWListener`. A test drives an ``InspectorClient`` on the other
    /// end and asserts replay-then-live. Returns when the channel closes (or the task is
    /// cancelled).
    public func serve(channel: ByteChannel) async {
        await serve(channel: channel, id: UUID())
    }

    /// The per-connection protocol: gate on the first `.subscribe(fromSeq:)`, then pump
    /// `replayLog.subscribe(fromSeq:)` (replay-then-live) to the client with a periodic
    /// keep-alive — while concurrently observing the client's disconnect on the SAME
    /// inbound control stream. Closes the source and detaches the connection on exit.
    ///
    /// ## Disconnect observation (no per-client task / keep-alive / subscriber leak)
    /// The replay-log subscription only finishes on host shutdown (`markFinished`) or task
    /// cancellation — never on a client disconnect. So the event pump alone would run
    /// forever after the peer goes away (the keep-alive timer firing into a dead channel,
    /// the replay-log subscriber never detached). We therefore run the pump AND an
    /// inbound-drain of `controls` concurrently (the established
    /// `for try await … in channel.inbound` forwarder idiom):
    /// when the peer finishes/fails its inbound (real client FIN — `NWByteChannel`
    /// `finishInbound`/`failInbound` — or test channel `close`), the drain returns and we
    /// cancel the group. Cancelling tears down the pump's `replayLog.subscribe` stream,
    /// firing its `onTermination → removeSubscriber`, and the trailing `keepAlive.cancel()`
    /// stops the timer. The pump itself returns (cancelling the group) when the replay
    /// stream finishes (host shutdown) or a `source.send` throws (a failed send to a dead
    /// channel must end the loop — not be swallowed).
    ///
    /// The SAME `controls` stream is used for the subscribe gate and the disconnect drain
    /// — `channel.inbound` is a single-continuation `AsyncThrowingStream`, so it must be
    /// iterated by exactly one consumer; re-deriving a second `controls()` would race that
    /// one stream and desync framing.
    private func serve(channel: ByteChannel, id: UUID) async {
        let source = InspectorSource(channel: channel)
        defer { detach(id: id, source: source) }

        let controls = await source.controls()

        // Gate: do nothing until the client subscribes. Read controls until the first
        // .subscribe(fromSeq:) (ignore anything else — the client only ever sends
        // subscribe; an unknown/malformed control is skipped by decodeStream, BUG-G). A
        // throw or a clean finish here means the connection died before any subscribe.
        var fromSeq: Int64?
        do {
            controlLoop: for try await message in controls {
                if case let .subscribe(seq) = message {
                    fromSeq = seq
                    break controlLoop
                }
            }
        } catch {
            return
        }

        guard let fromSeq, !Task.isCancelled else { return }

        // Replay-then-live. The replay log delivers history[fromSeq...] then the live
        // tail on one stream (snapshot-then-attach atomic — no gap).
        let events = await replayLog.subscribe(fromSeq: fromSeq)

        // Periodic keep-alive so a quiet run still reads as alive. Cancelled (below) when
        // serve returns — i.e. the pump or the disconnect-drain ended.
        let keepAlive = Task { [keepAliveInterval] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: keepAliveInterval)
                } catch {
                    return
                }
                try? await source.sendKeepAlive()
            }
        }
        defer { keepAlive.cancel() }

        // Pump events to the client AND drain the rest of the control stream concurrently;
        // when EITHER child returns (replay stream finished / a send failed, OR the client
        // disconnected — inbound finished/threw), cancel the group so the other unwinds.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events {
                    if Task.isCancelled { break }
                    do {
                        try await source.send(event)
                    } catch {
                        // A failed send to a dead channel ends the pump (do not swallow).
                        break
                    }
                }
            }
            group.addTask {
                // Disconnect observer: drain remaining controls on the same stream until
                // it finishes (client FIN) or throws (transport failure). Either ends it.
                // (`channel.inbound` is single-continuation; the gate's iterator was
                // dropped at `break`, so this fresh one continues pulling the next bytes —
                // no second `controls()`, no framing race.)
                do {
                    for try await _ in controls {}
                } catch {
                    // Transport failure also means the client is gone.
                }
            }
            // First child to finish (pump done OR client gone) tears down the rest.
            await group.next()
            group.cancelAll()
        }
    }

    /// Detaches a finished connection: closes the source and drops its serve-task record.
    private func detach(id: UUID, source: InspectorSource) {
        Task { await source.close() }
        lock.lock()
        connections[id] = nil
        lock.unlock()
    }
}

/// Errors distinct from `AislopdeskTransportError` for the inspector listener.
public enum InspectorServerError: Error, Equatable, Sendable {
    case listenerFailed(String)
}

/// A tiny thread-safe latch so the listener's state handler resumes the start
/// continuation exactly once (mirrors `AislopdeskTransport`'s internal `ReadyBox`, which is
/// not visible across the module boundary).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func tryResume(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}
