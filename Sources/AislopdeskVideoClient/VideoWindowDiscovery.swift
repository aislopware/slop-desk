#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import Foundation
import AislopdeskVideoProtocol

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
@MainActor
public enum VideoWindowDiscovery {
    /// Discovers the host's shareable windows. Returns `[]` on timeout / no registry / no host support
    /// (the picker then shows its manual-id fallback). Best-effort — never throws.
    public static func discoverWindows(
        host: String,
        mediaPort: UInt16,
        cursorPort: UInt16,
        retryInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(3)
    ) async -> [WindowSummary] {
        guard let registry = VideoWindowPipeline.sharedRegistry else { return [] }
        let acq = registry.acquire(host: host, mediaPort: mediaPort, cursorPort: cursorPort)
        defer { registry.release(host: host, mediaPort: mediaPort, cursorPort: cursorPort, channelID: acq.channelID) }

        let box = ReplyBox()
        acq.flow.registerLane(
            channelID: acq.channelID,
            onMedia: { channel, payload in
                guard channel == .control,
                      let msg = try? VideoControlMessage.decode(payload),
                      case .windowList(let windows) = msg else { return }
                box.deliver(windows)
            },
            onCursor: { _ in }
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
            box.finish()   // resolve the waiter with whatever arrived (possibly nothing)
        }
        let result = await box.firstReply()   // resumes on the first windowList OR on the sender's finish()
        sender.cancel()
        return result ?? []
    }
}

/// Thread-safe one-shot box correlating the `windowList` reply (delivered off the flow's receive queue)
/// with the awaiting discovery call. The single waiter is resolved EXACTLY once — by the first
/// `deliver(_:)` or by `finish()` on timeout — so the `CheckedContinuation` never leaks.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: [WindowSummary]?
    private var cont: CheckedContinuation<[WindowSummary]?, Never>?
    private var resolved = false

    var hasReply: Bool { lock.withLock { result != nil } }

    /// A `windowList` arrived (may be called more than once under UDP duplication — only the first sticks).
    func deliver(_ windows: [WindowSummary]) {
        lock.lock()
        if result == nil { result = windows }
        guard !resolved, let c = cont else { lock.unlock(); return }
        resolved = true; cont = nil
        let r = result
        lock.unlock()
        c.resume(returning: r)
    }

    /// Timeout: resolve the waiter with whatever we have (possibly `nil`). No-op once resolved.
    func finish() {
        lock.lock()
        guard !resolved, let c = cont else { lock.unlock(); return }
        resolved = true; cont = nil
        let r = result
        lock.unlock()
        c.resume(returning: r)
    }

    /// Awaits the first reply (or `finish()`). Returns immediately if already resolved/delivered.
    func firstReply() async -> [WindowSummary]? {
        await withCheckedContinuation { (c: CheckedContinuation<[WindowSummary]?, Never>) in
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
