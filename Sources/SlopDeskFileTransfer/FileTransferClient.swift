import Foundation
import Network

/// A single upload's progress, surfaced to the UI. `id` is the client-scoped transfer id.
public enum FileUploadEvent: Sendable, Equatable {
    case started(id: UInt32, name: String, totalBytes: UInt64)
    case progress(id: UInt32, sentBytes: UInt64, totalBytes: UInt64)
    case completed(id: UInt32)
    case failed(id: UInt32, reason: String)
}

/// Client-side PATH-4 driver: dials the host's dedicated file-transfer port and streams dropped files
/// over it, one at a time, reporting progress. Never touches the terminal mux or the video path.
///
/// The wire dance per connection: `hello` → await `helloAck`; then per file `offer` → await `accept`
/// → stream `chunk`s (256 KiB, read straight off disk so a multi-GiB file stays flat in RAM) →
/// `finish` → await `complete`. A `failed` at any point ends that file (the rest still try).
///
/// A value type with no shared state — each ``upload(files:host:port:onEvent:)`` drives an independent
/// connection with a local frame reader, so no actor isolation is needed (and an actor would flag the
/// non-`Sendable` inbound iterator as it crosses an await).
public struct FileTransferClient: Sendable {
    public init() {}

    /// Dials `host:port` and uploads `files`. Emits events as each transfer progresses. Returns when
    /// every file has completed or failed and the connection is closed.
    ///
    /// `onEvent` is AWAITED per event, so events reach the consumer strictly in emission order — an
    /// actor-isolated consumer observes the exact `started → progress… → completed/failed` sequence
    /// (a fire-and-forget per-event hop reorders under pool contention: progress runs backwards, a
    /// stale progress stomps a completed row). Every event is delivered before this returns.
    @preconcurrency
    public func upload(
        files: [URL],
        host: String,
        port: UInt16,
        onEvent: @Sendable @escaping (FileUploadEvent) async -> Void,
    ) async {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: NWFileTransferChannel.parameters(),
        )
        let channel = NWFileTransferChannel(connection: connection)
        await channel.start()
        await run(files: files, over: channel, onEvent: onEvent)
    }

    /// The testable core: run the upload protocol over an already-open channel (a test wires a
    /// ``LoopbackFileTransferChannel`` to a real ``FileTransferServer``).
    @preconcurrency
    public func run(
        files: [URL],
        over channel: FileTransferChannel,
        onEvent: @Sendable @escaping (FileUploadEvent) async -> Void,
    ) async {
        var reader = FrameReader(channel: channel)
        defer { channel.close() }

        // Handshake.
        do {
            try await send(.hello(version: fileTransferVersion), over: channel)
            guard case let .helloAck(accepted)? = try await reader.next(), accepted else {
                for (index, url) in files.enumerated() {
                    await onEvent(.failed(
                        id: UInt32(index),
                        reason: "host rejected handshake — url \(url.lastPathComponent)",
                    ))
                }
                return
            }
        } catch {
            return
        }

        for (index, url) in files.enumerated() {
            await uploadOne(url: url, transferId: UInt32(index), over: channel, reader: &reader, onEvent: onEvent)
        }
    }

    // MARK: - One file

    private func uploadOne(
        url: URL,
        transferId: UInt32,
        over channel: FileTransferChannel,
        reader: inout FrameReader,
        onEvent: @Sendable (FileUploadEvent) async -> Void,
    ) async {
        let name = url.lastPathComponent
        let handle: FileHandle
        let size: UInt64
        do {
            handle = try FileHandle(forReadingFrom: url)
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            size = UInt64(max(0, fileSize))
        } catch {
            await onEvent(.failed(id: transferId, reason: "cannot read \(name)"))
            return
        }
        defer { try? handle.close() }

        await onEvent(.started(id: transferId, name: name, totalBytes: size))

        do {
            try await send(.offer(transferId: transferId, fileSize: size, name: name), over: channel)
            guard case .accept? = try await expect(transferId, reader: &reader) else {
                // `expect` already emitted `.failed` for a `failed` reply; a nil/other ends it too.
                await onEvent(.failed(id: transferId, reason: "host did not accept \(name)"))
                return
            }

            var sent: UInt64 = 0
            while true {
                let chunk = try handle.read(upToCount: FileTransferProtocolConstants.chunkByteCount) ?? Data()
                if chunk.isEmpty { break }
                try await send(.chunk(transferId: transferId, data: chunk), over: channel)
                sent += UInt64(chunk.count)
                await onEvent(.progress(id: transferId, sentBytes: sent, totalBytes: size))
            }

            try await send(.finish(transferId: transferId), over: channel)
            switch try await expect(transferId, reader: &reader) {
            case .complete:
                await onEvent(.completed(id: transferId))
            case let .failed(reason):
                await onEvent(.failed(id: transferId, reason: reason))
            default:
                await onEvent(.failed(id: transferId, reason: "no completion for \(name)"))
            }
        } catch {
            try? await send(.cancel(transferId: transferId), over: channel)
            await onEvent(.failed(id: transferId, reason: "upload error for \(name)"))
        }
    }

    /// The relevant reply outcome for `transferId`, skipping any message about another id.
    private enum Outcome { case accept, complete, failed(String), other }

    private func expect(_ transferId: UInt32, reader: inout FrameReader) async throws -> Outcome? {
        while let message = try await reader.next() {
            switch message {
            case let .accept(id) where id == transferId: return .accept
            case let .complete(id) where id == transferId: return .complete
            case let .failed(id, reason) where id == transferId: return .failed(reason)
            default: continue // a reply about a different transfer, or a stray — keep reading
            }
        }
        return nil
    }

    private func send(_ message: FileTransferMessage, over channel: FileTransferChannel) async throws {
        try await channel.send(FileTransferCodec.encodeFrame(message))
    }
}

/// Pulls whole ``FileTransferMessage`` values off a channel's inbound byte stream, buffering partial
/// frames across reads. One per connection, iterated by a single consumer.
private struct FrameReader {
    private var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator
    private var decoder = FileTransferFrameDecoder()

    init(channel: FileTransferChannel) {
        iterator = channel.inbound.makeAsyncIterator()
    }

    mutating func next() async throws -> FileTransferMessage? {
        while true {
            if let message = try decoder.nextMessage() { return message }
            guard let bytes = try await iterator.next() else { return nil }
            decoder.append(bytes)
        }
    }
}
