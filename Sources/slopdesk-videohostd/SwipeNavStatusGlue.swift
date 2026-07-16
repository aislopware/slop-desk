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
        // Thread-safe AppKit read on main; the fan-out hops through the registry actor and
        // each session actor — a 5-byte datagram per lane, nothing on any hot path.
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        Task { [registry] in
            await registry.forEachSession { await $0.pushSwipeNavStatus(frontmostBundleID: bundleID) }
        }
    }
}
#endif
