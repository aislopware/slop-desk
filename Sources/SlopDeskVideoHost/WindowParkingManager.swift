#if os(macOS)
import CoreGraphics
import Foundation
import OSLog

/// Owns the lifecycle of windows PARKED on the virtual display (feature #1). Each remoted pane moves
/// its target window onto the VD (shrunk to fit, ``WindowPlacement/moveWindowOntoDisplay``); this
/// manager remembers the window's ORIGINAL frame and puts it back when the last pane using that
/// window goes away — on pane close, daemon shutdown, or WindowServer tearing the VD down. Without
/// it the user's real window is left shrunk + stranded on the (physically invisible) VD after every
/// session.
///
/// The bug-prone refcount + channel→window bookkeeping lives in the PURE, unit-tested
/// ``WindowParkingLedger``; this @MainActor wrapper only performs the AX move/restore the ledger's
/// decisions call for. Refcounted by `CGWindowID` (the §2 asymmetry lets two panes name the SAME
/// window → moved once, restored once).
@preconcurrency
@MainActor
public final class WindowParkingManager {
    private let log = Logger(subsystem: "slopdesk.video.host", category: "WindowParking")
    private let ledger = WindowParkingLedger()

    /// C6 BUG C crash-recovery persistence hook: called with the CURRENT parked-window snapshot
    /// whenever the parked SET changes (a recorded park, a last-lane unpark, a drain), so the
    /// daemon can mirror it to the on-disk sidecar (`WindowParkingSnapshot.defaultSidecarURL`).
    /// Best-effort: unset in tests / when persistence is not wired.
    public var persistSnapshot: ((WindowParkingSnapshot) -> Void)?

    public init() {}

    /// The channelIDs currently holding a parked window (C6 BUG A: the VD-termination policy's
    /// snapshot input).
    public var parkedChannelIDs: Set<UInt32> { ledger.parkedChannelIDs }

    /// Mirror the parked set to the sidecar (only the daemon wires `persistSnapshot`).
    private func persistParkedSet() {
        persistSnapshot?(WindowParkingSnapshot(entries: ledger.sidecarEntries()))
    }

    /// Park `windowID` for `channelID` on `displayID`. If already parked (another pane / a retransmit)
    /// returns the cached achieved size without moving again. Otherwise AX-moves it onto the VD and
    /// records its original frame for restore. Returns the ACHIEVED point size to capture/ack at, or
    /// `nil` if the move failed (caller then captures the window in place at 1×). Crash-free.
    public func park(channelID: UInt32, windowID: CGWindowID, pid: pid_t, displayID: CGDirectDisplayID) -> CGSize? {
        switch ledger.park(channelID: channelID, windowID: windowID) {
        case let .reuse(size):
            return size
        case .needsMove:
            guard let result = WindowPlacement.moveWindowOntoDisplay(
                windowID: windowID,
                pid: pid,
                displayID: displayID,
            ) else { return nil } // move failed → ledger unchanged (no orphan record), 1× fallback
            ledger.recordMove(
                channelID: channelID,
                windowID: windowID,
                pid: pid,
                originalFrame: result.originalFrame,
                achievedSize: result.achievedSize,
            )
            persistParkedSet() // C6 BUG C: a new window is parked — mirror to the crash sidecar
            return result.achievedSize
        }
    }

    /// Release `channelID`'s hold; restores the window to its original frame iff this was its last
    /// lane. No-op if the channel never parked a window (1× pane) or it was already restored (e.g. by
    /// ``restoreAll``). Idempotent.
    public func unpark(channelID: UInt32) {
        guard let target = ledger.unpark(channelID: channelID) else { return }
        WindowPlacement.restoreWindow(windowID: target.windowID, pid: target.pid, toFrame: target.originalFrame)
        persistParkedSet() // C6 BUG C: a window left the parked set — mirror to the crash sidecar
    }

    /// Restore EVERY parked window to its original frame and clear all bookkeeping. Called on daemon
    /// shutdown (BEFORE the VD is destroyed, while the original display still exists) and on VD
    /// termination. Best-effort; never throws.
    public func restoreAll() {
        let targets = ledger.drainAll()
        guard !targets.isEmpty else { return }
        let count = targets.count
        log.notice("restoreAll: \(count) parked window(s)")
        for target in targets {
            WindowPlacement.restoreWindow(windowID: target.windowID, pid: target.pid, toFrame: target.originalFrame)
        }
        persistParkedSet() // C6 BUG C: the parked set drained to empty — the sidecar clears
    }

    /// The number of distinct windows currently parked (for diagnostics / tests).
    public var parkedCount: Int { ledger.parkedCount }
}
#endif
