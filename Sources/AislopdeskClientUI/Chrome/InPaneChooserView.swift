// InPaneChooserView — the pane-type chooser rendered AS THE CONTENT of a freshly-minted `.chooser` pane.
//
// New-pane gestures (⌘D / ⌘⇧D split, the `+` button, title-menu split, right-click split, new-session)
// create a real, FOCUSED `.chooser` pane immediately; `PaneContainer` renders THIS view as that
// pane's content. The user picks Terminal or Remote window INLINE — `store.choosePaneKind(paneID, kind)`
// flips the pane's spec kind in place (same `PaneID`) so reconcile materializes the real session (a
// `.remoteGUI` pick then lands in its OWN in-pane window picker). No modal, no popover — the chooser IS the
// pane. Replaces the old `PaneChooserPopover` (a centred overlay), per the "create + focus, content = the
// choices" UX.
//
// Native system styling: semantic colors / system text styles, and a `.regularMaterial` card (the
// native-SwiftUI chrome migration — docs/DECISIONS.md 2026-07-03).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct InPaneChooserView: View {
    let store: WorkspaceStore
    let paneID: PaneID

    /// Pulls the AppKit first responder onto THIS freshly-minted pane. Without it the pane that was focused
    /// *before* the new-pane gesture keeps the keyboard: that is a `GhosttyTerminalView`, which only resigns
    /// first responder when a sibling **terminal** claims it — never for a SwiftUI sibling like this chooser —
    /// so a bare `t`/`r` would be typed into the OLD terminal instead of picking a kind here (the focus bug).
    @FocusState private var keyboardFocused: Bool

    /// The kinds a user can deliberately create (Terminal, Remote window) — the shared registry list, so the
    /// chooser, the navigator, and the cheat sheet can never drift.
    private var options: [PaneChooserOption] { PaneChooserRegistry.options }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Text("New Pane")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Choose what to open in this pane")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            VStack(spacing: 8) {
                ForEach(options, id: \.kind) { option in
                    InPaneChooserCard(option: option) { store.choosePaneKind(paneID, kind: option.kind) }
                }
            }
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Claim the keyboard for the NEW pane: `.focusable()` + `@FocusState` makes this view the window's
        // first responder, which RESIGNS the previously-focused terminal surface so its keyDown stops eating
        // our mnemonics. `.focusEffectDisabled()` keeps a flat, ring-free look. The claim is deferred one
        // runloop hop because a `@FocusState` set in the same tick as the view appears (before its backing
        // responder exists on-window) is dropped.
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onAppear { DispatchQueue.main.async { keyboardFocused = true } }
        // Single-key resolve, SCOPED TO FOCUS — unlike a global `.keyboardShortcut(modifiers: [])`, which is
        // window-wide and would also fire when a DIFFERENT pane is focused while a background chooser exists.
        // Map the pressed key to a chooser option and flip the pane's kind in place; `choosePaneKind` no-ops
        // once the pane is no longer a `.chooser`, so a stray repeat is harmless.
        .onKeyPress { press in
            guard let key = press.characters.first,
                  let option = PaneChooserRegistry.option(forKey: key) else { return .ignored }
            store.choosePaneKind(paneID, kind: option.kind)
            return .handled
        }
    }
}

/// One large chooser card: SF-Symbol + title + single-key mnemonic hint (t = Terminal, r = Remote). Clicking
/// runs `action`; the keyboard path is the parent's focus-scoped `.onKeyPress` (NOT a per-card global
/// `.keyboardShortcut`, which would leak across panes), so the hint here is purely an affordance.
private struct InPaneChooserCard: View {
    let option: PaneChooserOption
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: option.symbol)
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                Text(option.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(String(option.mnemonic).uppercased())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            // A native material card with a hover plate over it — the material replaces the old inset
            // element fill, so the card reads as native chrome without a bespoke surface color.
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1),
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
