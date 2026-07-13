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
// PURITY: this file imports only Foundation. It owns a clock-injected `PrefixStateMachine` (B2) and folds:
//   1. the tmux/zellij multi-key PREFIX path (arm → resolve → send-prefix double-tap → escape-timeout →
//      tmux-faithful unbound-swallow), and
//   2. the SINGLE-CHORD workspace table (the override-aware `resolvedChordTable`, so B5's ⌘D/⌘⇧D split is
//      resolved here rather than hard-coded, and a rebind takes effect),
// into ONE `Disposition` the view maps to swallow / forward / send-literal-bytes. The view does NOTHING but
// (a) map its native event → `KeyChord` and (b) act on the returned `Disposition`. No transition logic, no
// table knowledge, and no AppKit/UIKit live in the view.

import Foundation

/// What a per-surface key path must DO with one keystroke, decided entirely here so the view stays a thin
/// event→intent shim. A pure value type (no AppKit/UIKit) so the whole interceptor is unit-testable.
public enum TerminalKeyDisposition: Equatable, Sendable {
    /// Not a workspace chord / prefix concern — the view runs its OWN normal path (libghostty encoder, the
    /// Ctrl+C0 raw-byte branch, the iOS key encoder, …). Carries the chord back unchanged for convenience.
    case forward(KeyChord)
    /// SWALLOW the key: it armed the prefix, resolved+dispatched an action, or was a tmux-faithful disarm.
    /// The view forwards NOTHING (and — for press/release symmetric paths — must suppress the matching
    /// release too; see ``shouldSuppressRelease``).
    case swallow
    /// The prefix was double-tapped (tmux `send-prefix`): emit these LITERAL bytes once to the focused
    /// pane/PTY, then forward nothing further. Empty only if the configured prefix has no single literal
    /// byte (a prefix moved off a Ctrl-letter), in which case the double-tap is a graceful no-op.
    case sendLiteral([UInt8])
}

/// The PURE prefix + single-chord interceptor every per-surface key path consults. Holds a clock-injected
/// ``PrefixStateMachine`` (B2) and an injected action sink; resolves single chords against the override-aware
/// ``WorkspaceBindingRegistry/resolvedChordTable`` so a rebind (B5) takes effect with no view change.
///
/// `@MainActor` (it drives the main-actor `PrefixStateMachine` and the store-bound `onAction` sink) — the
/// view paths it serves are all already main-actor. Headless: nothing here touches AppKit/UIKit/Metal.
@preconcurrency
@MainActor
public final class TerminalKeyInterceptor {
    /// The pure prefix machine (B2). Its `resolveAfterPrefix` reads the override-aware single-chord table so
    /// a length-2 sequence (⌃B → ⌘D) honours a rebind; the prefix chord itself is configurable.
    private let machine: PrefixStateMachine

    /// Resolve a single (idle) chord to its workspace action, or `nil` to let it fall through. Injected so
    /// the interceptor stays pure; the live wiring passes a lookup over ``resolvedChordTable``.
    private let resolveChord: (KeyChord) -> WorkspaceAction?

    /// Run a resolved action (the store-bound `WorkspaceBindingRegistry.route(...)` sink). Injected.
    private let onAction: (WorkspaceAction) -> Void

    /// A monotonic clock (seconds). Injected so tests drive the escape-timeout deterministically; the live
    /// view paths pass `ProcessInfo.processInfo.systemUptime`.
    private let now: () -> TimeInterval

    /// The configured prefix chord — exposed so a view can show a "prefix armed" affordance and so the
    /// double-tap's literal byte is derivable. Default ⌃B (the shared
    /// ``WorkspaceBindingRegistry/defaultPrefixChord``); CONFIGURABLE off a Ctrl-letter (see B2).
    public var prefix: KeyChord { machine.prefix }

    /// Whether the prefix is currently armed (read-only mirror; does not expire a stale arm — only `feed`
    /// does). A view can read it to draw a prefix indicator.
    public var isArmed: Bool { machine.isArmed }

