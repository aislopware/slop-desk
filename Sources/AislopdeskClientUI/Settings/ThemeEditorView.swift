// ThemeEditorView — the otty Appearance → Theme editor (E15 WI-7).
//
// A faithful clone of `docs/otty-clone/screenshots/dark-mode-theme.png` + `import-theme.png`: a live
// mini-preview strip, the SWATCH GRID (the big foreground/background pair on the left + the 16 ANSI colour
// dots in two rows on the right), the CHROME-REGION label groups (Window / Container / Panel / Sidebar /
// Titlebar / Tab / Accents / Cursor / Selection), then the Duplicate / Edit Selected Theme / Open Themes
// Folder buttons and the "Import Theme…" dropdown (5 formats) + open panel.
//
// VERTICAL-TABS-ONLY (E15 binding constraint): otty's `dark-mode-theme.png` shows a "Tabbar" swatch group.
// aislopdesk is vertical-tabs-only by deliberate product decision (no horizontal/top tab strip), so the
// "Tabbar" region is OMITTED here — its chrome folds into the vertical-rail Sidebar/Tab regions, which we
// keep. A future reviewer must NOT read the missing Tabbar group as a gap to backfill.
//
// EDIT MODEL: the swatch grid is a read-only DISPLAY of the ACTIVE theme cross-platform. On macOS, a CUSTOM
// theme can be edited in place — "Edit Selected Theme" reveals `ColorPicker`s over the active custom theme's
// ``ThemeDocument`` (reusing the `CursorColorHex` / `Color(cursorHex:)` glue from `CursorPreviewView`), and
// each edit writes the `.ottytheme` file back, re-scans the catalog, and re-resolves the active theme so the
// chrome + terminal cells reflect the change live. A BUILT-IN theme is read-only (Edit is disabled) — the
// user must Duplicate it first (Duplicate materialises the built-in's palette into a fresh custom
// `.ottytheme`, activates it, and drops straight into edit mode), exactly otty's flow.
//
// PLATFORM: every filesystem touch — Duplicate / Edit write-back / Open Themes Folder / Import — is
// `#if os(macOS)` (custom themes live at `~/.config/aislopdesk/themes/`, which iOS has no analog for). iOS
// renders the read-only swatch display + a note that editing/import is a macOS affordance today (a native
// iOS document-picker import is explicitly DEFERRED, per E15 decision #1). Otty.* tokens only (no raw
// font/radius literals — `scripts/check-ds-leaks.sh`).
//
// GOLDEN-SAFE: nothing here reaches `EnvConfig` / the sidecar / the wire. A custom ``ThemeDocument`` is pure
// client chrome + a terminal-palette override (the `AppearancePreferences` invariant); activating one writes
// only `customLightSlug` / `customDarkSlug` to `UserDefaults`.

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import AislopdeskWorkspaceCore
import SwiftUI

#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - ThemeDocument ← OttyTheme (materialise a built-in theme into an editable custom document)

extension ThemeDocument {
    /// Materialise a built-in (or any resolved) ``OttyTheme`` into a fresh ``ThemeDocument`` for Duplicate:
    /// the terminal palette (`foreground`/`background`/the 16-entry ANSI `palette`/`selection`/`cursor`) comes
    /// straight from the theme's already-canonical 6-hex fields, so the copy renders byte-identical TERMINAL
    /// cells. The structural CHROME surfaces (window/sidebar/tab/panel) are intentionally left unset so
    /// ``OttyTheme/init(document:)`` re-derives them from `background`/`foreground` with the same opacities the
    /// built-in used (identical chrome geometry). The `accent` IS carried explicitly, though: its derivation
    /// otherwise falls through to the ANSI "blue" palette slot, which on a Monokai filter is ORANGE — so an
    /// unset accent would silently flip a duplicated Monokai's chrome accent from cyan to orange. Pure — no
    /// AppKit — so the Duplicate path is headlessly unit-testable.
    init(materializing theme: OttyTheme, displayName: String, slug: String) {
        self.init(
            displayName: displayName,
            slug: slug,
            mode: theme.isLight ? .light : .dark,
            foreground: theme.terminalForegroundHex,
            background: theme.terminalBackgroundHex,
            palette: theme.ansiPalette,
            cursor: theme.cursorHex,
            cursorText: theme.cursorTextHex,
            selectionBackground: theme.selectionBackgroundHex,
            accent: theme.accentHex,
        )
    }
}

