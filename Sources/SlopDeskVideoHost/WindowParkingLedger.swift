#if os(macOS)
import CoreGraphics
import OSLog

/// PURE refcount + channel→window bookkeeping for ``WindowParkingManager`` (feature #1). No AX, no
/// IPC — only the DECISIONS: when to AX-move a window onto the VD (first park), when to REUSE an
/// already-parked window (another pane, or a hello retransmit), and which window to RESTORE when its
/// last lane releases it. Kept separate so the bug-prone refcount logic is headlessly unit-tested
/// while the AX side effects stay thin in the manager.
///
/// Native Swift, the single source of truth. It is a `final class` (not the former value struct) so
/// the single ``WindowParkingManager`` owner holds it by reference (`private let ledger`) without a
/// `let`→`var` ripple. It is singly owned by the `@MainActor` ``WindowParkingManager`` and never
/// value-compared / copied, so no value semantics are lost by holding it as a reference.
final class WindowParkingLedger {
    /// A window parked on the VD: the frame to restore to, the achieved on-VD size to capture at,
    /// and how many lanes currently hold it.
    struct Parked: Equatable {
        var pid: pid_t
        var originalFrame: CGRect
        var achievedSize: CGSize
        var refcount: Int
    }

    /// A window that must be AX-restored (its last lane just released it, or a drain).
    struct RestoreTarget: Equatable {
        var windowID: CGWindowID
        var pid: pid_t
        var originalFrame: CGRect
    }

    enum ParkDecision: Equatable {
        /// Already parked — the refcount is bumped (or unchanged for a same-lane retransmit); the
        /// caller just captures at this size, no AX move.
        case reuse(CGSize)
        /// First park of this window — the caller AX-moves it, then commits via ``recordMove``.
        case needsMove
    }

    private var parked: [CGWindowID: Parked] = [:]
    private var channelWindow: [UInt32: CGWindowID] = [:]
    private let log = Logger(subsystem: "slopdesk.video.host", category: "WindowParking")

    /// A restore obligation `park(channelID:windowID:)` produced from a RETARGET (the channel already
    /// held a DIFFERENT windowID) that the caller has not yet drained via
    /// ``takePendingRetargetRestore()``. `ParkDecision`'s shape is unchanged (source-compatible with
    /// existing callers); a caller that wants retarget-restore support opts in by polling this right
    /// after `park` — one at a time is sufficient since `park` is called serially per request.
    private var pendingRetargetRestore: RestoreTarget?

    init() {}

    /// Decide a park request, applying the refcount bookkeeping for the REUSE cases. A fresh window
    /// returns `.needsMove`; the caller AX-moves it and commits via ``recordMove`` ONLY on success
    /// (so a failed move leaves no orphan record). If `channelID` already held a DIFFERENT windowID
    /// (a retarget), that old binding is released FIRST — mirroring `unpark`'s decrement/restore-target
    /// bookkeeping exactly — so its refcount never over-counts and strands it parked forever; the
    /// released target (if this was its last lane) is queued for ``takePendingRetargetRestore()`` so
    /// the caller can AX-restore it, the same way an `unpark`-produced target is handled.
    func park(channelID: UInt32, windowID: CGWindowID) -> ParkDecision {
        if let existing = channelWindow[channelID], existing != windowID {
            log.notice("park: channel \(channelID) retargeted window \(existing) -> \(windowID)")
            pendingRetargetRestore = releaseHold(channelID: channelID, windowID: existing)
        }
        // Same lane re-parking the same window (UDP hello retransmit / re-mint) — never double-count.
        if channelWindow[channelID] == windowID, let p = parked[windowID] {
            return .reuse(p.achievedSize)
        }
        // Another lane already parked this window — share it (one move, refcounted restore).
        if var p = parked[windowID] {
            p.refcount += 1
            parked[windowID] = p
            channelWindow[channelID] = windowID
            return .reuse(p.achievedSize)
        }
        return .needsMove
    }

