// WarpMotion — motion tokens (warp-tokens-layout.md §5). Warp's open-source layer has almost no
// declarative motion: hover/selection are INSTANT style swaps (no tween token). The only real
// animation is the shimmer (3s). The short hover/overlay eases below are explicitly ADDITIVE design
// choices (warp-tokens-layout.md §5 note), not Warp-sourced — kept tiny so chrome stays Warp-like.

import Foundation

public enum WarpMotion {
    /// Hover/selection transition — Warp is instant; we allow a tiny ease (additive).
    public static let hover: Duration = .milliseconds(90)
    /// Overlay (palette/menu) present — Warp is instant; a short fade is additive.
    public static let overlay: Duration = .milliseconds(120)
    /// Instant (no tween) — the faithful Warp value for hover/selection.
    public static let instant: Duration = .zero
    /// Shimmer "loading"/AI text sweep period (config.rs:32).
    public static let shimmerPeriod: Duration = .seconds(3)
}