// MARK: - ThemeEditorView

/// The Appearance → Theme editor `Section` (swatch grid + chrome regions + Duplicate/Edit/Open-Folder/Import),
/// bound to the live ``PreferencesStore``. Hosted by `AppearanceSettingsTab` directly under the Theme picker.
struct ThemeEditorView: View {
    @Bindable var store: PreferencesStore

    /// The in-flight edit buffer — the active custom theme's ``ThemeDocument`` while editing, else `nil`.
    /// Edits mutate this (so the swatch ColorPickers reflect immediately), then ``persistEdit(_:)`` writes it
    /// back to disk. Always `nil` on iOS (no editing).
    @State private var editingDocument: ThemeDocument?
    /// A transient status line under the action row (import result / write failure). Cleared on the next action.
    @State private var statusMessage: String?

    #if os(macOS)
    /// A trailing-debounce handle for swatch `ColorPicker` edits: each drag tick updates ``editingDocument``
    /// (the live in-memory preview the swatch grid reads) and (re)arms this task; the EXPENSIVE persist (disk
    /// write + library rescan + app-wide surface reflow via ``persistEdit(_:)``) runs only ONCE the drag
    /// settles (≈ commit), never per tick. Cancelled / flushed when edit mode ends or the active theme changes.
    @State private var pendingPersist: Task<Void, Never>?
    #endif

