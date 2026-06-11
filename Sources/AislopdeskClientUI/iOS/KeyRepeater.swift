import Foundation

/// Manual key-repeat for the iOS hardware-keyboard path (doc 17 §2.5 — the #1 table-stake).
///
/// UIKit fires `pressesBegan` / `pressesEnded` **exactly once** per physical key — it does
/// **not** auto-repeat the way `keyDown` does on macOS. Holding an arrow / Delete therefore
/// does nothing past the first event unless the embedder re-emits the key itself. This type
/// owns that re-emission: on ``keyDown(_:)`` it fires the key immediately, waits an
/// **initial delay (350ms)**, then re-fires every **repeat interval (50ms = 20Hz)** until
/// ``keyUp(_:)`` (or ``stop()``). The SwiftTerm/Blink-verified cadence.
///
/// ### Why a `RepeatScheduler` seam
/// The whole point is unit-testability **without real wall-clock time**. Production uses a
/// `DispatchSourceTimer` (``DispatchRepeatScheduler``); tests inject a deterministic
/// ``ManualRepeatScheduler`` and advance virtual time, asserting the exact fire cadence
/// (immediate → +350ms → +50ms → +50ms …). No `Task.sleep`, no flakiness.
///
/// The repeater itself holds no SwiftUI/UIKit type, so it compiles and is tested on macOS.
///
/// ### Thread-safety
/// `keyDown`/`keyUp`/`stop` are called from the main thread (`pressesBegan`/`pressesEnded`),
/// but the production ``DispatchRepeatScheduler`` fires its callbacks on a background serial
/// queue — and those callbacks read `heldKey` and reassign `handle`. So `heldKey`/`handle` are
/// guarded by an `NSLock` (the same pattern the handles already use). The lock is held only
/// around the state read/write; `onFire` and `scheduler.schedule(...)` run *outside* the lock
/// so a re-entrant callback (a scheduler that fires synchronously, or an `onFire` that calls
/// back in) can never deadlock.
public final class KeyRepeater<Key: Hashable & Sendable>: @unchecked Sendable {
    /// The cadence (doc 17 §2.5: initial 350ms, then 50ms / 20Hz).
    public struct Timing: Sendable, Equatable {
        public var initialDelay: Duration
        public var repeatInterval: Duration

        public init(initialDelay: Duration = .milliseconds(350), repeatInterval: Duration = .milliseconds(50)) {
            self.initialDelay = initialDelay
            self.repeatInterval = repeatInterval
        }

        public static var standard: Timing { Timing() }
    }

    private let timing: Timing
    private let scheduler: RepeatScheduler
    private let onFire: @Sendable (Key) -> Void

    /// Guards `heldKey` + `handle` against the cross-thread access described in the type doc
    /// (main-thread key events vs. the background-queue scheduler callbacks).
    private let lock = NSLock()
    /// The key currently held + repeating, if any. Holding a *new* key supersedes the old.
    private var heldKey: Key?
    private var handle: RepeatSchedulerHandle?

    public init(
        timing: Timing = .standard,
        scheduler: RepeatScheduler,
        onFire: @escaping @Sendable (Key) -> Void
    ) {
        self.timing = timing
        self.scheduler = scheduler
        self.onFire = onFire
    }

    /// Whether a key is currently held + repeating (diagnostics / tests).
    public var isRepeating: Bool {
        lock.lock(); defer { lock.unlock() }
        return heldKey != nil
    }

    /// The key currently held, if any.
    public var currentKey: Key? {
        lock.lock(); defer { lock.unlock() }
        return heldKey
    }

    /// A physical key went down: fire it once now, then schedule the repeat ramp.
    ///
    /// A second `keyDown` for a *different* key replaces the held key (last-key-wins, the
    /// platform behaviour: holding `→` then also pressing `←` repeats `←`). A `keyDown` for
    /// the *same* held key is idempotent (the timer is already running).
    public func keyDown(_ key: Key) {
        lock.lock()
        if heldKey == key { lock.unlock(); return } // already repeating this key.
        let old = handle
        handle = nil
        heldKey = key
        lock.unlock()

        // Cancel + emit OUTSIDE the lock (cancel / onFire may re-enter).
        old?.cancel()
        onFire(key)
        scheduleInitial(for: key)
    }