    public init(
        prefix: KeyChord = WorkspaceBindingRegistry.defaultPrefixChord,
        timeout: TimeInterval = 1,
        resolveChord: @escaping (KeyChord) -> WorkspaceAction? = { WorkspaceBindingRegistry.resolvedChordTable[$0] },
        resolveSequence: @escaping (KeySequence)
            -> WorkspaceAction? = { WorkspaceBindingRegistry.resolvedSequenceTable[$0] },
        onAction: @escaping (WorkspaceAction) -> Void,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    ) {
        // The machine resolves a completed prefix sequence `[prefix, follow-up]` against the override-aware
        // SEQUENCE table FIRST (so a multi-key sequence whose tail key is not a standalone binding fires too),
        // falling back to the SINGLE-chord table — matching B3 (``WorkspaceKeyDispatcher``) so the app monitor
        // and this per-surface fallback agree on what every chord/sequence means.
        machine = PrefixStateMachine(
            prefix: prefix,
            timeout: timeout,
            resolveAfterPrefix: resolveChord,
            resolveSequenceAfterPrefix: resolveSequence,
        )
        self.resolveChord = resolveChord
        self.onAction = onAction
        self.now = now
    }

    /// Update the configured prefix (e.g. the user moved it off the default in settings). The machine re-keys live.
    public func setPrefix(_ chord: KeyChord) { machine.prefix = chord }

    /// Fold ONE keystroke (already normalized to a ``KeyChord`` by the view) into a ``TerminalKeyDisposition``.
    /// This is the ONLY method a view calls; it maps every B2 ``PrefixIntent`` plus the idle single-chord
    /// table into swallow / forward / send-literal. Never traps on any chord; idempotent on its own state.
    ///
    /// Order mirrors ``WorkspaceKeyDispatcher/handle`` exactly so B3 (the app monitor) and this fallback
    /// agree on what a chord means:
    ///   • idle + the prefix            → arm + swallow
    ///   • idle + a bound single chord  → dispatch + swallow (B5's ⌘D binding is resolved here, not hard-coded)
    ///   • idle + a bare/unbound key    → FORWARD (never swallow normal typing)
    ///   • armed + a bound key/sequence → dispatch + swallow
    ///   • armed + the prefix again     → send the literal prefix byte (double-tap), disarm
    ///   • armed + an unbound key       → tmux-faithful disarm + swallow (prefix NOT replayed)
    ///   • armed + escape-timeout       → the stale arm expires to idle BEFORE the key is classified
    public func intercept(_ chord: KeyChord) -> TerminalKeyDisposition {
        switch machine.feed(chord, at: now()) {
        case let .passthrough(passed):
            // Idle: a workspace SINGLE chord (⌘D/⌘T/… or its override) still resolves here so a focused
            // surface honours it without the app monitor; everything else is normal typing → FORWARD.
            if let action = resolveChord(passed) {
                onAction(action)
                return .swallow
            }
            return .forward(passed)

        case .consumedArm:
            return .swallow // armed on the prefix — swallow it (never leak the prefix to the terminal)

        case let .resolved(action):
            onAction(action)
            return .swallow // a bound key resolved while armed → run + swallow

        case .sendPrefixLiteral:
            // tmux `send-prefix`: emit the literal C0 byte the prefix would have sent raw, then swallow.
            return .sendLiteral(Self.literalBytes(for: machine.prefix))

        case .disarmSwallow:
            return .swallow // an unbound key while armed (tmux-faithful: disarm + eat the key)
        }
    }

    /// Force the machine back to idle (focus loss / explicit Escape from the view). Swallows nothing — the
    /// view decides; this only clears the armed state so a stale arm never eats a later keystroke.
    public func disarm() { machine.disarm() }

    /// The literal C0 byte(s) a Ctrl-letter prefix would have sent raw (tmux `send-prefix`). For the default
    /// ⌃B this is `0x02`; for any `Control + <a…z>` it is the standard C0 mapping `letter & 0x1F`. Returns an
    /// EMPTY array for a prefix moved off a Ctrl-letter (no single literal byte — the double-tap then no-ops).
    /// Pure + static so the iOS path (B7) and the macOS surfaces (B4/B6) share ONE definition (parity with
    /// `KeyChordNormalizer.literalBytes`, which lives in ClientUI and is unreachable from those surfaces).
    public static func literalBytes(for prefix: KeyChord) -> [UInt8] {
        guard prefix.modifiers.contains(.control),
              !prefix.modifiers.contains(.command),
              !prefix.modifiers.contains(.option),
              case let .character(c) = prefix.key,
              let ascii = c.asciiValue,
              ascii >= 0x61, ascii <= 0x7A // a…z (KeyChord.init already lower-cased it)
        else { return [] }
        return [ascii & 0x1F]
    }
}
