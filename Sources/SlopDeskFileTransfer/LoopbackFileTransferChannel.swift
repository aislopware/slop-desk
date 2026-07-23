import Foundation

/// An in-process ``FileTransferChannel`` pair for tests: bytes sent on one end surface on the other's
/// `inbound`. Lets a test drive the real ``FileTransferServer`` serve loop and ``FileTransferClient``
/// upload against each other with NO socket (hang-safety), asserting bytes land in a fake sink.
///
/// `@unchecked Sendable`: the peer continuation is set once at construction and only `yield`/`finish`
/// are called afterward (both continuation-safe).
public final class LoopbackFileTransferChannel: FileTransferChannel, @unchecked Sendable {
    private let inboundStream: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let peerContinuation: () -> AsyncThrowingStream<Data, Error>.Continuation
    private let onClose: @Sendable () -> Void

    private init(
        inboundStream: AsyncThrowingStream<Data, Error>,
        inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation,
        peerContinuation: @escaping () -> AsyncThrowingStream<Data, Error>.Continuation,
        onClose: @escaping @Sendable () -> Void,
    ) {
        self.inboundStream = inboundStream
        self.inboundContinuation = inboundContinuation
        self.peerContinuation = peerContinuation
        self.onClose = onClose
    }

    public nonisolated var inbound: AsyncThrowingStream<Data, Error> { inboundStream }

    public func send(_ data: Data) {
        peerContinuation().yield(data)
    }

    public func close() {
        inboundContinuation.finish()
        peerContinuation().finish()
        onClose()
    }

    /// Two wired channels: `a.send` → `b.inbound` and vice versa.
    public static func pair() -> (a: LoopbackFileTransferChannel, b: LoopbackFileTransferChannel) {
        var aCont: AsyncThrowingStream<Data, Error>.Continuation?
        let aStream = AsyncThrowingStream<Data, Error> { aCont = $0 }
        var bCont: AsyncThrowingStream<Data, Error>.Continuation?
        let bStream = AsyncThrowingStream<Data, Error> { bCont = $0 }
        guard let aCont, let bCont else {
            preconditionFailure("AsyncThrowingStream build closures run synchronously")
        }
        let a = LoopbackFileTransferChannel(
            inboundStream: aStream,
            inboundContinuation: aCont,
            peerContinuation: { bCont },
            onClose: {},
        )
        let b = LoopbackFileTransferChannel(
            inboundStream: bStream,
            inboundContinuation: bCont,
            peerContinuation: { aCont },
            onClose: {},
        )
        return (a, b)
    }
}
