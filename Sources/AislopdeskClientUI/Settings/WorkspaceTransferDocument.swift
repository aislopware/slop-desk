// WorkspaceTransferDocument — SwiftUI document plumbing for portable workspace export / import (E7 WI-4).
//
// The codec + every hostile-bounds guard already live in `WorkspaceTransfer` (AislopdeskWorkspaceCore) and
// the store-level API (`WorkspaceStore.exportWorkspaceData()` / `importWorkspace(_:mode:)`). This file is
// PURELY the SwiftUI plumbing the file picker needs:
//   • a dedicated `UTType` (`com.aislopdesk.workspace`, `.json`-conforming) so a workspace file is
//     recognized as ours yet still openable as plain JSON,
//   • a minimal `FileDocument` wrapping the `Data` blob `exportWorkspaceData()` produces (the `.fileExporter`
//     payload) and reading raw bytes back (the `.fileImporter` hands those straight to `importWorkspace`,
//     where the codec's validate-then-drop owns the decode — the document never parses on read),
//   • the Advanced → "Workspace" Section (Export / Import rows + the import-failure alert), and
//   • the optional, shortcut-LESS macOS File-menu items (DECISIONS N6: the NSEvent dispatcher owns chords).
//
// The live `WorkspaceStore` reaches the Settings surface via the `\.workspaceStore` environment slot: the
// macOS `Settings` scene is a SEPARATE scene from the main `WindowGroup`, so the store is injected there
// explicitly (an environment value set on the WindowGroup does not cross into the Settings scene).
//
// Slate.* tokens only (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit // NSSavePanel / NSOpenPanel — the menu lives in a different scene from the Settings .fileExporter
#endif

// MARK: - Dedicated content type

extension UTType {
    /// The content type for an exported aislopdesk workspace document. Declared `exportedAs` (we own it) and
    /// conforming to `.json` (the envelope is JSON), so a workspace file is tagged as ours yet still opens as
    /// plain JSON. Created at runtime — no Info.plist declaration is required for export/import to function.
    static let aislopdeskWorkspace = UTType(exportedAs: "com.aislopdesk.workspace", conformingTo: .json)
}

// MARK: - The FileDocument wrapper

/// A minimal `FileDocument` wrapping the `Data` the store's `exportWorkspaceData()` produces — the SwiftUI
/// `.fileExporter` payload. It is WRITE-ORIENTED: the exporter hands it the export bytes and it writes them
/// verbatim. On the read side the bytes are kept raw (the store's `importWorkspace` runs the
/// validate-then-drop decode), so the document never traps on a hostile / empty / truncated file.
struct WorkspaceTransferDocument: FileDocument {
    /// The exported document bytes (the `WorkspaceTransfer` envelope JSON), or the raw bytes of a picked file.
    var data: Data

    init(data: Data) { self.data = data }

    /// Both our dedicated type and plain `.json` are readable (a workspace file is JSON under the hood, so a
    /// user who renamed it `.json` can still re-import it).
    static var readableContentTypes: [UTType] { [.aislopdeskWorkspace, .json] }
    /// Written only as our dedicated type.
    static var writableContentTypes: [UTType] { [.aislopdeskWorkspace] }

    /// `.fileImporter` reads through here; keep the raw bytes (the store's `importWorkspace` does the decode),
    /// never trapping on a hostile / empty file (`regularFileContents == nil` ⇒ empty ⇒ a clean reject later).
    /// Non-throwing (it can't fail) — a non-throwing witness still satisfies `FileDocument`'s throwing init.
    init(configuration: ReadConfiguration) {
        data = configuration.file.regularFileContents ?? Data()
    }

    /// `.fileExporter` writes the export bytes verbatim. Non-throwing — satisfies the throwing requirement.
    func fileWrapper(configuration _: WriteConfiguration) -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Workspace-store environment slot (the Settings scene is separate from the main WindowGroup)

extension EnvironmentValues {
    /// The single live workspace owner, injected into the macOS `Settings` scene so the Advanced → Workspace
    /// rows can export/import. `nil` outside the app scene (previews / the iOS sheet before WI-5 wires it) →
    /// the Workspace section renders disabled rather than crashing.
    @Entry var workspaceStore: WorkspaceStore?
}

extension View {
    /// Inject the live ``WorkspaceStore`` into the environment (called at the Settings scene root).
    func workspaceStore(_ store: WorkspaceStore?) -> some View {
        environment(\.workspaceStore, store)
    }
}

// MARK: - Advanced → Workspace section (Export / Import rows)

/// The Advanced → "Workspace" Section (E7 WI-4): Export / Import rows that drive `.fileExporter` /
/// `.fileImporter` over ``WorkspaceTransferDocument``, reusing `WorkspaceStore.exportWorkspaceData()` /
/// `importWorkspace(_:mode:)`. Returns a `Group { Section }` so it composes into the Advanced `Form` (the
/// same shape ``VideoHostSettingsView`` / ``AllSettingsListView`` use, which proves view modifiers on the
/// `Group` survive the `Form`'s section rendering). A rejected import surfaces an inline alert and is a
/// no-op — never a crash (the codec's validate-then-drop owns the decode).
struct WorkspaceTransferSettingsView: View {
    @Environment(\.workspaceStore) private var workspaceStore

