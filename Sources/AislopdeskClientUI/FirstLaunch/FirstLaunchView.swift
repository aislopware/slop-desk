// E20 WI-9 (ES-E20-4) — the guided first-launch sheet.
//
// A non-blocking, one-time setup flow composing already-built settings into a first-launch checklist
// (`spec/getting-started__first-launch.md`, governed by the 6 screenshots): On-Launch (E7), Set-as-Default-
// Terminal (LOCAL handler; the remote "Common Apps" case honestly-DISABLED with a note), Install-CLI (the
// macOS `CLIInstaller` symlink + Omit-Prefix + Allow-Overwrite), Theme (E15 picker), and Install-Claude-hooks
// (the E13 `AgentHooksController` card). The gating + step order live in the PURE `FirstLaunchModel`
// (`AislopdeskWorkspaceCore`); this is the view layer only — compiled + HW-verified, never unit-tested.
//
// iOS keeps the cross-platform steps (On-Launch, Theme, Claude-hooks); `FirstLaunchModel.steps(for: .iOS)`
// drops the two macOS-only OS-integration steps, so the macOS-only step bodies (`#if os(macOS)`) are never
// reached on iOS.

#if canImport(SwiftUI)
import AislopdeskVideoProtocol // ThemeChoice
import AislopdeskWorkspaceCore // FirstLaunchModel, PreferencesStore
import Defaults
import SwiftUI

/// The guided first-launch sheet shell: a header (glyph + "Step N of M" + title/subtitle), the per-step body,
/// and a footer (Back · progress dots · Skip / Next / Done). Dismissing by ANY path persists
/// ``FirstLaunchModel/finish()`` (`.onDisappear` safety net) so the sheet never re-presents.
public struct FirstLaunchView: View {
    @Bindable var model: FirstLaunchModel
    @Bindable var store: PreferencesStore
    @Environment(\.dismiss) private var dismiss

