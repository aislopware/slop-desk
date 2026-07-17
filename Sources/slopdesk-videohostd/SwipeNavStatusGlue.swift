#if os(macOS)
import AppKit
import SlopDeskVideoHost

/// Pushes the swipe-nav status (``SwipeNavStatusMessage``, cursor socket type=3) to every
/// live video session: instantly on each frontmost-app ACTIVATION, on every 250 ms tick whose
/// (frontmost, eligibility, history) key CHANGED — history flips on every navigation, and a
/// 2 s-stale "can't go back" right after clicking a link would eat the most common swipe —
/// and unconditionally on every 8th tick (the ~2 s heartbeat: the loss self-heal for a
/// fire-and-forget UDP push AND the bootstrap for freshly minted sessions).
///
/// Daemon-level, not per-session: the frontmost app is ONE global truth shared by all
/// lanes (mirrors ``WindowFeedKicker``); each session resolves its own pid>0 window-target
/// override inside `pushSwipeNavStatus`. With ZERO sessions every tick returns before the
/// WindowServer/AX reads (perf-audit-caught: the idle daemon otherwise paid the 4 Hz polling
/// forever for an audience of zero).
@MainActor
final class SwipeNavStatusKicker {
    private let registry: VideoMuxSessionRegistry
    private var heartbeat: Task<Void, Never>?

    /// Change-only push trace (`SLOPDESK_SWIPE_NAV_TRACE`, the per-gesture trace's flag): one
    /// line per (frontmost, eligibility, history) transition, not per beat. This push path is
    /// otherwise UNOBSERVABLE — the eligible=false freeze shipped silently because nothing
    /// logged what the heartbeat was actually saying.
    private nonisolated static let trace = ProcessInfo.processInfo
        .environment["SLOPDESK_SWIPE_NAV_TRACE"] != nil

    /// Cross-tick state for the detached workers: the last pushed key (change detection) and
    /// an in-flight latch. The latch spans the WHOLE worker — read AND fan-out: a cold AX
    /// rescan can take ~200 ms, and if a later worker could start (or merely reach the
    /// registry actor first) while an earlier fan-out was still in flight, sessions would see
    /// NEW-then-OLD and hold the stale state until the next heartbeat.
    private final class TickState: @unchecked Sendable {
        let lock = NSLock()
        var lastKey: String?
        var inFlight = false

        /// Returns whether this worker may run; `end()` releases the latch.
        func begin() -> Bool {
            lock.withLock {
                guard !inFlight else { return false }
                inFlight = true
                return true
            }
        }

        /// Stores the new key and reports whether it changed (the latch stays held).
        func changed(key: String) -> Bool {
            lock.withLock {
                let changed = lastKey != key
                lastKey = key
                return changed
            }
        }

        func end() {
            lock.withLock { inFlight = false }
        }
    }

    private let state = TickState()
    private let navHistory = HostNavHistory()

    init(registry: VideoMuxSessionRegistry) {
        self.registry = registry
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(noteActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil,
        )
        heartbeat = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                tick += 1
                push(force: tick.isMultiple(of: 8))
            }
        }
        push(force: true)
    }

    @objc
    private func noteActivation(_: Notification) { push(force: true) }

    private func push(force: Bool) {
        // The frontmost read is ``HostFrontmostApp`` (a fresh WindowServer query), NEVER
        // `NSWorkspace`: the daemon's NSWorkspace snapshot freezes at first access (on and off
        // the main thread — probe-verified with Chrome frontmost while every heartbeat kept
        // pushing the launch-time Terminal → eligible=false forever, chip never lit). Detached
        // so the CGWindowList + AX IPC never block the main actor; the fan-out then hops
        // through the registry actor and each session actor — a 6-byte datagram per lane,
        // nothing on a hot path.
        Task.detached(priority: .utility) { [registry, state, navHistory] in
            guard state.begin() else { return }
            defer { state.end() }
            // Zero sessions ⇒ nobody can render the chip: skip the WindowServer query and the
            // AX read entirely (idle daemon is the COMMON state, and this loop otherwise runs
            // for its whole life). lastKey is left as-is — a freshly minted session bootstraps
            // off the ≤2 s forced beat exactly as it does today.
            guard await registry.hasSessions else { return }
            let front = HostFrontmostApp.frontmost()
            let bundleID = front?.bundleID
            let eligible = SwipeNavHostConfig.eligible(bundleID: bundleID)
            // The AX read only runs for an eligible frontmost (a dark chip needs no history,
            // and ineligible pushes zero the bits anyway); a cached hit is ~0.05 ms, and only
            // the forced beat may retry a pid whose last scan found no Back/Forward pair or
            // pay the toolbar-pair window-currency round trip (perf-audit-caught: verifying
            // per beat cost 1–6 ms of live IPC × 4 Hz into Safari-family targets).
            let history: NavHistoryFlags? =
                if SwipeNavHostConfig.historyGate, eligible, let pid = front?.pid {
                    navHistory.read(pid: pid, rescanUnknown: force, verifyWindow: force)
                } else {
                    nil
                }
            let key = "\(bundleID ?? "nil") eligible=\(eligible) "
                + "history=\(history.map { "back=\($0.canGoBack) fwd=\($0.canGoForward)" } ?? "unknown")"
            let changed = state.changed(key: key)
            guard force || changed else { return }
            if Self.trace, changed {
                FileHandle.standardError
                    .write(Data("slopdesk-videohostd: swipe-nav status push → \(key)\n".utf8))
            }
            await registry.forEachSession {
                await $0.pushSwipeNavStatus(frontmostBundleID: bundleID, history: history)
            }
        }
    }
}
#endif
