// DeviceSocket — the near side of `slopdesk_device_ws_*` and `slopdesk_device_bridge_*`.
//
// Both device panels used to hold `NWConnection`s and decide their own lifecycles; the sockets are
// `slopdesk-devicelink`'s now (`docs/63` §6's deferred lane campaign), and what is left on this side
// is the calling convention: a retained context, one `@convention(c)` function, and the hop from the
// socket's thread to the main actor. Nothing here decides anything.
//
// ## The hop is `DispatchQueue.main.async`, and that is not interchangeable with `Task { @MainActor }`
//
// The Swift lanes this replaces hopped with a `Task` and got away with it because they re-armed the
// receive INSIDE the hop, so at most one was ever in flight. The reader is a Rust thread now and
// delivers back to back, so several hops are in flight at once — and `Task` enqueues carry no
// ordering guarantee between them where a serial `DispatchQueue` does. What crosses is a video
// stream: two access units delivered out of order are a corrupt picture, not a late one.
//
// ## Why a silence, when the door already joins
//
// `_free` joins the reader, so the CALLBACK cannot run afterwards. What can still run is a hop
// already sitting on the main queue, and that is exactly what the old `isTornDown` flag existed to
// swallow. ``DeviceSocketSink/silence()`` is that flag, in the one place both sockets share.

import CSlopDeskFFI
import Foundation

/// Where a device socket's events land, and the gate that stops them.
///
/// A `final class` rather than a closure because the door's `context` must be a raw pointer valid on
/// any thread until `_free` RETURNS, and only a retained object is that. The lock covers the one
/// publication — the sink is installed at init and cleared at silence — rather than a hot path.
package final class DeviceSocketSink: @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@MainActor (UInt32, Data) -> Void)?

    /// `deliver` is called on the main actor, in the order the socket produced the events.
    package init(_ deliver: @escaping @MainActor (UInt32, Data) -> Void) {
        self.deliver = deliver
    }

    /// Drop everything from here on, including hops already queued.
    package func silence() {
        lock.lock()
        defer { lock.unlock() }
        deliver = nil
    }

    /// One event, from the socket's thread. See the file header on why this queue and not a `Task`.
    ///
    /// Reachable from the file's callback rather than `fileprivate`, which the lint bars: this is
    /// the sink's own delivery and the class is `final`, so `internal` costs nothing but a wider
    /// name inside one module.
    func say(_ kind: UInt32, _ payload: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            lock.lock()
            let sink = deliver
            lock.unlock()
            guard let sink else { return }
            MainActor.assumeIsolated { sink(kind, payload) }
        }
    }
}

/// One simulator websocket, for as long as this object lives.
///
/// ARC is the lifetime, ``LivePaneDriver``'s arrangement: the last release frees the door's handle,
/// which tears the socket down and joins its reader, and only then releases the context. Freeing in
/// the other order would release a context a running callback still holds.
package final class DeviceWebSocket {
    private let handle: OpaquePointer?
    private let context: Unmanaged<DeviceSocketSink>

    /// Opens `url`. Never fails from here: a URL the crate will not dial reports
    /// `SLOPDESK_DEVICE_WS_ENDED` through the sink, which is what keeps the caller to one failure
    /// path — see the door.
    package init(url: String, sink: DeviceSocketSink) {
        let retained = Unmanaged.passRetained(sink)
        context = retained
        let bytes = Array(url.utf8)
        handle = bytes.withUnsafeBufferPointer { span in
            slopdesk_device_ws_open(span.baseAddress, span.count, retained.toOpaque(), deviceSocketEvent)
        }
    }

    /// Sends one text message. Dropped when the socket is not up.
    @discardableResult
    package func sendText(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { span in
            slopdesk_device_ws_send_text(handle, span.baseAddress, span.count)
        }
    }

    deinit {
        slopdesk_device_ws_free(handle)
        context.release()
    }
}

/// One Android bridge call, for as long as this object lives. Same lifetime rules as
/// ``DeviceWebSocket``.
package final class DeviceBridgeCall {
    private let handle: OpaquePointer?
    private let context: Unmanaged<DeviceSocketSink>

    /// Dials `host:port` and writes `request`, which is a whole line — ``AndroidBridgeRequest`` built
    /// it and is the only thing that can refuse to.
    package init(host: String, port: UInt16, request: Data, sink: DeviceSocketSink) {
        let retained = Unmanaged.passRetained(sink)
        context = retained
        let hostBytes = Array(host.utf8)
        handle = hostBytes.withUnsafeBufferPointer { hostSpan in
            request.withUnsafeBytes { requestSpan in
                slopdesk_device_bridge_open(
                    hostSpan.baseAddress, hostSpan.count,
                    port,
                    requestSpan.baseAddress?.assumingMemoryBound(to: UInt8.self), requestSpan.count,
                    retained.toOpaque(), deviceSocketEvent,
                )
            }
        }
    }

    /// Sends bytes upstream — `open`'s control channel. Dropped when the socket is not up.
    @discardableResult
    package func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { span in
            slopdesk_device_bridge_send(
                handle, span.baseAddress?.assumingMemoryBound(to: UInt8.self), span.count,
            )
        }
    }

    deinit {
        slopdesk_device_bridge_free(handle)
        context.release()
    }
}

// MARK: - The one callback

// A free function rather than a closure, because a `@convention(c)` pointer captures nothing. Both
// door families share it: every event on both is a kind and a run of bytes, so a second entry point
// would discriminate nothing this one does not.
private func deviceSocketEvent(
    context: UnsafeMutableRawPointer?,
    kind: UInt32,
    bytes: UnsafePointer<UInt8>?,
    length: Int,
) {
    guard let context else { return }
    let sink = Unmanaged<DeviceSocketSink>.fromOpaque(context).takeUnretainedValue()
    // The run is copied HERE and exactly once. The LENGTH decides, never the pointer: an empty
    // payload crosses as a null pointer, which is the door's stated convention.
    let payload = length > 0 ? bytes.map { Data(bytes: $0, count: length) } ?? Data() : Data()
    sink.say(kind, payload)
}
