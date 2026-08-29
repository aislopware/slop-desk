// OverlayDwell — a toast card's countdown, spent the same way on both platforms.
//
// A timed notification leaves on its own after ``ToastPresentation/dwellSeconds(_:)``. Both shells wrote
// that as the same ladder: zero the spend, ask the presentation for the total, bail on a sticky card,
// then SAMPLE at ``ToastPresentation/dwellTick`` until the spend reaches the total.
//
// ⚠️ SAMPLED RATHER THAN ONE TIMER OF `total`, and the reason is a platform difference the two halves
// must nonetheless spend identically. The Mac FREEZES a card's clock under the pointer — a notification
// can no longer be yanked away mid-read — and a single `Timer(total)` has nothing to freeze. The phone
// has no hover event at all, so its ``isFrozen`` is the default and never true; the clock it spends is
// still the same clock, which is what stops a card from meaning "four seconds" on one device and
// "four seconds unless you look at it" on the other.
//
// ⚠️ THE TIMER HOLDS THIS OBJECT WEAKLY AND THE FIRST ORPHANED TICK RETIRES ITSELF. A scheduled `Timer`
// is retained by the run loop, so a strong capture would keep a dead card's countdown alive to the end
// of its dwell — and the closure that fires would be pointed at a view that has left the window. A weak
// one inverts the problem: the block would go on firing into nothing forever. So the tick that finds its
// owner gone invalidates the timer FROM INSIDE, which costs at most one 0.1s sample and needs no
// `deinit` — this type is `@MainActor` and a `deinit` is not, so a `deinit` here could not touch the
// timer at all without an isolation hop that a dealloc has no way to take. The card that owns one
// therefore needs no `deinit` of its own either, which is one more line off both shells.
//
// NOTHING DRAWS THE SPEND. An earlier round put a depleting hairline along the card's bottom edge and it
// was cut for reading as ornament; the pause is behaviour, not decoration.

import Foundation

/// One toast card's countdown: restartable, freezable, and dead the moment its owner is.
@preconcurrency
@MainActor
public final class OverlayDwell {
    /// Whether the clock is currently HELD. The Mac's pointer rest; never true on a touch device.
    public var isFrozen: () -> Bool = { false }
    /// What a fully spent dwell does — dismiss the toast. Set by the card that owns the countdown.
    public var onExpire: () -> Void = {}

    /// Dwell CONSUMED, in seconds.
    private var spent: Double = 0
    private var timer: Timer?

    public init() {}

    /// Starts (or restarts) the countdown for `toast`. A sticky card — `autoDismiss == nil` — gets no
    /// timer at all, which is also why its ✕ is unconditional.
    public func restart(for toast: Toast) {
        stop()
        spent = 0
        let total = ToastPresentation.dwellSeconds(toast)
        guard total > 0 else { return }
        // ⚠️ THE `Timer` STAYS OUTSIDE THE ISOLATED BLOCK. `Timer` is not `Sendable`, so handing the
        // tick's own argument INTO `assumeIsolated` is a compile error rather than a style question —
        // the block answers whether the countdown is still running and the retirement happens out here.
        timer = Timer.scheduledTimer(
            withTimeInterval: ToastPresentation.dwellTick, repeats: true,
        ) { [weak self] tick in
            let running = MainActor.assumeIsolated { self?.advance(to: total) ?? false }
            guard !running else { return }
            tick.invalidate()
        }
    }

    /// Spends one sample, answering whether the countdown is still running.
    ///
    /// A frozen clock still counts as running: the pointer will move off eventually, and a card whose
    /// timer had been retired under it would then never leave at all.
    private func advance(to total: Double) -> Bool {
        guard !isFrozen() else { return true }
        spent = Swift.min(total, spent + ToastPresentation.dwellTick)
        guard spent >= total else { return true }
        stop()
        onExpire()
        return false
    }

    /// Stops the countdown. Idempotent, and called on teardown so no timer outlives its card.
    public func stop() {
        timer?.invalidate()
        timer = nil
    }
}
