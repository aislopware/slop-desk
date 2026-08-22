// Phase-5 AX support for the host-window feed (docs/45 §6): instant differ kicks from the
// frontmost app's AX notifications, and the budgeted `kAXWindows` probe that (a) disambiguates
// "minimized" from "on another Space" for off-screen windows and (b) supplies the AX EVIDENCE an
// off-screen window needs to be listed at all (the phantom-window junk filter).
//
// ⚠️ **GUI + TCC ONLY** (Accessibility — the same grant the injector / geometry watcher hold).
// COMPILED + reviewed like ``WindowGeometryWatcher``; not driven from unit tests. The 1 Hz differ
// remains the mandatory backstop — AX is flaky on some apps (Electron), so every AX failure here
// degrades to "the differ catches it within a second", never to a broken feed.

#if os(macOS)
import ApplicationServices
import CSlopDeskFFI
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

/// One classification pass over the off-screen windows: which are MINIMIZED, and which have any AX
/// evidence of being real windows at all (the feed's inclusion gate).
public struct OffScreenAXClassification: Sendable {
    public var minimized: Set<UInt32> = []
    public var axListed: Set<UInt32> = []

    public init() {}
}

/// The budgeted AX probe (docs/45 Phase 5): sweeps an app's windows to tell a MINIMIZED window from
/// one on another Space, and to tell EITHER from a phantom `CGWindowList` entry that no AX sweep
/// ever returns.
///
/// Everything it decides is `slopdesk_video::ax_probe` — which pids are stale enough to sweep, what
/// a sweep proves, and what a window's absence from one means — and everything it reads is
/// `slopdesk-apple-ax`. The two meet behind ``slopdesk_ax_probe_classify``, so what is left here is
/// the handle's lifetime and the shape the feed wants back. Those rules used to be Swift and this
/// file's own header conceded they were "COMPILED + reviewed; not driven from unit tests"; they now
/// have fifteen.
public final class MinimizedStateProbe {
    private let handle: OpaquePointer?

    public init() {
        handle = slopdesk_ax_probe_new()
    }

    deinit {
        slopdesk_ax_probe_free(handle)
    }

    /// Classifies `offScreenByPID` (off-screen windowIDs grouped by owning pid), sweeping at most
    /// the budget's stale-pid quota this call; everything else answers from the ledger.
    public func classify(
        offScreenByPID: [pid_t: [UInt32]], now: TimeInterval,
    ) -> OffScreenAXClassification {
        let windows = offScreenByPID.flatMap { pid, ids in
            ids.map { SlopDeskAxOffScreen(window_id: $0, pid: pid) }
        }
        guard !windows.isEmpty else { return OffScreenAXClassification() }
        var verdicts = [SlopDeskAxVerdict](
            repeating: SlopDeskAxVerdict(window_id: 0, ax_listed: false, minimized: false),
            count: windows.count,
        )
        // One record per window asked about, so the count is known before the call and the door's
        // "report what you need" retry can never trigger. Checked anyway: a mismatch would mean the
        // door and this face disagree about what a window is, and a partial fold is worse than none.
        let written = windows.withUnsafeBufferPointer { asked in
            verdicts.withUnsafeMutableBufferPointer { out in
                slopdesk_ax_probe_classify(
                    handle, asked.baseAddress, asked.count, now, out.baseAddress, out.count,
                )
            }
        }
        guard written == windows.count else { return OffScreenAXClassification() }
        var out = OffScreenAXClassification()
        for verdict in verdicts {
            if verdict.ax_listed { out.axListed.insert(verdict.window_id) }
            if verdict.minimized { out.minimized.insert(verdict.window_id) }
        }
        return out
    }
}
#endif
