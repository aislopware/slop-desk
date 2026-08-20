// SettingsBespokeSurfaces — the groups a table cannot describe, drawn for the PHONE.
//
// `Control.bespoke(id)` is the layout table's admission that a group is not a list of settings: an
// override box that parses free text, a card that writes someone's `~/.claude/settings.json`, a page
// that states its own emptiness. The table still says WHERE each one goes and on which platform, which
// is the part that was worth crossing; what it cannot say is what the surface looks like.
//
// UNTIL INCREMENT 49 THIS FILE WAS BOTH HALVES: the Mac resolved a bespoke id here too and hosted the
// result in an `NSHostingView`, on the argument that a surface which is not a control kind has nothing
// for the two halves to differ about. That argument confused a shared DECISION with a shared DRAWING. A
// hosted subtree is a SwiftUI runtime inside an `NSStackView` — it sizes itself, it sits outside the
// window's responder chain, and an `ImageRenderer` snapshot of the page photographs it as a hole — while
// the words inside it were "shared" only by being typed once in a view, which is exactly how four of the
// option lists here drifted from the Rust catalog that has held them all along.
//
// So this is now the phone's renderer and only the phone's (docs/56 stage D: the DECISION is shared and
// lives below both halves; the DRAWING is per-half and never is). Every word, option list, state→control
// fold and validation rule these surfaces carry lives one floor down in `SlopDeskClientCore`
// (`SettingsBespokePresentation`, `SettingsIndexPresentation`), where `SlopDeskMacUI/Settings` reads the
// same answers. Nothing here re-decides one.
//
// FOUR IDS HAVE NO ARM HERE, and none of them is an exception. `os-integration`, `cli-install`,
// `raw-overrides` and `config-file` are gated to `Platform::Mac` by the layout table, and what they do is
// LaunchServices, `/usr/local/bin`, a `SLOPDESK_*` env box and a path under `~/.config` — there is no
// phone version of any of them to keep in step with, so they are AppKit and their words live with that
// one renderer. A surface is drawn once; "once" means once per platform that HAS it.
//
// Each surface owns whatever display-time state it needs (which font scope is showing, what has been
// typed into a search field) rather than taking it from a host page, which is what lets one be dropped
// into any page with nothing but a store.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI

// MARK: - The door

/// A bespoke group, by the id the layout table carries — the PHONE's half of each.
///
/// `internal` since increment 49: its only cross-target caller was `SlopDeskMacUI`'s row builder, and
/// that half now draws its own (``SlopDeskMacUI/MacSettingsRowBuilder``). Nothing outside this target
/// resolves a bespoke id through here any more.
///
/// An id with no arm renders NOTHING — the honest answer for a surface a build does not have, and the
/// same contract a key with no arm holds on the described side. Four ids have no arm ON PURPOSE:
/// `os-integration`, `cli-install`, `raw-overrides` and `config-file` are gated to `Platform::Mac` by
/// the layout table, so the Mac draws them in AppKit and the phone never asks.
///
/// `onJump` is how the All-Settings index repoints the navigator: a SECTION ID, because the two halves
/// navigate differently (a `List` selection here, an `NSTableView` row there) and neither owns the
/// other's selection type.
struct SettingsBespokeSurface: View {
    private let id: String
    private let store: PreferencesStore
    private let onJump: (String) -> Void

    init(id: String, store: PreferencesStore, onJump: @escaping (String) -> Void = { _ in }) {
        self.id = id
        self.store = store
        self.onJump = onJump
    }

    var body: some View {
        switch id {
        case "notification-permission": NotificationPermissionRow()
        case "editor-empty": EditorEmptySurface()
        case "claude-hooks": ClaudeHooksSurface()
        // The Font-Family scope tabs over two different bodies — the primary family with its three
        // derived faces, or the ordered fallback list — and the "Aa" specimen combobox
        // (`font-setting.png`). Size, line height, ligatures and style are described rows above it.
        case "font-family": FontSettingsView(store: store)
        case "cursor-preview": CursorPreviewView(store: store)
        case "keybindings": KeybindingsEditorView(store: store)
        case "all-settings": AllSettingsListView(store: store, onJump: onJump)
        default: EmptyView()
        }
    }
}

// MARK: - Editor (reserved)

