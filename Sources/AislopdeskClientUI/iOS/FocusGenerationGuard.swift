import Foundation

/// The pure, value-typed generation counter that defeats the iOS first-responder race
/// (docs/22 §7 — first-responder coordination).
///
/// On iPad-regular, more than one ``TerminalInputHost`` is mounted at once, so switching the
/// focused pane means *resigning* one `IMEProxyTextView` and *making another* the first
/// responder. UIKit's `becomeFirstResponder` is honoured asynchronously (a runloop hop later),
/// so two rapid focus changes (A→B→C, or a stale `makeUIView` `DispatchQueue.main.async` claim)
/// can land **out of order**: a late callback for an already-superseded pane steals focus back,
/// leaving the wrong terminal receiving keystrokes — the classic "I typed into the pane I just
/// left" bug. There is no generation counter in ``TerminalInputHost`` today.
///
/// This guard is the deterministic core of the fix: a monotonically increasing token stamped at
/// the moment a focus change is *requested*. Each pending `becomeFirstResponder` callback captures
/// the token it was issued under and, before acting, asks ``isCurrent(_:)`` — a callback minted at
/// an older generation is simply dropped. The same shape as ``FloatingCursorMapping``: no UIKit,
/// no actor, fully `Sendable`, and unit-tested on macOS so the race logic is assertable without a
/// device. The UIKit wiring lives in ``PaneFocusCoordinator``.
///
/// ### Contract
/// - ``begin()`` bumps the generation and returns the **new current** token. The very first
///   `begin()` returns `1` (the initial state is generation `0`, which no real callback is ever
///   issued under, so a pre-begin token is never "current").
/// - ``isCurrent(_:)`` is `true` **only** for the exact latest token handed out by `begin()`.
///   Every older token — including `0` — is stale and returns `false`.
/// - A rapid `begin()` sequence keeps only the latest token current; all prior ones are rejected.
public struct FocusGenerationGuard: Sendable, Equatable {
    /// The current generation. Starts at `0` (a sentinel no callback is issued under); every
    /// ``begin()`` increments it. Exposed read-only for diagnostics / tests.
    public private(set) var generation: Int = 0

    public init() {}

    /// Opens a new focus generation: bumps the counter and returns the new current token.
    ///
    /// Call this when a focus change is *requested* (synchronously, before scheduling the async
    /// `becomeFirstResponder`); hand the returned token to the pending callback so it can later
    /// verify it has not been superseded via ``isCurrent(_:)``.
    public mutating func begin() -> Int {
        generation += 1
        return generation
    }

    /// Whether `token` is the latest generation handed out by ``begin()``.
    ///
    /// Returns `false` for any earlier token (a superseded, in-flight callback) AND for the `0`
    /// sentinel even before any `begin()` (no real callback is ever issued under generation `0`), so a
    /// stale `becomeFirstResponder` callback is rejected and never steals focus.
    public func isCurrent(_ token: Int) -> Bool {
        token != 0 && token == generation
    }
}
