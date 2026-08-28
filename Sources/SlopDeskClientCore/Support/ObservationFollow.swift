// ObservationFollow — the one spelling of "re-arm on every change", for both imperative shells.
//
// `withObservationTracking(_:onChange:)` fires ONCE, so the re-arm IS the subscription: a consumer
// that forgets to re-arm gets exactly one update and then silence. docs/62 §3.1 answered that with an
// eleven-line prologue every follower copies — and 88 files across `SlopDeskMacUI` and
// `SlopDeskPhoneUI` now copy it. This type is that prologue, written once.
//
// It is NOT a de-duplication for its own sake. Three of the four load-bearing properties §3.1 names
// are, in the hand-written form, DISCIPLINE — nothing in the language stops a site from getting them
// wrong, and each is silent when it is:
//
//   1. `[weak self]` — `withObservationTracking` retains `onChange` until it fires, and the observed
//      models here are app-lifetime, so a strong capture pins a torn-down controller until the next
//      unrelated mutation. Here the owner is held weakly BY CONSTRUCTION; a call site cannot capture
//      it strongly because it never writes the capture list.
//   2. The generation guard — an in-flight wake must not re-arm tracking on a live model after
//      teardown. The counter becomes the owner's own lifetime: a wake that finds the owner gone does
//      not re-arm, so the guard cannot be one someone forgot to bump. ``stop()`` is the remaining
//      case, an owner that outlives the following. Note that the two live spellings DISAGREED about
//      whether the counter was needed at all — `MacSplitCanvasView` keeps one, the three follows in
//      `MacWorkspaceWindowController` keep none — which is itself the argument for one spelling.
//   3. Reads inside, work outside — §3.1's first hazard and the one with no symptom at all: a
//      tracked property read OUTSIDE the block does not invalidate, and a property read INSIDE it
//      that only the WORK needed silently widens the dependency set (``followTitle``'s comment in
//      `MacWorkspaceWindowController` is exactly this fear, written by hand). Splitting `read` from
//      `apply` makes the boundary a type signature: `read` returns the value, `apply` receives it and
//      is invoked OUTSIDE the tracking block, so neither mistake is expressible.
//
// The fourth — `onChange` fires BEFORE the mutation lands, so the wake must hop to the next main turn
// before reading anything — stays a mechanism rather than a signature, and lives in ``rearm()``.
//
// ⚠️ THIS IS `Observation`, NOT SWIFTUI, AND THAT IS WHY THE PRESSURE DID NOT LEAVE WITH THE VIEWS.
// Observation tracks at PROPERTY granularity: reading `dict[oneKey]` registers a dependency on the
// whole dictionary, exactly as it did under a SwiftUI `body`. Keep `read` narrow for the same reason
// a `body` was kept narrow, and keep the memo layer (``RailRowsMemo``) for the same reason it exists.

import Foundation

/// A live `withObservationTracking` subscription that re-arms itself, owned by the object it reads.
///
/// Created by ``arm(_:read:apply:)``, which performs the first read and apply synchronously before
/// returning — the arming call is itself the initial update, so a caller never writes "apply once,
/// then follow" and never gets the order wrong. (`WorkspaceRootView.swift:154`'s
/// `.onChange(of:initial: true)` is the conversion docs/62 §3.1 calls delicate for exactly that
/// ordering; here the order is not a call site's to get wrong.)
///
/// The result is discardable: the armed subscription keeps itself alive, and the owner going away
/// ends it. Keep it only to call ``stop()`` — a following that must end while its owner lives on.
@MainActor
public final class ObservationFollow {
    /// Cleared by ``stop()`` and checked by every wake. Not merely an optimisation: a wake already
    /// scheduled when `stop()` runs is still delivered, and this is what makes it a no-op rather than
    /// a re-arm against a model the owner has finished with.
    private var live = true

    /// The whole read/apply/re-arm cycle, captured once. Held here rather than rebuilt per wake so a
    /// re-arm allocates nothing.
    private var cycle: (() -> Void)?

    fileprivate init() {}

    /// Arms an observation that re-arms itself on every change, and takes the first reading now.
    ///
    /// - Parameters:
    ///   - owner: Held WEAKLY. When it goes, the following goes with it — a wake that finds it gone
    ///     returns without re-arming, so a torn-down shell never observes a live model.
    ///   - read: Runs INSIDE the tracking block. Every property read here — and only these — wakes
    ///     the follow. Return the values `apply` needs; do no work.
    ///   - apply: Runs OUTSIDE the tracking block, so its own reads register nothing. This is where
    ///     the shell touches views.
    @discardableResult
    public static func arm<Owner: AnyObject, Value>(
        _ owner: Owner,
        read: @escaping (Owner) -> Value,
        apply: @escaping (Owner, Value) -> Void,
    ) -> ObservationFollow {
        let follow = ObservationFollow()
        // WHAT KEEPS THIS ALIVE is the armed subscription itself, not the returned handle: `onChange`
        // captures `follow` STRONGLY, and `withObservationTracking` retains that closure until it
        // fires. So a caller that discards the result still follows — which is the point, because the
        // 88 hand-written sites store nothing either, and requiring a stored property at each would
        // have made the conversion a rewrite rather than a substitution.
        //
        // It is a self-reference that ENDS, three ways, which is what separates it from a leak: a wake
        // whose owner has gone does not re-arm, a `stop()` clears the cycle, and either way the
        // registry consumes its entry and drops the last reference. `cycle` itself captures both
        // sides weakly so that it is only ever the LIVE arm holding the follow up, never the stored
        // closure holding it up in a ring.
        follow.cycle = { [weak owner, weak follow] in
            guard let follow, follow.live, let owner else { return }
            var value: Value?
            withObservationTracking {
                value = read(owner)
            } onChange: {
                follow.rearm()
            }
            // Force-unwrap over a `guard`: `withObservationTracking` runs its `apply` closure
            // synchronously and exactly once, so `value` is written before this line by the same
            // contract that makes the whole idiom work. A `guard` here would compile into a silent
            // "stop following" for a case that cannot occur.
            apply(owner, value!)
        }
        follow.cycle?()
        return follow
    }

    /// Ends the following. Idempotent, and safe from inside `apply`.
    ///
    /// Needed only when the following must end while the owner lives on — a view controller detached
    /// from the hierarchy but retained, the `teardown()` the generation counter was written for.
    /// An owner that simply deallocates needs no call.
    public func stop() {
        live = false
        cycle = nil
    }

    /// The wake path, and the one place §3.1's third property lives.
    ///
    /// `onChange` fires BEFORE the mutation is applied, so reading anything on this turn reads the
    /// OLD value — hence the hop to the next main turn. `assumeIsolated` rather than a `Task` or an
    /// `await`: `DispatchQueue.main.async` has already put us on the main thread, the isolation is a
    /// fact the compiler cannot see, and a `Task` would add a suspension that lets a second mutation
    /// interleave before the first is read.
    ///
    /// The callback is delivered on whichever thread mutated the model, which is why this method — and
    /// not the closure it schedules — is what `onChange` may touch.
    private nonisolated func rearm() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.cycle?()
            }
        }
    }
}