    /// Drains (and clears) the restore obligation the MOST RECENT ``park(channelID:windowID:)`` call
    /// produced from a retarget, if any. Returns `nil` on every ordinary (non-retargeting) park.
    func takePendingRetargetRestore() -> RestoreTarget? {
        defer { pendingRetargetRestore = nil }
        return pendingRetargetRestore
    }

    /// Release `channelID`'s hold on `windowID`: removes the channel binding UNCONDITIONALLY FIRST,
    /// decrements the refcount, and — iff this was the last lane — removes the parked record and
    /// returns its `RestoreTarget`. Shared by ``unpark(channelID:)`` and the retarget path in
    /// ``park(channelID:windowID:)`` so both release a hold identically.
    private func releaseHold(channelID: UInt32, windowID: CGWindowID) -> RestoreTarget? {
        channelWindow.removeValue(forKey: channelID)
        guard var p = parked[windowID] else { return nil }
        p.refcount -= 1
        if p.refcount <= 0 {
            parked.removeValue(forKey: windowID)
            return RestoreTarget(windowID: windowID, pid: p.pid, originalFrame: p.originalFrame)
        }
        parked[windowID] = p
        return nil
    }

    /// Commit a successful first move (after ``park`` returned `.needsMove`). NOTE: a plain
    /// dictionary assignment — it OVERWRITES any existing `parked[windowID]`, RESETTING refcount to
    /// 1 (it does NOT accumulate).
    func recordMove(
        channelID: UInt32,
        windowID: CGWindowID,
        pid: pid_t,
        originalFrame: CGRect,
        achievedSize: CGSize,
    ) {
        parked[windowID] = Parked(pid: pid, originalFrame: originalFrame, achievedSize: achievedSize, refcount: 1)
        channelWindow[channelID] = windowID
    }

    /// Release `channelID`'s hold; returns the window to RESTORE iff its last lane just released it.
    /// The channel binding is removed UNCONDITIONALLY FIRST, THEN `parked` is consulted — so an
    /// unknown channel, or a channel whose window is no longer parked, both return `nil` with the
    /// binding already gone. Idempotent.
    func unpark(channelID: UInt32) -> RestoreTarget? {
        guard let windowID = channelWindow[channelID] else { return nil }
        return releaseHold(channelID: channelID, windowID: windowID)
    }

    /// Drain ALL parked windows (shutdown / VD termination): return one restore target per DISTINCT
    /// parked window and clear all state. Idempotent (a second drain returns `[]`). The order is
    /// `Dictionary`'s unspecified iteration order; not load-bearing (each target is AX-restored
    /// independently).
    func drainAll() -> [RestoreTarget] {
        let targets = parked.map {
            RestoreTarget(windowID: $0.key, pid: $0.value.pid, originalFrame: $0.value.originalFrame)
        }
        parked.removeAll()
        channelWindow.removeAll()
        return targets
    }

    /// Number of distinct windows currently parked.
    var parkedCount: Int { parked.count }

    /// The channelIDs currently holding a parked window (C6 BUG A: the VD-termination policy's
    /// "which lanes parked onto the dead VD" snapshot input).
    var parkedChannelIDs: Set<UInt32> { Set(channelWindow.keys) }

    /// One crash-recovery sidecar entry per DISTINCT parked window (C6 BUG C), sorted by windowID
    /// for a stable on-disk file. Refcount is deliberately dropped — a next-launch restore puts
    /// each window back exactly once.
    func sidecarEntries() -> [WindowParkingSnapshot.Entry] {
        parked
            .map { WindowParkingSnapshot.Entry(
                windowID: UInt32($0.key),
                pid: Int32($0.value.pid),
                originalFrame: $0.value.originalFrame,
            ) }
            .sorted { $0.windowID < $1.windowID }
    }
}
#endif
