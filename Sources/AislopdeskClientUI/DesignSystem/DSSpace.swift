#if canImport(SwiftUI)
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - DSSpace (LAYER 2 — the ONE 4pt-base spacing scale)

/// The single 4pt-base spacing scale (kills the dual ``AislopdeskTheme.Space`` / ``UIMetrics.spacing*``
/// systems). Named by step so a density flip reflows everything. Every value is scaled by ``DSScale``.
///
/// P1 STATUS: target spec values. The legacy spacing accessors keep their CURRENT literals — and the map
/// is by VALUE not NAME (legacy `spacing5 = 10` does NOT become `s5 = 12`; the legacy accessor keeps 10).
/// NO view consumes `DSSpace` in P1.
///
/// ⚠️ LIVE-SCALE CONTRACT (read before P3/P5 adoption): these are `static var` getters that read
/// `DSScale.shared.multiplier` directly inside ``DSScale/scaled(_:)``. A singleton read inside a `static`
/// computed var is NOT tracked by SwiftUI's `@Observable` graph — it is the EXACT dead-notification shape
/// the spec indicts for legacy ``UIMetrics``. So `height = DSSpace.statusBarHeight` / `.padding(DSSpace.s6)`
/// / `.cornerRadius(DSRadius.sm)` wired STRAIGHT into view code will NOT live-repaint on a P5 density flip
/// (only `.dsFont`/`.dsSpace`, which read `@Environment(DSScale.self)`, reflow). To get a tracked,
/// live-reflowing geometry, consume these through a modifier that reads the injected environment (e.g.
/// `.dsSpace`, or the P5 `.dsFrame(height:)` helper below, which ALSO reads `@Environment(DSThemeStore.self)`
/// because a chrome height's VALUE comes from the density TIER, not just the multiplier) — do NOT read the
/// static var directly in a view body that must reflow. P5 funnels the chrome heights through `.dsFrame`.
@preconcurrency @MainActor
public enum DSSpace {
    public static var s0: CGFloat { DSScale.scaled(0) }
    public static var s1: CGFloat { DSScale.scaled(2) }
    public static var s2: CGFloat { DSScale.scaled(4) }
    public static var s3: CGFloat { DSScale.scaled(6) }
    public static var s4: CGFloat { DSScale.scaled(8) }
    /// NOTE: 12 (the spec collapses the legacy 10 → 12 to land on a clean 4pt grid). Target-only in P1.
    public static var s5: CGFloat { DSScale.scaled(12) }
    public static var s6: CGFloat { DSScale.scaled(16) }
    public static var s7: CGFloat { DSScale.scaled(20) }
    public static var s8: CGFloat { DSScale.scaled(24) }
    public static var s9: CGFloat { DSScale.scaled(32) }
    public static var s10: CGFloat { DSScale.scaled(40) }
    public static var s11: CGFloat { DSScale.scaled(48) }
    public static var s12: CGFloat { DSScale.scaled(64) }

    // MARK: Density-driven layout tokens (default tier in P1; tier-driven in P5)

    /// The chrome HEIGHTS are driven by the active density TIER ALONE — NOT also multiplied by ``DSScale``.
    ///
    /// SINGLE DENSITY STEP (the fix for the double-scaling the review flagged): the per-tier height values
    /// (`rowHeight` 24/28/32, `tabHeight` 28/30/34, `statusBarHeight` 24/26/28) ALREADY encode the density
    /// progression — they ARE the spec density table. The ``DSScale`` multiplier (0.92/1.00/1.10) ALSO encodes
    /// it, so wrapping the height in `DSScale.scaled(...)` would COMPOUND the two (comfortable tab → 34·1.10 =
    /// 37.4 instead of the spec's 34; compact → 28·0.92 = 25.76 instead of 28). The spec pseudocode reads the
    /// tier height UNSCALED (`DSDensity.current.tabHeight`), so the height comes PURELY from the tier here; the
    /// multiplier remains the density driver for FONTS + PADDING only (via `.dsFont` / `.dsSpace`). The
    /// ``DSFrameHeightModifier`` below applies the SAME unscaled rule on the live-reflow path.

    /// List-row height — the active tier's `rowHeight` (24/28/32), UNSCALED. Resolves through
    /// ``DSThemeStore/shared`` `.density.rowHeight` (there is no `DSDensity.current`; the active tier lives on
    /// the persisted ``DSThemeStore``).
    public static var rowHeight: CGFloat { DSThemeStore.shared.density.rowHeight }
    /// Tab-strip height — the active tier's `tabHeight` (28/30/34), UNSCALED. Legacy `Metrics.tabHeight` stays 32.
    public static var tabHeight: CGFloat { DSThemeStore.shared.density.tabHeight }
    /// Bottom status-bar height — the active tier's `statusBarHeight` (24/26/28), UNSCALED. Legacy
    /// `Metrics.statusBarHeight` stays 28.
    public static var statusBarHeight: CGFloat { DSThemeStore.shared.density.statusBarHeight }

