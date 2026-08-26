// KeyRepeater — the face over `slopdesk_workspace::key_repeat`, which owns the manual key-repeat
// CADENCE for the iOS hardware-keyboard path (doc 17 §2.5 — the #1 table-stake).
//
// UIKit fires `pressesBegan` / `pressesEnded` EXACTLY ONCE per physical key — it does not
// auto-repeat the way macOS `keyDown` does. Holding an arrow / Delete therefore does nothing past
// the first event unless the embedder re-emits the key itself. The re-emission SCHEDULE is a timer,
// and timers stay here; the DECISION behind each one crossed:
//
//   • which key is latched, and whether this `keyDown` supersedes it or is the same key again,
//   • whether a `keyUp` is the release of the latched key or a stale event for another one,
//   • whether a timer that just elapsed still belongs to the live latch, and what it owes: fire,
//     fire-and-start-repeating, or nothing at all.
//
// ### Why the key crosses as eight bytes of `hashValue`
//
// `Key` is generic over `Hashable`, and a generic Swift value has no C spelling. What the crate
// needs is not the key but its IDENTITY — an opaque token it can compare byte for byte — and
// `hashValue` is the only encoding available here that agrees with the TYPE'S OWN `==`: `Hashable`'s
// law is `a == b ⟹ a.hashValue == b.hashValue`. That is exactly what
// `KeyRepeaterTests.testKeyUpMatchingByIdentityNotPayloadStopsRunawayRepeat` pins — its `IdKey`
// hashes on the identity alone, so a release whose PAYLOAD differs (the modifier came up before the
// letter) still matches the held key and stops the repeat. `String(reflecting:)` would not: it would
// see the payload and let a held ⌃L flood at 20 Hz forever. The seed is per-process and the latch
// never leaves this process, so seeding is irrelevant. A 2⁻⁶⁴ collision would let one key's release
// cancel another's repeat, which the next press recovers from — the mildest failure available.
//
// ### Why the generation counter replaced the "still holding this key?" checks
//
// The original asked `heldKey == key` twice per armed timer: once in the callback, once when
// adopting the handle. A re-press of the SAME key inside the window between them adopted a second
// timer against one latch and doubled the rate. The crate hands out a never-reused generation with
// every latch instead, and both questions become "is this generation still current?" — one fact,
// asked twice, that a re-press cannot make ambiguous.
//
// ### Thread-safety
//
// `keyDown`/`keyUp`/`stop` come from the main thread (`pressesBegan`/`pressesEnded`) while the
// production `DispatchRepeatScheduler` fires its callbacks on a background serial queue. The latch
// lives behind the crate's own lock, so the handle here is one of the declared two-thread handles;
// `heldKey`/`timer` are the Swift-side mirror and keep the `NSLock` they always had. `onFire` and
// `scheduler.schedule(...)` still run OUTSIDE that lock, so a scheduler that fires synchronously —
// or an `onFire` that calls back in — cannot deadlock.

import CSlopDeskFFI
import Foundation

public final class KeyRepeater<Key: Hashable & Sendable>: @unchecked Sendable {
    /// The cadence (doc 17 §2.5: initial 350ms, then 50ms / 20Hz).
    ///
    /// The two defaults are ASKED for rather than transcribed: they are what the crate arms its
    /// timers from, and a copy that drifted would be a cadence this side had stopped applying.
    public struct Timing: Sendable, Equatable {
        public var initialDelay: Duration
        public var repeatInterval: Duration

        public init(
            initialDelay: Duration = .milliseconds(slopdesk_key_repeat_default_initial_delay_ms()),
            repeatInterval: Duration = .milliseconds(slopdesk_key_repeat_default_repeat_interval_ms()),
        ) {
            self.initialDelay = initialDelay
            self.repeatInterval = repeatInterval
        }

        public static var standard: Self { Self() }
    }

    private let scheduler: RepeatScheduler
    private let onFire: @Sendable (Key) -> Void
    /// The latch, its generation counter and the cadence — the crate's, behind its own lock.
    private let latch: OpaquePointer

