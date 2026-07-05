// DockProgressController — E14/K5/K8, macOS-only. Owns `NSApp.dockTile` and actuates the cross-session
// progress/error aggregate onto it: an animate-on-progress bar (gated by `dock-icon-animate-progress`), a
// red-on-error tint (gated by `dock-icon-error-badge`), and the K8 `requestUserAttention` bounce driven from
// the notification OSCs (NOT the bell — wired off `CommandCompletionNotifier.bounceDock`). Every DECISION is
// the pure ``DockTintPolicy`` (unit-pinned headlessly, ES-E14-3); this file is ONLY the AppKit drawing +
// bounce + the dock-reveal hook. iOS no-ops (there is no Dock) — the file is `#if os(macOS)` and the shared
// aggregate state lives in ``WorkspaceStore`` (``WorkspaceStore/dockTileModel``), consumed only here.
//
// HANG-SAFETY (ES-E14-3): never instantiate `NSDockTile` in a test — the pure decision is pinned by
// `DockTintPolicyTests`; this actuation is GUI-verified (Phase-3 `check-macos.sh` screenshot) only.

#if os(macOS)
import AppKit
import SlopDeskWorkspaceCore

/// Drives the macOS Dock tile from the workspace's rolled-up OSC 9;4 progress / error aggregate (E14/K5/K8).
/// Process-global mutable state (one Dock per app), so the app feeds it the resolved ``DockTileModel`` on every
/// progress/completion edge and a last-session-end edge resolves to ``DockTileModel/inert`` → ``clear()`` (the
/// carryover "no stuck red tile after the failing pane closes" trap).
@preconcurrency
@MainActor
public final class DockProgressController {
    private let dockTile: NSDockTile
    private let contentView = DockProgressContentView()
    private var animationTimer: Timer?
    private var lastModel: DockTileModel = .inert
    /// The block-based `didBecomeActive` observer token. `nonisolated(unsafe)` so the nonisolated `deinit`
    /// can remove it (the token is only ever written on the main actor at init; `NotificationCenter` removal
    /// is thread-safe).
    private nonisolated(unsafe) var activationObserver: NSObjectProtocol?

    /// Invoked when the app becomes active WHILE the Dock tile is in the error tint — clicking the tinted
    /// Dock icon jumps to the next failing tab and clears the tint (the precise per-click hook is
    /// `NSApplicationDelegate.applicationShouldHandleReopen`, which SwiftUI owns; see docs/DECISIONS.md).
    /// The app wires this to ``WorkspaceStore/revealNextErrorPane()``.
    public var onActivatedWhileErrored: () -> Void = {}

    // `NSApplication.shared` (NOT the `NSApp` IUO global) so the default argument is safe even when the
    // controller is built during `App.init()` — at that point in the SwiftUI macOS lifecycle the `NSApp`
    // global can still be nil (it is only wired once `.shared` is first touched), so `NSApp.dockTile` would
    // trap "found nil while implicitly unwrapping". `.shared` is non-optional and creates the app object if
    // needed, which also wires `NSApp` for the later `requestUserAttention` / `applicationIconImage` uses.
    public init(dockTile: NSDockTile = NSApplication.shared.dockTile) {
        self.dockTile = dockTile
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidBecomeActive() }
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    /// Applies the resolved Dock-tile state (E14/K5/K8). Idempotent — a no-op when unchanged so the tile is
    /// never redrawn on a non-edge. An ``DockTileModel/inert`` model restores the default Dock icon (the
    /// last-session-end CLEAR). Otherwise it draws the icon + progress bar + error tint and arms/stops the
    /// indeterminate sweep animation. The DECISION already happened in ``DockTintPolicy`` (in the store's
    /// ``WorkspaceStore/dockTileModel``); this only actuates.
    public func apply(_ model: DockTileModel) {
        guard model != lastModel else { return }
        lastModel = model
        guard !model.isInert else {
            clear()
            return
        }
        contentView.model = model
        if dockTile.contentView !== contentView { dockTile.contentView = contentView }
        contentView.needsDisplay = true
        dockTile.display()
        // Only an INDETERMINATE spinner needs the per-frame sweep; a determinate bar redraws on the next
        // `apply` (its percent edge), and a held error never animates.
        updateAnimation(model.animatesProgress && model.determinateFraction == nil)
    }

