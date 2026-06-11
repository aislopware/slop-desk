import AppKit
import SwiftUI
import AislopdeskTransport   // PortValidation (R16 HOSTVIEW-1)

/// The body of the menu-bar popover (research §C4 / §C1).
///
/// Top to bottom: a status row (running / stopped / failed), an editable + persisted port
/// field, a Start/Stop button, a best-effort client-activity line, the TCC permission
/// checklist (the C1 deliverable), and a Quit button.
struct MenuContentView: View {
    @Bindable var controller: HostController
    /// The desired listen port, persisted across launches (research default 7779). Editable
    /// only while stopped — changing the port requires a stop → start.
    @Binding var port: Int

    /// Re-preflighted TCC state. Bumped on `.onAppear` and on a light timer so the dots
    /// reflect grants the user just toggled in System Settings (grants go stale — never cache).
    @State private var tccRefreshTick = 0

    /// Drives the periodic TCC re-check while the popover is open.
    private let tccTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// A destructive action awaiting confirmation because clients are connected (stop / quit kills their
    /// live shells). `nil` = no pending confirmation. The 0-client case bypasses this (one-click).
    @State private var pendingDestruction: DestructiveAction?

    /// Whether at least one client is connected (so stop/quit needs confirmation). `clientCount` is `nil`
    /// while "listening but not observed" — treat that as no confirmed clients (one-click).
    private var hasConnectedClients: Bool { (controller.clientCount ?? 0) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            portField
            startStopButton
            clientActivity
            Divider()
            tccChecklist
            Divider()
            quitButton
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { tccRefreshTick &+= 1 }
        .onReceive(tccTimer) { _ in tccRefreshTick &+= 1 }
        // Guard stop/quit when clients are connected — the confirm button (NOT the originating button)
        // performs the action, so the dialog actually intercepts. 0-client paths never reach here.
        .confirmationDialog(
            pendingDestruction?.title ?? "",
            isPresented: Binding(get: { pendingDestruction != nil },
                                 set: { if !$0 { pendingDestruction = nil } }),
            titleVisibility: .visible,
            presenting: pendingDestruction
        ) { action in
            Button(action.confirmLabel, role: .destructive) {
                switch action {
                case .stopHost: controller.stop()
                case .quit: NSApplication.shared.terminate(nil)
                }
                pendingDestruction = nil
            }
            Button("Cancel", role: .cancel) { pendingDestruction = nil }
        } message: { action in
            // R16 HOSTVIEW-3: render from the count CAPTURED when the dialog was armed, not live state.
            // If the last client drops (or the host self-stops via a listener failure) while the dialog
            // is open, live state flips to "Listening" (0 clients), producing the self-contradictory
            // "Listening — they will be disconnected." The snapshot keeps the justification consistent.
            Text("\(Self.clientCountPhrase(action.clientCount)) — they will be disconnected.")
        }
    }

    /// A stop/quit action that needs a connected-client confirmation. Carries the client count CAPTURED
    /// at arm time (R16 HOSTVIEW-3) so the dialog message cannot drift to a stale/contradictory value.
    private enum DestructiveAction: Identifiable {
        case stopHost(clientCount: Int)
        case quit(clientCount: Int)
        /// Identifies the dialog KIND (independent of the captured count).
        var id: Int {
            switch self {
            case .stopHost: return 0
            case .quit: return 1
            }
        }
        var clientCount: Int {
            switch self {
            case let .stopHost(c), let .quit(c): return c
            }
        }
        var title: String {
            switch self {
            case .stopHost: return "Stop the host?"
            case .quit: return "Quit Aislopdesk Host?"
            }
        }
        var confirmLabel: String {
            switch self {
            case .stopHost: return "Stop Host"
            case .quit: return "Quit"
            }
        }
    }

    /// "1 client connected" / "N clients connected" from a fixed count (the dialog snapshot).
    private static func clientCountPhrase(_ count: Int) -> String {
        count == 1 ? "1 client connected" : "\(count) clients connected"
    }

