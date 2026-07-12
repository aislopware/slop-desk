// ConnectHostView — the Connect-to-Host editor, NATIVE SwiftUI. Everything OUTSIDE the
// workspace + panes is native chrome (the directive that also made Settings a native `NavigationSplitView`):
// so this is a native `.sheet` body — a grouped `Form` of native `TextField`s + a native button bar — NOT the
// old bespoke `Scrim` + `OverlayPanel` card. Presented as a real macOS sheet by `OverlayHostView`.
//
// A THIN form over the app-global ``AppConnection`` (which already owns the editable host/port fields, the
// parse/validation, and the `connect()` lifecycle) — opened by the sidebar connection status line / the
// top-bar pill (`onTap → openConnect`) and the palette's "Connect to Host…" action. It builds NO new
// connection model and never force-unwraps a parsed target: "Connect" is gated on ``AppConnection/canConnect``
// (`parsedTarget() != nil`) and `connect()` re-guards the parse internally (validate-then-connect). The
// host/port are the headline fields; the two video ports sit behind a `DisclosureGroup` (most keep defaults).

#if canImport(SwiftUI)
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
        VStack(spacing: 0) {
            SlateSheetHeader("Connect to Host")

            Form {
                Section {
                    TextField("Host", text: $connection.host, prompt: Text("host.local or 10.0.0.7"))
                        .focused($hostFocused)
                    TextField("Port", text: $connection.port, prompt: Text("9000"))
                        .font(.body.monospaced())
                }

                Section {
                    DisclosureGroup("Video ports", isExpanded: $showAdvanced) {
                        TextField("Media port", text: $connection.mediaPort, prompt: Text("9001"))
                            .font(.body.monospaced())
                        TextField("Cursor port", text: $connection.cursorPort, prompt: Text("9002"))
                            .font(.body.monospaced())
                    }
                }

                if let hint = connection.validationHint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)

            SlateSheetFooter {
                Button("Cancel") { cancelAndClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connectAndClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!connection.canConnect)
            }
        }
        #if os(macOS)
        .frame(width: 460) // a fixed-width macOS dialog; iOS presents the sheet full-width
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

    /// Validate-then-connect: no-op unless the form parses (the button is also disabled then), then fire the
    /// app's `connect()` and close. Never force-unwraps — `canConnect` gates here and `connect()` re-guards
    /// the parse internally. The close is DOUBLE-guarded: the Task is stored + cancelled on
    /// Cancel/teardown, AND the completion only closes if the coordinator's `connectGeneration` still matches
    /// the presentation this Task started under — a slow connect resolving after cancel + reopen must not
    /// dismiss the fresh sheet.
    private func connectAndClose() {
        guard connection.canConnect else { return }
        connectTask?.cancel()
        let generation = coordinator.connectGeneration
        connectTask = Task {
            await connection.connect()
            guard !Task.isCancelled else { return }
            coordinator.closeConnect(ifCurrent: generation)
        }
    }

    /// Cancel: kill the in-flight connect Task (its completion must never fire) and close the sheet.
    private func cancelAndClose() {
        connectTask?.cancel()
        connectTask = nil
        coordinator.closeConnect()
    }
}
#endif
