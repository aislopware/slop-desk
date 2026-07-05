import Foundation

// MARK: - WorkspaceStore + Session templates (open a named layout / capture the current one)

/// The store-side surface for **session templates / project profiles** (a layout + per-pane cwd/command):
/// open a fresh named session from a template (the panes auto-`cd` + run their command once live), and
/// capture the active session's geometry into a reusable template. CLIENT-ONLY — no wire / host / FFI /
/// schema-version change. The pure expand/capture is ``SessionTemplateEngine``; the store only inserts the
/// session (via the ``replaceTree(_:)`` / ``mutateTree(_:)`` in-file seams), reconciles, and sends each
/// pane's launch bytes after its PTY comes up (the SAME 1400 ms grace the launch-preset apply uses).
public extension WorkspaceStore {
    /// The user's session templates (built-ins + any they captured), in display order. The palette / menu
    /// read this; ``newSessionFromTemplate(_:)`` opens one.
    var sessionTemplates: [SessionTemplate] { tree.sessionTemplates }

    /// Opens a NEW named session laid out by `template`: expands the template into a ``Session`` (one tab,
    /// the template's split tree, fresh ``PaneID``s + seeded specs), inserts it ACTIVE, reconciles to
    /// materialize every leaf, then types each pane's `cd`/command once its PTY is live. Returns the
    /// created pane ids (DFS order). The keystroke send is deferred ~1.4 s after materialize — the SAME
    /// "let the remote prompt come up" grace ``applyLaunchPreset(_:)`` uses; the PURE byte expansion is
    /// ``SessionTemplateEngine/launchBytes(cwd:command:)`` (a `nil` ⇒ a no-op pane, no bytes sent).
    @discardableResult
    func newSessionFromTemplate(_ template: SessionTemplate) -> [PaneID] {
        newSessionFromTemplate(template, launchGrace: .milliseconds(1400))
    }

    /// The `launchGrace`-parameterized core of ``newSessionFromTemplate(_:)`` — tests inject a `0`ms grace
    /// to observe the store→PTY `sendBytes` wiring without a 1.4 s wall-clock wait. Production callers use
    /// the public no-grace-argument overload (the SAME 1400 ms `applyLaunchPreset` uses).
    @discardableResult
    func newSessionFromTemplate(_ template: SessionTemplate, launchGrace: Duration) -> [PaneID] {
        let (session, launches) = SessionTemplateEngine.makeSession(from: template, name: defaultSessionName)
        replaceTree(WorkspaceTreeOps.insertSession(session, in: tree, makeActive: true))
        reconcileTree()

        // Send each pane's command bytes once its PTY is live (deferred — the shell prompt must come up
        // first), mirroring `applyLaunchPreset`. The cwd already rides the pane spec into host-side spawn.
        for (paneID, pane) in launches {
            guard let bytes = SessionTemplateEngine.launchBytes(cwd: nil, command: pane.command) else {
                continue
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: launchGrace)
                self?.handle(for: paneID)?.sendBytes(bytes)
            }
        }
        return launches.map(\.0)
    }

    /// Captures the ACTIVE session's active-tab geometry into a fresh user template named `name` (a default
    /// "Layout N" when blank) with `symbol`, appends it to ``TreeWorkspace/sessionTemplates``, and persists.
    /// The capture is pure (``SessionTemplateEngine/captureTemplate(from:name:symbol:)``) — `cwd`/`command`
    /// are not recoverable from a running PTY, so the captured panes carry only kind + title. No-op (no
    /// append) when there is no active session.
    func saveCurrentSessionAsTemplate(name: String, symbol: String = "rectangle.split.2x1") {
        guard let session = tree.activeSession else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? defaultLayoutTemplateName : trimmed
        let template = SessionTemplateEngine.captureTemplate(from: session, name: finalName, symbol: symbol)
        mutateTree { $0.sessionTemplates.append(template) }
    }

    /// Adds (or replaces, by id) a session template, then persists. The settings / capture "save" path.
    func upsertSessionTemplate(_ template: SessionTemplate) {
        mutateTree { tree in
            if let idx = tree.sessionTemplates.firstIndex(where: { $0.id == template.id }) {
                tree.sessionTemplates[idx] = template
            } else {
                tree.sessionTemplates.append(template)
            }
        }
    }

    /// Removes a session template by id, then persists.
    func removeSessionTemplate(_ id: UUID) {
        mutateTree { $0.sessionTemplates.removeAll { $0.id == id } }
    }

    /// The default name for a CAPTURED template — "Layout N" where N is one past the current template
    /// count, so a saved layout is never blank (mirrors ``defaultSessionName``).
    var defaultLayoutTemplateName: String {
        "Layout \(tree.sessionTemplates.count + 1)"
    }
}
