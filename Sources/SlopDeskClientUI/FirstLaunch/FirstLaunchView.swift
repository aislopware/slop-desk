// The guided first-launch checklist, in SwiftUI.
//
// A non-blocking, one-time setup flow composing already-built settings into a checklist
// (`spec/getting-started__first-launch.md`, governed by the 6 screenshots). The gating + step order live
// in the PURE `FirstLaunchModel` (`SlopDeskWorkspaceCore`); this is the view layer only — compiled +
// HW-verified, never unit-tested.
//
// WHO RENDERS THIS. `FirstLaunchView` is the PHONE's shell, and only the phone's:
// `FirstLaunchModel.steps(for: .iOS)` drops the two macOS-only OS-integration steps, so the phone's
// checklist is On-Launch and Claude-hooks. The Mac draws its own shell in AppKit
// (`SlopDeskMacUI/FirstLaunch`) from the SAME model, and draws ALL FOUR of its steps itself.
//
// ⚠️ NOTHING IN THIS FILE IS DRAWN FOR THE MAC ANY MORE (docs/56 stage D, increment 47). It used to be:
// the two CROSS-PLATFORM step bodies were drawn once here, in ``FirstLaunchStepSurface``, and the Mac
// HOSTED that surface — which was the last thing `MacFirstLaunchSheet` imported this target for. The Mac
// draws them in AppKit now, so `FirstLaunchStepSurface` is `private` and this whole file is the phone's.
//
// What CROSSED is the painting; what did NOT is any answer. Every word these bodies say, the picker's
// option order, which state earns a badge rather than a button, and whether an install ticks the step
// are ``FirstLaunchStepPresentation`` in `SlopDeskClientCore` — below both halves, so neither half can
// re-decide them. The hue is the one thing that stays with each drawing, because `SlopDeskSlate` depends
// on `SlopDeskClientCore` and a token read from below would be a cycle.

#if canImport(SwiftUI)
import Defaults
import SlopDeskClientCore
import SlopDeskSlate
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
///
/// ⚠️ `private`, NARROWED FROM `package`. The widening existed for exactly one cross-target caller —
/// `MacFirstLaunchSheet` hosting this in an `NSHostingView` — under docs/56's promise that it comes back
/// the moment that caller draws its own. It does, so it is: the only caller left is
/// ``FirstLaunchView/stepBody`` a few lines up, and an access level that outlives its reason reads
/// exactly like one that still has it.
private struct FirstLaunchStepSurface: View {
    let step: FirstLaunchStep
    let model: FirstLaunchModel

    var body: some View {
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
/// `restoreLastSession` reconnects the still-running detached host sessions; `newWindow` starts fresh.
/// The labels are `ON_LAUNCH`'s, not this file's — quoting them here is how a third spelling gets born.
private struct FirstLaunchOnLaunchStep: View {
    @Default(.onLaunch) private var onLaunch

    var body: some View {
        FirstLaunchCard {
            onLaunchPicker
            FirstLaunchNote(FirstLaunchStepPresentation.onLaunchNote)
        }
    }

    /// The On-Launch picker — a radio group on macOS, an inline list on iOS (`.radioGroup` is
    /// macOS-only).
    ///
    /// The options and their order come from ``FirstLaunchStepPresentation/onLaunchOptions``, never from
    /// two `Text(…).tag(…)` lines typed here: the Mac's AppKit radios offer the same two, and a picker
    /// that grew a third case would otherwise grow it on one platform only.
    @ViewBuilder
    private var onLaunchPicker: some View {
        let picker = Picker("On Launch", selection: $onLaunch) {
            ForEach(FirstLaunchStepPresentation.onLaunchOptions, id: \.self) { option in
                Text(option.title).tag(option)
            }
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

    var body: some View {
        FirstLaunchCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                    Text(FirstLaunchStepPresentation.hooksAgentName)
                        .font(.system(size: Slate.Typeface.base, weight: .semibold))
                        .foregroundStyle(Slate.Text.primary)
                    Text(FirstLaunchStepPresentation.hooksBlurb)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                installControl
            }
            if FirstLaunchStepPresentation.showsConnectNote(agentHooks) {
                FirstLaunchNote(FirstLaunchStepPresentation.hooksConnectNote)
            }
        }
        .task { await agentHooks?.refresh() }
    }

    /// The trailing slot, drawn from ``FirstLaunchHooksControl``. The SWITCH is on the resolved control,
    /// never on the raw ``AgentHooksController/InstallState`` — the fold from six states to three shapes
    /// is the decision, and it is spelled once, below, for both halves.
    @ViewBuilder
    private var installControl: some View {
        switch FirstLaunchStepPresentation.hooksControl(agentHooks) {
        case let .badge(badge):
            badgeLabel(badge)
        case let .offerInstall(enabled):
            Button(FirstLaunchStepPresentation.hooksInstallTitle) {
                Task {
                    await agentHooks?.install()
                    if FirstLaunchStepPresentation.completesHooksStep(agentHooks) {
                        model.markComplete(.installClaudeHooks)
                    }
                }
            }
            .disabled(!enabled)
            .buttonStyle(.bordered)
        case .working:
            ProgressView().controlSize(.small)
        }
    }

    /// A finished badge. The word, the silhouette and the hint are the badge's own; the HUE is this
    /// renderer's, because `SlopDeskSlate` sits above `SlopDeskClientCore` and a token cannot descend.
    /// The Mac's AppKit twin spells the same two constants `Slate.Native.StatusInk.*`.
    @ViewBuilder
    private func badgeLabel(_ badge: FirstLaunchHooksBadge) -> some View {
        let label = Label(badge.label, systemImage: badge.systemImage)
            .foregroundStyle(badge == .installed ? Slate.StatusInk.ok : Slate.StatusInk.warn)
        if let hint = badge.hint { label.help(hint) } else { label }
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
