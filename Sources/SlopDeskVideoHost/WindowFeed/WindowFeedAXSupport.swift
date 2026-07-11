// Phase-5 AX support for the host-window feed (docs/45 §6): instant differ kicks from the
// frontmost app's AX notifications, and the budgeted AXMinimized probe that disambiguates
// "minimized" from "on another Space" for off-screen windows.
//
// ⚠️ **GUI + TCC ONLY** (Accessibility — the same grant the injector / geometry watcher hold).
// COMPILED + reviewed like ``WindowGeometryWatcher``; not driven from unit tests. The 1 Hz differ
// remains the mandatory backstop — AX is flaky on some apps (Electron), so every AX failure here
// degrades to "the differ catches it within a second", never to a broken feed.

#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation

/// Watches the FRONTMOST app for window-level AX events (created / destroyed / title / focus /
/// miniaturize) and fires `onEvent` — the feed differ's instant-kick source. Runs its observer on
/// a DEDICATED thread's run loop: the daemon's main thread runs `dispatchMain()` (no CFRunLoop), and
/// a beachballing app must never stall anything but this thread (`AXUIElementSetMessagingTimeout`
/// 0.25 s caps even that).
public final class WindowFeedAXObserver: @unchecked Sendable {
    private let onEvent: @Sendable () -> Void
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var observedPID: pid_t = 0

    private static let notifications: [String] = [
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    @preconcurrency
    public init(onEvent: @escaping @Sendable () -> Void) {
        self.onEvent = onEvent
        let thread = Thread { [weak self] in
            guard let self else { return }
            lock.withLock { runLoop = CFRunLoopGetCurrent() }
            // A Port keeps the run loop alive before the first observer source is attached.
            RunLoop.current.add(Port(), forMode: .default)
            RunLoop.current.run()
        }
        thread.name = "slopdesk.window-feed.ax"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Re-points the observer at `pid` (the newly frontmost app). Runs ON the AX thread; safe to
    /// call from any thread/actor. A pid that refuses observation (protected process, AX off) just
    /// leaves the feed on its 1 Hz backstop.
    public func retarget(pid: pid_t) {
        guard let runLoop = lock.withLock({ runLoop }) else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.installObserver(pid: pid)
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// AX-thread only: tear down the old observer and install one for `pid`.
    private func installObserver(pid: pid_t) {
        guard pid != observedPID else { return }
        if let old = observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(old), .defaultMode,
            )
            observer = nil
            observedElement = nil
        }
        observedPID = pid
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<WindowFeedAXObserver>.fromOpaque(refcon).takeUnretainedValue().onEvent()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            // Best-effort per notification — an app that rejects one (Electron quirks) still
            // delivers the rest; total refusal leaves the 1 Hz differ as the only source.
            AXObserverAddNotification(created, appElement, name as CFString, refcon)
        }
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode,
        )
        observer = created
        observedElement = appElement
    }
}

/// PURE budget decider for the minimized probe: which pids may be AX-probed this tick. Each pid is
/// re-probed at most once per ``ttl``; at most ``maxPIDsPerTick`` STALE pids probe per call (a
/// hung app costs ≤0.25 s, so the worst tick is bounded at ~0.75 s and steady state is ~0).
public struct MinimizedProbeBudget: Sendable {
    private var stamps: [pid_t: TimeInterval] = [:]
    public let ttl: TimeInterval
    public let maxPIDsPerTick: Int

    public init(ttl: TimeInterval = 3.0, maxPIDsPerTick: Int = 3) {
        self.ttl = ttl
        self.maxPIDsPerTick = maxPIDsPerTick
    }

    /// The stale subset of `candidates` (≤ `maxPIDsPerTick`, deterministic order), stamped as
    /// probed. Unpicked stale pids stay stale and win a later tick.
    public mutating func pidsToProbe(_ candidates: [pid_t], now: TimeInterval) -> [pid_t] {
        let stale = candidates.sorted().filter { now - (stamps[$0] ?? -.infinity) >= ttl }
        let picked = Array(stale.prefix(maxPIDsPerTick))
        for pid in picked { stamps[pid] = now }
        // Drop stamps for pids no longer present (quit apps) so the map never grows unbounded.
        let live = Set(candidates)
        stamps = stamps.filter { live.contains($0.key) }
        return picked
    }
}

/// The budgeted `AXMinimized` probe (docs/45 Phase 5): tells a MINIMIZED off-screen window from an
/// on-another-Space one. Cache-first — each probed pid refreshes every one of its windows' entries,
/// so between probes the answer is free. Main-actor (the repo's AX-messaging convention; the
/// per-app 0.25 s timeout bounds a hung target).
@preconcurrency
@MainActor
public final class MinimizedStateProbe {
    private var budget = MinimizedProbeBudget()
    /// windowID → last observed AXMinimized (survives between probes; dropped with its pid's apps).
    private var cache: [CGWindowID: Bool] = [:]

    public init() {}

    /// The minimized windowIDs among `offScreenByPID` (windowIDs grouped by owning pid), probing at
    /// most the budget's stale-pid quota this call.
    public func minimizedWindowIDs(
        offScreenByPID: [pid_t: [UInt32]], now: TimeInterval,
    ) -> Set<UInt32> {
        for pid in budget.pidsToProbe(Array(offScreenByPID.keys), now: now) {
            probe(pid: pid)
        }
        var out: Set<UInt32> = []
        for ids in offScreenByPID.values {
            for id in ids where cache[CGWindowID(id)] == true { out.insert(id) }
        }
        return out
    }

    /// One app's AX window sweep: read every window's `AXMinimized` and refresh the cache. Failures
    /// (no AX, hung past the timeout) leave prior entries standing — stale beats absent for a
    /// tooltip, and the next TTL window retries.
    private func probe(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef,
        ) == .success, let axWindows = windowsRef as? [AXUIElement] else { return }
        for axWindow in axWindows {
            guard let windowID = axWindowID(of: axWindow) else { continue }
            var minimizedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                axWindow, kAXMinimizedAttribute as CFString, &minimizedRef,
            ) == .success else { continue }
            cache[windowID] = (minimizedRef as? Bool) ?? false
        }
    }
}
#endif
