// DesignTokens — the view-facing resolved token bundle. Given a `Theme`, it exposes ready-to-use
// SwiftUI `Color`s for each role (so views never re-run blends per frame) plus pass-throughs to the
// theme-independent type/space/size/radius/border/shadow/motion scales.
//
// Build it ONCE from a `Theme` and inject via `@Environment(\.theme)`. The underlying `ResolvedColors`
// is retained so a view that needs a contrast-aware color on an arbitrary surface (e.g. text on a
// custom bg) can still call into the derivation.

import CoreGraphics
import SwiftUI

public struct DesignTokens: Sendable {
    public let theme: ThemeSeeds
    public let resolved: ResolvedColors
    public let name: String

    public init(theme: any Theme) {
        seeds = theme.seeds
        self.theme = theme.seeds
        resolved = theme.colors
        name = theme.name
    }

    private let seeds: ThemeSeeds

    // MARK: Core surfaces / ink (SwiftUI Color)

    public var background: Color { Color(resolved.background) }
    public var foreground: Color { Color(resolved.foreground) }
    public var accent: Color { Color(resolved.accent) }
    public var cursor: Color { Color(resolved.cursor) }

    public var surface1: Color { Color(resolved.surface1) }
    public var surface2: Color { Color(resolved.surface2) }
    public var surface3: Color { Color(resolved.surface3) }
    public var neutral4: Color { Color(resolved.neutral4) }
    public var neutral5: Color { Color(resolved.neutral5) }
    public var neutral6: Color { Color(resolved.neutral6) }
    public var neutral7: Color { Color(resolved.neutral7) }

    public var tooltipBackground: Color { Color(resolved.tooltipBackground) }
    public var blockBannerBackground: Color { Color(resolved.blockBannerBackground) }
    public var subshellBackground: Color { Color(resolved.subshellBackground) }

    // MARK: Overlays / borders

    public var fgOverlay1: Color { Color(resolved.fgOverlay1) }
    public var fgOverlay2: Color { Color(resolved.fgOverlay2) }
    public var fgOverlay3: Color { Color(resolved.fgOverlay3) }
    public var outline: Color { Color(resolved.outline) }
    public var splitPaneBorder: Color { Color(resolved.splitPaneBorder) }
    public var inactivePaneOverlay: Color { Color(resolved.inactivePaneOverlay) }

    public var accentOverlay1: Color { Color(resolved.accentOverlay1) }
    public var accentOverlay2: Color { Color(resolved.accentOverlay2) } // selection / block selection
    public var accentOverlay3: Color { Color(resolved.accentOverlay3) } // button pressed
    public var accentOverlay4: Color { Color(resolved.accentOverlay4) } // button hover

    // MARK: Text tiers (on the standard surface2, plus contrast-aware helpers)

    public var textMain: Color { Color(resolved.activeUIText) }
    public var textSub: Color { Color(resolved.nonactiveUIText) }
    public var textDisabled: Color { Color(resolved.disabledUIText) }

    /// Contrast-aware text on an arbitrary surface (for panes/blocks with custom backgrounds).
    public func textMain(on bg: ColorU) -> Color { Color(resolved.textMain(on: bg)) }
    public func textSub(on bg: ColorU) -> Color { Color(resolved.textSub(on: bg)) }
    public func textHint(on bg: ColorU) -> Color { Color(resolved.textHint(on: bg)) }

    // MARK: Fixed status literals + agent accents

    public var uiWarning: Color { Color(UIStatus.warning) }
    public var uiError: Color { Color(UIStatus.error) }
    public var uiYellow: Color { Color(UIStatus.yellow) }
    public var uiGreen: Color { Color(UIStatus.green) }
    public var success: Color { Color(UIStatus.success) }
    public var textSelection: Color { Color(UIStatus.textSelection) }

    /// Claude model/brand orange (terminal/theme accent stays teal — see `accent`).
    public var claudeOrange: Color { Color(AgentAccent.claudeOrange) }
    /// Claude bottom-bar/footer brand tint.
    public var agentFooterBrand: Color { Color(AgentAccent.footerBrand) }

    // MARK: Terminal ANSI palette (SwiftUI)

    public var ansiNormal: AnsiColors { seeds.terminal.normal }
    public var ansiBright: AnsiColors { seeds.terminal.bright }

    // MARK: Type / space / size / radius / border / shadow / motion (theme-independent scales)

    //
    // These scales are theme-INDEPENDENT, so views reference them directly as `WarpType.*`,
    // `WarpSpace.*`, `WarpSize.*`, `WarpRadius.*`, `WarpBorder.*`, `WarpShadow.*`, `WarpMotion.*`.
    // Only the shadow/scrim TINTS depend on no theme but are exposed here as SwiftUI Color for
    // ergonomics alongside the resolved color roles.

    /// The drop-shadow tint as SwiftUI Color (geometry lives in WarpShadow).
    public var shadowColor: Color { Color(WarpShadow.color) }
    public var scrim: Color { Color(WarpShadow.scrim) }
}

public extension DesignTokens {
    /// The default tokens (Warp Dark).
    static let warpDark = DesignTokens(theme: WarpTheme.dark)
}