    /// Guards the Swift-side mirror: the typed key the crate cannot hold, and the armed timer it
    /// does not own.
    private let lock = NSLock()
    private var heldKey: Key?
    private var timer: RepeatSchedulerHandle?

    @preconcurrency
    public init(
        timing: Timing = .standard,
        scheduler: RepeatScheduler,
        onFire: @escaping @Sendable (Key) -> Void,
    ) {
        self.scheduler = scheduler
        self.onFire = onFire
        // Never null — there is no cadence the crate can refuse; a zero wait is a caller asking for
        // a timer that fires immediately, which its own scheduler decides what to do about.
        guard let latch = slopdesk_key_repeat_new(
            UInt32(clamping: timing.initialDelay.wholeMilliseconds),
            UInt32(clamping: timing.repeatInterval.wholeMilliseconds),
        ) else { preconditionFailure("the key-repeat door answered null, which it never does") }
        self.latch = latch
    }

    /// Whether a key is currently held + repeating (diagnostics / tests).
    public var isRepeating: Bool { slopdesk_key_repeat_is_held(latch) }

    /// The key currently held, if any.
    public var currentKey: Key? {
        lock.lock()
        defer { lock.unlock() }
        return heldKey
    }

    /// A physical key went down: fire it once now, then schedule the repeat ramp.
    ///
    /// A second `keyDown` for a *different* key replaces the held key (last-key-wins, the
    /// platform behaviour: holding `→` then also pressing `←` repeats `←`). A `keyDown` for
    /// the *same* held key is idempotent — the crate answers "already latched" and neither
    /// out-param is touched, so nothing fires and no second timer is armed.
    public func keyDown(_ key: Key) {
        var latched: UInt64 = 0
        var afterMS: UInt32 = 0
        let starts = withIdentity(key) { bytes, count in
            slopdesk_key_repeat_down(latch, bytes, count, &latched, &afterMS)
        }
        guard starts else { return }
        // A `var` cannot be captured by the escaping @Sendable timer body, and the out-parameter has
        // to be one. The generation it names never moves, so the copy IS the whole value.
        let generation = latched

        lock.lock()
        let old = timer
        timer = nil
        heldKey = key
        lock.unlock()

        // Cancel + emit OUTSIDE the lock (cancel / onFire may re-enter).
        old?.cancel()
        onFire(key)
        let armed = scheduler.schedule(after: .milliseconds(Int(afterMS))) { [weak self] in
            self?.elapsed(stage: 0, generation: generation)
        }
        adopt(armed, generation: generation)
    }

    /// A physical key went up: stop repeating **iff** it is the key we are tracking. A
    /// `keyUp` for a key we are not holding (e.g. a stale event) is ignored so it cannot
    /// cancel an unrelated repeat — the crate compares the identity and says so.
    public func keyUp(_ key: Key) {
        let released = withIdentity(key) { bytes, count in
            slopdesk_key_repeat_up(latch, bytes, count)
        }
        guard released else { return }
        clearTimer()
    }

    /// Stops any active repeat (focus loss, disconnect, view teardown). Idempotent.
    public func stop() {
        guard slopdesk_key_repeat_stop(latch) else { return }
        clearTimer()
    }

    /// A timer armed under `generation` elapsed: emit what the crate says it owes, and swap the
    /// one-shot for the repeating timer when it says to.
    private func elapsed(stage: UInt8, generation: UInt64) {
        var everyMS: UInt32 = 0
        let verdict = slopdesk_key_repeat_elapsed(latch, stage, generation, &everyMS)
        // The three verdicts are ASKED for, never transcribed: a `0`/`1`/`2` spelled here would be a
        // second copy of the crate's own enum, and the copy is what drifts.
        guard verdict != UInt8(SLOPDESK_KEY_REPEAT_STALE) else { return } // the latch moved; let this timer go.
        lock.lock()
        let key = heldKey
        lock.unlock()
        guard let key else { return }
        onFire(key)
        guard verdict == UInt8(SLOPDESK_KEY_REPEAT_FIRE_AND_ARM) else { return }
        let armed = scheduler.scheduleRepeating(every: .milliseconds(Int(everyMS))) { [weak self] in
            self?.elapsed(stage: 1, generation: generation)
        }
        adopt(armed, generation: generation)
    }

