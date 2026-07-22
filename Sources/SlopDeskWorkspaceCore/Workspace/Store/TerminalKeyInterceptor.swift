// TerminalKeyInterceptor — the PURE, headless brain the per-surface key paths (WS-B / B4·B5·B6·B7) consult
// BEFORE their own raw-byte branches. It is the single source of truth shared by every first-responder that
// can swallow a keystroke ahead of the terminal/video pipeline:
//
//   • B4/B5  GhosttyLayerBackedView.keyDown   (the libghostty terminal surface — NOT in `swift build`)
//   • B6     MetalLayerBackedView.keyDown      (the remote-video surface — gated SlopDeskVideoClient)
//   • B7     the iOS UIKit pressesBegan path   (InputRouting/KeyEncoding — never type-checked by macOS build)
//
// The app-level `WorkspaceKeyDispatcher` (B3) is the PRIMARY interceptor (its `.keyDown` monitor fires
// BEFORE any first responder). This type is the belt-and-suspenders layer for when one of those views IS the
// first responder and the monitor is bypassed (e.g. a focused libghostty surface that handles the event in
// its own `keyDown`). To avoid two layers DOUBLE-routing the same chord, an interceptor instance is only
// armed where the B3 monitor is NOT installed (iOS has no `NSEvent` monitor; the macOS surfaces consult it
// only as a fallback) — the policy is documented at each call site.
//
// PURITY: this file imports only Foundation. It resolves the SINGLE-CHORD workspace table (the
// override-aware `resolvedChordTable`, so B5's ⌘D/⌘⇧D split is resolved here rather than hard-coded, and a
// rebind takes effect) into ONE `Disposition` the view maps to swallow / forward. The view does NOTHING but
// (a) map its native event → `KeyChord` and (b) act on the returned `Disposition`. No table knowledge and
// no AppKit/UIKit live in the view. (The tmux-style multi-key PREFIX engine that used to live here is
// REMOVED — DECISIONS.md 2026-07-22: the ⌘ plane is the only workspace-chord surface.)

import Foundation

/// What a per-surface key path must DO with one keystroke, decided entirely here so the view stays a thin
/// event→intent shim. A pure value type (no AppKit/UIKit) so the whole interceptor is unit-testable.
public enum TerminalKeyDisposition: Equatable, Sendable {
    /// Not a workspace chord — the view runs its OWN normal path (libghostty encoder, the Ctrl+C0 raw-byte
    /// branch, the iOS key encoder, …). Carries the chord back unchanged for convenience.
    case forward(KeyChord)
    /// SWALLOW the key: it resolved+dispatched a workspace action. The view forwards NOTHING (and — for
    /// press/release symmetric paths — must suppress the matching release too).
    case swallow
}

/// The PURE single-chord interceptor every per-surface key path consults. Resolves chords against the
/// override-aware ``WorkspaceBindingRegistry/resolvedChordTable`` (injected) so a rebind (B5) takes effect
/// with no view change.
///
/// `@MainActor` (it drives the store-bound `onAction` sink) — the view paths it serves are all already
/// main-actor. Headless: nothing here touches AppKit/UIKit/Metal.
@preconcurrency
@MainActor
public final class TerminalKeyInterceptor {
    /// Resolve a chord to its workspace action, or `nil` to let it fall through. Injected so the
    /// interceptor stays pure; the live wiring passes a lookup over ``resolvedChordTable``.
    private let resolveChord: (KeyChord) -> WorkspaceAction?

    /// Run a resolved action (the store-bound `WorkspaceBindingRegistry.route(...)` sink). Injected.
    private let onAction: (WorkspaceAction) -> Void

    public init(
        resolveChord: @escaping (KeyChord) -> WorkspaceAction? = { WorkspaceBindingRegistry.resolvedChordTable[$0] },
        onAction: @escaping (WorkspaceAction) -> Void,
    ) {
        self.resolveChord = resolveChord
        self.onAction = onAction
    }

    /// Fold ONE keystroke (already normalized to a ``KeyChord`` by the view) into a ``TerminalKeyDisposition``.
    /// This is the ONLY method a view calls. Never traps on any chord; stateless.
    ///
    /// Order mirrors ``WorkspaceKeyDispatcher/handle`` so B3 (the app monitor) and this fallback agree on
    /// what a chord means:
    ///   • a bound single chord  → dispatch + swallow (B5's ⌘D binding is resolved here, not hard-coded)
    ///   • a bare/unbound key    → FORWARD (never swallow normal typing)
    public func intercept(_ chord: KeyChord) -> TerminalKeyDisposition {
        if let action = resolveChord(chord) {
            onAction(action)
            return .swallow
        }
        return .forward(chord)
    }
}
