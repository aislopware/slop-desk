// ThemeEnvironment — inject the resolved `DesignTokens` through the SwiftUI environment so views read
// `@Environment(\.theme)`. Default = Warp Dark (ORCH-DECISIONS A3/F1). Value type (no ObservableObject):
// the tokens are immutable for a given theme; swapping themes replaces the value.

import SwiftUI

public extension EnvironmentValues {
    /// The active design tokens. Defaults to Warp Dark.
    @Entry var theme: DesignTokens = .warpDark
}

public extension View {
    /// Inject a `DesignTokens` bundle for the subtree.
    func theme(_ tokens: DesignTokens) -> some View {
        environment(\.theme, tokens)
    }

    /// Inject tokens resolved from a `Theme`.
    func theme(_ theme: any Theme) -> some View {
        environment(\.theme, DesignTokens(theme: theme))
    }
}
