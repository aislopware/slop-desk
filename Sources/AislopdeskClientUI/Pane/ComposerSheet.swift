// ComposerSheet — the iOS bottom-sheet host for the otty Composer (E12 / WI-5). iOS has no system-level
// floating window above other apps (sandbox), so the macOS non-activating `NSPanel` float degrades here to a
// bottom sheet (`.presentationDetents([.medium, .large])`) hosting the SAME ``ComposerBar`` + queue strip —
// the documented iOS ceiling (spec `agents__composer.md`). The sheet keeps the pane's DURABLE
// ``ComposerModel`` so `⌘↩` still injects into the originating pane's PTY, and a pinned Composer is
// re-presented across tab switches.
//
// WI-5 defines the sheet content + the `composerSheet(...)` presentation modifier; the presentation SITE
// (binding `isFloating` / the pinned re-present) is wired by WI-6 in the workspace root. This is `#if
// os(iOS)` — it never compiles into the macOS slice (macOS uses ``ComposerFloatPanel``, WI-6).

#if os(iOS)
import AislopdeskWorkspaceCore
import SwiftUI

/// The bottom-sheet content: a compact title row, the Prompt-Queue chip strip, and the Composer field +
/// toolbar. Drives the SAME ``ComposerModel`` / ``ComposerLeafChrome`` as the in-pane mount, so sending /
/// enqueuing / drafting from the sheet behaves identically.
struct ComposerSheet: View {
    let composer: ComposerModel
    let chrome: ComposerLeafChrome
    var maxLines: Int = 12
    /// Whether the active pane is an agent (`claudeStatus != .none`) — appends " — Claude Code" to the title
    /// (the otty "Aislopdesk Composer — Claude Code" rule; no agent-name guessing when there is no agent).
    var agentActive: Bool = false

    private var title: String {
        agentActive ? "Aislopdesk Composer — Claude Code" : "Aislopdesk Composer"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: Otty.Typeface.footnote, weight: .semibold))
                    .foregroundStyle(Otty.Text.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Otty.Metric.space3)
            .padding(.vertical, Otty.Metric.space2)

            PromptQueueStrip(composer: composer)
            ComposerBar(composer: composer, chrome: chrome, maxLines: maxLines)
            Spacer(minLength: 0)
        }
        .background(NativePaneColor.terminalBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

extension View {
    /// Presents the iOS Composer ``ComposerSheet`` as a bottom sheet bound to `isPresented` (WI-6 binds this
    /// to the pane's `composer.isFloating`, and to the pinned re-present). The macOS float (a non-activating
    /// panel) has no iOS analogue — this is the documented substitute.
    func composerSheet(
        isPresented: Binding<Bool>,
        composer: ComposerModel,
        chrome: ComposerLeafChrome,
        maxLines: Int = 12,
        agentActive: Bool = false,
    ) -> some View {
        sheet(isPresented: isPresented) {
            ComposerSheet(composer: composer, chrome: chrome, maxLines: maxLines, agentActive: agentActive)
        }
    }
}
#endif
