#if canImport(SwiftUI)
import SwiftUI

// MARK: - KeyboardCheatSheet (the ⌘/ shortcut reference, generated from the bindings table)

/// The data behind the ⌘/ keyboard-shortcut overlay. Every workspace row's GLYPH is resolved from
/// ``CommandInterpreter/defaultBindings`` via ``CommandPaletteView/shortcutHint(for:)`` — the SAME
/// single source of truth the menu bar + palette use — so a rebinding can never drift the cheat sheet.
/// A small curated "Terminal" section covers the chords the focused libghostty surface handles itself
/// (⌘C/V/A, font sizing) which live outside the workspace table, plus the ⌘K palette + ⌘/ itself.
///
/// `@MainActor` because `shortcutHint` reads the main-actor `defaultBindings`. Pure (no view state) —
/// the overlay just renders ``sections()``.
@MainActor
enum KeyboardCheatSheet {
    struct Item: Identifiable, Equatable {
        let glyph: String
        let label: String
        var id: String { label }
    }

    struct Section: Identifiable, Equatable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    /// Every WORKSPACE command the sheet documents, grouped, in display order. Used both to build the
    /// sections and (via ``workspaceCommands``) to drift-guard against ``defaultBindings``.
    private static let groups: [(title: String, commands: [(WorkspaceCommand, String)])] = [
        ("Panes", [
            (.newPaneDefault, "New pane"),
            (.newPane(.terminal), "New terminal"),
            (.newPane(.claudeCode), "New Claude Code pane"),
            (.newPane(.remoteGUI), "New remote window"),
            (.duplicatePane, "Duplicate pane"),
            (.closePane, "Close pane"),
            (.reopenClosedPane, "Reopen closed pane"),
            (.renamePane, "Rename pane"),
            (.reconnectPane, "Reconnect pane"),
        ]),
        ("Groups & selection", [
            (.newGroup, "New group / group selection"),
            (.groupSelection, "Group selected panes"),
            (.selectAllPanes, "Select all panes"),
        ]),
        ("Focus", [
            (.focus(.left), "Focus left"),
            (.focus(.right), "Focus right"),
            (.focus(.up), "Focus up"),
            (.focus(.down), "Focus down"),
            (.cycleFocus(forward: true), "Focus next pane"),
            (.cycleFocus(forward: false), "Focus previous pane"),
            (.switchRecentPane(forward: false), "Go to previous pane (recent)"),
            (.switchRecentPane(forward: true), "Forward through recent panes"),
            (.cycleFocusInGroup(forward: true), "Cycle next in group"),
            (.cycleFocusInGroup(forward: false), "Cycle previous in group"),
        ]),
        ("Arrange & view", [
            (.tidy, "Tidy layout"),
            (.centerFocusedPane, "Center on pane"),
            (.centerAll, "Center on all"),
            (.toggleZoom, "Maximize pane"),
            (.toggleOverview, "Overview"),
            (.toggleBroadcast, "Broadcast input"),
            (.saveLayout, "Save current layout"),
            (.manageSnippets, "Manage snippets"),
            (.runLastSnippet, "Run last snippet"),
        ]),
    ]

    /// Flat list of every workspace command the sheet covers — the drift guard's reference set.
    static var workspaceCommands: [WorkspaceCommand] { groups.flatMap { $0.commands.map(\.0) } }

    /// The rendered sections for the overlay. A workspace row is dropped if its command has no default
    /// chord (so the sheet never shows a blank glyph); bookmark slots are collapsed to two representative
    /// rows; the curated terminal/palette extras are appended.
    static func sections() -> [Section] {
        var out: [Section] = groups.compactMap { group in
            let items = group.commands.compactMap { cmd, label -> Item? in
                guard let glyph = CommandPaletteView.shortcutHint(for: cmd) else { return nil }
                return Item(glyph: glyph, label: label)
            }
            return items.isEmpty ? nil : Section(title: group.title, items: items)
        }
        // Viewport bookmarks: ⌘1–9 recall / ⇧⌘1–9 save — collapsed (the 18 per-slot bindings would
        // bury the sheet). Shown only if slot 1 is actually bound (it always is in the defaults).
        if CommandPaletteView.shortcutHint(for: .recallBookmark(1)) != nil {
            out.append(Section(title: "Viewport bookmarks", items: [
                Item(glyph: "⌘1–9", label: "Recall bookmark"),
                Item(glyph: "⇧⌘1–9", label: "Save bookmark"),
            ]))
        }
        // Chords handled OUTSIDE the workspace table: the palette (scene-level), and the ones the focused
        // terminal surface claims itself (the §5 conflict rule). Curated, not generated.
        out.append(Section(title: "Search & terminal", items: [
            Item(glyph: "⌘K", label: "Command palette"),
            Item(glyph: "⌘/", label: "This shortcut list"),
            Item(glyph: "⌘C / ⌘V", label: "Copy / paste (focused terminal)"),
            Item(glyph: "⌘A", label: "Select all text (focused terminal)"),
            Item(glyph: "⌘= / ⌘− / ⌘0", label: "Font size (focused terminal)"),
        ]))
        return out
    }
}

// MARK: - KeyboardCheatSheetView (the ⌘/ overlay)

/// A Spotlight-style floating card listing every shortcut, grouped, dismissed by ⎋ / backdrop tap / ⌘/.
/// Mirrors ``CommandPaletteView``'s overlay shape (dim backdrop, top-third card) but is read-only.
struct KeyboardCheatSheetView: View {
    @Binding var isPresented: Bool

    var body: some View {
        if isPresented {
            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.18))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }
                card
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Keyboard Shortcuts", systemImage: "keyboard")
                    .font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(KeyboardCheatSheet.sections()) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(section.items) { item in
                                HStack(spacing: 12) {
                                    Text(item.label)
                                        .font(.callout)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(item.glyph)
                                        .font(.system(.callout, design: .rounded).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(Color.primary.opacity(0.06)))
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: 520, maxHeight: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
            Color.primary.opacity(0.08),
            lineWidth: 1,
        ) }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 70)
        #if os(macOS)
            .onExitCommand { isPresented = false }
        #endif
    }
}
#endif
