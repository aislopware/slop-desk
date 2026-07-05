// ConnectHostView — the Connect-to-Host editor (E2 / WI-5, ES-E2-6), NATIVE SwiftUI. Everything OUTSIDE the
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
                Button("Cancel") { coordinator.closeConnect() }
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
    }

    /// Validate-then-connect: no-op unless the form parses (the button is also disabled then), then fire the
    /// app's `connect()` and close. Never force-unwraps — `canConnect` gates here and `connect()` re-guards
    /// the parse internally.
    private func connectAndClose() {
        guard connection.canConnect else { return }
        Task {
            await connection.connect()
            coordinator.closeConnect()
        }
    }
}
#endif
