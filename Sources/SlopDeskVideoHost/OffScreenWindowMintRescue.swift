/// MINT-TIME RESCUE for an off-screen window pick (docs/45): the host-windows rail offers
/// MINIMIZED windows and windows on another Space, but the mint path resolves a hello's
/// requestedWindowID against `SCShareableContent`'s ON-SCREEN enumeration — which can never contain
/// either — so picking one would bounce the pane straight back to the picker (`muxNoWindow`).
///
/// The rescue: find the target in the FULL enumeration, un-minimize it via AX when that is what
/// hides it (the WindowServer never paints a minimized window, so capturing one streams nothing),
/// and hand back a handle only once the restore has SETTLED. The settle gate is load-bearing:
/// capture size is locked from the minted handle's frame (`resolveCaptureSize` reads
/// `window.frame`), and the Dock restore reports intermediate animation frames with
/// `isOnScreen == true` (HW-measured: 62×136 → 757×423 → 656×422 over ~550 ms for a 656×422
/// window) — minting a mid-animation handle crops the stream to a top-left sliver of the real
/// window, permanently (the geometry watcher installs only after mint, so nothing re-targets).
///
/// PURE orchestration over injected effects — headlessly testable; the AX and SCK sides live in
/// `WindowPlacement` and the daemon.

/// Whether/how the injected un-minimize changed the target window.
public enum DeminiaturizeOutcome: Equatable, Sendable {
    /// The window was not minimized — it lives on another Space, or a restore was ALREADY animating
    /// when this hello raced it (`AXMinimized` flips false at animation START).
    case notMinimized
    /// The window WAS minimized and the AX un-minimize landed — the Dock restore is animating.
    case restoring
    /// AX could not reach or flip the window (no Accessibility grant, hung app, dead window).
    case failed
}

public enum OffScreenWindowMintRescue {
    /// Resolve `windowID` for capture after the on-screen enumeration missed it. Returns the window
    /// to mint from, or `nil` when the window is truly gone / stays hidden (the caller's terminal
    /// refusal stands). Generic over the window type so the decision tree is testable without SCK.
    public static func run<Window>(
        windowID: UInt32,
        pollAttempts: Int = 16,
        fullList: () async -> [Window]?,
        onScreenList: () async -> [Window]?,
        windowIDOf: (Window) -> UInt32,
        frameOf: (Window) -> some Equatable,
        deminiaturize: (Window) async -> DeminiaturizeOutcome,
        sleep: () async -> Void,
    ) async -> Window? {
        guard let all = await fullList(),
              let target = all.first(where: { windowIDOf($0) == windowID })
        else { return nil } // in NEITHER enumeration → the window is closed
        switch await deminiaturize(target) {
        case .notMinimized:
            // On another Space, SCK's desktop-independent window filter captures it wherever it
            // lives — but the frame may STILL be animating if a restore was already in flight when
            // this hello raced it, and an other-Space window never joins the on-screen list, so
            // the settle gate runs on the FULL enumeration.
            let settled = await settledHandle(
                windowID: windowID, pollAttempts: pollAttempts, list: fullList,
                windowIDOf: windowIDOf, frameOf: frameOf, sleep: sleep,
            )
            return settled ?? target
        case .failed:
            // Still hidden and un-restorable — a mint would stream black; refuse so the client
            // falls back to the picker instead of showing a dead pane.
            return nil
        case .restoring:
            // Wait for the window to land on the ON-SCREEN list AND for its frame to settle. A
            // restore that never lands within the budget still mints from the full-list handle —
            // its frame is the pre-minimize one, which is what the window restores to.
            let settled = await settledHandle(
                windowID: windowID, pollAttempts: pollAttempts, list: onScreenList,
                windowIDOf: windowIDOf, frameOf: frameOf, sleep: sleep,
            )
            return settled ?? target
        }
    }

    /// Poll `list` until two CONSECUTIVE sightings of `windowID` report the same frame, then return
    /// the newest handle. Budget overrun returns the last sighting (closest to settled), or `nil`
    /// when the window was never sighted at all. A failed enumeration mid-poll is skipped, not
    /// counted as a sighting.
    private static func settledHandle<Window, Frame: Equatable>(
        windowID: UInt32,
        pollAttempts: Int,
        list: () async -> [Window]?,
        windowIDOf: (Window) -> UInt32,
        frameOf: (Window) -> Frame,
        sleep: () async -> Void,
    ) async -> Window? {
        var lastSighting: (window: Window, frame: Frame)?
        for _ in 0..<pollAttempts {
            await sleep()
            guard let sighted = await list()?.first(where: { windowIDOf($0) == windowID })
            else { continue }
            let frame = frameOf(sighted)
            if let prior = lastSighting, prior.frame == frame { return sighted }
            lastSighting = (sighted, frame)
        }
        return lastSighting?.window
    }
}
