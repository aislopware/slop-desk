// The host-window FEED glue (docs/45): Phase-1 request/reply + Phase-2 PUSH. Renewals register a
// subscriber (TTL 6 s — the lane is retired on expiry, not per answer); while ≥1 subscriber lives, a
// differ ticks at 1 Hz (4 Hz for 3 s after a structural change; 0 Hz with none), folds per the pure
// coalesce policy, and pushes snapshot chunks ×2 on every generation bump. NSWorkspace
// launch/terminate/activate events kick an immediate tick (debounced 150 ms).
//
// Enumeration is `CGWindowListCopyWindowInfo` (~2.5 ms) — NEVER `SCShareableContent` (that stays
// hello/mint-only). All pure logic (inclusion, flags, caps, generation, packing, subscribers,
// coalesce/burst) lives in `SlopDeskVideoHost/WindowFeed` and is headless-tested; this file is only
// the AppKit/CoreGraphics reads + send/retire choreography. Nothing here ever runs on the transport
// receive queue or any queue the input path touches (actor executor + main-queue AppKit reads).

import Foundation

#if os(macOS)
import AppKit
import CoreGraphics
import SlopDeskVideoHost
import SlopDeskVideoProtocol

/// The ONE minimized-state probe (docs/45 Phase 5): budgeted `AXMinimized` reads that tell a
/// MINIMIZED off-screen window from an on-another-Space one (≤3 stale pids per tick, 3 s TTL,
/// 0.25 s per-app timeout — a fleet of hung apps costs ≤0.75 s worst-tick, ~0 steady-state).
@MainActor private let minimizedProbe = MinimizedStateProbe()

