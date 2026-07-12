// InPaneChooserView — the pane-type chooser rendered AS THE CONTENT of a freshly-minted `.chooser` pane.
//
// New-pane gestures (⌘D / ⌘⇧D split, the `+` button, title-menu split, right-click split, new-session)
// create a real, FOCUSED `.chooser` pane immediately; `PaneContainer` renders THIS view as that
// pane's content. The user picks Terminal or Remote window INLINE — `store.choosePaneKind(paneID, kind)`
// flips the pane's spec kind in place (same `PaneID`) so reconcile materializes the real session (a
// `.remoteGUI` pick then lands in its OWN in-pane window picker). No modal, no popover — a centred overlay
// popover would decouple the choice from the pane it creates; here the chooser IS the pane, so "create +
// focus" and "pick the content" are the same gesture.
//
// Slate.* tokens only (raw font/radius literals fail scripts/check-ds-leaks.sh).

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
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
        VStack(spacing: Slate.Metric.space2) {
            Spacer(minLength: 0)
            Text("New Pane")
                .font(.system(size: Slate.Typeface.body, weight: .semibold))
                .foregroundStyle(Slate.Text.primary)
            Text("Choose what to open in this pane")
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
                .padding(.bottom, Slate.Metric.space2)
            VStack(spacing: Slate.Metric.space2) {
                ForEach(options, id: \.kind) { option in
                    InPaneChooserCard(option: option) { store.choosePaneKind(paneID, kind: option.kind) }
                }
            }
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
        }
        .padding(Slate.Metric.space4)
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
            HStack(spacing: Slate.Metric.space3) {
                Image(systemName: option.symbol)
                    .font(.system(size: Slate.Typeface.body))
                    .foregroundStyle(Slate.State.accent)
                    .frame(width: 22)
                Text(option.title)
                    .font(.system(size: Slate.Typeface.body))
                    .foregroundStyle(Slate.Text.primary)
                Spacer(minLength: Slate.Metric.space2)
                Text(String(option.mnemonic).uppercased())
                    .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Slate.Text.secondary)
            }
            .padding(.horizontal, Slate.Metric.space3)
            .frame(height: Slate.Metric.heightRowTall)
            .background(hovering ? Slate.State.hover : Slate.Surface.raised)
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                    .stroke(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
            )
            .clipShape(RoundedRectangle(cornerRadius: Slate.Metric.radiusControl))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
