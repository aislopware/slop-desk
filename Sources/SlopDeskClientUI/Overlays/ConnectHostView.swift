// ConnectHostView — the Connect-to-Host editor, presented in a NATIVE SHEET (user-directed 2026-08-08).
//
// It is the only overlay in the set that is a FORM to fill in and commit rather than a picker to skim, so
// it is the one that takes the platform's own modal: the sheet owns the window (no stray click into the
// workspace can drop it mid-edit), and Esc / Return reach Cancel and Connect through the buttons' native
// roles in ``SlateCardFooter`` rather than through the in-window cards' hand-rolled dismiss floor. The
// PARTS stay the shared floating family (``SlateCardTitle`` / ``SlateLabeledField`` / ``SlateCardFooter``,
// in the neutral system inks) — what changed is the container, not the vocabulary.
//
// It was a grouped `Form` before, under the "everything outside the workspace is native chrome" directive.
// The Form is gone: its inset grey group boxes are a ground of their own, and a ground inside a floating card
// is a box inside a box — the single thing that most made these dialogs look unrelated to the workspace it
// floats over.
//
// ⚠️ The CARD changed; the CONTROLS did not. A first cut also replaced the stock field with a hand-drawn
// plate and re-tinted the buttons to the theme accent, and both were rejected on sight: the plate was
// thinner than a real macOS field and read as cramped, and a theme-accented prominent button looks like a
// recoloured system button rather than like workspace furniture. So the inputs are native `.roundedBorder`
// fields at `.large` and the buttons take the app's one NEUTRAL accent (the AccentColor asset) — which is
// also what keeps the field's focus ring grey instead of machine-blue. A dialog's controls should be the
// system's; only the thing holding them is ours. The parts are the shared ``SlateOverlayControls`` family.
//
// A THIN form over the app-global ``AppConnection`` (which already owns the editable host/port fields, the
// parse/validation, and the `connect()` lifecycle) — opened by the sidebar connection status line / the
// top-bar pill (`onTap → openConnect`) and the palette's "Connect to Host…" action. It builds NO new
// connection model and never force-unwraps a parsed target: "Connect" is gated on ``AppConnection/canConnect``
// (`parsedTarget() != nil`) and `connect()` re-guards the parse internally (validate-then-connect). The
// host/port are the headline fields; the two video ports sit behind a `DisclosureGroup` (most keep defaults).

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

struct ConnectHostView: View {
    /// The app-global connection — `@Bindable` so the native fields two-way edit its form, and `body`
    /// re-renders on `status` / `validationHint` / `canConnect` changes.
    @Bindable var connection: AppConnection
    /// The single overlay reducer — the view's only overlay mutation is `closeConnect()` (Cancel / a
    /// successful connect; the sheet's own Esc dismissal also routes here via the presentation binding).
    let coordinator: OverlayCoordinator

    /// Whether the advanced (video-port) disclosure is expanded. Collapsed by default — the host/port lead.
    @State private var showAdvanced = false
    /// Pre-focuses the host field on appear (the first thing a user edits).
    @FocusState private var hostFocused: Bool
    /// The in-flight connect Task. Stored so Cancel / sheet teardown CANCEL it — the old
    /// fire-and-forget `Task { await connect(); closeConnect() }` outlived the sheet and, when a slow
    /// connect finally resolved, unconditionally dismissed a freshly REOPENED sheet mid-edit. Belt and
    /// suspenders with the ``OverlayCoordinator/connectGeneration`` completion guard below.
    @State private var connectTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlateCardTitle("Connect to Host")