    /// A physical key went up: stop repeating **iff** it is the key we are tracking. A
    /// `keyUp` for a key we are not holding (e.g. a stale event) is ignored so it cannot
    /// cancel an unrelated repeat.
    public func keyUp(_ key: Key) {
        lock.lock()
        let matches = (heldKey == key)
        lock.unlock()
        guard matches else { return }
        stop()
    }

    /// Stops any active repeat (focus loss, disconnect, view teardown). Idempotent.
    public func stop() {
        lock.lock()
        let old = handle
        handle = nil
        heldKey = nil
        lock.unlock()
        old?.cancel()
    }

    /// Reads the currently-held key under the lock (the scheduler-callback liveness check).
    private func currentlyHeld() -> Key? {
        lock.lock(); defer { lock.unlock() }
        return heldKey
    }

    private func scheduleInitial(for key: Key) {
        let h = scheduler.schedule(after: timing.initialDelay) { [weak self] in
            guard let self, self.currentlyHeld() == key else { return }
            self.onFire(key)
            self.scheduleRepeat(for: key)
        }
        store(h, ifStillHolding: key)
    }

    private func scheduleRepeat(for key: Key) {
        let h = scheduler.scheduleRepeating(every: timing.repeatInterval) { [weak self] in
            guard let self, self.currentlyHeld() == key else { return }
            self.onFire(key)
        }
        store(h, ifStillHolding: key)
    }

    /// Adopts a freshly-scheduled handle as the live one — but only if `key` is still held.
    /// If a `keyUp`/`keyDown`(other) raced in between, the new handle is stale: cancel it and
    /// leave the live `handle` (set by the racer) untouched.
    private func store(_ newHandle: RepeatSchedulerHandle, ifStillHolding key: Key) {
        lock.lock()
        if heldKey == key {
            handle = newHandle
            lock.unlock()
        } else {
            lock.unlock()
            newHandle.cancel()
        }
    }

    deinit {
        lock.lock()
        let old = handle
        handle = nil
        lock.unlock()
        old?.cancel()
    }
}

// MARK: - Scheduler seam

/// A cancellable scheduled-work handle.
public protocol RepeatSchedulerHandle: AnyObject, Sendable {
    func cancel()
}

/// The injectable clock the ``KeyRepeater`` schedules against. Production = GCD
/// (``DispatchRepeatScheduler``); tests = virtual time (``ManualRepeatScheduler``).
public protocol RepeatScheduler: Sendable {
    /// Runs `work` once after `delay`. Returns a handle that cancels it if it hasn't fired.
    func schedule(after delay: Duration, _ work: @escaping @Sendable () -> Void) -> RepeatSchedulerHandle
    /// Runs `work` repeatedly every `interval` (first fire after one `interval`). The
    /// returned handle cancels the repeating timer.
    func scheduleRepeating(every interval: Duration, _ work: @escaping @Sendable () -> Void) -> RepeatSchedulerHandle
}

// MARK: - Production scheduler (DispatchSourceTimer)

/// GCD-backed ``RepeatScheduler``. The doc-17 §2.5 mandate is "`DispatchSourceTimer`": each
/// scheduled item is a one-shot / repeating `DispatchSourceTimer` on a serial queue, so the
/// repeat fires on a consistent thread the embedder can hop to the main actor from.
public final class DispatchRepeatScheduler: RepeatScheduler, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "aislopdesk.keyrepeat", qos: .userInteractive)) {
        self.queue = queue
    }

    public func schedule(after delay: Duration, _ work: @escaping @Sendable () -> Void) -> RepeatSchedulerHandle {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay.timeIntervalSeconds, repeating: .infinity)
        timer.setEventHandler(handler: work)
        let handle = DispatchTimerHandle(timer: timer)
        timer.resume()
        return handle
    }

    public func scheduleRepeating(every interval: Duration, _ work: @escaping @Sendable () -> Void) -> RepeatSchedulerHandle {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval.timeIntervalSeconds, repeating: interval.timeIntervalSeconds)
        timer.setEventHandler(handler: work)
        let handle = DispatchTimerHandle(timer: timer)
        timer.resume()
        return handle
    }
}

private final class DispatchTimerHandle: RepeatSchedulerHandle, @unchecked Sendable {
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var cancelled = false

    init(timer: DispatchSourceTimer) { self.timer = timer }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        timer.cancel()
    }
}

// MARK: - Duration helper

extension Duration {
    /// Seconds as a `TimeInterval` (for the GCD `DispatchTimeInterval` bridge).
    var timeIntervalSeconds: TimeInterval {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
