// RecipeOpenPicker — the File ▸ Open Recipe surface (E16 WI-10, spec `customization__custom-commands.md`
// §Opening a Recipe). An otty-card sheet with two ways in:
//   • the in-app recipe DATABASE — the saved `.ottyrecipe` files under `~/.config/aislopdesk/recipes/`
//     (`store.savedRecipeFiles()`); tap one to open it (source `.savedLibrary`, follows the Saved-Recipes
//     replay mode). A malformed file keeps its slot GREYED (honest — never a crash, never a dead-looking
//     enabled row);
//   • **Open File…** → a `.fileImporter` for an external `.ottyrecipe` (source `.file`, follows the
//     Recipe-Files replay mode + the trust prompt). On iOS `.fileImporter` is backed by
//     `UIDocumentPickerViewController`, so the same call covers the spec's iOS document-picker requirement.
//
// DEFERRED (plan §6, documented honestly — NOT shipped as dead UI): Finder double-click → new window
// (`CFBundleDocumentTypes`, app packaging) and the `aislopdesk open foo.ottyrecipe` CLI (→ E20). File ▸ Open
// Recipe + the palette are the baseline entry points E16 ships.
//
// Otty.* tokens only (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The content type for an `.ottyrecipe` document — plain TOML text, so declared conforming to
    /// `.plainText`. Declared `exportedAs` (we own the extension) but created at runtime; no Info.plist entry
    /// is needed for the picker to function (mirrors ``UTType/aislopdeskWorkspace``).
    static let ottyRecipe = UTType(exportedAs: "com.aislopdesk.ottyrecipe", conformingTo: .plainText)
}

/// The Open-Recipe picker. Lists the saved recipe library off `store` and opens a tapped / imported recipe
/// through the store glue (`openRecipe(at:source:)` / `openRecipe(bytes:source:recipeLocation:)`).
struct RecipeOpenPicker: View {
    let store: WorkspaceStore

    @State private var files: [RecipeLibrary.RecipeFile] = []
    @State private var importing = false

    @Environment(\.dismiss) private var dismiss

    /// The types the `.fileImporter` accepts: our dedicated type plus the bare `.ottyrecipe` extension and
    /// plain text (a file that lost its UTI tag is still TOML text). `.compactMap` drops a nil extension type.
    private static var recipeContentTypes: [UTType] {
        [UTType.ottyRecipe, UTType(filenameExtension: RecipeLibrary.fileExtension), .plainText, .text]
            .compactMap(\.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space4) {
            header
            libraryList
            footer
        }
        .padding(Otty.Metric.space4)
        #if os(macOS)
            .frame(width: 520)
        #else
            .frame(maxWidth: 520)
        #endif
            .background(Otty.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: Otty.Metric.radiusCard))
            .onAppear { files = store.savedRecipeFiles() }
            // `.fileImporter` presents an `NSOpenPanel` on macOS and a `UIDocumentPickerViewController` on iOS.
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: Self.recipeContentTypes,
                allowsMultipleSelection: false,
            ) { result in handleImport(result) }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Open Recipe")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Otty.Text.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: Library list

    @ViewBuilder private var libraryList: some View {
        if files.isEmpty {
            Text("No saved recipes yet. Save one with ⌘S, or open an external .ottyrecipe file below.")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
        } else {
            ScrollView {
                VStack(spacing: Otty.Metric.space1) {
                    ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                        recipeRow(file)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
    }

    @ViewBuilder
    private func recipeRow(_ file: RecipeLibrary.RecipeFile) -> some View {
        if let recipe = file.recipe {
            Button { open(file) } label: { rowBody(
                title: displayName(recipe, url: file.url),
                subtitle: scopeLabel(recipe),
                enabled: true,
            ) }
            .buttonStyle(.plain)
        } else {
            // Validate-then-drop: an unreadable / malformed file keeps a GREYED, non-tappable slot.
            rowBody(title: file.url.lastPathComponent, subtitle: "Unreadable recipe", enabled: false)
        }
    }

    private func rowBody(title: String, subtitle: String, enabled: Bool) -> some View {
        HStack(spacing: Otty.Metric.space2) {
            Image(systemName: "doc.text")
                .font(.system(size: Otty.Metric.iconSize))
                .foregroundStyle(enabled ? Otty.Text.icon : Otty.Text.tertiary)
            VStack(alignment: .leading, spacing: Otty.Metric.space1) {
                Text(title)
                    .font(.system(size: Otty.Typeface.body))
                    .foregroundStyle(enabled ? Otty.Text.primary : Otty.Text.tertiary)
                Text(subtitle)
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(Otty.Metric.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                .fill(Otty.Surface.element),
        )
        .contentShape(Rectangle())
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Otty.Metric.space2) {
            Spacer(minLength: 0)
            Button { importing = true } label: {
                Text("Open File…")
                    .font(.system(size: Otty.Typeface.body, weight: .semibold))
                    .foregroundStyle(Otty.Surface.card)
                    .padding(.horizontal, Otty.Metric.space3)
                    .padding(.vertical, Otty.Metric.space1)
                    .background(
                        RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                            .fill(Otty.State.accent),
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Helpers

    private func displayName(_ recipe: Recipe, url: URL) -> String {
        let trimmed = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url.deletingPathExtension().lastPathComponent : trimmed
    }

    private func scopeLabel(_ recipe: Recipe) -> String {
        switch recipe.scope {
        case .tab: "Tab layout"
        case .window: "Window layout"
        case .commands: "Commands"
        }
    }

    private func open(_ file: RecipeLibrary.RecipeFile) {
        store.openRecipe(at: file.url, source: .savedLibrary)
        dismiss()
    }

    /// Reads a picked external `.ottyrecipe` and hands its EXACT bytes to the store (which parses, consults
    /// the trust store, and either restores or parks the trust prompt). Opens a security-scoped read
    /// (sandbox-correct) and never traps on a bad read; a cancel / IO error is a silent no-op.
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        store.openRecipe(
            bytes: [UInt8](data),
            source: .file,
            recipeLocation: url.deletingLastPathComponent().path,
        )
        dismiss()
    }
}
#endif