    /// The K8 Dock bounce: `requestUserAttention(.informationalRequest)`. Called from the notifier's
    /// ``CommandCompletionNotifier/bounceDock`` seam (gated by the "Bounce Dock Icon" toggle at the wire site),
    /// so the bounce rides a DELIVERED notification banner, not the bell.
    public func bounce() {
        _ = NSApp.requestUserAttention(.informationalRequest)
    }

    /// Restores the default Dock icon and stops any animation — the CLEAR the controller runs when the last
    /// progress/error session ends (or on scene teardown). Resets ``lastModel`` so a subsequent ``apply`` of a
    /// fresh state re-draws.
    public func clear() {
        stopAnimation()
        lastModel = .inert
        contentView.model = .inert
        dockTile.contentView = nil
        dockTile.display()
    }

    // MARK: - private

    private func handleDidBecomeActive() {
        guard lastModel.tint == .error else { return }
        onActivatedWhileErrored()
    }

    private func updateAnimation(_ animating: Bool) {
        guard animating else {
            stopAnimation()
            return
        }
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickAnimation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func tickAnimation() {
        contentView.advancePhase()
        contentView.needsDisplay = true
        dockTile.display()
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

/// The custom `NSDockTile` content view (E14/K5/K8). Draws the app icon, an animate-on-progress bar (a
/// determinate fill or an indeterminate sweep keyed by ``phase``), and a red error wash — all decided upstream
/// by ``DockTintPolicy`` and carried in ``model``. Drawing-only; no state beyond the resolved model + the
/// sweep phase. GUI-verified (Phase-3) only — never instantiated in a test (the hang-safety rule). `NSView`
/// is already `@MainActor`-isolated, so the subclass inherits it (no explicit annotation needed).
private final class DockProgressContentView: NSView {
    var model: DockTileModel = .inert
    /// The indeterminate sweep position `0…1`, advanced by the controller's animation tick.
    private var phase: CGFloat = 0

    func advancePhase() {
        phase += 1.0 / 12.0
        if phase > 1 { phase -= 1 }
    }

    override func draw(_: NSRect) {
        let area = bounds
        // 1. The app icon (the content view fully replaces the tile, so we draw it ourselves).
        NSApp.applicationIconImage?.draw(in: area, from: .zero, operation: .sourceOver, fraction: 1)
        // 2. The red error wash (the spec "tints the Dock icon red on error").
        if model.tint == .error {
            NSColor.systemRed.withAlphaComponent(0.45).setFill()
            NSBezierPath(rect: area).fill()
        }
        // 3. The animate-on-progress bar.
        if model.animatesProgress { drawProgressBar(in: area) }
    }

    private func drawProgressBar(in area: NSRect) {
        let barHeight = Swift.max(6, area.height * 0.10)
        let inset = area.width * 0.12
        let track = NSRect(
            x: area.minX + inset, y: area.minY + area.height * 0.12,
            width: area.width - inset * 2, height: barHeight,
        )
        guard track.width > 0 else { return }
        let radius = barHeight / 2
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        (model.tint == .error ? NSColor.systemRed : NSColor.controlAccentColor).setFill()
        if let fraction = model.determinateFraction {
            var fill = track
            // Ordered clamp (NaN-safe house style), no fused multiply.
            fill.size.width = track.width * CGFloat(Double.minimum(1, Double.maximum(0, fraction)))
            if fill.width > 0 { NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill() }
        } else {
            // Indeterminate: a fixed-width segment sweeping left → right, wrapping by `phase`.
            let segWidth = track.width * 0.35
            let travel = track.width + segWidth
            let leadingX = track.minX - segWidth + travel * phase
            let clampedX = Swift.max(track.minX, leadingX)
            let segWidthClamped = Swift.min(segWidth, track.maxX - clampedX)
            guard segWidthClamped > 0 else { return }
            let segment = NSRect(x: clampedX, y: track.minY, width: segWidthClamped, height: barHeight)
            NSBezierPath(roundedRect: segment, xRadius: radius, yRadius: radius).fill()
        }
    }
}
#endif
