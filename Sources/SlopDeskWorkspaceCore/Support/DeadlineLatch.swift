/// One re-armable deadline: cancel whatever was pending, wait, and fire — unless something armed it
/// again or cancelled it first.
///
/// Every model in this app that shows a thing and then takes it away again owns one of these. The
/// shape is five lines and it was written out at each of them, identically:
///
/// ```swift
/// task?.cancel()
/// task = Task { [weak self] in
///     try? await Task.sleep(for: timeout)
///     guard !Task.isCancelled else { return }
///     self?.something()
/// }
/// ```
///
/// Three details in those five lines are load-bearing, and each is the kind that reads as noise
/// until the one time it is missing:
///
/// - **The cancel comes FIRST.** Arming without cancelling leaves two tasks racing the same
///   deadline, so a re-arm during a live drag stacks one timer per layout pass and the earliest of
///   them fires while the gesture is still going.
/// - **`Task.isCancelled` is checked AFTER the sleep.** `Task.sleep` throws on cancellation, but the
///   `try?` swallows that — without the check, a cancelled timer runs its body anyway, which is
///   exactly backwards.
/// - **`[weak self]` on the caller's closure.** The latch holds the task, the model holds the latch;
///   a strong capture would keep a torn-down model alive until its deadline.
///
/// The latch deliberately holds NO state a view observes. The flag a scrim or a notice reads stays
/// on the model, `private(set)` and `@Observable` as it was — this owns the timer and nothing else,
/// which is why a model can adopt it without opening its own setters.
///
/// `@MainActor` because every current owner is: a view model arming a scrim, a sidebar clearing a
/// notice. An actor-isolated variant would need its own executor and there is no caller for one.
@preconcurrency
@MainActor
public final class DeadlineLatch {
    private var task: Task<Void, Never>?

    public init() {}

    /// Cancels any pending deadline and starts a new one. `fire` runs on the main actor once
    /// `timeout` has passed, unless the latch was re-armed or cancelled in the meantime.
    @preconcurrency
    public func arm(after timeout: Duration, then fire: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            fire()
        }
    }

    /// ``arm(after:then:)`` for a deadline whose work is `async` — a retry that re-opens a socket, a
    /// settle that asks the host something.
    ///
    /// A separate overload rather than one `async` signature for both: the sync form must stay sync,
    /// because wrapping a one-line state write in an `await` adds a suspension point where the model
    /// currently has none, and a suspension is somewhere a re-arm can interleave.
    @preconcurrency
    public func arm(after timeout: Duration, then fire: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await fire()
        }
    }

    /// Cancels the pending deadline, if any. Idempotent — the ordinary case is that there is none.
    public func cancel() {
        task?.cancel()
        task = nil
    }

    // No `deinit` cancel, deliberately. A `@MainActor` class's `deinit` is not main-actor isolated,
    // so reaching `task` from it needs an `assumeIsolated` that TRAPS when the last release happens
    // off-main — a crash traded for nothing. An orphaned latch's timer fires into the caller's
    // `[weak self]` closure and finds nil, which is what the hand-written copies already did.
}