    /// The per-side pane gutter — 4pt (spec: paneGutter = space4(8)/2). Legacy `Space.paneGap` stays 7.
    public static var paneGutter: CGFloat { DSScale.scaled(4) }
    /// The split-divider grab band hit area (unchanged from today — forward-safe).
    public static var dividerHit: CGFloat { DSScale.scaled(16) }

    // MARK: Command-palette modal extents (Warp/Raycast IDE spec — fixed, NOT density-reflowing)

    /// The ⌘K command-palette panel WIDTH — a LITERAL 640pt (Warp/Raycast IDE spec). Deliberately NOT
    /// `DSScale`-scaled: a palette is a fixed modal whose frame extents stay constant across density
    /// (the spec's "a palette should not reflow with density" rule), so this is a plain named constant —
    /// living in `DesignSystem/` so the leak gate exempts it rather than two inline `640`/`464` literals.
    public static let paletteWidth: CGFloat = 640
    /// The ⌘K command-palette panel HEIGHT — a LITERAL 464pt (Warp/Raycast IDE spec). Fixed (see
    /// ``paletteWidth``).
    public static let paletteHeight: CGFloat = 464
}

// MARK: - DSRadius (LAYER 2 — the ONE radius scale)

/// The single corner-radius scale, scaled by ``DSScale``. Values 4/6/8/10 are unchanged from today; the
/// pane radius stays 8. `overlay` (12) is the new L4 overlay/modal radius (target-only in P1).
///
/// ⚠️ LIVE-SCALE CONTRACT: like ``DSSpace``, these `static var` getters read `DSScale.shared` inside a
/// static computed var, which SwiftUI cannot observe — a value read straight into `.cornerRadius(...)`
/// will NOT live-repaint on a P5 density flip. Consume via a tracked `@Environment(DSScale.self)`-reading
/// modifier when the radius must reflow live. See the ``DSSpace`` contract note.
@preconcurrency @MainActor
public enum DSRadius {
    public static var sm: CGFloat { DSScale.scaled(4) }
    public static var md: CGFloat { DSScale.scaled(6) }
    public static var lg: CGFloat { DSScale.scaled(8) }
    public static var xl: CGFloat { DSScale.scaled(10) }
    /// the per-pane rounded-card radius (8pt continuous)
    public static var pane: CGFloat { DSScale.scaled(8) }
    /// L4 overlay / palette / floating-pane radius
    public static var overlay: CGFloat { DSScale.scaled(12) }
    /// hard-modal radius (connection gate / settings sheet) — the larger 16pt corner the spec's
    /// `shadowModal` profile pairs with (DSElevation.shadowModal). Distinct from `overlay` (12) so the
    /// connection-gate card reads as a heavier modal than a transient ⌘K overlay.
    public static var modal: CGFloat { DSScale.scaled(16) }
}

// MARK: - dsSpace ViewModifier (reads @Environment(DSScale.self) — the tracked repaint path)

/// Applies uniform padding from a base point value, reading `@Environment(DSScale.self)` so the padding
/// repaints on a live density change (the same tracked-dependency mechanism as `.dsFont`). Forward
/// vocabulary in P1 — no view adopts it yet.
@preconcurrency @MainActor
public struct DSSpaceModifier: ViewModifier {
    // OPTIONAL form (`DSScale?`) — nil instead of TRAPPING when rendered outside the injected scope (the
    // pre-connect gate, a sheet, a detached NSHostingView). Falls back to the shared instance's multiplier
    // (the bridged source) so padding stays correct; only the live-repaint dependency is lost when unscoped.
    @Environment(DSScale.self) private var scale: DSScale?
    let edges: Edge.Set
    let base: CGFloat

    public func body(content: Content) -> some View {
        // Read the injected instance's multiplier so SwiftUI records the dependency (single `*`, no FMA).
        content.padding(edges, base * (scale?.multiplier ?? DSScale.shared.multiplier))
    }
}

public extension View {
    /// Pads by a base point value scaled live through `@Environment(DSScale.self)`. Forward vocabulary.
    @MainActor
    func dsSpace(_ edges: Edge.Set = .all, _ base: CGFloat) -> some View {
        modifier(DSSpaceModifier(edges: edges, base: base))
    }
}

// MARK: - dsScaledFrame ViewModifier (tracked fixed-pt geometry — the sidebar/status-bar reflow fix)

