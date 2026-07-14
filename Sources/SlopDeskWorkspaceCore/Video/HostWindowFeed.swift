import Foundation

// The HOST-WINDOWS rail's cross-platform data layer (docs/45): the mirror record + seam (the
// `RemoteWindowSummary`/`RemoteWindowDiscovery` pattern — SlopDeskClientUI never imports the gated
// video module) and the ONE `@Observable` feed store + renewal loop.
//
// PUBLICATION DISCIPLINE (docs/45 §7, the leafIdentity 3-part rule's data side): the STRUCTURAL
// array (`structure`) mutates only on membership change; VOLATILE per-window fields (title, metrics,
// state) live in per-field dictionaries leaves live-read; `frontmostWindowID` is its own property.
// An unchanged snapshot publishes nothing, so a feed tick can never invalidate a video pane.

/// One host window as the rail/pickers see it — the cross-platform mirror of the wire
/// `HostWindowRecord` (kept here so `SlopDeskClientUI` needn't depend on `SlopDeskVideoProtocol`).
public struct HostWindowInfo: Equatable, Sendable, Identifiable {
    public var windowID: UInt32
    public var bundleID: String
    public var appName: String
    public var title: String
    public var widthPt: Int
    public var heightPt: Int
    public var displayIndex: Int
    public var isOnScreen: Bool
    public var isMinimized: Bool
    public var isAppHidden: Bool
    public var isFrontmostApp: Bool
    /// The host's focused window (at most one per snapshot).
    public var isFocused: Bool
    public var id: UInt32 { windowID }

    public init(
        windowID: UInt32,
        bundleID: String,
        appName: String,
        title: String,
        widthPt: Int,
        heightPt: Int,
        displayIndex: Int = 0,
        isOnScreen: Bool = true,
        isMinimized: Bool = false,
        isAppHidden: Bool = false,
        isFrontmostApp: Bool = false,
        isFocused: Bool = false,
    ) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.widthPt = widthPt
        self.heightPt = heightPt
        self.displayIndex = displayIndex
        self.isOnScreen = isOnScreen
        self.isMinimized = isMinimized
        self.isAppHidden = isAppHidden
        self.isFrontmostApp = isFrontmostApp
        self.isFocused = isFocused
    }

    /// The row's display title — the window title, falling back to the app name (docs/45 §2).
    public var displayTitle: String { title.isEmpty ? appName : title }
}

/// One feed answer through the seam: "you're current" or a full snapshot (the mirror of the video
/// module's `WindowFeedAnswer`). `nil` from the seam = the round timed out (old host / offline).
public enum HostWindowFeedAnswer: Equatable, Sendable {
    case current(generation: UInt32)
    case snapshot(generation: UInt32, windows: [HostWindowInfo])
}

/// A live window-feed lane: fire renewals; answers — including Phase-2 PUSHES between renewals —
/// arrive on the callback given at open. `close()` releases the lane (the host's subscriber TTL
/// reaps the server side after 3 missed renewals).
@preconcurrency
@MainActor
public protocol HostWindowFeedLink: AnyObject {
    func send(knownGeneration: UInt32)
    func close()
}

/// The **window-feed seam** (docs/45): the GUI app injects the lane-opener (implemented in
/// `SlopDeskVideoClient.WindowFeedChannel`), so the cross-platform feed loop can subscribe WITHOUT
/// importing the gated video module. `nil` → the rail shows its unavailable empty state.
@preconcurrency
@MainActor
public final class HostWindowFeedQuery {
    /// App-registered lane opener (set once at launch). Args: host, mediaPort, cursorPort, and the
    /// answer sink (renewal replies AND pushes). Returns `nil` when the video pipeline is absent.
    public static var openLink: (@MainActor (
        _ host: String, _ mediaPort: UInt16, _ cursorPort: UInt16,
        _ onAnswer: @escaping @MainActor (HostWindowFeedAnswer) -> Void,
    ) -> (any HostWindowFeedLink)?)?
}

/// A window's structural identity: the `leafIdentity` key (`windowID|bundleID`)
/// plus the section key (`appName` — fixed for a window's lifetime, so structural by nature).
public struct HostWindowIdentity: Equatable, Hashable, Sendable, Identifiable {
    public var windowID: UInt32
    public var bundleID: String
    public var appName: String
    public var id: String { leafIdentity }

    /// The `.id()` key for the row leaf — memoized row content re-renders ONLY when this changes
    /// (volatile fields are live-read inside the leaf; the ca429f90 3-part rule).
    public var leafIdentity: String { "\(windowID)|\(bundleID)" }

