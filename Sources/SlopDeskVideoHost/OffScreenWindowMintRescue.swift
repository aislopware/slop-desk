/// MINT-TIME RESCUE for an off-screen window pick (docs/45): the host-windows rail offers
/// MINIMIZED windows and windows on another Space, but the mint path resolves a hello's
/// requestedWindowID against `SCShareableContent`'s ON-SCREEN enumeration — which can never contain
/// either — so picking one would bounce the pane straight back to the picker (`muxNoWindow`).
///
/// The rescue: find the target in the FULL enumeration, un-minimize it via AX when that is what
/// hides it (the WindowServer never paints a minimized window, so capturing one streams nothing),
/// and wait briefly for it to land on-screen before minting. PURE orchestration over injected
/// effects — headlessly testable; the AX and SCK sides live in `WindowPlacement` and the daemon.

/// Whether/how the injected un-minimize changed the target window.
public enum DeminiaturizeOutcome: Equatable, Sendable {
    /// The window was not minimized (e.g. it lives on another Space) — nothing to undo.
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
        pollAttempts: Int = 12,
        fullList: () async -> [Window]?,
        onScreenList: () async -> [Window]?,
        windowIDOf: (Window) -> UInt32,
        deminiaturize: (Window) async -> DeminiaturizeOutcome,
        sleep: () async -> Void,
    ) async -> Window? {
        guard let all = await fullList(),
              let target = all.first(where: { windowIDOf($0) == windowID })
        else { return nil } // in NEITHER enumeration → the window is closed
        switch await deminiaturize(target) {
        case .notMinimized:
            // On another Space (or it landed on-screen since the miss): SCK's desktop-independent
            // window filter captures it wherever it lives — mint from the full-list handle as-is.
            return target
        case .failed:
            // Still hidden and un-restorable — a mint would stream black; refuse so the client
            // falls back to the picker instead of showing a dead pane.
            return nil
        case .restoring:
            // The Dock restore animates for a few hundred ms. Prefer the freshly ON-SCREEN handle
            // (its frame is live again, so the VD-park/resize math starts from truth); a restore
            // slower than the poll budget still mints from the full-list handle — the un-minimize
            // already landed, and the capturer re-resolves off-screen windows itself.
            for _ in 0..<pollAttempts {
                await sleep()
                if let landed = await onScreenList()?.first(where: { windowIDOf($0) == windowID }) {
                    return landed
                }
            }
            return target
        }
    }
}