    // MARK: Header / status

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text("Aislopdesk Host")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    // A failed start is an error, not idle chatter — colour it red so it reads as one.
                    .foregroundStyle(isFailed ? Color.red : Color.secondary)
            }
            Spacer()
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .running: return .green
        case .starting, .stopping: return .yellow
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var isFailed: Bool {
        if case .failed = controller.state { return true }
        return false
    }

    private var statusText: String {
        switch controller.state {
        case let .running(boundPort): return "Running on :\(boundPort)"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .stopped: return "Stopped"
        case let .failed(message): return "Failed: \(message)"
        }
    }

    // MARK: Port

    /// R16 HOSTVIEW-1: whether the entered port is a usable TCP port (`0`…`65535`, `0` = OS-assigned).
    /// Gates the Start button so a negative / out-of-range value can never be silently coerced into a
    /// bound port (the old `UInt16(clamping: max(0, port))` mapped `-5 → 0` and `99999 → 65535`,
    /// desyncing the displayed/persisted value from the port actually bound).
    private var portIsValid: Bool { PortValidation.isValid(port) }

    private var portField: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Port")
                    .frame(width: 56, alignment: .leading)
                TextField("7779", value: $port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .disabled(controller.isRunning || controller.isBusy)
                    .help(controller.isRunning ? "Stop the host to change the port." : "TCP port to listen on (0 = OS-assigned, max 65535).")
            }
            // Non-color + color feedback that the field is out of range, with Start disabled below.
            if !controller.isRunning && !portIsValid {
                Text("Enter a port between 0 and 65535.")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: Start / Stop

    private var startStopButton: some View {
        Button(action: toggle) {
            HStack {
                if controller.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(controller.isRunning ? "Stop Host" : "Start Host")
                    .frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(controller.isRunning ? .red : .accentColor)
        // Disable while busy (starting/stopping) OR, when not running, while the port is out of range
        // (R16 HOSTVIEW-1) so an invalid value can never be coerced into a bound port.
        .disabled(controller.isBusy || (!controller.isRunning && !portIsValid))
    }

    private func toggle() {
        if controller.isRunning {
            // Confirm before tearing down live client shells; one-click when nobody is connected. The
            // count is SNAPSHOTTED into the action (R16 HOSTVIEW-3) so the dialog message can't drift.
            if hasConnectedClients {
                pendingDestruction = .stopHost(clientCount: controller.clientCount ?? 0)
            } else {
                controller.stop()
            }
        } else {
            // Start ONLY on a valid port (R16 HOSTVIEW-1); the button is disabled otherwise, so this is
            // belt-and-suspenders against a coerced bind.
            guard let boundPort = PortValidation.port(port) else { return }
            controller.start(port: boundPort)
        }
    }

    // MARK: Client activity (best-effort)

    @ViewBuilder
    private var clientActivity: some View {
        if controller.isRunning {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.secondary)
                Text(clientActivityText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clientActivityText: String {
        guard let count = controller.clientCount else { return "Listening" }
        return count == 1 ? "1 client connected" : "\(count) clients connected"
    }

    // MARK: TCC permission checklist (research §C1)

    private var tccChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.subheadline.weight(.semibold))
            Text("Needed for the GUI-video & remote-input features.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(TCC.rows) { row in
                TCCRowView(row: row, refreshTick: tccRefreshTick)
            }
        }
    }

    // MARK: Quit

    private var quitButton: some View {
        Button(role: .destructive) {
            // Confirm before quitting if it would disconnect live clients; one-click otherwise. Snapshot
            // the count into the action (R16 HOSTVIEW-3) so the dialog message stays consistent.
            if hasConnectedClients {
                pendingDestruction = .quit(clientCount: controller.clientCount ?? 0)
            } else {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Text("Quit Aislopdesk Host")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
    }
}

/// One checklist row: a live status dot, the title + rationale, and an "Enable…" deep-link
/// button (hidden once granted). The `refreshTick` input forces a re-render — and therefore a
/// fresh `row.isGranted()` preflight — whenever the parent bumps it.
private struct TCCRowView: View {
    let row: TCCRow
    let refreshTick: Int

    var body: some View {
        // Re-preflight on every render (grants go stale; never cache). `refreshTick` is read so
        // SwiftUI invalidates this view when the parent bumps it.
        let granted = withRefresh(refreshTick) { row.isGranted() }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.callout.weight(.medium))
                Text(row.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !granted && row.requiresRelaunch {
                    Text("Quit & Reopen Aislopdesk Host after granting.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if !granted {
                Button("Enable…") {
                    NSWorkspace.shared.open(row.settingsURL)
                }
                .controlSize(.small)
            }
        }
    }

    /// Reads `tick` (so the view depends on it) and returns the freshly-computed value.
    private func withRefresh<T>(_ tick: Int, _ body: () -> T) -> T {
        _ = tick
        return body()
    }
}
