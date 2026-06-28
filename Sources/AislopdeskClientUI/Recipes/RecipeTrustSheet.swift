// RecipeTrustSheet — the command-replay trust prompt (E16 WI-10, spec `customization__custom-commands.md`
// §Security for Command Replay). When you open an UNFAMILIAR `.ottyrecipe` that carries commands, the store
// (`WorkspaceStore.openRecipe`) parks a `RecipeTrustPrompt` instead of running anything; this sheet SHOWS the
// commands first and offers the three otty choices:
//   • Always Trust → remember the file by its SHA-256 hash, then follow the replay settings;
//   • Run Once     → run this instance only, prompt again next time;
//   • Cancel       → open nothing.
// Editing the file changes its bytes → a new hash → a fresh prompt (the store's trust model owns that). The
// SHA-256 here is a local trust-on-first-use CHECKSUM, not app-layer crypto/auth (see `RecipeTrust.swift`).
//
// Otty.* tokens only (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

/// The trust prompt for an unfamiliar command-carrying recipe. Built off the store's parked
/// `RecipeTrustPrompt`; each button routes through the store's `confirmTrust` / `cancelTrust` and dismisses.
struct RecipeTrustSheet: View {
    let store: WorkspaceStore
    let prompt: RecipeTrustPrompt

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space4) {
            header
            intro
            commandList
            footer
        }
        .padding(Otty.Metric.space4)
        #if os(macOS)
            .frame(width: 520)
        #else
            .frame(maxWidth: 520)
        #endif
            .background(Otty.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: Otty.Metric.radiusCard))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Otty.Metric.space2) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Status.warn)
            Text("Run commands from this recipe?")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
            Spacer(minLength: 0)
        }
    }

    private var intro: some View {
        Text(introText)
            .font(.system(size: Otty.Typeface.footnote))
            .foregroundStyle(Otty.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var introText: String {
        let trimmed = prompt.recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "This recipe" : "“\(trimmed)”"
        return "\(label) wants to run the following commands. Only run commands you recognize and trust."
    }

    // MARK: Commands

    private var commandList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Otty.Metric.space1) {
                ForEach(Array(prompt.commands.enumerated()), id: \.offset) { _, command in
                    Text(command)
                        .font(.system(size: Otty.Typeface.body).monospaced())
                        .foregroundStyle(Otty.Text.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Otty.Metric.space2)
        }
        .frame(maxHeight: 180)
        .background(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                .fill(Otty.Surface.element),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                .strokeBorder(Otty.Line.subtle, lineWidth: Otty.Metric.hairline),
        )
    }

    // MARK: Footer (Cancel · Run Once · Always Trust)

    private var footer: some View {
        HStack(spacing: Otty.Metric.space2) {
            Button("Cancel") { cancel() }
                .buttonStyle(.plain)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.secondary)
                .padding(.horizontal, Otty.Metric.space3)
                .padding(.vertical, Otty.Metric.space1)
            Spacer(minLength: 0)
            secondaryButton("Run Once") { confirm(alwaysTrust: false) }
            primaryButton("Always Trust") { confirm(alwaysTrust: true) }
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Otty.Typeface.body, weight: .medium))
                .foregroundStyle(Otty.Text.primary)
                .padding(.horizontal, Otty.Metric.space3)
                .padding(.vertical, Otty.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                        .fill(Otty.Surface.element),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                        .strokeBorder(Otty.Line.subtle, lineWidth: Otty.Metric.hairline),
                )
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Surface.card)
                .padding(.horizontal, Otty.Metric.space3)
                .padding(.vertical, Otty.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                        .fill(Otty.State.accent),
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func confirm(alwaysTrust: Bool) {
        store.confirmTrust(alwaysTrust: alwaysTrust)
        dismiss()
    }

    private func cancel() {
        store.cancelTrust()
        dismiss()
    }
}
#endif