/// Constrains a view to a fixed base size SCALED by the live `@Environment(DSScale.self)` multiplier — the
/// tracked counterpart to a raw `UIMetrics.scaled(_:)` / `UIMetrics.iconXXL` read in a `.frame(...)`.
///
/// WHY (the P5 partial-reflow fix the review flagged): a chrome leaf whose only geometry is a fixed-pt size
/// (a sidebar icon tile, a status/agent dot, the 3pt accent bar) read via `UIMetrics.scaled(_:)` resolves to
/// the CORRECT value on a tier flip (since `UIScale.multiplier` now delegates to the live density tier) but
/// is read inside a `static var`, which SwiftUI cannot observe — so the leaf FREEZES (does not repaint) until
/// a view-identity change while the row's `.dsFont`/`.dsSpace` text/padding reflow, leaving the row
/// half-scaled. Routing the size through this modifier records the `@Environment(DSScale.self)` dependency so
/// the leaf repaints in lockstep. OPTIONAL form — falls back to the shared multiplier (correct value, only
/// the live-repaint dependency lost) when rendered outside the injected scope rather than TRAPPING.
@preconcurrency @MainActor
public struct DSScaledFrameModifier: ViewModifier {
    @Environment(DSScale.self) private var scale: DSScale?
    /// The unscaled base WIDTH (nil ⇒ leave the width intrinsic).
    let width: CGFloat?
    /// The unscaled base HEIGHT (nil ⇒ leave the height intrinsic).
    let height: CGFloat?

    public func body(content: Content) -> some View {
        // Read the injected multiplier so SwiftUI records the dependency (single `*`, no FMA). Scale each
        // supplied base; a nil base leaves that dimension intrinsic.
        let mult = scale?.multiplier ?? DSScale.shared.multiplier
        return content.frame(width: width.map { $0 * mult }, height: height.map { $0 * mult })
    }
}

public extension View {
    /// Constrains the receiver to a fixed base size scaled live by `@Environment(DSScale.self)` — the tracked
    /// replacement for `.frame(width: UIMetrics.scaled(w), height: UIMetrics.scaled(h))`. Pass UNSCALED base
    /// points; the modifier applies the live density multiplier and repaints on a tier flip.
    @MainActor
    func dsScaledFrame(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        modifier(DSScaledFrameModifier(width: width, height: height))
    }

    /// Constrains the receiver to a scaled SQUARE of `side` base points (the common icon-tile / dot case).
    @MainActor
    func dsScaledFrame(square side: CGFloat) -> some View {
        modifier(DSScaledFrameModifier(width: side, height: side))
    }
}

// MARK: - dsFrame(height:) ViewModifier (the P5 live-reflowing CHROME HEIGHT — tracks DSThemeStore + DSScale)

/// Constrains a view's height to a density-driven chrome height token (`tabHeight` / `statusBarHeight` /
/// `rowHeight`), reading it through `@Environment(DSThemeStore.self)` so a P5 density TIER flip repaints the
/// frame LIVE. This is the load-bearing fix the ``DSSpace`` contract note warns about: the height tokens
/// (`DSSpace.tabHeight` etc.) are `static var` reads of `DSThemeStore.shared.density.<height>`, which
/// SwiftUI cannot observe — so `.frame(height: DSSpace.tabHeight)` FREEZES until a view-identity change.
///
/// Unlike `.dsFont`/`.dsSpace` (which scale a base by the `DSScale` multiplier), a chrome HEIGHT comes
/// PURELY from the active TIER (the spec density table, UNSCALED — see the ``rowHeight`` note above on why
/// re-multiplying by the ``DSScale`` multiplier would double-count the density step). So this modifier reads
/// the height from `@Environment(DSThemeStore.self)` (the tier → the height VALUE) and does NOT multiply by
/// the multiplier. It ALSO observes `@Environment(DSScale.self)` purely so SwiftUI tracks that dependency too
/// (a tier flip re-sets the multiplier via `DSThemeStore.density.didSet`, so tracking the store alone already
/// covers the reflow, but reading the scale keeps the modifier consistent with `.dsFont`/`.dsSpace` and
/// future-proofs a multiplier-only change). Both are OPTIONAL forms — they fall back to the shared singletons
/// instead of TRAPPING when rendered outside the injected scope (only the live-repaint dependency is lost).
@preconcurrency @MainActor
public struct DSFrameHeightModifier: ViewModifier {
    @Environment(DSThemeStore.self) private var theme: DSThemeStore?
    @Environment(DSScale.self) private var scale: DSScale?
    /// The density-height keypath (e.g. `\.tabHeight`) — the per-tier height to resolve (UNSCALED).
    let height: KeyPath<DSDensity, CGFloat>

    public func body(content: Content) -> some View {
        // Read the tier for the height VALUE. Read the multiplier too so SwiftUI records BOTH dependencies
        // (keeps this modifier consistent with `.dsFont`/`.dsSpace`), but DISCARD it from the height math: the
        // chrome height is the tier value UNSCALED (re-multiplying would double-count the density step).
        let density = (theme ?? DSThemeStore.shared).density
        _ = (scale ?? DSScale.shared).multiplier // observed-only; intentionally not applied (see type doc).
        return content.frame(height: density[keyPath: height])
    }
}

public extension View {
    /// Constrains the receiver to a density-driven chrome height token, live-reflowing on a P5 tier flip
    /// (tracks `@Environment(DSThemeStore.self)` + `@Environment(DSScale.self)`). Pass a ``DSDensity``
    /// height keypath, e.g. `.dsFrame(height: \.tabHeight)`.
    @MainActor
    func dsFrame(height: KeyPath<DSDensity, CGFloat>) -> some View {
        modifier(DSFrameHeightModifier(height: height))
    }
}
#endif
