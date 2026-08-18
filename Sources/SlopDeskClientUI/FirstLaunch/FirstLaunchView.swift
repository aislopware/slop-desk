// The guided first-launch checklist, in SwiftUI.
//
// A non-blocking, one-time setup flow composing already-built settings into a checklist
// (`spec/getting-started__first-launch.md`, governed by the 6 screenshots). The gating + step order live
// in the PURE `FirstLaunchModel` (`SlopDeskWorkspaceCore`); this is the view layer only — compiled +
// HW-verified, never unit-tested.
//
// WHO RENDERS THIS. `FirstLaunchView` is the PHONE's shell: `FirstLaunchModel.steps(for: .iOS)` drops the
// two macOS-only OS-integration steps, so the phone's checklist is On-Launch and Claude-hooks. The Mac
// draws its own shell in AppKit (`SlopDeskMacUI/FirstLaunch`) from the SAME model, and draws those two
// macOS-only steps itself — registering as the default terminal is LaunchServices and installing the CLI
// is `/usr/local/bin`, neither of which the phone has a version of.
//
// The two CROSS-PLATFORM step bodies are drawn once, here, and reached through ``FirstLaunchStepSurface``
// — the Mac hosts it. The same division the settings page makes: a control KIND each half draws its own
// way, a SURFACE there is nothing to differ about.

#if canImport(SwiftUI)
import Defaults
import SlopDeskClientCore
import SlopDeskWorkspaceCore // FirstLaunchModel, PreferencesStore
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
            Divider().overlay(Slate.Line.divider)
            ScrollView { stepBody.padding(Slate.Metric.space4) }
            Divider().overlay(Slate.Line.divider)
            footer
        }
        .frame(width: 540, height: 580)
        // The app's own ground, not the system's aux backdrop: this is the first surface anyone sees,
        // and it should be the cream the workspace behind it is about to be (ONE ISLAND, law 4).
        .background(Slate.Surface.field)
        // Safety net: any dismissal (Done / Skip Setup / Esc / window-close) marks first-launch complete so it
        // never re-presents. Idempotent (sets a single `Defaults` flag).
        .onDisappear { model.finish() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Slate.Metric.space3) {
            Image(systemName: model.currentStep.systemImage)
                .font(.system(size: Slate.Typeface.display))
                .foregroundStyle(Slate.State.accent)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                Text("Step \(model.stepNumber) of \(model.stepCount)")
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.tertiary)
                Text(model.currentStep.title)
                    .font(.system(size: Slate.Typeface.body, weight: .semibold))
                    .foregroundStyle(Slate.Text.primary)
                Text(model.currentStep.subtitle)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Slate.Metric.space4)
    }

    private var stepBody: some View {
        FirstLaunchStepSurface(step: model.currentStep, model: model)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Slate.Metric.space2) {
            if !model.isFirstStep {
                Button("Back") { model.back() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            progressDots
            Spacer()
            Button("Skip Setup") { finishAndDismiss() }
                .buttonStyle(.borderless)
                .foregroundStyle(Slate.Text.secondary)
            if model.isLastStep {
                Button("Done") { finishAndDismiss() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Next") { model.advance() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Slate.Metric.space4)
    }

    private var progressDots: some View {
        HStack(spacing: Slate.Metric.space1) {
            ForEach(Array(model.steps.enumerated()), id: \.element) { index, _ in
                Circle()
                    .fill(index == model.index ? Slate.State.accent : Slate.Line.subtle)
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func finishAndDismiss() {
        model.finish()
        dismiss()
    }
}

// MARK: - The step bodies both platforms show

/// One step's body, by the step.
///
/// The two CROSS-PLATFORM steps have a body here; the two macOS-only ones do not, and draw nothing —
/// the honest answer, since the phone never reaches them and the Mac draws its own. That is the same
/// contract `SettingsBespokeSurface` holds for an id it has no surface for.
package struct FirstLaunchStepSurface: View {
    private let step: FirstLaunchStep
    private let model: FirstLaunchModel

    package init(step: FirstLaunchStep, model: FirstLaunchModel) {
        self.step = step
        self.model = model
    }

    package var body: some View {
        switch step {
        case .onLaunch: FirstLaunchOnLaunchStep()
        case .installClaudeHooks: FirstLaunchClaudeHooksStep(model: model)
        case .defaultTerminal,
             .installCLI:
            EmptyView()
        }
    }
}

// MARK: - Step 1 · On Launch (cross-platform)

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

// MARK: - Step 4 · Install Claude Code hooks (cross-platform, Claude only)

/// Step 4 — reuses the `AgentHooksController` install card (Claude only). The controller is injected
/// by the app scene (`\.agentHooksController`); when no pane backs it the card shows the honest "Connect a
/// session" disabled state rather than a dead button.
private struct FirstLaunchClaudeHooksStep: View {
    @Environment(\.agentHooksController) private var agentHooks
    let model: FirstLaunchModel

    private var state: AgentHooksController.InstallState { AgentSettingsCard.installState(agentHooks) }

    var body: some View {
        FirstLaunchCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                    Text("Claude Code")
                        .font(.system(size: Slate.Typeface.base, weight: .semibold))
                        .foregroundStyle(Slate.Text.primary)
                    Text("Add hooks to ~/.claude/settings.json for real-time agent state.")
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.secondary)
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
            Label("Installed", systemImage: "checkmark").foregroundStyle(Slate.StatusInk.ok)
        case .installedInactive:
            // Written to settings.json but the host listener is not bound — honest amber, not the green
            // check (Settings ▸ Agents carries the restart hint).
            Label("Installed — inactive", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Slate.StatusInk.warn)
                .help("The host's hook socket isn't bound. Restart the host daemon, then open new panes.")
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

// MARK: - Shared step chrome (a flat card + a gray note)

/// A flat card wrapping a step's controls: a translucent lift over the window's cream, hairline-bordered.
///
/// `raised` rather than an opaque tone — the card is a REGION of this surface, not a second surface laid
/// on it, and a translucent fill tints the ground it stands on instead of substituting another palette's
/// grey for it (the same reason the device panels' placeholder plates use it).
struct FirstLaunchCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space3) { content }
            .padding(Slate.Metric.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard).fill(Slate.Surface.raised),
            )
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                    .stroke(Slate.Line.card, lineWidth: Slate.Metric.hairline),
            )
    }
}

/// A subordinate gray note beneath a step's controls (row-subtext styling).
struct FirstLaunchNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: Slate.Typeface.footnote))
            .foregroundStyle(Slate.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#endif