    var body: some View {
        Section {
            previewStrip
            swatchGrid
            chromeRegions
            #if os(macOS)
            Divider()
            actionRow
            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: Otty.Typeface.small))
                    .foregroundStyle(Otty.Text.tertiary)
            }
            #else
            Text("iOS shows the built-in palette read-only. Custom themes are created, edited, and stored on "
                + "macOS (~/.config/aislopdesk/themes/); a native document-picker import on iOS is a planned "
                + "addition.")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
            #endif
        }
    }

    // MARK: Live preview strip

    /// A compact terminal mock that re-renders with the (edited) palette — otty's preview row above the swatch
    /// grid. Foreground text + a handful of ANSI-coloured filenames on the theme background.
    private var previewStrip: some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            HStack(spacing: 0) {
                Text("~/project ").foregroundStyle(paletteColor(6))
                Text("$ ").foregroundStyle(foregroundColor)
                Text("ls -la").foregroundStyle(foregroundColor)
            }
            HStack(spacing: Otty.Metric.space3) {
                Text("README.md").foregroundStyle(paletteColor(2))
                Text("src").foregroundStyle(paletteColor(4))
                Text("error.log").foregroundStyle(paletteColor(1))
                Text("TODO").foregroundStyle(paletteColor(3))
            }
        }
        .font(.system(size: Otty.Typeface.small, design: .monospaced))
        .padding(.vertical, Otty.Metric.space2)
        .padding(.horizontal, Otty.Metric.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusCard, style: .continuous)
                .fill(displayColor(displayBackground, fallback: Otty.Surface.card)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusCard, style: .continuous)
                .strokeBorder(Otty.Line.subtle, lineWidth: 1),
        )
    }

    // MARK: Swatch grid (fg/bg pair + 16 ANSI dots)

    /// The big foreground/background pair on the left and the 16 ANSI colour dots (two rows of 8) on the right.
    private var swatchGrid: some View {
        HStack(alignment: .top, spacing: Otty.Metric.space4) {
            VStack(spacing: Otty.Metric.space2) {
                bigSwatch(\.foreground, hex: displayForeground)
                bigSwatch(\.background, hex: displayBackground)
            }
            VStack(spacing: Otty.Metric.space2) {
                ansiRow(0..<8)
                ansiRow(8..<16)
            }
            Spacer(minLength: 0)
        }
    }

    private func ansiRow(_ range: Range<Int>) -> some View {
        HStack(spacing: Otty.Metric.space2) {
            ForEach(range, id: \.self) { index in ansiDot(index) }
        }
    }

    // MARK: Chrome-region groups (Tabbar OMITTED — vertical-tabs-only)

    /// The chrome-region label groups, mirroring `dark-mode-theme.png` MINUS the "Tabbar" group (folded into
    /// the vertical-rail Sidebar/Tab regions per the vertical-tabs-only product decision). Window/Container/
    /// Panel/Sidebar/Titlebar/Tab/Accents are read-only chrome DERIVED from the active theme; Cursor and
    /// Selection map to clean ``ThemeDocument`` fields and are editable for a custom theme on macOS.
    private var chromeRegions: some View {
        let theme = activeTheme
        return VStack(alignment: .leading, spacing: Otty.Metric.space2) {
            chromeGroup("Window", [theme.window])
            chromeGroup("Container", [theme.card, theme.cardBorder])
            chromeGroup("Panel", [theme.element, theme.content, theme.border])
            chromeGroup("Sidebar", [theme.sidebar, theme.textPrimary, theme.selectedCard])
            chromeGroup("Titlebar", [theme.window, theme.icon])
            chromeGroup("Tab", [theme.selectedCard, theme.textPrimary, theme.hover, theme.border])
            chromeGroup("Accents", [
                theme.accent, theme.textPrimary, theme.textSecondary,
                theme.textTertiary, theme.border, theme.hover,
            ])
            HStack(spacing: Otty.Metric.space3) {
                cursorGroup
                selectionGroup
            }
        }
    }

    /// The Cursor region — block colour + glyph-under-cursor. Editable swatches on macOS while editing a custom
    /// theme (cursor falls back to the foreground, cursor-text to the background — otty's "Default").
    private var cursorGroup: some View {
        chromeContainer("Cursor") {
            #if os(macOS)
            if isEditingActive {
                swatchPicker(optionalBinding(\.cursor, fallback: displayForeground))
                swatchPicker(optionalBinding(\.cursorText, fallback: displayBackground))
            } else {
                swatchSquare(displayColor(displayCursor, fallback: foregroundColor))
                swatchSquare(displayColor(displayCursorText, fallback: backgroundColor))
            }
            #else
            swatchSquare(displayColor(displayCursor, fallback: foregroundColor))
            swatchSquare(displayColor(displayCursorText, fallback: backgroundColor))
            #endif
        }
    }

    /// The Selection region — highlight background + (read-only) the text colour over it.
    private var selectionGroup: some View {
        chromeContainer("Selection") {
            #if os(macOS)
            if isEditingActive {
                swatchPicker(optionalBinding(\.selectionBackground, fallback: displaySelectionFallback))
                swatchSquare(foregroundColor)
            } else {
                swatchSquare(displayColor(displaySelection, fallback: Otty.State.selected))
                swatchSquare(foregroundColor)
            }
            #else
            swatchSquare(displayColor(displaySelection, fallback: Otty.State.selected))
            swatchSquare(foregroundColor)
            #endif
        }
    }

    // MARK: Swatch primitives

    /// A 16pt rounded chrome swatch with a hairline border.
    private func swatchSquare(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall, style: .continuous)
            .fill(color)
            .frame(width: 16, height: 16)
            .overlay(
                RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall, style: .continuous)
                    .strokeBorder(Otty.Line.subtle, lineWidth: 1),
            )
    }

    /// One labelled chrome-region pill: the role name + its swatches inside a rounded inset plate.
    private func chromeGroup(_ label: String, _ swatches: [Color]) -> some View {
        chromeContainer(label) {
            ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in swatchSquare(color) }
        }
    }

    /// The rounded inset pill that wraps a chrome-region label + arbitrary swatch content.
    private func chromeContainer(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: Otty.Metric.space2) {
            Text(label)
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
            content()
        }
        .padding(.vertical, Otty.Metric.space1)
        .padding(.horizontal, Otty.Metric.space2)
        .background(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusPill, style: .continuous)
                .fill(Otty.Surface.element),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusPill, style: .continuous)
                .strokeBorder(Otty.Line.subtle, lineWidth: 1),
        )
    }

    /// A foreground/background large swatch — an editable `ColorPicker` while editing on macOS, else a display
    /// tile showing the effective colour. Takes the document key path (not a prebuilt binding) so the iOS
    /// display path never references the macOS-only ``terminalBinding(_:fallback:)``.
    @ViewBuilder
    private func bigSwatch(_ keyPath: WritableKeyPath<ThemeDocument, String>, hex: String) -> some View {
        #if os(macOS)
        if isEditingActive {
            ColorPicker("", selection: terminalBinding(keyPath, fallback: hex), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 52, height: 26)
        } else {
            bigSwatchTile(hex)
        }
        #else
        bigSwatchTile(hex)
        #endif
    }

    private func bigSwatchTile(_ hex: String) -> some View {
        RoundedRectangle(cornerRadius: Otty.Metric.radiusControl, style: .continuous)
            .fill(displayColor(hex, fallback: Otty.Text.primary))
            .frame(width: 52, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: Otty.Metric.radiusControl, style: .continuous)
                    .strokeBorder(Otty.Line.subtle, lineWidth: 1),
            )
    }

    /// One ANSI palette dot (index 0…15) — an editable `ColorPicker` while editing on macOS, else a display dot.
    @ViewBuilder
    private func ansiDot(_ index: Int) -> some View {
        #if os(macOS)
        if isEditingActive {
            ColorPicker("", selection: paletteBinding(index), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 20, height: 20)
        } else {
            ansiDotTile(index)
        }
        #else
        ansiDotTile(index)
        #endif
    }

    private func ansiDotTile(_ index: Int) -> some View {
        Circle()
            .fill(paletteColor(index))
            .frame(width: 20, height: 20)
            .overlay(Circle().strokeBorder(Otty.Line.subtle, lineWidth: 1))
    }

    #if os(macOS)
    /// A small editable swatch for the Cursor/Selection optional fields.
    private func swatchPicker(_ binding: Binding<Color>) -> some View {
        ColorPicker("", selection: binding, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 18, height: 18)
    }
    #endif

    // MARK: - Action row (Duplicate / Edit / Open Folder / Import) — macOS only

    #if os(macOS)
    private var actionRow: some View {
        HStack(spacing: Otty.Metric.space2) {
            Button("Duplicate") { duplicateActive() }
            Button(isEditingActive ? "Done Editing" : "Edit Selected Theme") { toggleEdit() }
                .disabled(!isActiveCustom)
                .help(isActiveCustom
                    ? "Edit this custom theme's colours in place."
                    : "Built-in themes are read-only — Duplicate first to edit.")
            Button("Open Themes Folder") { openThemesFolder() }
            Menu("Import Theme…") {
                ForEach(ThemeImporters.Format.allCases, id: \.self) { format in
                    Button(format.displayLabel) { importTheme(format: format) }
                }
            }
            .fixedSize()
            Spacer(minLength: 0)
        }
    }
    #endif

    // MARK: - Active-theme resolution

    private var activeTheme: OttyTheme { ThemeStore.shared.active }

    /// Whether the active theme is a scanned custom (`custom-<slug>` id) vs a built-in.
    private var isActiveCustom: Bool { activeTheme.id.hasPrefix(Self.customIDPrefix) }

    /// The active custom theme's slug, or `nil` for a built-in.
    private var activeCustomSlug: String? {
        guard isActiveCustom else { return nil }
        return String(activeTheme.id.dropFirst(Self.customIDPrefix.count))
    }

    /// Whether the in-flight edit buffer targets the CURRENTLY-active custom theme (so a picker switch mid-edit
    /// doesn't leave stale ColorPickers bound to a no-longer-active document).
    private var isEditingActive: Bool {
        guard let editingDocument, let slug = activeCustomSlug else { return false }
        return editingDocument.slug == slug
    }

    // MARK: - Display sources (active theme, overlaid by the in-flight edit buffer)

    private var displayForeground: String { editingDocument?.foreground ?? activeTheme.terminalForegroundHex }
    private var displayBackground: String { editingDocument?.background ?? activeTheme.terminalBackgroundHex }
    private var displayCursor: String? { editingDocument?.cursor ?? activeTheme.cursorHex }
    private var displayCursorText: String? { editingDocument?.cursorText ?? activeTheme.cursorTextHex }
    private var displaySelection: String? { editingDocument?.selectionBackground ?? activeTheme.selectionBackgroundHex }
    private var foregroundColor: Color { displayColor(displayForeground, fallback: Otty.Text.primary) }
    private var backgroundColor: Color { displayColor(displayBackground, fallback: Otty.Surface.card) }

    /// The Selection ColorPicker fallback when the document declares none (the foreground's lighter wash isn't
    /// available as a hex, so use the foreground itself as a visible seed).
    private var displaySelectionFallback: String { displaySelection ?? displayForeground }

    private func paletteHex(_ index: Int) -> String {
        let palette = editingDocument?.palette ?? activeTheme.ansiPalette
        return palette.indices.contains(index) ? palette[index] : displayForeground
    }

    private func paletteColor(_ index: Int) -> Color {
        displayColor(paletteHex(index), fallback: Otty.Text.primary)
    }

    /// A cross-platform hex → `Color` (sRGB), falling back when the string is empty / malformed. Uses the pure
    /// ``CursorColorHex/rgb(_:)`` parser (available on every platform) so the swatch DISPLAY works on iOS too.
    private func displayColor(_ hex: String?, fallback: Color) -> Color {
        guard let hex, let rgb = CursorColorHex.rgb(hex) else { return fallback }
        return Color(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255, opacity: 1)
    }

    // MARK: - Edit bindings (macOS) + persistence

    #if os(macOS)
    /// Bind a required ``ThemeDocument`` colour field (`foreground`/`background`) to a `ColorPicker`. The edit
    /// updates the buffer (so the swatch reflects immediately) then persists. Reuses `Color(cursorHex:)` /
    /// `.cursorHexString` (the `CursorPreviewView` NaN-faithful glue).
    private func terminalBinding(
        _ keyPath: WritableKeyPath<ThemeDocument, String>, fallback: String,
    ) -> Binding<Color> {
        Binding(
            get: {
                let hex = editingDocument?[keyPath: keyPath] ?? fallback
                return Color(cursorHex: hex) ?? displayColor(fallback, fallback: Otty.Text.primary)
            },
            set: { newColor in
                guard var document = editingDocument else { return }
                document[keyPath: keyPath] = newColor.cursorHexString
                editingDocument = document
                schedulePersist() // live preview now; debounced disk write + reflow on drag-end
            },
        )
    }

    /// Bind an OPTIONAL ``ThemeDocument`` colour field (`cursor`/`cursorText`/`selectionBackground`) to a
    /// `ColorPicker`; the well shows `fallback` when the field is unset, and an edit writes a concrete hex.
    private func optionalBinding(
        _ keyPath: WritableKeyPath<ThemeDocument, String?>, fallback: String,
    ) -> Binding<Color> {
        Binding(
            get: {
                let hex = editingDocument?[keyPath: keyPath] ?? fallback
                return Color(cursorHex: hex) ?? displayColor(fallback, fallback: Otty.Text.primary)
            },
            set: { newColor in
                guard var document = editingDocument else { return }
                document[keyPath: keyPath] = newColor.cursorHexString
                editingDocument = document
                schedulePersist() // live preview now; debounced disk write + reflow on drag-end
            },
        )
    }

    /// Bind one ANSI palette entry to a `ColorPicker`.
    private func paletteBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                let hex = (editingDocument?.palette).flatMap { $0.indices.contains(index) ? $0[index] : nil }
                return Color(cursorHex: hex ?? "") ?? paletteColor(index)
            },
            set: { newColor in
                guard var document = editingDocument, document.palette.indices.contains(index) else { return }
                document.palette[index] = newColor.cursorHexString
                editingDocument = document
                schedulePersist() // live preview now; debounced disk write + reflow on drag-end
            },
        )
    }

    /// Write the edited document back to its `.ottytheme` file, re-scan the catalog, and re-resolve the active
    /// theme so the chrome + terminal cells reflect the edit live (the swatch grid already reflects it from the
    /// in-memory buffer). Failure is surfaced, never fatal.
    private func persistEdit(_ document: ThemeDocument) {
        guard let directory = ThemeLibrary.themesDirectoryURL() else { return }
        do {
            try ThemeLibrary.write(document, to: directory)
            ThemeCatalog.shared.reloadCustom()
            // Same slug ⇒ same theme id ⇒ no cross-`NSHostingController` re-pin, but `ThemeStore.active` is
            // reassigned (new colours) so in-window SwiftUI chrome re-reads, and the terminal config rebuilds
            // off the freshly-resolved palette.
            ThemeStore.shared.apply(appearance: store.appearance)
            store.refreshTerminalControls()
        } catch {
            statusMessage = "Could not save theme: \(error.localizedDescription)"
        }
    }

    /// (Re)arm the trailing debounce: a swatch ColorPicker drag already updated ``editingDocument`` (live
    /// preview), so here we only schedule the EXPENSIVE ``persistEdit(_:)`` to run once the drag goes quiet for
    /// a short window (≈ a commit). Each tick cancels the prior task, so disk/rescan/reflow fire ONCE per drag,
    /// not per pixel. Reads the SETTLED ``editingDocument`` at fire time.
    private func schedulePersist() {
        pendingPersist?.cancel()
        pendingPersist = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms quiet window ≈ drag-end
            guard !Task.isCancelled, let document = editingDocument else { return }
            pendingPersist = nil
            persistEdit(document)
        }
    }

    /// Commit any in-flight (debounced) swatch edit IMMEDIATELY, before leaving edit mode or switching the
    /// active theme — so the last drag is never lost to a cancelled pending task.
    private func flushPendingPersist() {
        guard pendingPersist != nil else { return }
        pendingPersist?.cancel()
        pendingPersist = nil
        if let document = editingDocument { persistEdit(document) }
    }

    // MARK: - Edit / Duplicate / Open Folder / Import (macOS)

    private func toggleEdit() {
        statusMessage = nil
        if isEditingActive {
            flushPendingPersist() // commit the last live swatch edit before leaving edit mode
            editingDocument = nil
        } else if let slug = activeCustomSlug {
            editingDocument = ThemeCatalog.shared.customDocument(slug: slug)
        }
    }

    /// Duplicate the active theme into a fresh, slug-unique custom `.ottytheme`, activate it, and drop into
    /// edit mode (otty's Duplicate flow). A built-in is materialised from its palette; a custom is copied.
    private func duplicateActive() {
        flushPendingPersist() // commit any in-flight edit on the current theme before duplicating
        statusMessage = nil
        let baseName: String
        var copy: ThemeDocument
        if let slug = activeCustomSlug, let source = ThemeCatalog.shared.customDocument(slug: slug) {
            baseName = source.displayName
            copy = source
        } else {
            baseName = Self.friendlyName(for: activeTheme)
            copy = ThemeDocument(
                materializing: activeTheme,
                displayName: baseName,
                slug: ThemeDocument.slug(from: baseName),
            )
        }

        let newName = baseName + " Copy"
        let existing = Set(ThemeCatalog.shared.customThemes.map(\.slug))
        let newSlug = ThemeLibrary.uniqueSlug(ThemeDocument.slug(from: newName), existing: existing)
        copy.displayName = newName
        copy.slug = newSlug

        guard let directory = ThemeLibrary.themesDirectoryURL() else {
            statusMessage = "No themes folder is available."
            return
        }
        do {
            try ThemeLibrary.write(copy, to: directory)
            ThemeCatalog.shared.reloadCustom()
            activate(slug: newSlug)
            editingDocument = ThemeCatalog.shared.customDocument(slug: newSlug)
            statusMessage = "Duplicated as “\(newName)”."
        } catch {
            statusMessage = "Could not duplicate theme: \(error.localizedDescription)"
        }
    }

    private func openThemesFolder() {
        guard let directory = ThemeLibrary.themesDirectoryURL() else {
            statusMessage = "No themes folder is available."
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    /// Open a panel for `format`, import the chosen file into the themes folder, re-scan, and activate it.
    private func importTheme(format: ThemeImporters.Format) {
        flushPendingPersist() // commit any in-flight edit before switching to the imported theme
        statusMessage = nil
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Import"
        panel.message = "Choose a \(format.displayLabel) theme file to import."
        if let types = Self.allowedContentTypes(for: format), !types.isEmpty {
            panel.allowedContentTypes = types
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try ThemeLibrary.importFile(
                at: url, format: format, builtinSlugs: Self.builtinSlugs,
            )
            ThemeCatalog.shared.reloadCustom()
            activate(slug: result.slug)
            editingDocument = nil
            statusMessage = "Imported as “\(result.slug)”."
        } catch {
            statusMessage = "Import failed: \(Self.describe(error))"
        }
    }

    /// Activate `slug` in the slot the current OS appearance resolves to: the dark slot when "Use separated
    /// theme for dark mode" is on AND the OS is dark, else the light / primary slot. Mutating
    /// `store.appearance` once routes through its `didSet` → applyAppearance → `ThemeStore` re-resolution.
    private func activate(slug: String) {
        var appearance = store.appearance
        if editingDarkSlot {
            appearance.customDarkSlug = slug
        } else {
            appearance.customLightSlug = slug
        }
        store.appearance = appearance
    }

    /// Whether the active slot is the DARK slot (so Duplicate/Import activate the slot the user is actually
    /// looking at under the current OS appearance).
    private var editingDarkSlot: Bool {
        (store.appearance.useSeparateDarkTheme ?? false) && ThemeStore.shared.osIsDark()
    }
    #endif
}

// MARK: - Static helpers

extension ThemeEditorView {
    /// The `OttyTheme.id` prefix a scanned custom theme carries (`custom-<slug>`).
    static let customIDPrefix = "custom-"

    /// A human-readable display name for a resolved theme (built-in id → its picker label), used as the
    /// Duplicate base name. A custom theme uses its document's own `displayName` (handled by the caller).
    static func friendlyName(for theme: OttyTheme) -> String {
        switch theme.id {
        case "monokai-classic": "Monokai Pro (Classic)"
        case "monokai-classic-light": "Monokai Pro Light"
        case "monokai-octagon": "Monokai Pro Octagon"
        case "monokai-machine": "Monokai Pro Machine"
        case "monokai-ristretto": "Monokai Pro Ristretto"
        case "monokai-spectrum": "Monokai Pro Spectrum"
        case "paper": "Paper"
        case "dark": "Dark"
        default:
            theme.id.hasPrefix(customIDPrefix) ? String(theme.id.dropFirst(customIDPrefix.count)) : theme.id
        }
    }

    #if os(macOS)
    /// The shipped built-in theme slugs an import must not collide with (so an imported "monokai-classic"
    /// becomes "monokai-classic-1" rather than shadowing a built-in). Mirrors the `ThemeStore` id table.
    static let builtinSlugs: Set<String> = [
        "monokai-classic", "monokai-classic-light", "monokai-octagon", "monokai-machine",
        "monokai-ristretto", "monokai-spectrum", "paper", "dark",
    ]

    /// The open-panel content-type filter for an import format. `nil` (Ghostty) ⇒ allow any file, since a
    /// Ghostty config is frequently extensionless. Text formats add plain-text so an oddly-named file is still
    /// selectable; iTerm2/otty use their dynamic extension type.
    static func allowedContentTypes(for format: ThemeImporters.Format) -> [UTType]? {
        switch format {
        case .ottytheme: [UTType(filenameExtension: "ottytheme")].compactMap(\.self)
        case .iterm2: [UTType(filenameExtension: "itermcolors"), .xml].compactMap(\.self)
        case .kitty: [UTType(filenameExtension: "conf"), .plainText, .text].compactMap(\.self)
        case .alacritty: [UTType(filenameExtension: "toml"), .plainText, .text].compactMap(\.self)
        case .ghostty: nil
        }
    }

    /// A short, user-facing reason for an import failure.
    static func describe(_ error: Error) -> String {
        guard let importError = error as? ThemeLibrary.ImportError else { return error.localizedDescription }
        switch importError {
        case .unreadable: return "the file could not be read."
        case .unknownFormat: return "the file format was not recognised."
        case .malformed: return "the file did not contain a valid theme."
        case .directoryUnavailable: return "no themes folder is available."
        }
    }
    #endif
}
#endif