/// A RESERVED page states its own emptiness in the empty-state voice (MERIDIAN C3: muted symbol,
/// short title, one-line cause) rather than as a "File editor — Not available" row, which read like a
/// broken control. NOT a new `PaneEmptyCause`: that enum's typed causes are the pane area's
/// connection states, with pinned copy per case.
///
/// The glyph, the title and the sentence are ``SettingsEditorEmpty``'s — this is the arrangement only.
struct EditorEmptySurface: View {
    var body: some View {
        VStack(spacing: Slate.Metric.space2) {
            Image(systemName: SettingsEditorEmpty.systemImage)
                .font(SettingsType.placeholderGlyph)
                .foregroundStyle(SettingsInk.tertiary)
            Text(SettingsEditorEmpty.title)
                .font(SettingsType.body.weight(.semibold))
            Text(SettingsEditorEmpty.blurb)
                .font(SettingsType.subtitle)
                .foregroundStyle(SettingsInk.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Slate.Metric.space4)
    }
}

// MARK: - Agents → Claude Code

/// The CLAUDE CODE card (`install-agent-integeration.png`): a bold "Install Hooks" title + gray
/// description with trailing pill buttons (Install when not installed, "Installed" disabled +
/// Uninstall when installed) and a Status row. Disabled with a "Connect a session" note while no pane
/// backs the card. Claude-only.
///
/// Every word and every state→control fold is ``SettingsHooksCard``'s, which the Mac's
/// ``SlopDeskMacUI/MacHooksSettingsRows`` reads too. What is left here is the SwiftUI arrangement: which
/// row shape holds them, and that a spinner replaces the buttons rather than joining them.
struct ClaudeHooksSurface: View {
    @Environment(\.agentHooksController) private var agentHooks

    var body: some View {
        Group {
            LabeledContent {
                installButtons(SettingsHooksCard.buttons(agentHooks))
            } label: {
                rowLabel(SettingsHooksCard.rowTitle, SettingsHooksCard.rowBlurb)
            }

            LabeledContent(SettingsHooksCard.statusRowTitle) {
                statusBadge(SettingsHooksCard.status(agentHooks))
            }

            if SettingsHooksCard.showsConnectNote(agentHooks) {
                Text(SettingsHooksCard.connectNote)
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.tertiary)
            }

            if SettingsHooksCard.showsInactiveNote(agentHooks) {
                Text(SettingsHooksCard.inactiveNote)
                    .font(SettingsType.subtitle)
                    .foregroundStyle(SettingsInk.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(SettingsHooksCard.restartCaption)
                .font(SettingsType.caption)
                .foregroundStyle(SettingsInk.tertiary)
        }
        .task { await agentHooks?.refresh() }
    }

    /// The trailing pill buttons for the Install Hooks row. While a write is in flight a small spinner
    /// replaces them; a disabled Install is drawn rather than hidden, which is what keeps the row saying
    /// what it is for while nothing backs it.
    private func installButtons(_ slot: SettingsHooksButtons) -> some View {
        HStack(spacing: Slate.Metric.space2) {
            switch slot {
            case .offerUninstall:
                Button(SettingsHooksCard.installedTitle) {}.disabled(true)
                Button(SettingsHooksCard.uninstallTitle) { Task { await agentHooks?.uninstall() } }
            case let .offerInstall(enabled):
                Button(SettingsHooksCard.installTitle) {
                    guard enabled else { return }
                    Task { await agentHooks?.install() }
                }
                .disabled(!enabled)
            case .working:
                ProgressView().controlSize(.small)
            }
        }
        .buttonStyle(.bordered)
    }

    /// The Status-row trailing badge: the word, its silhouette when it has one, in the ink the state names.
    @ViewBuilder
    private func statusBadge(_ status: SettingsHooksStatus) -> some View {
        if let systemImage = status.systemImage {
            Label(status.label, systemImage: systemImage)
                .foregroundStyle(SettingsInk.of(status.ink))
        } else {
            Text(status.label).foregroundStyle(SettingsInk.of(status.ink))
        }
    }
}

// MARK: - The one ink vocabulary, resolved for this half

extension SettingsInk {
    /// One ``SettingsProseInk`` role as this half's colour.
    ///
    /// The role descends from `SlopDeskClientCore` and the hue does not: `SlopDeskSlate` DEPENDS on that
    /// target, so a token read from below would be a cycle rather than a widening (docs/56 increment 47).
    /// The Mac spells the same seven in `NSColor` on its own side.
    static func of(_ role: SettingsProseInk) -> Color {
        switch role {
        case .primary: primary
        case .secondary: secondary
        case .tertiary: tertiary
        case .ok: ok
        case .warn: warn
        case .err: err
        case .info: info
        }
    }
}

#endif