    /// Adopts a freshly-scheduled handle as the live one — but only if its generation is STILL the
    /// latch's. A release (or another key's press) that landed while the arm was in flight makes it
    /// stale: cancel it and leave the live timer, set by the racer, untouched.
    ///
    /// The ASK and the assignment happen under ONE hold of the mirror's lock, and that is the whole
    /// point of the function: `keyUp` drops the latch and then calls ``clearTimer()``, which needs
    /// this same lock. Splitting the two halves would let a release land in between — the crate
    /// answers "still current", the release runs to completion finding no timer to cancel, and the
    /// assignment then installs a live 20 Hz timer nobody holds a handle to. Held together, the
    /// release either arrives first (the generation is stale → cancel here) or waits and collects
    /// exactly this handle.
    private func adopt(_ armed: RepeatSchedulerHandle, generation: UInt64) {
        lock.lock()
        guard slopdesk_key_repeat_is_current(latch, generation) else {
            lock.unlock()
            armed.cancel()
            return
        }
        timer = armed
        lock.unlock()
    }

    /// Drops the mirror and cancels the armed timer, outside the lock.
    private func clearTimer() {
        lock.lock()
        let old = timer
        timer = nil
        heldKey = nil
        lock.unlock()
        old?.cancel()
    }

    /// Lends a key's identity for exactly the call inside the closure.
    ///
    /// Eight bytes of `hashValue`, for the reason the file header gives: it is the only encoding of
    /// a generic `Hashable` that agrees with the type's own `==`.
    private func withIdentity<T>(_ key: Key, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        withUnsafeBytes(of: key.hashValue) { raw in
            body(raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count)
        }
    }

    deinit {
        lock.lock()
        let old = timer
        timer = nil
        lock.unlock()
        old?.cancel()
        slopdesk_key_repeat_free(latch)
    }
}

// MARK: - Scheduler seam

/// A cancellable scheduled-work handle.
public protocol RepeatSchedulerHandle: AnyObject, Sendable {
    func cancel()
}

/// The injectable clock the ``KeyRepeater`` schedules against. Production = GCD
/// (``DispatchRepeatScheduler``); tests = virtual time (``ManualRepeatScheduler``).
///
/// This seam is the one half of the old repeater that could NOT cross: a `DispatchSourceTimer` is
/// the platform's, and the whole point of injecting it is asserting the cadence without a wall
/// clock. What crossed is what the callbacks DECIDE; when they run is still this protocol's.
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

    public init(queue: DispatchQueue = DispatchQueue(label: "slopdesk.keyrepeat", qos: .userInteractive)) {
        self.queue = queue
    }

    @preconcurrency
    public func schedule(after delay: Duration, _ work: @escaping @Sendable () -> Void) -> RepeatSchedulerHandle {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay.timeIntervalSeconds, repeating: .infinity)
        timer.setEventHandler(handler: work)
        let handle = DispatchTimerHandle(timer: timer)
        timer.resume()
        return handle
    }

    @preconcurrency
    public func scheduleRepeating(
        every interval: Duration,
        _ work: @escaping @Sendable () -> Void,
    ) -> RepeatSchedulerHandle {
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
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        timer.cancel()
    }
}

// MARK: - Duration helpers

extension Duration {
    /// Seconds as a `TimeInterval` (for the GCD `DispatchTimeInterval` bridge).
    var timeIntervalSeconds: TimeInterval {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    /// Whole milliseconds, by integer arithmetic — the crate's cadence is a `uint32_t` count of
    /// them, and routing a wait through a `Double` to get there would round a boundary value the
    /// tests assert to the millisecond.
    var wholeMilliseconds: Int {
        let c = components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }
}