    @State private var exporting = false
    @State private var importing = false
    /// Filled at export-tap time from `store.exportWorkspaceData()` (the exact bytes the document writes).
    @State private var exportDocument = WorkspaceTransferDocument(data: Data())
    /// Raised when a picked file decodes to nothing (`importWorkspace == false`) → the "not a valid file" alert.
    @State private var importFailed = false

    var body: some View {
        Group {
            slateFormSection("Workspace") {
                Text(
                    "Export your layout, groups, and bookmarks to a file, or import one back. The "
                        + "host connection is never written into the file or adopted on import.",
                )
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)

                Button("Export Workspace…") {
                    guard let store = workspaceStore else { return }
                    exportDocument = WorkspaceTransferDocument(data: store.exportWorkspaceData())
                    exporting = true
                }
                Button("Import Workspace…") { importing = true }
            }
        }
        .disabled(workspaceStore == nil)
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .aislopdeskWorkspace,
            defaultFilename: "Workspace",
        ) { _ in }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: WorkspaceTransferDocument.readableContentTypes,
            allowsMultipleSelection: false,
        ) { result in handleImport(result) }
        .alert("Couldn’t import workspace", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "That file isn’t a valid aislopdesk workspace document. Your current workspace is unchanged.",
            )
        }
    }

    /// Reads the picked file's bytes and REPLACES the live canvas. A hostile / foreign / truncated file
    /// decodes to a no-op (`importWorkspace == false`) → raise the alert; the live workspace is untouched.
    /// Only a successfully-PICKED-but-undecodable file is "not a valid workspace": a user cancel or a picker
    /// IO error is NOT surfaced as the decode alert. Opens a security-scoped read (sandbox-correct) and
    /// never traps on a bad read.
    private func handleImport(_ result: Result<[URL], Error>) {
        guard let store = workspaceStore else { return }
        guard case let .success(urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), store.importWorkspace(data, mode: .replace) else {
            importFailed = true
            return
        }
    }
}

// MARK: - macOS File-menu items (optional parity, shortcut-LESS)

#if os(macOS)
/// The macOS File-menu Export / Import Workspace items (E7 WI-4, optional — mirrors the Settings → Advanced
/// "Config File" action rows). Shortcut-LESS by design: the app-level `NSEvent` dispatcher owns chord dispatch
/// (DECISIONS N6), so a `.keyboardShortcut` here would double-fire / swallow a prefix tail. The menu lives in
/// a different scene from the Settings `.fileExporter`, so a shared SwiftUI document state can't span them —
/// these use AppKit `NSSavePanel` / `NSOpenPanel` directly, reusing the SAME store engine + `UTType`. A
/// hostile pick decodes to a no-op and surfaces a toast — never a crash (validate-then-drop in the codec).
@MainActor
struct WorkspaceFileCommands: Commands {
    let store: WorkspaceStore
    let overlay: OverlayCoordinator

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export Workspace…") { exportWorkspace() }
            Button("Import Workspace…") { importWorkspace() }
        }
    }

    private func exportWorkspace() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = WorkspaceTransferDocument.writableContentTypes
        panel.nameFieldStringValue = "Workspace"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportWorkspaceData().write(to: url, options: .atomic)
        } catch {
            overlay.pushToast(Toast(
                id: "workspace.export", flavor: .error,
                title: "Export failed", body: error.localizedDescription,
            ))
        }
    }

    private func importWorkspace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = WorkspaceTransferDocument.readableContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), store.importWorkspace(data, mode: .replace) else {
            overlay.pushToast(Toast(
                id: "workspace.import", flavor: .error,
                title: "Import failed", body: "Not a valid aislopdesk workspace file.",
            ))
            return
        }
    }
}
#endif
#endif