    public init(windowID: UInt32, bundleID: String, appName: String) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.appName = appName
    }
}

/// A window's size/display metrics — volatile row data (tooltip + peek caption only).
public struct HostWindowMetrics: Equatable, Sendable {
    public var widthPt: Int
    public var heightPt: Int
    public var displayIndex: Int

    public init(widthPt: Int, heightPt: Int, displayIndex: Int) {
        self.widthPt = widthPt
        self.heightPt = heightPt
        self.displayIndex = displayIndex
    }
}

/// A window's visibility state — volatile row data (dimming + tooltip disambiguation).
public struct HostWindowState: Equatable, Sendable {
    public var isOnScreen: Bool
    public var isMinimized: Bool
    public var isAppHidden: Bool

    public init(isOnScreen: Bool, isMinimized: Bool, isAppHidden: Bool) {
        self.isOnScreen = isOnScreen
        self.isMinimized = isMinimized
        self.isAppHidden = isAppHidden
    }

    /// Whether the row renders dimmed (minimized / other Space / hidden app — docs/45 §2).
    public var isDimmed: Bool { !isOnScreen }
}

/// The ONE host-windows feed store + renewal loop (docs/45 §6–7): `@Observable` for the rail +
/// Open Quickly, lifecycle-gated by injected closures (the `SystemDialogMonitor` shape — the OWNER
/// spawns/cancels the `run()` task; gating is explicit, never `.task`-based, because SwiftUI
/// teardown across an AppKit collapse is not a contract).
@preconcurrency
@MainActor
@Observable
public final class HostWindowFeed {
    // MARK: Structural state (mutates ONLY on membership change)

    /// Window identities in first-seen order (the initial snapshot seeds in received order — host
    /// z-order; thereafter positions are FROZEN, new windows append). Stability is the UX: nothing
    /// reorders on focus flips, title churn, or refresh ticks (docs/45 §1).
    public private(set) var structure: [HostWindowIdentity] = []

    // MARK: Volatile per-window state (leaves live-read; never row init params)

    public private(set) var titles: [UInt32: String] = [:]
    public private(set) var metrics: [UInt32: HostWindowMetrics] = [:]
    public private(set) var states: [UInt32: HostWindowState] = [:]
    /// The host's focused window (`.medium` title weight on exactly one row).
    public private(set) var frontmostWindowID: UInt32?

    // MARK: Feed liveness

    /// True once any snapshot has ever applied (gates empty-state vs dimmed-stale rendering).
    public private(set) var hasEverLoaded = false
    /// True while renewals are being answered with the gates open; false while idle/disconnected/
    /// unanswered — the rail dims its cached rows and disables clicks (docs/45 §2).
    public private(set) var isLive = false

    /// The generation this client holds (0 = nothing) — renewal input, not UI state.
    @ObservationIgnored public private(set) var knownGeneration: UInt32 = 0
    /// When the last answer (renewal reply OR push) landed — the staleness signal.
    @ObservationIgnored private var lastAnswerAt: ContinuousClock.Instant?
    /// Whether any answer has landed since the current link opened (drives the fast first-answer
    /// retransmit cadence).
    @ObservationIgnored private var answeredSinceOpen = false
    /// The live lane (Phase 2: held open across renewals so pushes always have a handler).
    @ObservationIgnored private var link: (any HostWindowFeedLink)?

    // MARK: Lifecycle gates (injected — chrome flag + OQ visibility + connection)

    private let isActive: @MainActor () -> Bool
    private let isConnected: @MainActor () -> Bool
    private let target: @MainActor () -> ConnectionTarget
    /// Gap between renewals once answered (docs/45: 2 s) — injectable for deterministic tests.
    private let renewalGap: Duration
    /// Retransmit gap until the FIRST answer after a lane opens (docs/45: 500 ms).
    private let firstAnswerGap: Duration
    /// Poll gap while the gates are closed (cheap closure checks, no wire traffic).
    private let idleGap: Duration

    @preconcurrency
    public init(
        isActive: @escaping @MainActor () -> Bool,
        isConnected: @escaping @MainActor () -> Bool,
        target: @escaping @MainActor () -> ConnectionTarget = { .default },
        renewalGap: Duration = .seconds(2),
        firstAnswerGap: Duration = .milliseconds(500),
        idleGap: Duration = .milliseconds(500),
    ) {
        self.isActive = isActive
        self.isConnected = isConnected
        self.target = target
        self.renewalGap = renewalGap
        self.firstAnswerGap = firstAnswerGap
        self.idleGap = idleGap
    }

