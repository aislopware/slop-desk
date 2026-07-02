// InspectorColumn — the right Details panel. The Details panel is a SEGMENTED
// header (active tab = icon+label pill, inactive = icon only) over a warm panel; hidden until ⌘⇧R.
// It keeps aislopdesk's live content under the Info tab:
//   • Info  — the live SESSION (connection dot+label, host:port, ping, agent) + working directory + a
//             one-row GIT SUMMARY (branch + change count; the full status/diff opens as a popup — the old
//             standalone Git tab merged here, its changed-file list is unbounded so it gets a window) + the
//             first-class command navigator (`BlockHistoryView` over the active pane's `TerminalBlockModel`).
//   • Files — the remote file tree.
//
// Resolution mirrors `PaneContainer`: `store.handle(for: paneID) as? LivePaneSession` keyed by the active
// tab's active pane. Reading `connection.status` + `LivePaneSession.claudeStatus` + `connection?.latencyMS`
// (all @Observable) keeps Info live. Shared design-system tokens / fonts only.

#if canImport(SwiftUI)
import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct InspectorColumn: View {
    let store: WorkspaceStore
    let connection: AppConnection
    /// The shared, command-drivable Details-tab selection (E9/WI-7). Hoisted out of the old private `@State`
    /// so the `Details: *` jump commands (ES-E9-5) can switch the tab from OUTSIDE the view — the root
    /// view installs a `selectDetailsTab` closure that writes `details.selected` (and reveals the panel). Both
    /// inspector mounts (macOS split item + iOS detail) share ONE instance, so the active tab is one truth.
    let details: DetailsPanelState
    /// Opens the Send-to-Chat dialog pre-loaded with a transcript context (wired to
    /// `overlay.openSendToChat(context:)` by the root view). No-op default keeps the column
    /// standalone-mountable (previews / tests).
    var onSendToChat: (SendToChatContext) -> Void = { _ in }

    /// Whether the "View Session History" viewer (`AgentSessionHistoryView`) is presented over the panel.
    /// Set by the Info tab's agent-sessions action; the viewer binds the focused pane's model (its session
    /// list + the `readAgentSession` fetch). E4/WI-6.
    @State private var showSessionHistory = false

    /// Whether the Git details popup (`GitDetailsSheet` over the full `GitStatusView`) is presented. Set by
    /// the Info tab's git-summary row — the old standalone Git tab merged into Info; the unbounded
    /// changed-file list + diff live in the popup, the Info row carries only branch + change count.
    @State private var showGitDetails = false

    /// PER-PANE decoded host metadata (E4): processes / ports / git / files / cwd. One model per pane the
    /// inspector has shown — so each pane RETAINS its data and a slow `refresh()` for the pane you just left
    /// can never clobber the pane you switched TO (a single shared model would race two in-flight refreshes).
    /// Pruned to live panes (a closed pane drops out) so the cache stays bounded.
    @State private var models: [PaneID: PaneMetadataModel] = [:]
    /// A stable, never-bound empty model rendered for the one frame before the focused pane's model is
    /// created (the `.task` populates `models` off the body-update path), and when no pane is focused. Its
    /// `nil` client makes every read an empty state — never a hang.
    @State private var placeholder = PaneMetadataModel()

    /// The active tab's active pane id.
    private var activePaneID: PaneID? { store.tree.activeSession?.activeTab?.activePane }

    /// The active pane's live session (terminal model + per-pane channel + agent status), if materialized.
    private var activeLive: LivePaneSession? {
        guard let id = activePaneID else { return nil }
        return store.handle(for: id) as? LivePaneSession
    }

    private var terminalModel: TerminalViewModel? { activeLive?.terminalModel }
    private var activeAgentStatus: ClaudeStatus { activeLive?.claudeStatus ?? .none }

    /// Whether the focused pane is a LIVE agent pane (a non-`.none` Claude status) — the gate for the Info-tab
    /// agent section (E4/WI-6 `info-panel.png` › "OpenCode" section appears "when the focused pane is an agent
    /// pane"). Gating on the live pane (not on whether on-disk sessions exist) means a freshly-started agent
    /// shows the section immediately, and a plain terminal never does.
    private var isAgentPane: Bool { activeAgentStatus != .none }

    /// The focused agent pane's CURRENTLY-running Claude session id (the `claude --resume <id>` target), or
    /// `nil` when the pane is not a live agent or the session id is not yet known — drives the "Copy Session
    /// ID" affordance (disabled when `nil`).
    private var activeAgentSessionID: String? { activeLive?.liveAgentSessionID }

    private var cwd: String? {
        guard let id = activePaneID else { return nil }
        return store.tree.activeSession?.specs[id]?.lastKnownCwd
    }

    /// The focused pane's working directory for the Info-tab Working Directory section (E9/WI-6): the pane
    /// spec's live `lastKnownCwd` (kept fresh on every `cd` via OSC-7 / the post-command cwd RPC) if known,
    /// else the host-resolved cwd from the metadata fetch. `lastKnownCwd` is preferred because the metadata
    /// model's `cwd` is only refetched on pane-focus/(re)connect — a `cd` in an already-focused pane would
    /// otherwise keep showing the bind-time directory until the next refresh. An empty string collapses to
    /// `nil` so the section shows the "—" placeholder and Copy Path stays disabled.
    private var resolvedCwd: String? {
        InfoTabFormatting.resolveWorkingDirectory(lastKnownCwd: cwd, modelCwd: activeModel.cwd)
    }

    /// The focused pane's typed metadata façade, or `nil` while it is disconnected.
    private var activeMetadataClient: MetadataClient? {
        activeLive?.connection?.activeMetadataClient
    }

    /// Identity of "what the panel is showing": the focused pane, its metadata façade, AND the connection's
    /// live status. A change — switching panes, a pane (re)connecting with a fresh `MetadataClient`, OR a
    /// WARM reconnect (same `MetadataClient` instance, `status` cycling `.connected` → `.reconnecting` →
    /// `.connected`) — re-fires the bind+refresh `.task` (which auto-cancels the prior, so a stale in-flight
    /// fetch can't land late). Without `status` in the key, a warm ReconnectManager resume (which never
    /// mints a new `MetadataClient`) would leave a bind-time-refresh-during-the-drop's empty results
    /// (processes/ports/git/files) cached forever, since nothing else re-triggers the fetch.
    private struct RefreshKey: Equatable {
        let pane: PaneID?
        let client: ObjectIdentifier?
        let status: ConnectionViewModel.Status?
    }

    private var refreshKey: RefreshKey {
        RefreshKey(
            pane: activePaneID,
            client: activeMetadataClient.map { ObjectIdentifier($0) },
            status: activeLive?.connection?.status,
        )
    }

    /// The focused pane's metadata model (its cached one, or the empty placeholder until the `.task` mints
    /// it). The tabs always have a non-`nil` model to render, so there is no missing-data layout jump.
    private var activeModel: PaneMetadataModel {
        guard let id = activePaneID, let model = models[id] else { return placeholder }
        return model
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Slate.Line.divider).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Slate.Surface.sidebar)
        .task(id: refreshKey) { await bindAndRefresh() }
        .sheet(isPresented: $showSessionHistory) {
            AgentSessionHistoryView(
                model: activeModel,
                onClose: { showSessionHistory = false },
                liveSessionIDs: store.liveAgentSessionIDs(),
                onResume: { performResume($0) },
                onSendToChat: onSendToChat,
            )
        }
        .sheet(isPresented: $showGitDetails) {
            GitDetailsSheet(model: activeModel, onClose: { showGitDetails = false })
        }
    }

    /// Performs a History-viewer Resume (E13/WI-6, ES-E13-6) off the pure ``AgentResumeRouter`` decision: JUMP
    /// to the pane already running the session (still-live), or SPAWN a fresh terminal tab running the VERBATIM
    /// `claude --resume <id>`. The spawn deliberately does NOT inject into the FOCUSED pane — the viewer is
    /// opened from the inspector of a pane that is frequently a live Claude agent, so injecting there would
    /// deliver the resume command as a chat prompt INTO the running agent rather than starting a session.
    /// ``WorkspaceStore/resumeAgentInNewTab(command:)`` spawns the new tab + injects (VERBATIM, never
    /// ``SendKeysParser``). The jump map is wired from ``WorkspaceStore/liveAgentSessionIDs()``. Closes the
    /// viewer either way.
    private func performResume(_ target: AgentResumeRouter.ResumeTarget) {
        switch target {
        case let .jumpTo(pane):
            store.focusPaneTree(pane)
        case let .spawn(command):
            store.resumeAgentInNewTab(command: command)
        }
        showSessionHistory = false
    }

    /// Binds the focused pane's metadata model to its façade and fetches its Info/Git/Files data, then
    /// mirrors the host-resolved cwd into the pane's `lastKnownCwd` (so the titlebar / rail / palette pick it
    /// up). Each pane has its OWN model, so a stale in-flight refresh writes to the pane you left, never the
    /// one you switched to. A disconnected pane (`nil` client) just clears its model — no fetch, no hang.
    private func bindAndRefresh() async {
        pruneClosedPaneModels()
        guard let id = activePaneID else { return }
        let model: PaneMetadataModel
        if let existing = models[id] {
            model = existing
        } else {
            model = PaneMetadataModel()
            models[id] = model
        }
        let client = activeMetadataClient
        model.setClient(client)
        guard client != nil else { return }
        await model.refresh()
        if let cwd = model.cwd, !cwd.isEmpty {
            store.setLastKnownCwd(cwd, for: id)
        }
    }

    /// Drops models for panes the inspector once showed but that are now closed (no live session handle),
    /// keeping the per-pane cache bounded. The active pane is always materialized, so a missing handle ⇒
    /// the pane is gone.
    private func pruneClosedPaneModels() {
        for id in Array(models.keys) where store.handle(for: id) == nil {
            models[id]?.setClient(nil)
            models.removeValue(forKey: id)
        }
    }

    // MARK: Segmented header (Details bar — active = icon+label pill, inactive = icon only)

    private var header: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: 8, height: 40) // clear the titlebar strip / traffic lights line
            ForEach(DetailsPanelTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }

    private func tabButton(_ tab: DetailsPanelTab) -> some View {
        let active = tab == details.selected
        return Button {
            withAnimation(Slate.Anim.standard) { details.selected = tab }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: tab.icon).font(.system(size: Slate.Typeface.footnote, weight: .medium))
                if active { Text(tab.title).font(.system(size: Slate.Typeface.footnote, weight: .medium)) }
            }
            .foregroundStyle(active ? Slate.Text.primary : Slate.Text.icon)
            .padding(.horizontal, active ? 8 : 6)
            .frame(height: 24)
            .background(active ? Slate.State.hover : .clear, in: .rect(cornerRadius: Slate.Metric.radiusControl))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch details.selected {
        // `.id(activePaneID)` resets the Info tab's local interaction state too — critically the Commands
        // navigator's `@State` selection + fetched-output cache — when the focused pane changes, so a stale
        // index-keyed cache can never render one pane's output under another pane's same-index block.
        case .info: infoContent.id(activePaneID)
        // `.id(activePaneID)` resets the tab's local interaction state (find query / scroll position) when
        // the focused pane changes — `activeModel` already switches to that pane's data.
        case .files: RemoteFileTreeView(model: activeModel).id(activePaneID)
        }
    }

    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            workingDirectorySection
            gitSection
            sectionDivider
            ProcessPortsView(model: activeModel)
                .padding(.bottom, Slate.Metric.space2)
            if isAgentPane {
                sectionDivider
                agentSessionsSection
            }
            sectionDivider
            commandsSection
        }
    }

    /// The Info-tab Working Directory section (E9/WI-6, ES-E9-1): leads the host-metadata content with the
    /// focused pane's working-directory path — a prominent, SELECTABLE, RESPONSIVE path per `info-panel.png`
    /// (full path when it fits, component-abbreviated `/V/L/W/o/leaf` when not, head-truncated as the last
    /// resort) — with the Copy action inline as a trailing icon (the old full-width "Copy Path" row wasted a
    /// line). Reveal-in-Finder / Open-in-VS-Code/Cursor/Xcode/Typora are intentionally absent: the path is a
    /// REMOTE host path with no local opener (E4 mapping note); Copy Path is the only working-directory
    /// action E9 ships. The canonical home for the cwd (the old truncated Session "Dir" row was removed).
    private var workingDirectorySection: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            SlateSectionHeader("Working Directory")
            HStack(spacing: Slate.Metric.space2) {
                workingDirectoryLabel
                Spacer(minLength: 0)
                ConfirmFlashButton(action: copyWorkingDirectory) { confirming in
                    // Fixed 16×16 — the copy/checkmark glyphs differ in intrinsic size, and letting the
                    // swap resize the button shifted the whole row.
                    Image(systemName: confirming ? "checkmark" : "doc.on.doc")
                        .font(.system(size: Slate.Typeface.base))
                        .foregroundStyle(confirming ? Slate.Status.ok : Slate.State.accent)
                        .frame(width: 16, height: 16)
                        .contentShape(.rect)
                }
                .disabled(resolvedCwd == nil)
                .help("Copy the working-directory path")
                .accessibilityLabel("Copy the working-directory path")
            }
            .padding(.horizontal, Slate.Metric.space3)
        }
        .padding(.top, Slate.Metric.space1)
        .padding(.bottom, Slate.Metric.space2)
    }

    /// The RESPONSIVE working-directory label: `ViewThatFits` tries the full path, then the fish-style
    /// component-abbreviated form (`/V/L/W/o/aislopdesk`), and falls back to HEAD-truncating the abbreviated
    /// form when even that overflows — so the leaf directory (the part that identifies the project) survives
    /// every width. The old single head-truncated `Text` lost the leading components at any overflow, and its
    /// selectable text scrolled part of the TAIL out of view once selected.
    @ViewBuilder private var workingDirectoryLabel: some View {
        if let path = resolvedCwd {
            ViewThatFits(in: .horizontal) {
                pathText(path)
                pathText(InfoTabFormatting.abbreviatedPath(path))
                pathText(InfoTabFormatting.abbreviatedPath(path))
                    .truncationMode(.head)
            }
        } else {
            pathText("—")
        }
    }

    private func pathText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Slate.Typeface.body))
            .foregroundStyle(Slate.Text.primary)
            .textSelection(.enabled)
            .lineLimit(1)
    }

    /// The Info-tab GIT section (the old standalone Git tab merged here): ONE summary row — branch name,
    /// ahead/behind deltas, and the changed-file count — that opens the full `GitStatusView` (status list +
    /// per-file diff) as a POPUP. The changed-file list is unbounded, so it gets a window instead of a
    /// sidebar tab; the Info row stays one line. Hidden while the pane has no metadata yet or the cwd is not
    /// inside a git repo (the summary would carry no signal).
    @ViewBuilder private var gitSection: some View {
        if let status = activeModel.gitStatus, status.hasRepo {
            sectionDivider
            VStack(alignment: .leading, spacing: 0) {
                SlateSectionHeader("Git")
                Button {
                    showGitDetails = true
                } label: {
                    HStack(spacing: Slate.Metric.space2) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(Slate.Text.icon)
                        Text(status.branch.isEmpty ? "detached" : status.branch)
                            .foregroundStyle(Slate.Text.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if status.ahead != 0 {
                            gitDelta(symbol: "arrow.up", count: status.ahead, tint: Slate.Status.ok)
                        }
                        if status.behind != 0 {
                            gitDelta(symbol: "arrow.down", count: status.behind, tint: Slate.Status.warn)
                        }
                        Spacer(minLength: Slate.Metric.space2)
                        Text(InfoTabFormatting.gitChangeSummary(status.files.count))
                            .font(.system(size: Slate.Typeface.footnote))
                            .foregroundStyle(status.files.isEmpty ? Slate.Status.ok : Slate.Status.warn)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.system(size: Slate.Typeface.small, weight: .semibold))
                            .foregroundStyle(Slate.Text.tertiary)
                    }
                    .font(.system(size: Slate.Typeface.base))
                    .padding(.horizontal, Slate.Metric.space3)
                    .padding(.vertical, 3)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Show git status and diffs")
                .accessibilityLabel("Show git status and diffs")
            }
            .padding(.bottom, Slate.Metric.space2)
        }
    }

    private func gitDelta(symbol: String, count: Int32, tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: Slate.Typeface.small, weight: .semibold))
            Text(String(count)).font(.system(size: Slate.Typeface.footnote)).monospacedDigit()
        }
        .foregroundStyle(tint)
    }

    /// Writes the resolved working-directory path to the system pasteboard — the `RemoteFileTreeView.copyPath`
    /// idiom (NSPasteboard on macOS, UIPasteboard on iOS). A `nil` cwd is a no-op (the row is disabled), so
    /// the placeholder "—" never reaches the pasteboard.
    private func copyWorkingDirectory() {
        guard let path = resolvedCwd else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = path
        #endif
    }

    /// The Info-tab AGENT-PANE section (E4/WI-6, `info-panel.png` › the agent-named section — labelled with the
    /// agent's name, "Claude Code" here per the Claude-only scope). Shown when the focused pane is a live agent
    /// (``isAgentPane``), NOT gated on whether on-disk sessions exist — so the section appears for a freshly
    /// started agent. Carries the agent-specific actions: **Copy Session ID** (the live session
    /// id; disabled until known) and **View Session History** (presents `AgentSessionHistoryView`; the trailing
    /// count hints how many sessions are available when ≥ 1). A separate agent-fork surface ("Fork in…") is
    /// not shipped here.
    private var agentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SlateSectionHeader("Claude Code")
            // Copy Session ID flashes a checkmark after firing (the ConfirmFlashButton feedback beat) —
            // a silent pasteboard write otherwise reads as a no-op.
            ConfirmFlashButton(action: copySessionID) { confirming in
                agentRowLabel(
                    systemImage: confirming ? "checkmark" : "doc.on.doc",
                    title: confirming ? "Copied" : "Copy Session ID",
                    disabled: activeAgentSessionID == nil,
                    tint: confirming ? Slate.Status.ok : nil,
                )
            }
            .disabled(activeAgentSessionID == nil)
            .accessibilityLabel("Copy Session ID")
            agentActionRow(
                systemImage: "clock.arrow.circlepath",
                title: "View Session History",
                action: { showSessionHistory = true },
            ) {
                if !activeModel.agentSessions.isEmpty {
                    Text(String(activeModel.agentSessions.count))
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.tertiary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.bottom, Slate.Metric.space2)
    }

    /// One themed agent action row: a leading SF Symbol + an accent label, with an optional trailing
    /// accessory (e.g. the session count). A `disabled` row renders muted and is non-tappable.
    private func agentActionRow(
        systemImage: String,
        title: String,
        action: @escaping () -> Void,
        disabled: Bool = false,
        @ViewBuilder trailing: () -> some View = { EmptyView() },
    ) -> some View {
        Button(action: action) {
            agentRowLabel(systemImage: systemImage, title: title, disabled: disabled, trailing: trailing)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(title)
    }

    /// The agent action row's LABEL (shared by the plain rows and the flash-confirming Copy row): a leading
    /// SF Symbol + an accent label + optional trailing accessory. `tint` overrides the enabled accent (the
    /// flash state's `Slate.Status.ok`).
    private func agentRowLabel(
        systemImage: String,
        title: String,
        disabled: Bool = false,
        tint: Color? = nil,
        @ViewBuilder trailing: () -> some View = { EmptyView() },
    ) -> some View {
        HStack(spacing: Slate.Metric.space2) {
            // Fixed 16×16 — the Copy row swaps its glyph to a checkmark while flash-confirming, and the
            // glyphs' differing intrinsic sizes otherwise nudge the title and the row height.
            Image(systemName: systemImage)
                .frame(width: 16, height: 16)
            Text(title)
            Spacer(minLength: Slate.Metric.space2)
            trailing()
        }
        .font(.system(size: Slate.Typeface.base))
        .foregroundStyle(disabled ? Slate.Text.tertiary : (tint ?? Slate.State.accent))
        .padding(.horizontal, Slate.Metric.space3)
        .padding(.vertical, 3)
        .contentShape(.rect)
    }

    /// Writes the focused agent pane's live Claude session id to the system pasteboard (the `copyWorkingDirectory`
    /// idiom — NSPasteboard on macOS, UIPasteboard on iOS). A `nil` id is a no-op (the row is disabled).
    private func copySessionID() {
        guard let id = activeAgentSessionID else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = id
        #endif
    }

    private var sectionDivider: some View {
        Rectangle().fill(Slate.Line.divider).frame(height: 1).padding(.horizontal, Slate.Metric.space3)
    }

    @ViewBuilder private var commandsSection: some View {
        if let terminalModel {
            BlockHistoryView(
                model: terminalModel.blocks,
                requestOutput: { index, completion in
                    terminalModel.requestBlockOutputBytes(index: index, onResult: completion)
                },
                onJump: { store.jumpToNavigatorBlockInActivePane(index: $0) },
            )
        } else {
            emptyState("No Commands", systemImage: "terminal", note: "Select a terminal pane to see its history")
        }
    }

    private func emptyState(_ title: String, systemImage: String, note: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(note))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The segmented Details header's per-tab DISPLAY (E9/WI-7): the short label + SF Symbol for each
/// ``DetailsPanelTab``. Kept as a view-local extension (NOT on the core `DetailsPanelTab`, which stays a pure
/// value enum) so the SF-symbol / title strings live in the UI layer; `internal` so the placement pin in
/// `InspectorRenderingTests` reaches it via `@testable import`. Tab order is Info | Files (the old Outline
/// tab is merged into Info's Commands section; the old Git tab into Info's git-summary row + popup).
extension DetailsPanelTab {
    /// The short header label (NOT the `Details: …` palette title) shown when the tab is active.
    var title: String {
        switch self {
        case .info: "Info"
        case .files: "Files"
        }
    }

    /// The SF Symbol for the tab (mirrors the `Details: *` registry binding symbols).
    var icon: String {
        switch self {
        case .info: "info.circle"
        case .files: "folder"
        }
    }
}

/// Pure formatting for the Info tab's Working Directory section (E9/WI-6) — extracted so the cwd → display
/// normalisation is headlessly testable (no view, no `Slate` theme read). Mirrors the `MetadataFormatting`
/// pure-helper precedent so the WD section isn't purely GUI.
enum InfoTabFormatting {
    /// The display string for a working-directory path: a `nil` or empty path renders the em-dash
    /// placeholder "—" (never a blank row); any non-empty path passes through VERBATIM (it is a REMOTE host
    /// path — no client-side normalisation, since `~`/separators are the host's, not this machine's).
    static func displayPath(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "—" }
        return path
    }

    /// Resolves the Working Directory row's source of truth: the pane spec's live `lastKnownCwd` (kept
    /// fresh on every `cd` via OSC-7 / the post-command cwd RPC) wins over the metadata model's bind-time
    /// `cwd` (only refetched on pane-focus/(re)connect, so it goes stale the moment the user `cd`s in an
    /// already-focused pane). Falls back to the model cwd only when no live cwd is known yet (e.g. a
    /// freshly-spawned pane before any prompt has fired). An empty candidate is treated as missing.
    static func resolveWorkingDirectory(lastKnownCwd: String?, modelCwd: String?) -> String? {
        if let lastKnownCwd, !lastKnownCwd.isEmpty { return lastKnownCwd }
        if let modelCwd, !modelCwd.isEmpty { return modelCwd }
        return nil
    }

    /// The fish-style component-abbreviated form of a path — the Working Directory label's MIDDLE
    /// responsive step (`ViewThatFits`: full path → this → head-truncate this). Every component but the
    /// LAST collapses to its first character (`/Volumes/Lacie/Workspace/oss/aislopdesk` →
    /// `/V/L/W/o/aislopdesk`); a leading `~` survives whole and a hidden directory keeps its dot + first
    /// letter (`.config` → `.c`) so both stay recognisable. The leaf component — the part that identifies
    /// the project — is never shortened. Separators are the REMOTE host's `/` (the path is a host path;
    /// aislopdesk hosts are macOS). A path with fewer than two components passes through unchanged.
    static func abbreviatedPath(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1, let leaf = parts.last else { return path }
        let head = parts.dropLast().map { component in
            if component == "~" { return component }
            if component.hasPrefix(".") { return String(component.prefix(2)) }
            return String(component.prefix(1))
        }
        let joined = (head + [leaf]).joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }

    /// The Info-tab git-summary row's trailing change-count label: `0` reads "clean" (mirrors the popup's
    /// "Working tree clean" state), otherwise "N changed" (the popup's "Changed (N)" header count).
    static func gitChangeSummary(_ changedCount: Int) -> String {
        changedCount == 0 ? "clean" : "\(changedCount) changed"
    }
}
#endif