/// Enumerates the host's app windows into the pure feed input shape. `@MainActor`: the AppKit reads
/// (`NSWorkspace.frontmostApplication`, `NSRunningApplication`) belong there, and one ≤ 2.5 ms
/// CGWindowList call per tick on the daemon's otherwise-idle main queue is far below any budget
/// that matters.
@MainActor
func enumerateHostWindows() -> [WindowFeedSourceWindow] {
    guard let info = CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements], kCGNullWindowID,
    ) as? [[String: Any]] else { return [] }

    let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    // Display ordinals: CGDisplayBounds is in the SAME CG global top-left space as kCGWindowBounds,
    // so max-intersection is a plain rect test (NSScreen.frame would need a y-flip — see the
    // "NSScreen reports 1×" family of traps; stay in CG space).
    var displayCount: UInt32 = 0
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount)
    let displayBounds = displayIDs.prefix(Int(displayCount)).map(CGDisplayBounds)

    // Per-PID AppKit reads cached within ONE enumeration (an app owns many windows).
    var appStates: [pid_t: (bundleID: String, isHidden: Bool)] = [:]
    func appState(for pid: pid_t) -> (bundleID: String, isHidden: Bool) {
        if let cached = appStates[pid] { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        let state = (bundleID: app?.bundleIdentifier ?? "", isHidden: app?.isHidden ?? false)
        appStates[pid] = state
        return state
    }

    var onScreen: [WindowFeedSourceWindow] = []
    var offScreen: [WindowFeedSourceWindow] = []
    var offScreenByPID: [pid_t: [UInt32]] = [:]
    for dict in info {
        guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
              let number = dict[kCGWindowNumber as String] as? UInt32,
              let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { continue }
        let isOnScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? false
        let state = appState(for: pid)
        let display = displayBounds.enumerated().max(by: {
            $0.element.intersection(bounds).area < $1.element.intersection(bounds).area
        })?.offset ?? 0
        let window = WindowFeedSourceWindow(
            windowID: number,
            ownerName: dict[kCGWindowOwnerName as String] as? String ?? "",
            bundleID: state.bundleID,
            layer: layer,
            isOnScreen: isOnScreen,
            title: dict[kCGWindowName as String] as? String ?? "",
            widthPt: Int(bounds.width.rounded()),
            heightPt: Int(bounds.height.rounded()),
            displayIndex: UInt8(clamping: display),
            isAppHidden: state.isHidden,
            isFrontmostApp: pid == frontmostPID,
            isMinimized: false, // resolved below by the budgeted AX probe
        )
        if isOnScreen { onScreen.append(window) } else {
            offScreen.append(window)
            offScreenByPID[pid, default: []].append(number)
        }
    }
    // Off-screen AX classification (Phase 5 + junk filter): the budgeted `kAXWindows` probe marks
    // which off-screen windows are MINIMIZED and which have any AX evidence of being real at all —
    // the snapshot builder drops the evidence-less ones (phantom `.optionAll` entries). Probe
    // failures leave both flags `false` (the window hides until a later sweep succeeds).
    if !offScreenByPID.isEmpty {
        let now = TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let verdicts = minimizedProbe.classify(offScreenByPID: offScreenByPID, now: now)
        for index in offScreen.indices {
            let id = offScreen[index].windowID
            offScreen[index].isMinimized = verdicts.minimized.contains(id)
            offScreen[index].isAXListed = verdicts.axListed.contains(id)
        }
    }
    minimizedProbe.retain(onlyWindowIDs: Set(onScreen.map(\.windowID) + offScreen.map(\.windowID)))
    // CGWindowList orders on-screen windows front-to-back; off-screen order is unspecified — keep
    // the z-ordered block first so the client's first seed (and the focused-window pick) is honest.
    return onScreen + offScreen
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// The ONE feed service: subscriber table + snapshot cache + differ loop + pushes, serialized on
/// this actor. Renewal retransmits, generation re-requests, and N clients are all answered from the
/// same encoded chunks — at most one enumeration per cache TTL outside the differ's own cadence.
actor WindowFeedService {
    private var cache = WindowFeedCache()
    private var subscribers = WindowFeedSubscriberTable()
    private var policy = WindowFeedPushPolicy()
    private var tickTask: Task<Void, Never>?
    private let mux: NWVideoMuxDatagramTransport

    init(mux: NWVideoMuxDatagramTransport) {
        self.mux = mux
    }

    /// Monotonic seconds (never wall clock — TTLs must survive clock changes).
    private static func nowSeconds() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Answers one `windowFeedSubscribe` on `channelID` AND registers/renews it as a push
    /// subscriber. The lane is NOT retired per answer (Phase 2) — the TTL reap retires it after 3
    /// missed renewals, so pushes between renewals ride the stamped reply flow.
    func answer(
        channelID: UInt32,
        knownGeneration: UInt32,
        answerGuard: ListAnswerGuard,
    ) async {
        defer { answerGuard.end(channelID) }
        let now = Self.nowSeconds()
        subscribers.renew(channelID, now: now)
        if cache.needsRebuild(now: now) {
            let source = await enumerateHostWindows()
            cache.fold(WindowFeedSnapshotBuilder.records(from: source), now: now)
        }
        let (isSnapshot, payloads) = cache.replyDatagrams(forKnownGeneration: knownGeneration)
        if isSnapshot {
            log(
                "answered windowFeedSubscribe on chan=\(channelID): gen=\(cache.generation) "
                    + "\(cache.records.count) windows in \(payloads.count) chunk(s)",
            )
        }
        send(payloads, to: [channelID], dup: isSnapshot)
        ensureTicking()
    }

    /// An NSWorkspace event landed (debounced by the kicker): run one immediate differ tick so a
    /// launch/quit/⌘Tab reaches subscribers in ~150 ms instead of the next 1 Hz tick.
    func kick() async {
        guard !subscribers.isEmpty else { return }
        await tick(now: Self.nowSeconds())
    }

    /// The differ loop: reap → enumerate → classify → fold-per-policy → push. Runs ONLY while ≥1
    /// subscriber lives (0 Hz with none — the loop exits and the next renewal restarts it).
    private func ensureTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard await tickOnce() else { return }
                let interval = await policy.tickInterval(now: Self.nowSeconds())
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// One loop turn. Returns `false` when the subscriber table emptied (the loop exits).
    private func tickOnce() async -> Bool {
        let now = Self.nowSeconds()
        for expired in subscribers.reapExpired(now: now) {
            mux.retire(expired)
            log("window-feed subscriber chan=\(expired) expired (3 missed renewals) — lane retired")
        }
        guard !subscribers.isEmpty else {
            tickTask = nil
            return false
        }
        await tick(now: now)
        return true
    }

    /// One differ tick: enumerate, classify against the cached records, fold when the pure policy
    /// allows (structural = now + burst; volatile = coalesce gates), push on a generation bump.
    private func tick(now: TimeInterval) async {
        let source = await enumerateHostWindows()
        let fresh = WindowFeedSnapshotBuilder.records(from: source)
        let change = WindowFeedPushPolicy.classify(old: cache.records, new: fresh)
        guard policy.shouldFold(change, now: now) else {
            // Unchanged: refresh the cache TTL so renewals keep answering without re-enumerating.
            // Gated volatile churn: do NOT fold — the coalesce gate opens on a later tick.
            if change == .none { cache.fold(fresh, now: now) }
            return
        }
        cache.fold(fresh, now: now)
        let (isSnapshot, payloads) = cache.replyDatagrams(forKnownGeneration: 0)
        guard isSnapshot else { return }
        let targets = subscribers.subscribers(now: now)
        log("window-feed push gen=\(cache.generation) → \(targets.count) subscriber(s)")
        send(payloads, to: targets, dup: true)
    }

    /// Sends `payloads` to every target lane; `dup` re-sends ~25 ms later (the `bye`/`streamCadence`
    /// loss pattern — P(loss) → P(loss)²; the client's assembler is idempotent per chunk).
    private func send(_ payloads: [Data], to channels: [UInt32], dup: Bool) {
        for channelID in channels {
            for payload in payloads {
                mux.send(payload, on: .control, channelID: channelID)
            }
        }
        guard dup else { return }
        Task { [mux] in
            try? await Task.sleep(for: .milliseconds(25))
            for channelID in channels {
                for payload in payloads {
                    mux.send(payload, on: .control, channelID: channelID)
                }
            }
        }
    }
}

/// Builds the daemon's session-LESS discovery dispatcher (docs/31 picker + docs/45
/// feed/icons/peek): ONE closure the mux receive path calls for unbound control datagrams. Owns
/// the services + the per-channel answer guard (retransmit coalescing); returns `false` for
/// anything that is not a session-less request (→ the registry's session dispatch). Every service
/// answers WITHOUT minting a capture session; the transport already stamped each request's reply
/// flow (they bootstrap like a hello).
@MainActor
func makeSessionlessDispatcher(
    mux: NWVideoMuxDatagramTransport,
) -> @Sendable (_ channelID: UInt32, _ channel: VideoChannel, _ data: Data) -> Bool {
    let listAnswerGuard = ListAnswerGuard()
    let windowFeedService = WindowFeedService(mux: mux)
    // Retained by the returned closure's capture — observes NSWorkspace for the daemon's lifetime.
    let kicker = WindowFeedKicker(service: windowFeedService)
    let appIconService = AppIconService(mux: mux)
    let windowPreviewService = WindowPreviewService(mux: mux)
    return { channelID, channel, data in
        _ = kicker
        guard channel == .control, let msg = try? VideoControlMessage.decode(data) else { return false }
        switch msg {
        case .listWindows:
            if listAnswerGuard.begin(channelID) {
                Task { await answerWindowList(channelID: channelID, mux: mux, answerGuard: listAnswerGuard) }
            }
        case .listSystemDialogs:
            if listAnswerGuard.begin(channelID) {
                Task { await answerSystemDialogList(channelID: channelID, mux: mux, answerGuard: listAnswerGuard) }
            }
        case let .windowFeedSubscribe(knownGeneration):
            // Feed renewal (docs/45): answered from the shared 1 s-TTL cache AND registered as a
            // push subscriber (TTL 6 s — Phase 2).
            if listAnswerGuard.begin(channelID) {
                Task { await windowFeedService.answer(
                    channelID: channelID, knownGeneration: knownGeneration, answerGuard: listAnswerGuard,
                ) }
            }
        case let .appIconRequest(sizePx, bundleID):
            if listAnswerGuard.begin(channelID) {
                Task { await appIconService.answer(
                    channelID: channelID, sizePx: sizePx, bundleID: bundleID, answerGuard: listAnswerGuard,
                ) }
            }
        case let .windowPreviewRequest(windowID, maxWidthPx):
            if listAnswerGuard.begin(channelID) {
                Task { await windowPreviewService.answer(
                    channelID: channelID, windowID: windowID, maxWidthPx: maxWidthPx,
                    answerGuard: listAnswerGuard,
                ) }
            }
        default:
            return false
        }
        return true
    }
}

/// Bridges NSWorkspace app-lifecycle notifications AND the frontmost app's AX window events into
/// differ kicks, debounced 150 ms (an app launch fires several notifications back-to-back; one
/// kick suffices). Phase 5: a `didActivate` also retargets the ``WindowFeedAXObserver`` so window
/// create/destroy/title/focus/miniaturize IN the frontmost app kick instantly too — the 1 Hz
/// differ stays the backstop for everything else (background apps, AX-refusing apps).
@MainActor
final class WindowFeedKicker {
    private let service: WindowFeedService
    private var pending: DispatchWorkItem?
    private var axObserver: WindowFeedAXObserver?

    init(service: WindowFeedService) {
        self.service = service
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            center.addObserver(
                self, selector: #selector(noteWorkspaceEvent(_:)), name: name, object: nil,
            )
        }
        // AX events land on the observer's dedicated thread — hop to main for the shared debounce.
        axObserver = WindowFeedAXObserver { [weak self] in
            DispatchQueue.main.async { self?.scheduleKick() }
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            axObserver?.retarget(pid: frontmost.processIdentifier)
        }
    }

    @objc
    private func noteWorkspaceEvent(_ notification: Notification) {
        // Follow the focus: the newly ACTIVATED app becomes the AX-observed one (its windows are
        // where the user is working — exactly the windows whose churn should feel instant).
        if notification.name == NSWorkspace.didActivateApplicationNotification,
           let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        {
            axObserver?.retarget(pid: app.processIdentifier)
        }
        scheduleKick()
    }

    private func scheduleKick() {
        pending?.cancel()
        let work = DispatchWorkItem { [service] in
            Task { await service.kick() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
#endif
