#if canImport(SwiftUI)
import SwiftUI

// MARK: - SessionSidebarView (the sessions sidebar grouped by host — W5)

/// The coding-IDE sessions sidebar (docs/41 §3.4, docs/42 W5): sessions grouped by host (MRU within a
/// host), each row showing the session name + a rolled-up ``AgentStatusDot`` (Herdr rollup over the
/// session's panes). Select / new / close / rename a session; the footer adds a session. Drives the
/// store's tree ops (`selectSession` / `newSession` / `closeSession` / `renameSession`).
struct SessionSidebarView: View {
    @Bindable var store: WorkspaceStore

    /// The session whose inline rename field is open, or `nil`.
    @State private var renamingSession: SessionID?
    @State private var renameText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                ForEach(groupedByHost, id: \.host) { group in
                    Section(group.host) {
                        ForEach(group.sessions, id: \.id) { session in
                            sessionRow(session)
                                .tag(session.id)
                        }
                    }
                }
            }
            #if os(macOS)
            .listStyle(.sidebar)
            #endif

            Divider()
            footer
        }
    }

    // MARK: Row

    private func sessionRow(_ session: Session) -> some View {
        HStack(spacing: 8) {
            AgentStatusDot(status: store.rollupStatus(forSession: session.id), size: 8)
            CompletionBadge(badge: store.rollupPendingCompletion(forSession: session.id), size: 8)
            if renamingSession == session.id {
                TextField("Session", text: $renameText)
                    .textFieldStyle(.plain)
                    .onSubmit { commitRename(session.id) }
                    .onEscapeKey { renamingSession = nil }
                #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                #endif
            } else {
                Text(session.name.isEmpty ? "Session" : session.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(session.tabs.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("\(session.tabs.count) tab(s)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename(session) }
        .contextMenu {
            Button("Rename…") { beginRename(session) }
            Button("Close Session", role: .destructive) { store.closeSession(session.id) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button {
                // ITEM B3: name a footer-created session via the SAME store helper the keyboard
                // (`newSessionDefault`) uses, so the two paths can never drift ("Session N").
                store.newSession(name: store.defaultSessionName, kind: SettingsKey.defaultPaneKind)
            } label: {
                Label("New Session", systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Selection

    /// The selected-session binding the `List` drives — reads the active session, writes through
    /// `selectSession` (a pure active-state change; the full leaf set stays registered).
    private var selectionBinding: Binding<SessionID?> {
        Binding(
            get: { store.tree.activeSessionID ?? store.tree.sessions.first?.id },
            set: { id in if let id { store.selectSession(id) } },
        )
    }

    // MARK: Grouping (by host, MRU within host)

    private struct HostGroup { let host: String
        let sessions: [Session]
    }

    /// Sessions grouped by their connection host (sessions with no connection fall under "Local"), in the
    /// order each host first appears (a stable, MRU-ish order — the active session's host floats by virtue
    /// of selection, not reordering, to avoid churn).
    private var groupedByHost: [HostGroup] {
        var order: [String] = []
        var buckets: [String: [Session]] = [:]
        for session in store.tree.sessions {
            let host = session.connection?.host ?? "Local"
            if buckets[host] == nil { order.append(host) }
            buckets[host, default: []].append(session)
        }
        return order.map { HostGroup(host: $0, sessions: buckets[$0] ?? []) }
    }

    // MARK: Rename

    private func beginRename(_ session: Session) {
        renameText = session.name
        renamingSession = session.id
    }

    private func commitRename(_ id: SessionID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.renameSession(id, to: trimmed.isEmpty ? "Session" : trimmed)
        renamingSession = nil
    }
}
#endif
