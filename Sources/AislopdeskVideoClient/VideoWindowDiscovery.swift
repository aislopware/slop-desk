#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import AislopdeskVideoProtocol
import CoreGraphics
import Foundation
import ImageIO

/// One-shot client-side window DISCOVERY for the Remote Window picker (docs/31): asks the host "what
/// windows can I stream?" and returns the answer, so the UI can list them instead of making the user type
/// a CGWindowID.
///
/// It rides the SAME per-host shared UDP flow as streaming (``VideoConnectionRegistry`` /
/// ``NWVideoMuxClientFlow``): it acquires a transient lane (a collision-safe channelID), sends a
/// ``VideoControlMessage/listWindows`` on the `.control` channel — NOT a `hello`, so the host NEVER mints
/// a capture session — and awaits the ``VideoControlMessage/windowList`` reply. Because the whole video
/// path is fire-and-forget UDP (no request/response infra), this builds its own retry + timeout: it
/// resends the request every `retryInterval` until a reply arrives or `timeout` elapses, then releases
/// the lane. An old host (no listWindows support) simply never replies → empty result → the UI falls back
/// to manual entry.
@preconcurrency
@MainActor
public enum VideoWindowDiscovery {
    /// Discovers the host's shareable windows. Returns `[]` on timeout / no registry / no host support
    /// (the picker then shows its manual-id fallback). Best-effort — never throws.
    public static func discoverWindows(
        host: String,
        mediaPort: UInt16,
        cursorPort: UInt16,
        retryInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(3),
    ) async -> [WindowSummary] {
        guard let registry = VideoWindowPipeline.sharedRegistry else { return [] }
        let acq = registry.acquire(host: host, mediaPort: mediaPort, cursorPort: cursorPort)
        defer { registry.release(host: host, mediaPort: mediaPort, cursorPort: cursorPort, channelID: acq.channelID) }

        let box = ReplyBox<WindowSummary>()
        acq.flow.registerLane(
            channelID: acq.channelID,
            onMedia: { channel, payload in
                guard channel == .control,
                      let msg = try? VideoControlMessage.decode(payload),
                      case let .windowList(windows) = msg else { return }
                box.deliver(windows)
            },
            onCursor: { _ in },
        )

        let request = VideoControlMessage.listWindows.encode()
        let flow = acq.flow
        let channelID = acq.channelID

        // A sender that retransmits the request until a reply arrives or the deadline passes (UDP is
        // lossy — the request OR the reply can drop), then resolves the waiter so a no-reply discovery
        // returns [] instead of hanging the picker.
        let sender = Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline, !box.hasReply, !Task.isCancelled {
                flow.send(request, on: .control, channelID: channelID)
                try? await Task.sleep(for: retryInterval)
            }
            box.finish() // resolve the waiter with whatever arrived (possibly nothing)
        }
        let result = await box.firstReply() // resumes on the first windowList OR on the sender's finish()
        sender.cancel()
        return result ?? []
    }

    /// Polls the host for the open SYSTEM dialogs (the "show system popups in their own pane" feature).
    /// Same transient-lane request / retry / timeout discipline as ``discoverWindows`` but for the
    /// ``VideoControlMessage/listSystemDialogs`` ↔ ``VideoControlMessage/systemDialogList`` pair. The
    /// client's system-dialog monitor calls this on a slow cadence and diffs the result to spawn/close
    /// ephemeral dialog panes. Returns `[]` on timeout / no registry / an old host (no support). Tighter
    /// defaults than the picker (the monitor polls continuously, so a faster give-up keeps the cadence).
    public static func discoverSystemDialogs(
        host: String,
        mediaPort: UInt16,
        cursorPort: UInt16,
        retryInterval: Duration = .milliseconds(400),
        timeout: Duration = .milliseconds(1500),
    ) async -> [SystemDialogSummary] {
        guard let registry = VideoWindowPipeline.sharedRegistry else { return [] }
        let acq = registry.acquire(host: host, mediaPort: mediaPort, cursorPort: cursorPort)
        defer { registry.release(host: host, mediaPort: mediaPort, cursorPort: cursorPort, channelID: acq.channelID) }

        let box = ReplyBox<SystemDialogSummary>()
        acq.flow.registerLane(
            channelID: acq.channelID,
            onMedia: { channel, payload in
                guard channel == .control,
                      let msg = try? VideoControlMessage.decode(payload),
                      case let .systemDialogList(dialogs) = msg else { return }
                box.deliver(dialogs)
            },
            onCursor: { _ in },
        )

        let request = VideoControlMessage.listSystemDialogs.encode()
        let flow = acq.flow
        let channelID = acq.channelID
        let sender = Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline, !box.hasReply, !Task.isCancelled {
                flow.send(request, on: .control, channelID: channelID)
                try? await Task.sleep(for: retryInterval)
            }
            box.finish()
        }
        let result = await box.firstReply()
        sender.cancel()
        return result ?? []
    }

    /// Fetches a one-shot THUMBNAIL of one host window (MERIDIAN C4 — the picker grid / sidebar
    /// WINDOWS rows), decoded to a `CGImage`. Same transient-lane discipline as ``discoverWindows``
    /// but the reply is CHUNKED (`windowPreviewRequest` ↔ N × `windowPreviewChunk`, reassembled by
    /// the pure ``WindowPreviewAssembler``), so the retransmit loop stops at the FIRST chunk — a
    /// re-request after chunks started would make the host re-capture, and a fresh JPEG's bytes
    /// interleaved with the old ones under the same token could stitch a corrupt image. A chunk
    /// lost after that simply times the fetch out (`nil` → the caller keeps its monogram fallback;
    /// a later call re-requests under a NEW token). Returns `nil` on timeout / no registry / an old
    /// host (no support) / a JPEG that fails to decode. Best-effort — never throws.
    public static func discoverWindowPreview(
        host: String,
        mediaPort: UInt16,
        cursorPort: UInt16,
        windowID: UInt32,
        maxEdge: UInt16 = 320,
        retryInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(3),
    ) async -> CGImage? {
        guard let registry = VideoWindowPipeline.sharedRegistry else { return nil }
        let acq = registry.acquire(host: host, mediaPort: mediaPort, cursorPort: cursorPort)
        defer { registry.release(host: host, mediaPort: mediaPort, cursorPort: cursorPort, channelID: acq.channelID) }

        let token = UInt32.random(in: .min ... .max)
        let box = PreviewBox(token: token)
        acq.flow.registerLane(
            channelID: acq.channelID,
            onMedia: { channel, payload in
                guard channel == .control,
                      let msg = try? VideoControlMessage.decode(payload) else { return }
                box.deliver(msg)
            },
            onCursor: { _ in },
        )

        let request = VideoControlMessage.windowPreviewRequest(
            windowID: windowID, maxEdge: maxEdge, token: token,
        ).encode()
        let flow = acq.flow
        let channelID = acq.channelID
        let sender = Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: timeout)
            // Retransmit only until the host's first chunk arrives (see the doc comment above).
            while ContinuousClock.now < deadline, !box.hasStarted, !Task.isCancelled {
                flow.send(request, on: .control, channelID: channelID)
                try? await Task.sleep(for: retryInterval)
            }
            // Chunks started (or the request window closed) — give the tail until the deadline,
            // then resolve the waiter with whatever assembled (possibly nothing).
            let remaining = deadline - ContinuousClock.now
            if remaining > .zero { try? await Task.sleep(for: remaining) }
            box.finish()
        }
        let image = await box.assembledImage()
        sender.cancel()
        guard let image else { return nil }
        return Self.decodePreviewJPEG(image.data)
    }

    /// Decodes the reassembled preview bytes to a `CGImage` via ImageIO (cross-platform macOS/iOS).
    /// A corrupt/truncated payload returns `nil` — the thumbnail is simply skipped, never trapped on.
    static func decodePreviewJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Thread-safe one-shot box correlating a CHUNKED preview reply (delivered off the flow's receive
/// queue) with the awaiting ``VideoWindowDiscovery/discoverWindowPreview`` call. Wraps the pure
/// ``WindowPreviewAssembler`` under a lock; the single waiter is resolved EXACTLY once — by the
/// completing chunk or by `finish()` on timeout — so the `CheckedContinuation` never leaks.
private final class PreviewBox: @unchecked Sendable {
    private let lock = NSLock()
    private var assembler: WindowPreviewAssembler
    private var started = false
    private var result: WindowPreviewAssembler.Image?
    private var cont: CheckedContinuation<WindowPreviewAssembler.Image?, Never>?
    private var resolved = false

    init(token: UInt32) {
        assembler = WindowPreviewAssembler(token: token)
    }

    /// Whether ANY chunk arrived yet — the sender's stop-retransmitting signal.
    var hasStarted: Bool { lock.withLock { started } }

    /// Feed one control message (non-chunk / foreign-token messages are ignored by the assembler).
    func deliver(_ message: VideoControlMessage) {
        lock.lock()
        if case .windowPreviewChunk = message { started = true }
        guard result == nil, let image = assembler.feed(message) else {
            lock.unlock()
            return
        }
        result = image
        guard !resolved, let c = cont else {
            lock.unlock()
            return
        }
        resolved = true
        cont = nil
        lock.unlock()
        c.resume(returning: image)
    }

    /// Timeout: resolve the waiter with whatever assembled (possibly `nil`). No-op once resolved.
    func finish() {
        lock.lock()
        guard !resolved, let c = cont else {
            lock.unlock()
            return
        }
        resolved = true
        cont = nil
        let r = result
        lock.unlock()
        c.resume(returning: r)
    }

    /// Awaits the assembled image (or `finish()`). Returns immediately if already resolved.
    func assembledImage() async -> WindowPreviewAssembler.Image? {
        await withCheckedContinuation { (c: CheckedContinuation<WindowPreviewAssembler.Image?, Never>) in
            lock.lock()
            if resolved || result != nil {
                resolved = true
                let r = result
                lock.unlock()
                c.resume(returning: r)
                return
            }
            cont = c
            lock.unlock()
        }
    }
}

/// Thread-safe one-shot box correlating a list reply (delivered off the flow's receive queue) with the
/// awaiting discovery call. Generic over the record type so both the window picker (`WindowSummary`) and
/// the system-dialog monitor (`SystemDialogSummary`) reuse it. The single waiter is resolved EXACTLY once
/// — by the first `deliver(_:)` or by `finish()` on timeout — so the `CheckedContinuation` never leaks.
private final class ReplyBox<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: [Element]?
    private var cont: CheckedContinuation<[Element]?, Never>?
    private var resolved = false

    var hasReply: Bool { lock.withLock { result != nil } }

    /// A reply arrived (may be called more than once under UDP duplication — only the first sticks).
    func deliver(_ records: [Element]) {
        lock.lock()
        if result == nil { result = records }
        guard !resolved, let c = cont else { lock.unlock()
            return
        }
        resolved = true
        cont = nil
        let r = result
        lock.unlock()
        c.resume(returning: r)
    }

    /// Timeout: resolve the waiter with whatever we have (possibly `nil`). No-op once resolved.
    func finish() {
        lock.lock()
        guard !resolved, let c = cont else { lock.unlock()
            return
        }
        resolved = true
        cont = nil
        let r = result
        lock.unlock()
        c.resume(returning: r)
    }

    /// Awaits the first reply (or `finish()`). Returns immediately if already resolved/delivered.
    func firstReply() async -> [Element]? {
        await withCheckedContinuation { (c: CheckedContinuation<[Element]?, Never>) in
            lock.lock()
            if resolved || result != nil {
                resolved = true
                let r = result
                lock.unlock()
                c.resume(returning: r)
                return
            }
            cont = c
            lock.unlock()
        }
    }
}
#endif
