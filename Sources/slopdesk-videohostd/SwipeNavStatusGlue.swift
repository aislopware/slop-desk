#if os(macOS)
import AppKit
import SlopDeskVideoHost

/// Pushes the swipe-nav status (``SwipeNavStatusMessage``, cursor socket type=3) to every
/// live video session: instantly on each frontmost-app ACTIVATION — the only moment a
/// display session's eligibility can flip — and on a ~2 s heartbeat. The heartbeat is the
/// loss self-heal for a fire-and-forget UDP push AND the bootstrap for freshly minted
/// sessions (a session that missed the last activation push is at most one beat stale).
///
/// Daemon-level, not per-session: the frontmost app is ONE global truth shared by all
/// lanes (mirrors ``WindowFeedKicker``); each session resolves its own pid>0 window-target
/// override inside `pushSwipeNavStatus`.
@MainActor
final class SwipeNavStatusKicker {
    private let registry: VideoMuxSessionRegistry
    private var heartbeat: Task<Void, Never>?

    /// Change-only push trace (`SLOPDESK_SWIPE_NAV_TRACE`, the per-gesture trace's flag): one
    /// line per frontmost-app transition, not per 2 s beat. This push path is otherwise
    /// UNOBSERVABLE — the eligible=false freeze shipped silently because nothing logged what
    /// the heartbeat was actually saying.
    private nonisolated static let trace = ProcessInfo.processInfo
        .environment["SLOPDESK_SWIPE_NAV_TRACE"] != nil
    private final class LastPushed: @unchecked Sendable {
        let lock = NSLock()
        var key: String?
    }

    private let lastPushed = LastPushed()

    init(registry: VideoMuxSessionRegistry) {
        self.registry = registry
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(noteActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil,
        )
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                push()
            }
        }
        push()
    }

    @objc
    private func noteActivation(_: Notification) { push() }

    private func push() {
        // The frontmost read is ``HostFrontmostApp`` (a fresh WindowServer query), NEVER
        // `NSWorkspace`: the daemon's NSWorkspace snapshot freezes at first access (on and off
        // the main thread — probe-verified with Chrome frontmost while every heartbeat kept
        // pushing the launch-time Terminal → eligible=false forever, chip never lit). Detached
        // so the CGWindowList IPC never blocks the main actor; the fan-out then hops through
        // the registry actor and each session actor — a 5-byte datagram per lane, nothing on a
        // hot path.
        Task.detached(priority: .utility) { [registry, lastPushed] in
            let bundleID = HostFrontmostApp.bundleID()
            if Self.trace {
                let key = "\(bundleID ?? "nil") eligible=\(SwipeNavHostConfig.eligible(bundleID: bundleID))"
                let changed = lastPushed.lock.withLock {
                    let changed = lastPushed.key != key
                    lastPushed.key = key
                    return changed
                }
                if changed {
                    FileHandle.standardError
                        .write(Data("slopdesk-videohostd: swipe-nav status push → \(key)\n".utf8))
                }
            }
            await registry.forEachSession { await $0.pushSwipeNavStatus(frontmostBundleID: bundleID) }
        }
    }
}
#endif
