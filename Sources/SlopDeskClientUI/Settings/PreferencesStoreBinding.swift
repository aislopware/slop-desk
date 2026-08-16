import SlopDeskWorkspaceCore
import SwiftUI

/// The Settings pages' one wrapper for "write the value, then re-read the fire-time toggles".
///
/// Three copies of this existed — `SettingsView.refreshing`, `SettingsView.refreshingControls` and
/// `AllSettingsListView.refreshing` — with three different doc comments explaining the same seam and
/// identical bodies. Sixteen call sites across the two pages, and a fourth page would have written a
/// fourth.
///
/// The seam itself is `PreferencesStore`'s, not a view's: the store is isolated on its injected
/// `UserDefaults` while the Controls toggles live in `Defaults.standard`, so nothing observes them and
/// `refreshTerminalControls()` is the explicit re-read. Which is why this hangs off the STORE rather
/// than off a view — a page that has a store has the wrapper, and no page has to remember to declare
/// it.
///
/// It is an extension in ClientUI rather than a method in `PreferencesStore.swift` because that file
/// is deliberately SwiftUI-free (its header records the de-SwiftUI'ing: no `@AppStorage`, no
/// `import SwiftUI`, `@Observable` from Observation). A `Binding` is SwiftUI's, so the wrapper lives
/// on the side of the fence that already imports it.
public extension PreferencesStore {
    /// `binding`, wrapped so a write ALSO re-applies the live terminal config.
    ///
    /// The three originals each constrained `V: Equatable` and none of them used it — no comparison
    /// happens here, the write is unconditional. Dropped rather than carried, so the wrapper does not
    /// refuse a binding it could serve.
    func refreshing<V>(_ binding: Binding<V>) -> Binding<V> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                self.refreshTerminalControls()
            },
        )
    }
}
