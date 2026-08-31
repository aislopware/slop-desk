// ClientTerminalPalette — the terminal cells adopt the app palette, filled ONCE.
//
// ``AppearanceApplier`` (`SlopDeskWorkspaceCore`) publishes `resolveTerminalColors` and fills it
// with nothing: the seam exists because `WorkspaceCore` owns the terminal config but may not import
// the design floor's SwiftUI half, so the closure had to be handed in from above. Both shells handed
// in the SAME closure — character for character, down to the four argument labels — which is a
// composition root written twice, the failure docs/56 §3 says the split exists to prevent. The clone
// detector found it the moment the phone's shell was rewritten and its ledger row was paid.
//
// ⚠️ NOTHING HERE IS A PLATFORM GATE, and there is nothing here to gate. The
// asymmetry the two shells DO have is where the app's polarity is pinned, which is
// ``SlateAppearancePin``'s and stays there — one `NSApp` versus N `UIWindowScene`s is a real
// difference in arity, and this is not. `SlateTheme.app` is the same constant on both platforms, and
// what crosses is four packed colour words and a 16-entry ladder.

import SlopDeskSlate
import SlopDeskWorkspaceCore

/// Fills the terminal-colour seam from the app palette.
@MainActor
package enum ClientTerminalPalette {
    /// Hands the surface the flat palette: the background and foreground, the 16-entry ANSI ladder
    /// and the selection fill, resolved when `PreferencesStore` re-derives the terminal settings.
    ///
    /// The closure is stored rather than the values, because it is asked again on every rebuild — a
    /// snapshot taken at launch would freeze a palette the theme is allowed to move.
    package static func install() {
        AppearanceApplier.resolveTerminalColors = {
            let theme = SlateTheme.app
            // Straight from the profile's own 24-bit literals, which is the form the door takes.
            return ResolvedTerminalTheme(
                background: theme.glass.face,
                foreground: theme.glass.ink,
                palette: theme.ansi,
                selection: theme.glass.edge,
            )
        }
    }
}
