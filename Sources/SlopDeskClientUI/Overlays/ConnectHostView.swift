// ConnectHostView — the Connect-to-Host editor, drawn on the shared floating GLASS CARD
// (``SlateOverlayCard``) that every overlay now takes from the ⌃⇥ switcher.
//
// It was a grouped `Form` before, under the "everything outside the workspace is native chrome" directive.
// The Form is gone: its inset grey group boxes are a ground of their own, and a ground inside a glass card
// is a box inside a box — the single thing that most made these dialogs look unrelated to the workspace it
// floats over.
//
// ⚠️ The CARD changed; the CONTROLS did not. A first cut also replaced the stock field with a hand-drawn
// plate and re-tinted the buttons to the theme accent, and both were rejected on sight: the plate was
// thinner than a real macOS field and read as cramped, and a theme-accented prominent button looks like a
// recoloured system button rather than like workspace furniture. So the inputs are native `.roundedBorder`
// fields at `.large`, the buttons keep the system accent, and what the card supplies is the SURFACE and the
// labels around them. A dialog's controls should be the system's; only the thing holding them is ours.
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
                field("Host", text: $connection.host, prompt: "host.local or 10.0.0.7")
                    .focused($hostFocused)
                field("Port", text: $connection.port, prompt: "9000", mono: true)

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
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if showAdvanced {
                    field("Media port", text: $connection.mediaPort, prompt: "9001", mono: true)
                    field("Cursor port", text: $connection.cursorPort, prompt: "9002", mono: true)
                }

                if let hint = connection.validationHint {
                    warning(hint)
                } else if case let .failed(reason) = connection.status {
                    // The card stays open on a failed connect (see `connectAndClose`) — the same
                    // validation-hint row voice carries the reason, run through the presenter so it
                    // reads as the actionable copy every other connection surface shows, never the
                    // raw transport dump (which stays reachable via the status pill's tooltip).
                    warning(ConnectionPresenter.friendlyFailure(reason))
                }
            }
            .padding(.horizontal, Slate.Metric.space4)
            .padding(.bottom, Slate.Metric.space4)

            // No `Divider` above the buttons: the card's own edge already ends the surface, and a rule
            // here was the last of the stacked-boxes look the Form left behind.
            HStack(spacing: Slate.Metric.space2) {
                Spacer(minLength: 0)
                Button("Cancel") { cancelAndClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connectAndClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!connection.canConnect)
            }
            .padding(.horizontal, Slate.Metric.space4)
            .padding(.bottom, Slate.Metric.space4)
        }
        #if os(macOS)
        .frame(width: 460) // a fixed-width macOS card; iOS presents the sheet full-width
        #endif
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

    // MARK: - Card parts

    /// One labelled input: the caps label, then a REAL macOS text field under it. `.roundedBorder` at
    /// `.large` is the whole point — it is the system's field, at the system's size, so it takes the focus
    /// ring, the selection and the height a user expects instead of a look-alike plate that comes up short.
    private func field(
        _ label: String, text: Binding<String>, prompt: String, mono: Bool = false,
    ) -> some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text(label.uppercased())
                .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .medium))
                .tracking(Slate.Typeface.instrumentTracking)
                .foregroundStyle(Slate.Text.tertiary)
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                // A port is a NUMBER being read back, so it takes the mono face; a hostname is a name and
                // keeps the system one.
                .font(mono ? .body.monospaced() : .body)
        }
    }

    /// The validation / failure line — amber, because this one IS a status and the no-hue rule is about
    /// readouts competing for attention, not about suppressing an actual warning.
    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

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