    /// Renews until the owning Task is cancelled. While the gates are open it holds ONE persistent
    /// lane (renewal replies AND pushes land on it); while closed (rail collapsed AND Open Quickly
    /// hidden, or disconnected) the lane is released and it idles WITHOUT wire traffic — a collapsed
    /// rail costs the host exactly 0 Hz (docs/45 §8) — keeping cached rows for a dimmed reveal.
    public func run() async {
        defer { closeLink() }
        while !Task.isCancelled {
            guard isActive(), isConnected(), let open = HostWindowFeedQuery.openLink else {
                closeLink()
                if isLive { isLive = false }
                try? await Task.sleep(for: idleGap)
                continue
            }
            if link == nil {
                let t = target()
                answeredSinceOpen = false
                link = open(t.host, t.mediaPort, t.cursorPort) { [weak self] answer in
                    self?.fold(answer)
                }
            }
            link?.send(knownGeneration: knownGeneration)
            try? await Task.sleep(for: answeredSinceOpen ? renewalGap : firstAnswerGap)
            // A cancelled wake-up — thrown mid-sleep OR resumed past its deadline with teardown
            // already requested — is not an elapsed renewal interval: a staleness verdict here
            // would time an interval that never ran and dim the rail on its way out.
            guard !Task.isCancelled else { break }
            noteRenewalElapsed()
        }
    }

    /// Releases the live lane (gates closed / loop cancelled). The host's subscriber TTL reaps the
    /// server side after 3 missed renewals.
    private func closeLink() {
        link?.close()
        link = nil
    }

    /// Staleness check after each renewal interval: no answer (reply or push) for two full renewal
    /// gaps ⇒ dim the rail. UDP weather loses single datagrams, not multi-second stretches.
    private func noteRenewalElapsed() {
        guard isLive, answeredSinceOpen else { return }
        let grace = renewalGap * 2 + firstAnswerGap
        if let last = lastAnswerAt, ContinuousClock.now - last > grace {
            isLive = false
        }
    }

    /// Test seam: force the liveness flag so ack-rule tests need no real timers.
    func setLiveForTesting(_ live: Bool) { isLive = live }

    /// The current connection target — the rail's peek fetch reuses the feed's own target closure
    /// (one source for host + UDP ports).
    public var connectionTarget: ConnectionTarget { target() }

    /// Folds one answer (renewal reply or push) into the store (internal for deterministic tests).
    func fold(_ answer: HostWindowFeedAnswer?) {
        guard let answer else { return }
        lastAnswerAt = ContinuousClock.now
        answeredSinceOpen = true
        switch answer {
        case let .snapshot(generation, windows):
            apply(windows, generation: generation)
        case let .current(generation):
            // The host says our generation is current. A mismatched ack (stale/duplicated datagram)
            // is NOT confirmation of what we hold — liveness only when it names OUR generation.
            if !isLive, generation == knownGeneration { isLive = true }
        }
    }

    /// Applies one complete snapshot — the diff-before-publish core. Each `@Observable` property is
    /// written ONLY when its value actually changed.
    func apply(_ windows: [HostWindowInfo], generation: UInt32) {
        knownGeneration = generation

        // STRUCTURE: survivors keep their frozen positions; new windows append in snapshot order.
        let liveIDs = Set(windows.map(\.windowID))
        var next = structure.filter { liveIDs.contains($0.windowID) }
        let known = Set(next.map(\.windowID))
        for w in windows where !known.contains(w.windowID) {
            next.append(HostWindowIdentity(windowID: w.windowID, bundleID: w.bundleID, appName: w.appName))
        }
        if next != structure { structure = next }

        // VOLATILE: whole-dictionary swaps, one write per field per snapshot, only on change.
        let nextTitles = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0.title) })
        if nextTitles != titles { titles = nextTitles }
        let nextMetrics = Dictionary(uniqueKeysWithValues: windows.map {
            ($0.windowID, HostWindowMetrics(widthPt: $0.widthPt, heightPt: $0.heightPt, displayIndex: $0.displayIndex))
        })
        if nextMetrics != metrics { metrics = nextMetrics }
        let nextStates = Dictionary(uniqueKeysWithValues: windows.map {
            ($0.windowID, HostWindowState(
                isOnScreen: $0.isOnScreen, isMinimized: $0.isMinimized, isAppHidden: $0.isAppHidden,
            ))
        })
        if nextStates != states { states = nextStates }
        let nextFrontmost = windows.first(where: \.isFocused)?.windowID
        if nextFrontmost != frontmostWindowID { frontmostWindowID = nextFrontmost }

        if !hasEverLoaded { hasEverLoaded = true }
        if !isLive { isLive = true }
    }
}
