import CoreGraphics
import CSlopDeskFFI

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
/// This file is the FACE of `slopdesk-video`'s `mint_rescue`, and it performs effects rather than
/// deciding anything. Every effect the rescue needs suspends — two `SCShareableContent`
/// enumerations, an AX call that hops to the MainActor, a sleep — and no C ABI can call back into
/// that and wait, so the decision tree does not take these closures: it names ONE step at a time and
/// this loop performs it. The two handles that could be minted stay here, because a window handle
/// is an `SCWindow` and has no business crossing; the far side names WHICH, never which one.

/// Whether/how the injected un-minimize changed the target window.
public enum DeminiaturizeOutcome: Equatable, Sendable {
    /// The window was not minimized — it lives on another Space, or a restore was ALREADY animating
    /// when this hello raced it (`AXMinimized` flips false at animation START).
    case notMinimized
    /// The window WAS minimized and the AX un-minimize landed — the Dock restore is animating.
    case restoring
    /// AX could not reach or flip the window (no Accessibility grant, hung app, dead window).
    case failed

    /// The code this outcome crosses under.
    var code: UInt32 {
        switch self {
        case .notMinimized: SLOPDESK_MINT_NOT_MINIMIZED
        case .restoring: SLOPDESK_MINT_RESTORING
        case .failed: SLOPDESK_MINT_FAILED
        }
    }
}

public enum OffScreenWindowMintRescue {
    /// Resolve `windowID` for capture after the on-screen enumeration missed it. Returns the window
    /// to mint from, or `nil` when the window is truly gone / stays hidden (the caller's terminal
    /// refusal stands). Generic over the window type so the effects are injectable without SCK.
    public static func run<Window>(
        windowID: UInt32,
        pollAttempts: Int = 16,
        fullList: () async -> [Window]?,
        onScreenList: () async -> [Window]?,
        windowIDOf: (Window) -> UInt32,
        frameOf: (Window) -> CGRect,
        deminiaturize: (Window) async -> DeminiaturizeOutcome,
        sleep: () async -> Void,
    ) async -> Window? {
        var rescue = slopdesk_mint_rescue_begin(UInt32(Swift.max(0, pollAttempts)))
        // The two handles the far side may name. It never sees either — only which one.
        var target: Window?
        var sighted: Window?

        while true {
            switch rescue.step {
            case SLOPDESK_MINT_STEP_FULL_LIST:
                let everything = await fullList()
                target = pick(windowID, in: everything, windowIDOf)
                rescue = report(rescue, target, frameOf)

            case SLOPDESK_MINT_STEP_DEMINIATURIZE:
                // The step is only ever named after a sighting, so there is a target to flip; an
                // absent one is refused rather than assumed away.
                guard let target else { return nil }
                let outcome = await deminiaturize(target)
                rescue = slopdesk_mint_rescue_advance(
                    rescue, SLOPDESK_MINT_SAW_DEMINIATURIZE, outcome.code, 0, 0, 0, 0,
                )

            case SLOPDESK_MINT_STEP_POLL_FULL,
                 SLOPDESK_MINT_STEP_POLL_ON_SCREEN:
                // One sleep before every poll — the AX write needs time to paint.
                await sleep()
                let onScreen = rescue.step == SLOPDESK_MINT_STEP_POLL_ON_SCREEN
                let list = onScreen ? await onScreenList() : await fullList()
                let seen = pick(windowID, in: list, windowIDOf)
                if seen != nil { sighted = seen }
                rescue = report(rescue, seen, frameOf)

            case SLOPDESK_MINT_STEP_MINT_TARGET:
                return target

            case SLOPDESK_MINT_STEP_MINT_SIGHTED:
                return sighted

            default:
                // `SLOPDESK_MINT_STEP_REFUSE`, and any step this build does not know — both mint
                // nothing, which is the answer that leaves the caller's refusal standing.
                return nil
            }
        }
    }

    /// The target in one enumeration, where a FAILED enumeration and one that simply lacks it are
    /// the same answer: nothing was seen.
    private static func pick<Window>(
        _ windowID: UInt32,
        in list: [Window]?,
        _ windowIDOf: (Window) -> UInt32,
    ) -> Window? {
        list?.first { windowIDOf($0) == windowID }
    }

    /// Report what an enumeration showed. A sighting carries its frame, which the far side compares
    /// for equality and never interprets.
    private static func report<Window>(
        _ rescue: SlopDeskMintRescue,
        _ seen: Window?,
        _ frameOf: (Window) -> CGRect,
    ) -> SlopDeskMintRescue {
        guard let seen else {
            return slopdesk_mint_rescue_advance(rescue, SLOPDESK_MINT_SAW_NOTHING, 0, 0, 0, 0, 0)
        }
        let frame = frameOf(seen)
        return slopdesk_mint_rescue_advance(
            rescue, SLOPDESK_MINT_SAW_WINDOW, 0,
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
        )
    }
}
