// ClientTerminalPalette — the terminal cells adopt the app palette, filled ONCE.
//
// ``AppearanceApplier`` (`SlopDeskWorkspaceCore`) publishes `resolveTerminalColors` and fills it
// with nothing: the seam exists because `WorkspaceCore` owns the terminal config but may not import
// the design floor's SwiftUI half, so the closure had to be handed in from above. Both shells handed
// in the SAME closure — character for character, down to the four argument labels — which is a
// composition root written twice, the failure docs/56 §3 says the split exists to prevent. The clone
// detector found it the moment the phone's shell was rewritten and its ledger row was paid.
//
// ⚠️ NOTHING HERE IS A PLATFORM GATE, and there is nothing here to gate: `SlateTheme.app` is the same
// constant on both platforms, and the six values below are hex strings and a 16-entry palette. The
// asymmetry the two shells DO have is where the app's polarity is pinned, which is
// ``SlateAppearancePin``'s and stays there — one `NSApp` versus N `UIWindowScene`s is a real
// difference in arity, and this is not.

import SlopDeskSlate
import SlopDeskWorkspaceCore

/// Fills the terminal-colour seam from the app palette.
@MainActor
package enum ClientTerminalPalette {
    /// Hands libghostty the flat palette: the 6-hex background/foreground, the 16-entry ANSI ladder
    /// and the selection colour, resolved when `PreferencesStore` (re)builds the terminal config.
    ///
    /// The closure is stored rather than the values, because it is asked again on every rebuild — a
    /// snapshot taken at launch would freeze a palette the theme is allowed to move.
    package static func install() {
        AppearanceApplier.resolveTerminalColors = {
            let theme = SlateTheme.app
            return ResolvedTerminalTheme(
                background: theme.terminalBackgroundHex,
                foreground: theme.terminalForegroundHex,
                palette: theme.ansiPalette,
                selectionBackground: theme.selectionBackgroundHex,
                // Straight from the profile's own 24-bit literals — the hex four lines up are
                // `hex6` of these. See ``ResolvedTerminalTheme/Words``.
                words: ResolvedTerminalTheme.Words(
                    background: theme.glass.face,
                    foreground: theme.glass.ink,
                    palette: theme.ansi,
                    selection: theme.glass.edge,
                ),
            )
        }
    }
}