    public init(model: FirstLaunchModel, store: PreferencesStore) {
        self.model = model
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { stepBody.padding(16) }
            Divider()
            footer
        }
        .frame(width: 540, height: 580)
        // Safety net: any dismissal (Done / Skip Setup / Esc / window-close) marks first-launch complete so it
        // never re-presents. Idempotent (sets a single `Defaults` flag).
        .onDisappear { model.finish() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.currentStep.systemImage)
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Step \(model.stepNumber) of \(model.stepCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(model.currentStep.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(model.currentStep.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: - Step body (exhaustive switch; macOS-only cases never reached on iOS)

    @ViewBuilder
    private var stepBody: some View {
        switch model.currentStep {
        case .onLaunch:
            FirstLaunchOnLaunchStep()
        case .theme:
            FirstLaunchThemeStep(store: store, model: model)
        case .installClaudeHooks:
            FirstLaunchClaudeHooksStep(model: model)
        case .defaultTerminal:
            #if os(macOS)
            FirstLaunchDefaultTerminalStep(model: model)
            #else
            EmptyView()
            #endif
        case .installCLI:
            #if os(macOS)
            FirstLaunchInstallCLIStep(model: model)
            #else
            EmptyView()
            #endif
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if !model.isFirstStep {
                Button("Back") { model.back() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            progressDots
            Spacer()
            Button("Skip Setup") { finishAndDismiss() }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            if model.isLastStep {
                Button("Done") { finishAndDismiss() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Next") { model.advance() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private var progressDots: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.steps.enumerated()), id: \.element) { index, _ in
                Circle()
                    .fill(index == model.index ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func finishAndDismiss() {
        model.finish()
        dismiss()
    }
}

// MARK: - Step 1 · On Launch (E7 — cross-platform)

/// Step 1 — the On-Launch picker (`@Default(.onLaunch)` — the SAME live key Settings → General binds).
/// "Restore Last Session" reconnects the still-running detached host sessions; "New Window" starts fresh.
private struct FirstLaunchOnLaunchStep: View {
    @Default(.onLaunch) private var onLaunch

    var body: some View {
        FirstLaunchCard {
            onLaunchPicker
            FirstLaunchNote(
                "Restore Last Session brings back your scrollback and reconnects agents that kept running "
                    + "on the host. You can change this any time in Settings → General.",
            )
        }
    }

    /// The On-Launch picker — a radio group on macOS, an inline list on iOS (`.radioGroup` is
    /// macOS-only).
    @ViewBuilder
    private var onLaunchPicker: some View {
        let picker = Picker("On Launch", selection: $onLaunch) {
            Text("Restore Last Session").tag(OnLaunchBehavior.restoreLastSession)
            Text("New Window").tag(OnLaunchBehavior.newWindow)
        }
        #if os(macOS)
        picker.pickerStyle(.radioGroup)
        #else
        picker.pickerStyle(.inline)
        #endif
    }
}

// MARK: - Step 4 · Theme (E15 — cross-platform)

/// Step 4 — a compact theme grid (the E15 built-ins). Picking a swatch writes the light/primary slot
/// (`store.appearance.theme`) exactly like Settings → Appearance, so the whole app retints LIVE. A "more in
/// Settings" note points at the full grid + the ⌘⇧P palette flow.
private struct FirstLaunchThemeStep: View {
    @Bindable var store: PreferencesStore
    let model: FirstLaunchModel

    /// The built-ins offered in the first-launch grid (light-then-dark ordering, curated).
    private let choices: [(ThemeChoice, String)] = [
        (.paper, "Paper"),
        (.monokaiProClassicLight, "Monokai Light"),
        (.monokaiProClassic, "Monokai Classic"),
        (.dark, "Dark"),
        (.monokaiProOctagon, "Octagon"),
        (.monokaiProMachine, "Machine"),
        (.monokaiProRistretto, "Ristretto"),
        (.monokaiProSpectrum, "Spectrum"),
    ]

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    private var selected: ThemeChoice {
        store.appearance.theme ?? .monokaiProClassic
    }

    var body: some View {
        FirstLaunchCard {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(choices, id: \.0) { choice, label in
                    themeSwatch(choice, label)
                }
            }
            FirstLaunchNote("See every theme — and tweak colours, fonts, and padding — in Settings → Appearance.")
        }
    }

    /// One theme option card: a check circle + name chip; the selected card gets an accent wash + accent ring.
    private func themeSwatch(_ choice: ThemeChoice, _ label: String) -> some View {
        let isSelected = selected == choice
        return Button {
            select(choice)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                        lineWidth: 1,
                    ),
            )
        }
        .buttonStyle(.plain)
    }

    private func select(_ choice: ThemeChoice) {
        var appearance = store.appearance
        appearance.theme = choice
        store.appearance = appearance // didSet re-applies the theme LIVE (ThemeStore repoints every token).
        model.markComplete(.theme)
    }
}

// MARK: - Step 5 · Install Claude Code hooks (E13 — cross-platform, Claude only)

/// Step 5 — reuses the E13 `AgentHooksController` install card (Claude only). The controller is injected
/// by the app scene (`\.agentHooksController`); when no pane backs it the card shows the honest "Connect a
/// session" disabled state rather than a dead button.
private struct FirstLaunchClaudeHooksStep: View {
    @Environment(\.agentHooksController) private var agentHooks
    let model: FirstLaunchModel

    private var state: AgentHooksController.InstallState { AgentSettingsCard.installState(agentHooks) }

    var body: some View {
        FirstLaunchCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Code")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Add hooks to ~/.claude/settings.json for real-time agent state.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                installControl
            }
            if state == .disconnected || state == .unknown {
                FirstLaunchNote("Connect a session first, then install the hooks. You can also do this later in "
                    + "Settings → Agents.")
            }
        }
        .task { await agentHooks?.refresh() }
    }

    @ViewBuilder
    private var installControl: some View {
        switch state {
        case .installed:
            Label("Installed", systemImage: "checkmark").foregroundStyle(.green)
        case .installedInactive:
            // Queue-safety cluster (2026-07-02): written to settings.json but the host listener is not
            // bound — honest amber, not the green check (Settings ▸ Agents carries the restart hint).
            Label("Installed — inactive", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help("Restart the host daemon with AISLOPDESK_AGENT_HOOKS=1, then open new panes.")
        case .notInstalled:
            Button("Install") {
                Task {
                    await agentHooks?.install()
                    // The settings.json write is what this step tracks — `installedInactive` still
                    // counts (the listener half is a hostd-launch concern, surfaced by the badge).
                    if agentHooks?.isInstalled == true { model.markComplete(.installClaudeHooks) }
                }
            }
            .buttonStyle(.bordered)
        case .working:
            ProgressView().controlSize(.small)
        case .disconnected,
             .unknown:
            Button("Install") {}.disabled(true).buttonStyle(.bordered)
        }
    }
}

// MARK: - Shared step chrome (an inset card + a subordinate note)

/// An inset card wrapping a step's controls — a subtle primary-tint fill with a hairline separator border
/// (the native inset-box treatment).
struct FirstLaunchCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator, lineWidth: 1),
            )
    }
}

/// A subordinate gray note beneath a step's controls (row-subtext styling).
struct FirstLaunchNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if os(macOS)

// MARK: - Step 2 · Set as Default Terminal (macOS-only — LOCAL handler)

/// Step 2 — register the app as the LOCAL OS handler for terminal URL schemes / shell scripts, plus the
/// Finder-Integration and Full-Disk-Access deep-links. The "Set as Default Terminal for Common Apps" remote
/// case is honestly-DISABLED with a note (E20 exclusion §4 — no dead button: a remote-host editor's config
/// can't be rewritten from the client).
private struct FirstLaunchDefaultTerminalStep: View {
    let model: FirstLaunchModel
    @State private var isDefault = false

    var body: some View {
        FirstLaunchCard {
            actionRow(
                "Default Terminal",
                "Handle `ssh://` links and shell scripts opened from Finder or `open`.",
            ) {
                if isDefault {
                    Label("Default", systemImage: "checkmark").foregroundStyle(.green)
                } else {
                    Button("Set as Default Terminal") {
                        Task {
                            await DefaultTerminalIntegration.setAsDefaultTerminal()
                            isDefault = DefaultTerminalIntegration.isDefaultTerminal()
                            if isDefault { model.markComplete(.defaultTerminal) }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            // Honestly-disabled remote case (no dead button) — a documented note, not a Configure… button.
            actionRow(
                "Default Terminal for Common Apps",
                "Editors and git GUIs hardcode Terminal.app. Rewriting their config only works for a LOCAL "
                    + "editor — an editor on the remote host needs a host-side agent, so this is unavailable "
                    + "in the remote model.",
            ) {
                Text("Unavailable").foregroundStyle(.tertiary)
            }
            actionRow(
                "Finder Integration",
                "Add \u{201C}Open in Aislopdesk\u{201D} to Finder's right-click Services menu for folders.",
            ) {
                Button("Open System Settings") { DefaultTerminalIntegration.openFinderServicesSettings() }
                    .buttonStyle(.bordered)
            }
            actionRow(
                "Full Disk Access",
                "Needed when commands run inside Aislopdesk must read or write protected files. The app works "
                    + "without it.",
            ) {
                Button("Open System Settings") { DefaultTerminalIntegration.openFullDiskAccessSettings() }
                    .buttonStyle(.bordered)
            }
        }
        .onAppear { isDefault = DefaultTerminalIntegration.isDefaultTerminal() }
    }

    private func actionRow(
        _ title: String,
        _ subtitle: String,
        @ViewBuilder trailing: () -> some View,
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

// MARK: - Step 3 · Install the Aislopdesk CLI (macOS-only)

/// Step 3 — install the `/usr/local/bin/aislopdesk` symlink (admin-once via `CLIInstaller`), the
/// Omit-Prefix shell-function toggle, and the Allow-Overwrite toggle. The toggles drive `CLIInstaller`'s
/// shim-file write (the SAME card lives in Settings → Shell).
private struct FirstLaunchInstallCLIStep: View {
    let model: FirstLaunchModel
    @State private var installer = CLIInstaller()

    var body: some View {
        FirstLaunchCard {
            CLIInstallCardBody(installer: installer, onInstalled: { model.markComplete(.installCLI) })
        }
        .onAppear { installer.refreshInstalled() }
    }
}

// MARK: - Shared CLI-install card body (first-launch step 3 + Settings → Shell)

/// The "Aislopdesk CLI" card body — Install/Uninstall (admin-once via ``CLIInstaller``), the Omit-Prefix
/// toggle, and the Allow-Overwrite toggle — shared by the first-launch step and the Settings → Shell card so
/// the two are byte-identical (one source). The toggles drive ``CLIInstaller/applyOmitPrefix(enabled:allowOverwrite:)``
/// (writes the shim file). macOS-only.
struct CLIInstallCardBody: View {
    /// The shared install controller (owned by the presenting view's `@State`; read here via Observation).
    let installer: CLIInstaller
    /// Called when an install SUCCEEDS (the first-launch step marks itself complete; Settings passes nil).
    let onInstalled: (() -> Void)?
    @Default(.cliInstalled) private var cliInstalled
    @Default(.omitCLIPrefix) private var omitPrefix
    @Default(.allowPrefixOverwrite) private var allowOverwrite

    init(installer: CLIInstaller, onInstalled: (() -> Void)? = nil) {
        self.installer = installer
        self.onInstalled = onInstalled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            installRow
            Divider()
            Toggle("Omit `aislopdesk` Prefix", isOn: $omitPrefix)
                .onChange(of: omitPrefix) { _, on in
                    installer.applyOmitPrefix(enabled: on, allowOverwrite: allowOverwrite)
                }
            FirstLaunchNote("Expose `edit`, `view`, `watch`, `jump`, and `learn` as bare commands in shells "
                + "launched by Aislopdesk.")
            Toggle("Allow Overwrite", isOn: $allowOverwrite)
                .onChange(of: allowOverwrite) { _, _ in
                    if omitPrefix { installer.applyOmitPrefix(enabled: true, allowOverwrite: allowOverwrite) }
                }
            FirstLaunchNote("Leave OFF unless you already have your own `edit`/`view`/… functions you want "
                + "Aislopdesk to replace.")
            if installer.phase == .failed, let message = installer.errorMessage {
                FirstLaunchNote(message)
            }
        }
    }

    private var installRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install CLI")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Adds `/usr/local/bin/aislopdesk` (requests admin once).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            installControl
        }
    }

    @ViewBuilder
    private var installControl: some View {
        if installer.phase == .working {
            ProgressView().controlSize(.small)
        } else if cliInstalled {
            HStack(spacing: 8) {
                Label("Installed", systemImage: "checkmark").foregroundStyle(.green)
                Button("Uninstall") { Task { await installer.uninstall() } }
                    .buttonStyle(.bordered)
            }
        } else {
            Button("Install") {
                Task { if await installer.install() { onInstalled?() } }
            }
            .buttonStyle(.bordered)
        }
    }
}
#endif
#endif
