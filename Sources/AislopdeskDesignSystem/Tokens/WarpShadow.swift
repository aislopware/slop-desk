// WarpShadow — elevation / scrim (warp-tokens-layout.md §4). Warp expresses elevation with ONE
// DropShadow + `surface_n` fills (no z-tier ramp).

import CoreGraphics

public enum WarpShadow {
    /// Standard elevated-surface drop shadow (scene.rs:126-129,164).
    /// offset (0,10), blur 10, spread 30, color black @ alpha 32 (≈12.5%).
    public static let offset = CGSize(width: 0, height: 10)
    public static let blur: CGFloat = 10
    public static let spread: CGFloat = 30
    /// Shadow tint as a ColorU (black @ 32/255).
    public static let color = ColorU(r: 0, g: 0, b: 0, a: 32)

    /// Full-window modal scrim (lightbox.rs:24) — black @ 230 (≈90%).
    public static let scrim = ColorU(r: 0, g: 0, b: 0, a: 230)

    /// Modal/backdrop dim (blurred_background_overlay) — black @ ~70% (Fill::blur, 179).
    public static let modalBackdrop = ColorU(r: 0, g: 0, b: 0, a: 179)
}
