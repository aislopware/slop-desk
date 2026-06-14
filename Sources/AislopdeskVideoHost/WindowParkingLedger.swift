#if os(macOS)
import CoreGraphics

/// PURE refcount + channel→window bookkeeping for ``WindowParkingManager`` (feature #1). No AX, no
/// IPC — only the DECISIONS: when to AX-move a window onto the VD (first park), when to REUSE an
/// already-parked window (another pane, or a hello retransmit), and which window to RESTORE when its
/// last lane releases it. Kept separate so the bug-prone refcount logic is headlessly unit-tested
/// while the AX side effects stay thin in the manager.
struct WindowParkingLedger: Equatable {
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

    private(set) var parked: [CGWindowID: Parked] = [:]
    private(set) var channelWindow: [UInt32: CGWindowID] = [:]

    /// Decide a park request, applying the refcount bookkeeping for the REUSE cases. A fresh window
    /// returns `.needsMove`; the caller AX-moves it and commits via ``recordMove`` ONLY on success
    /// (so a failed move leaves no orphan record).
    mutating func park(channelID: UInt32, windowID: CGWindowID) -> ParkDecision {
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

    /// Commit a successful first move (after ``park`` returned `.needsMove`).
    mutating func recordMove(
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
    /// Idempotent: a second call for the same channelID finds no binding and returns `nil`.
    mutating func unpark(channelID: UInt32) -> RestoreTarget? {
        guard let windowID = channelWindow.removeValue(forKey: channelID), var p = parked[windowID] else { return nil }
        p.refcount -= 1
        if p.refcount <= 0 {
            parked.removeValue(forKey: windowID)
            return RestoreTarget(windowID: windowID, pid: p.pid, originalFrame: p.originalFrame)
        }
        parked[windowID] = p
        return nil
    }

    /// Drain ALL parked windows (shutdown / VD termination): return every restore target and clear
    /// all state. Idempotent (a second drain returns `[]`).
    mutating func drainAll() -> [RestoreTarget] {
        let targets = parked.map {
            RestoreTarget(windowID: $0.key, pid: $0.value.pid, originalFrame: $0.value.originalFrame)
        }
        parked.removeAll()
        channelWindow.removeAll()
        return targets
    }

    /// Number of distinct windows currently parked.
    var parkedCount: Int { parked.count }
}
#endif
