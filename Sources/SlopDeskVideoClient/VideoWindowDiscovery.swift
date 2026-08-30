#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

/// One-shot client-side window DISCOVERY for the Remote Window picker (docs/31): asks the host "what
/// windows can I stream?" and returns the answer, so the UI can list them instead of making the user type
/// a CGWindowID.
///
/// It rides the SAME per-host shared UDP flow as streaming (``VideoConnectionRegistry`` /
/// ``VideoMuxClientFlow``): it acquires a transient lane (a collision-safe channelID), sends a
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
        await discover(
            host: host, mediaPort: mediaPort, cursorPort: cursorPort,
            retryInterval: retryInterval, timeout: timeout,
            request: .listWindows,
            reply: { if case let .windowList(windows) = $0 { windows } else { nil } },
        )
    }

    /// Discovers the host's online DISPLAYS (the desktop pane's display-switcher menu): the
    /// ``VideoControlMessage/listDisplays`` ↔ ``VideoControlMessage/displayList`` pair, same
    /// transient-lane request / retry / timeout discipline as ``discoverWindows(host:mediaPort:cursorPort:retryInterval:timeout:)``
    /// (session-less — the host never mints a capture session for it). Returns `[]` on timeout / no
    /// registry / an old host (the menu then shows only the current display).
    public static func discoverDisplays(
        host: String,
        mediaPort: UInt16,
        cursorPort: UInt16,
        retryInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(3),
    ) async -> [DisplaySummary] {
        await discover(
            host: host, mediaPort: mediaPort, cursorPort: cursorPort,
            retryInterval: retryInterval, timeout: timeout,
            request: .listDisplays,
            reply: { if case let .displayList(displays) = $0 { displays } else { nil } },
        )
    }

    /// The one-shot discovery both lists run: take a transient lane, send `request` on the schedule
    /// the far side plans, and resolve on the first reply `reply` recognises.
    ///
    /// Written once for both, because the two differ only in which message they send and which one
    /// answers it — the lane discipline, the resend schedule and the empty-is-an-answer rule are the
    /// same discovery said twice.
    private static func discover<Element>(
        host: String,
        mediaPort: UInt16,
        cursorPort: UInt16,
        retryInterval: Duration,
        timeout: Duration,
        request message: VideoControlMessage,
        reply: @escaping @Sendable (VideoControlMessage) -> [Element]?,
    ) async -> [Element] {
        guard let registry = VideoWindowPipeline.sharedRegistry else { return [] }
        let acq = registry.acquire(host: host, mediaPort: mediaPort, cursorPort: cursorPort)
        defer { registry.release(host: host, mediaPort: mediaPort, cursorPort: cursorPort, channelID: acq.channelID) }

        let box = ReplyBox<Element>()
        acq.flow.registerLane(
            channelID: acq.channelID,
            onMedia: { channel, payload in
                guard channel == .control,
                      let msg = try? VideoControlMessage.decode(payload),
                      let records = reply(msg) else { return }
                box.deliver(records)
            },
            onCursor: { _ in },
        )

        let request = message.encode()
        let flow = acq.flow
        let channelID = acq.channelID
        let retrySeconds = seconds(retryInterval)
        let schedule = sendOffsets(timeout: seconds(timeout), retryInterval: retrySeconds)

        // A sender that retransmits on the planned offsets (UDP is lossy — the request OR the reply
        // can drop), then resolves the waiter so a no-reply discovery returns [] instead of hanging
        // the picker. Each wait is to an ABSOLUTE instant, so a slow send cannot walk the schedule
        // later than it was planned.
        let sender = Task { @MainActor in
            let start = ContinuousClock.now
            for offset in schedule {
                if box.hasReply || Task.isCancelled { break }
                flow.send(request, on: .control, channelID: channelID)
                try? await Task.sleep(until: start.advanced(by: .seconds(offset + retrySeconds)))
            }
            box.finish() // resolve the waiter with whatever arrived (possibly nothing)
        }
        let result = await box.firstReply() // resumes on the first reply OR on the sender's finish()
        sender.cancel()
        return result ?? []
    }

    /// The far side's resend plan: when each send goes out, counted in seconds from the start.
    static func sendOffsets(timeout: Double, retryInterval: Double) -> [Double] {
        let needed = slopdesk_video_request_send_offsets(timeout, retryInterval, nil, 0)
        guard needed > 0 else { return [] }
        var offsets = [Double](repeating: 0, count: needed)
        let written = offsets.withUnsafeMutableBufferPointer { room in
            slopdesk_video_request_send_offsets(timeout, retryInterval, room.baseAddress, room.count)
        }
        return written == needed ? offsets : []
    }

    /// A `Duration` as seconds.
    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Thread-safe one-shot box correlating a list reply (delivered off the flow's receive queue) with the
/// awaiting discovery call. Generic over the record type so every list-shaped discovery
/// (`WindowSummary`, `RemoteDisplaySummary`) reuses it. The single waiter is resolved EXACTLY once
/// — by the first `deliver(_:)` or by `finish()` on timeout — so the `CheckedContinuation` never leaks.
final class ReplyBox<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: [Element]?
    private var cont: CheckedContinuation<[Element]?, Never>?
    private var resolved = false

    var hasReply: Bool { lock.withLock { result != nil } }

    /// A reply arrived (may be called more than once under UDP duplication — only the first sticks).
    ///
    /// Once the box is RESOLVED the answer it gave is final, so a reply that lands after the
    /// deadline is dropped rather than recorded: the caller was already handed the empty answer and
    /// a second one it can never read is not an improvement on none.
    func deliver(_ records: [Element]) {
        lock.lock()
        guard !resolved else { lock.unlock()
            return
        }
        if result == nil { result = records }
        guard let c = cont else { lock.unlock()
            return
        }
        resolved = true
        cont = nil
        let r = result
        lock.unlock()
        c.resume(returning: r)
    }

    /// Timeout: resolve the waiter with whatever we have (possibly `nil`). No-op once resolved.
    ///
    /// The deadline can pass BEFORE anyone is waiting — the sender is a `Task`, and an empty resend
    /// schedule finishes it before `firstReply()` is even reached. So this marks the box resolved
    /// whether or not a continuation is parked yet: without that, the answer is thrown away, the
    /// waiter that arrives afterwards sees neither a result nor a resolution, and the picker hangs
    /// on a discovery that already gave up.
    func finish() {
        lock.lock()
        guard !resolved else { lock.unlock()
            return
        }
        resolved = true
        let waiter = cont
        cont = nil
        let r = result
        lock.unlock()
        waiter?.resume(returning: r)
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