            VStack(alignment: .leading, spacing: Slate.Metric.space3) {
                // Host and port share ONE row — a port is five digits, and a five-digit field the full
                // width of the card asks a question the same size as "which machine?". (A title-less,
                // placeholder-as-label cut was photographed and rejected: this card usually opens
                // PRE-FILLED with the live target, and a filled field with no label says nothing.)
                HStack(alignment: .top, spacing: Slate.Metric.space3) {
                    SlateLabeledField(label: "Host", text: $connection.host, prompt: "host.local or 10.0.0.7")
                        .focused($hostFocused)
                    SlateLabeledField(label: "Port", text: $connection.port, prompt: "9000", mono: true)
                        .frame(width: Slate.Metric.portFieldWidth)
                }

                // The two video ports stay folded away — most people keep the defaults, and a card that
                // opens showing four fields asks four questions when it only has two.
                Button {
                    withAnimation(Slate.Anim.standard) { showAdvanced.toggle() }
                } label: {
                    HStack(spacing: Slate.Metric.space1) {
                        Image(systemSymbol: showAdvanced ? .chevronDown : .chevronRight)
                            .font(.system(size: Slate.Typeface.small, weight: .semibold))
                        Text("Video ports")
                            .font(.callout)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(SlateOverlayInk.secondary)
                    // The WHOLE row is the target, the way a native disclosure row is — a hit area the
                    // width of two words is a miss waiting to happen, and on this card a miss used to land
                    // on the dismiss floor and take the card away mid-edit.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAdvanced {
                    // The two video ports are peers, so they share a row the way host/port do.
                    HStack(alignment: .top, spacing: Slate.Metric.space3) {
                        SlateLabeledField(label: "Media port", text: $connection.mediaPort, prompt: "9001", mono: true)
                        SlateLabeledField(
                            label: "Cursor port",
                            text: $connection.cursorPort,
                            prompt: "9002",
                            mono: true,
                        )
                    }
                }

                if let hint = connection.validationHint {
                    SlateWarningRow(text: hint)
                } else if case let .failed(reason) = connection.status {
                    // The card stays open on a failed connect (see `connectAndClose`) — the same
                    // validation-hint row voice carries the reason, run through the presenter so it
                    // reads as the actionable copy every other connection surface shows, never the
                    // raw transport dump (which stays reachable via the status pill's tooltip).
                    SlateWarningRow(text: ConnectionPresenter.friendlyFailure(reason))
                }
            }
            .padding(.horizontal, Slate.Metric.space4)
            .padding(.bottom, Slate.Metric.space4)

            SlateCardFooter(
                confirmTitle: "Connect",
                confirmDisabled: !connection.canConnect,
                onCancel: { cancelAndClose() },
                onConfirm: { connectAndClose() },
            )
        }
        #if os(macOS)
        .frame(width: Slate.Metric.cardFormWidth) // a fixed-width macOS card; iOS presents full-width
        #endif
        // The sheet wears the FAMILY's corner, not the system's — see ``SlateSheetSurface``. Without
        // this the one native surface in the set rounds differently from the seven in-window cards.
        .slateSheetSurface()
        .onAppear {
            // Seed the fields from the committed target (re-editing the live host), then defer focus a runloop
            // hop (a `@FocusState` set the same tick the sheet appears is dropped before its responder exists).
            connection.fillForm(from: connection.target)
            DispatchQueue.main.async { hostFocused = true }
        }
        .onDisappear {
            // ANY dismissal (Esc / scrim / Cancel already did it) cancels the in-flight connect Task so it
            // can't run its completion against a later presentation.
            connectTask?.cancel()
            connectTask = nil
        }
    }

    // MARK: - Actions

    /// Validate-then-connect: no-op unless the form parses (the button is also disabled then), then fire the
    /// app's `connect()`. Never force-unwraps — `canConnect` gates here and `connect()` re-guards the parse
    /// internally. Only a SUCCESSFUL connect closes the sheet — a `.failed` result leaves it open with the
    /// real reason inline (`connection.validationHint` already renders as the same warning row above; a
    /// dropped sheet with the reason reachable only via the status-pill tooltip is a silent failure). The
    /// close is DOUBLE-guarded: the Task is stored + cancelled on Cancel/teardown, AND the completion only
    /// closes if the coordinator's `connectGeneration` still matches the presentation this Task started
    /// under — a slow connect resolving after cancel + reopen must not dismiss the fresh sheet.
    private func connectAndClose() {
        guard connection.canConnect else { return }
        connectTask?.cancel()
        let generation = coordinator.connectGeneration
        connectTask = Task {
            await connection.connect()
            guard !Task.isCancelled else { return }
            guard Self.shouldCloseAfterConnect(status: connection.status) else { return }
            coordinator.closeConnect(ifCurrent: generation)
        }
    }

    /// Whether a `connect()` completion should dismiss the sheet — every terminal status except
    /// `.failed` does (a live `.connecting`/`.reconnecting` in between never reaches here; `connect()`
    /// has already resolved by the time this is checked). Pure + `static` so it's pinned headlessly
    /// without driving the view or a real socket.
    static func shouldCloseAfterConnect(status: ConnectionStatus) -> Bool {
        if case .failed = status { return false }
        return true
    }

    /// Cancel: kill the in-flight connect Task (its completion must never fire) and close the sheet.
    private func cancelAndClose() {
        connectTask?.cancel()
        connectTask = nil
        coordinator.closeConnect()
    }
}
#endif
