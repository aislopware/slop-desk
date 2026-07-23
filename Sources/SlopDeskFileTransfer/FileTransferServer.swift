import Foundation
import Network

/// Host-side PATH-4 listener: the dedicated file-transfer TCP server, independent of the terminal
/// mux and the video path. Modeled on `InspectorServer` (its own `NWListener`, plain per-client
/// accept — no CONTROL/DATA pairing), bound on `terminalPort &+ 2` by the daemon.
///
/// Each accepted connection gets its own ``FileReceiveLogic`` + ``FileDropSink`` and runs the
/// ``serve(channel:sink:)`` loop: decode frames, drive the FSM, execute its effects (open/write/
/// finalize on the sink, replies on the channel). A sink failure for a transfer poisons only that
/// transfer (sends `failed`, aborts, discards its later chunks) — it never tears down the connection
/// or another in-flight transfer.
///
/// `@unchecked Sendable`: mutable state (`listener`, `connections`) is guarded by `lock`.
public final class FileTransferServer: @unchecked Sendable {
    public let port: UInt16
    private let makeSink: @Sendable () -> FileDropSink

    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: Task<Void, Never>] = [:]
    private let queue = DispatchQueue(label: "slopdesk.filetransfer.listener")

    public var onLog: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - port: the port to bind (the daemon passes `terminalPort &+ 2`).
    ///   - makeSink: builds a fresh sink per connection (production → a ``DiskFileDropSink`` into the
    ///     drop directory; a test → an in-memory fake).
    @preconcurrency
    public init(port: UInt16, makeSink: @escaping @Sendable () -> FileDropSink) {
        self.port = port
        self.makeSink = makeSink
    }

    /// Convenience: a disk-backed server dropping into `directory`.
    public convenience init(port: UInt16, dropDirectory: URL) {
        self.init(port: port, makeSink: { DiskFileDropSink(directory: dropDirectory) })
    }

    public func boundPort() -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return listener?.port?.rawValue
    }

    /// Binds the listener and begins accepting. Suspends until `.ready` so the bound port is
    /// resolvable on return (mirrors the inspector's ReadyBox continuation discipline).
    public func start() async throws {
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: NWFileTransferChannel.parameters(), on: nwPort)
        storeListener(listener)

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }

        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let box = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let value = listener.port?.rawValue ?? self.port
                    box.tryResume { continuation.resume(returning: value) }
                case let .failed(error):
                    box.tryResume {
                        continuation.resume(throwing: FileTransferServerError.listenerFailed(String(describing: error)))
                    }
                case .cancelled:
                    box.tryResume {
                        continuation.resume(throwing: FileTransferServerError.listenerFailed("cancelled during start"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        onLog?("file-transfer listening on 0.0.0.0:\(port)")
    }

    public func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        let tasks = connections.values
        connections.removeAll()
        lock.unlock()
        for task in tasks { task.cancel() }
    }

    private func storeListener(_ listener: NWListener) {
        lock.lock()
        defer { lock.unlock() }
        self.listener = listener
    }

    // MARK: - Accept

    private func accept(connection: NWConnection) {
        let channel = NWFileTransferChannel(connection: connection)
        Task { await channel.start() }
        let sink = makeSink()
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await serve(channel: channel, sink: sink)
            detach(id: id)
        }
        lock.lock()
        connections[id] = task
        lock.unlock()
    }

    private func detach(id: UUID) {
        lock.lock()
        connections[id] = nil
        lock.unlock()
    }

    // MARK: - Serve (production + test seam)

    /// Serve one channel to completion: decode frames, drive the FSM, execute effects. Returns when
    /// the peer closes, the decoder faults, or the transport fails. Drives all partial transfers to
    /// abort on exit so a dropped connection leaves no stray temp files. A test drives this directly
    /// over a ``LoopbackFileTransferChannel`` with a fake sink — no `NWListener`.
    public func serve(channel: FileTransferChannel, sink: FileDropSink) async {
        var logic = FileReceiveLogic()
        var decoder = FileTransferFrameDecoder()
        var failedIds = Set<UInt32>()
        var liveIds = Set<UInt32>()

        do {
            for try await bytes in channel.inbound {
                decoder.append(bytes)
                while let message = try decoder.nextMessage() {
                    for effect in logic.handle(message) {
                        await execute(effect, sink: sink, channel: channel, failedIds: &failedIds, liveIds: &liveIds)
                    }
                }
            }
        } catch {
            onLog?("file-transfer connection ended: \(error)")
        }

        // Any transfer still open when the connection dies is abandoned — sweep its temp file.
        for id in liveIds where !failedIds.contains(id) { sink.abort(transferId: id) }
        channel.close()
    }

    private func execute(
        _ effect: FileReceiveEffect,
        sink: FileDropSink,
        channel: FileTransferChannel,
        failedIds: inout Set<UInt32>,
        liveIds: inout Set<UInt32>,
    ) async {
        switch effect {
        case let .open(transferId, name, size):
            liveIds.insert(transferId)
            do {
                try sink.open(transferId: transferId, name: name, size: size)
            } catch {
                failedIds.insert(transferId)
                liveIds.remove(transferId)
                sink.abort(transferId: transferId)
                await sendFailed(transferId, reason: "cannot open destination", channel: channel)
            }

        case let .write(transferId, data):
            guard !failedIds.contains(transferId) else { return }
            do {
                try sink.write(transferId: transferId, data: data)
            } catch {
                failedIds.insert(transferId)
                liveIds.remove(transferId)
                sink.abort(transferId: transferId)
                await sendFailed(transferId, reason: "write failed", channel: channel)
            }

        case let .finalize(transferId):
            guard !failedIds.contains(transferId) else { return }
            liveIds.remove(transferId)
            do {
                try sink.finalize(transferId: transferId)
            } catch {
                failedIds.insert(transferId)
                sink.abort(transferId: transferId)
                await sendFailed(transferId, reason: "finalize failed", channel: channel)
            }

        case let .abort(transferId):
            liveIds.remove(transferId)
            sink.abort(transferId: transferId)

        case let .reply(message):
            // Suppress an accept/complete for a transfer the sink already failed — the client got
            // its `failed` and must not also see success.
            if case let .accept(id) = message, failedIds.contains(id) { return }
            if case let .complete(id) = message, failedIds.contains(id) { return }
            try? await channel.send(FileTransferCodec.encodeFrame(message))
        }
    }

    private func sendFailed(_ transferId: UInt32, reason: String, channel: FileTransferChannel) async {
        try? await channel.send(FileTransferCodec.encodeFrame(.failed(transferId: transferId, reason: reason)))
    }
}

public enum FileTransferServerError: Error, Equatable, Sendable {
    case listenerFailed(String)
}

/// Resume-once latch so the listener state handler resumes the start continuation exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func tryResume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}
