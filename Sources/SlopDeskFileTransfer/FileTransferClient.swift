import CSlopDeskFFI
import Foundation

/// A single upload's progress, surfaced to the UI. `id` is the client-scoped transfer id.
public enum FileUploadEvent: Sendable, Equatable {
    case started(id: UInt32, name: String, totalBytes: UInt64)
    case progress(id: UInt32, sentBytes: UInt64, totalBytes: UInt64)
    case completed(id: UInt32)
    case failed(id: UInt32, reason: String)
}

/// PATH 4's client end, as a FACE over one door.
///
/// A drop rides its OWN reliable TCP connection to `slopdesk-dropd`, never the terminal mux (a bulk
/// body sharing the PTY data channel would stall keystrokes) and never the lossy video path (FEC
/// recovers frames, not files). What that connection SAYS — `hello` → `helloAck`, then per file
/// `offer` → `accept` → 256 KiB chunks → `finish` → `complete` — is `rust/slopdesk-dropd`'s `upload`
/// module, beside the layouts it writes and the `protocol` module that decodes them.
///
/// ## Why nothing here decides
/// This used to be the driver: it held the socket, the frame reader, the retry-free error policy
/// and the order every frame goes in, and it called eight small doors to lay each frame out. Every
/// one of those doors was right on its own and nothing could check the ORDER they were assembled
/// in, which is the fault `docs/55` §4b names — *a law moved without its sequencing*. With the
/// socket in Rust there is no order left on this side to get wrong, so what survives is the two
/// things a face is for: turning `URL`s into bytes the door reads, and turning the door's reports
/// back into a Swift enum the UI can switch on.
public struct FileTransferClient: Sendable {
    public init() {}

    /// Dials `host:port` and uploads `files`. Emits events as each transfer progresses. Returns when
    /// every file has completed or failed and the connection is closed.
    ///
    /// `onEvent` is AWAITED per event, so events reach the consumer strictly in emission order — an
    /// actor-isolated consumer observes the exact `started → progress… → completed/failed` sequence
    /// (a fire-and-forget per-event hop reorders under pool contention: progress runs backwards, a
    /// stale progress stomps a completed row). Every event is delivered before this returns.
    ///
    /// A file is offered under its INDEX in `files`, which is the `id` every event carries.
    @preconcurrency
    public func upload(
        files: [URL],
        host: String,
        port: UInt16,
        onEvent: @Sendable (FileUploadEvent) async -> Void,
    ) async {
        guard !files.isEmpty else { return }
        // NUL is the separator `find -print0` uses, for its reason: a POSIX path holds every byte
        // but this one, so there is no length prefix to write and nothing here to spell wrong.
        let batch = Data(files.map(\.path).joined(separator: "\0").utf8)
        let (events, continuation) = AsyncStream.makeStream(
            of: FileUploadEvent.self,
            bufferingPolicy: .unbounded,
        )
        let sink = Sink(continuation)

        // A GLOBAL QUEUE and not a `Task`: the door blocks for the whole batch, which is minutes on
        // a large file, and a blocked cooperative-pool thread is one the whole app no longer has.
        DispatchQueue.global(qos: .utility).async {
            drive(host: host, port: port, batch: batch, into: sink)
            continuation.finish()
        }

        // The stream ends only after `drive` returns, and buffered events drain before it does — so
        // this loop IS the "every event delivered before we return" guarantee above.
        for await event in events {
            await onEvent(event)
        }
    }
}

// MARK: - The door

/// Where the door's reports land, as something a `void *` can point at.
///
/// A `final class` and not the stream continuation itself, because the context crosses as a raw
/// pointer and a struct has no identity to make one from. Its one field is immutable and `Sendable`,
/// so the yield is safe from the door's thread with no lock.
private final class Sink: Sendable {
    let continuation: AsyncStream<FileUploadEvent>.Continuation

    init(_ continuation: AsyncStream<FileUploadEvent>.Continuation) {
        self.continuation = continuation
    }
}

/// How long the dial may take before the batch is failed by name.
///
/// A ceiling exists at all because the door BLOCKS: without one, a host that is asleep rather than
/// refusing parks the upload thread until the kernel gives up, which on a dropped tunnel is minutes
/// of a drop overlay saying nothing.
private let connectTimeoutMilliseconds: UInt64 = 10000

/// Runs the whole batch through `slopdesk_drop_upload`, blocking until it is done.
private func drive(host: String, port: UInt16, batch: Data, into sink: Sink) {
    var host = host
    // `passUnretained` is what the door's contract asks for — it retains nothing and calls nothing
    // after it returns — and `withExtendedLifetime` is what keeps that true: after `toOpaque()` the
    // only thing holding the sink is a RAW POINTER, which is not a reference ARC can see.
    withExtendedLifetime(sink) {
        let context = Unmanaged.passUnretained(sink).toOpaque()
        host.withUTF8 { hostBytes in
            batch.withUnsafeBytes { blob in
                _ = slopdesk_drop_upload(
                    hostBytes.baseAddress,
                    hostBytes.count,
                    port,
                    blob.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    blob.count,
                    connectTimeoutMilliseconds,
                    context,
                    report,
                )
            }
        }
    }
}

/// The `@convention(c)` progress callback: one report in, one ``FileUploadEvent`` out.
///
/// Runs on the calling thread — the global queue `drive` blocks on — never concurrently with itself
/// and never after the door returns, so `context` is live for every call and `text` is lent for the
/// duration of one.
private func report(
    _ context: UnsafeMutableRawPointer?,
    _ kind: UInt32,
    _ id: UInt32,
    _ sentBytes: UInt64,
    _ totalBytes: UInt64,
    _ text: UnsafePointer<UInt8>?,
    _ textLength: Int,
) {
    guard let context else { return }
    let sink = Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue()
    switch kind {
    case SLOPDESK_DROP_PROGRESS_STARTED:
        sink.continuation.yield(.started(id: id, name: said(text, textLength), totalBytes: totalBytes))
    case SLOPDESK_DROP_PROGRESS_ADVANCED:
        sink.continuation.yield(.progress(id: id, sentBytes: sentBytes, totalBytes: totalBytes))
    case SLOPDESK_DROP_PROGRESS_COMPLETED:
        sink.continuation.yield(.completed(id: id))
    case SLOPDESK_DROP_PROGRESS_FAILED:
        sink.continuation.yield(.failed(id: id, reason: said(text, textLength)))
    // A kind this build does not know is a report it cannot draw, and the door promises only the
    // four above — so dropping it IS the handling.
    default:
        break
    }
}

/// The one string a report can carry. Emptiness is decided by the LENGTH: a report with nothing to
/// say lends a dangling non-null the door documents as an empty string, so the pointer answers
/// nothing here and is unwrapped only to read the bytes a non-zero length promises.
private func said(_ text: UnsafePointer<UInt8>?, _ length: Int) -> String {
    guard let text, length > 0 else { return "" }
    let bytes = Array(UnsafeBufferPointer(start: text, count: length))
    // The producer is `slopdesk-dropd`'s own `String`, so these bytes cannot be invalid UTF-8. A
    // failable init would add a `nil` branch that means "the report said nothing", which the length
    // guard above already answers.
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: bytes, as: UTF8.self)
}
