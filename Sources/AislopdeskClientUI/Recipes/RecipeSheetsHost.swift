// RecipeSheetsHost — the single place the E16 recipe modals are presented off the store's `pending*` flags
// (WI-10). The store glue (`WorkspaceStore+Recipes`) flips `recipes.pendingSaveRecipe` (⌘S / File ▸ Recipe ▸
// Save…), `recipes.pendingOpenRecipe` (File ▸ Recipe ▸ Open…), and parks `recipes.pendingTrustPrompt` (an
// unfamiliar command-carrying recipe). This modifier observes those `@Observable` fields and presents the
// matching sheet, dismissing back through the store's `clear*` / `cancelTrust` entry points so a swipe-down /
// scrim tap can never strand a flag set.
//
// The store fields are `internal(set)` (settable only inside WorkspaceCore), so each `isPresented` binding's
// SETTER routes a dismissal through the public store API rather than writing the flag directly — and reading
// the field in the GETTER registers the `@Observable` dependency that re-presents the sheet when the flag
// flips (the same binding idiom `WorkspaceRootView.composerSheetPresented` uses).
//
// Applied ONCE at the WindowGroup root (`AislopdeskClientApp`), so the sheets ride above the workspace shell
// on both platforms. The snippet editor (File ▸ Recipe ▸ Save Snippet…, macOS) rides an app-owned `@State`
// flag passed in, since it has no store flag (snippet CRUD is otherwise reached via Settings → Recipes).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

extension View {
    /// Host the recipe save / open / trust modals (+ the Save-Snippet editor) off the store's `pending*`
    /// flags. `snippetEditor` is an app-owned presentation flag for the macOS File ▸ Recipe ▸ Save Snippet…
    /// row (it has no store flag).
    func recipeSheets(store: WorkspaceStore, snippetEditor: Binding<Bool>) -> some View {
        modifier(RecipeSheetsModifier(store: store, snippetEditor: snippetEditor))
    }
}

private struct RecipeSheetsModifier: ViewModifier {
    let store: WorkspaceStore
    @Binding var snippetEditor: Bool

    func body(content: Content) -> some View {
        // Read the `@Observable` pending flags HERE, in the modifier body, so a flip re-evaluates this body
        // and the captured-value bindings below re-present the sheet. Reading them only inside a Binding getter
        // may not register the observation (the same reason `WorkspaceRootView` reads `store.floatingComposer`
        // explicitly in its body to drive the composer sheet).
        let savePending = store.recipes.pendingSaveRecipe
        let openPending = store.recipes.pendingOpenRecipe
        let trustPrompt = store.recipes.pendingTrustPrompt
        // The parameterized-snippet value-entry flag (M5): `beginRunSnippet` arms `pendingSnippetRun` for a
        // body carrying a non-reserved `{{slot}}`, and this is the only surface that consumes it. Capture the
        // snippet body at present-time so a delete/edit mid-sheet can't blank the slots being collected.
        let pendingSnippetID = store.pendingSnippetRun
        let pendingSnippetBody = pendingSnippetID.flatMap { id in
            store.snippets.first { $0.id == id }?.body
        }
        return content
            .sheet(isPresented: Binding(
                get: { savePending },
                set: { if !$0 { store.clearSaveRecipeRequest() } },
            )) { RecipeSaveSheet(store: store) }
            .sheet(isPresented: Binding(
                get: { openPending },
                set: { if !$0 { store.clearOpenRecipeRequest() } },
            )) { RecipeOpenPicker(store: store) }
            .sheet(isPresented: Binding(
                get: { trustPrompt != nil },
                set: { if !$0 { store.cancelTrust() } },
            )) {
                // The prompt is captured at present time, so confirm/cancel (which clears it) can't blank the
                // sheet mid-dismiss; `if let` still guards the never-expected nil.
                if let trustPrompt {
                    RecipeTrustSheet(store: store, prompt: trustPrompt)
                }
            }
            .sheet(isPresented: $snippetEditor) {
                SnippetEditorSheet(isNew: true) { name, alias, body in
                    store.addSnippet(name: name, body: body, alias: alias)
                }
            }
            .sheet(isPresented: Binding(
                get: { pendingSnippetID != nil },
                set: { if !$0 { store.clearSnippetRunRequest() } },
            )) {
                // Both id + body are captured at present-time so confirm/cancel (which clears the flag) can't
                // blank the sheet mid-dismiss; `if let` still guards the never-expected nil body.
                if let pendingSnippetID, let pendingSnippetBody {
                    SnippetValueSheet(store: store, snippetID: pendingSnippetID, body: pendingSnippetBody)
                }
            }
    }
}
#endif
