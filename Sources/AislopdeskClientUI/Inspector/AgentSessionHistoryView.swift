// AgentSessionHistoryView — the Details Panel's "View Session History" viewer (E4, WI-6).
//
// Ports the otty agent-history viewer (spec/agents__history.md → agent-history.png): the Info tab surfaces
// a "View Session History" action (clock icon + green label); opening it presents this viewer, which lists
// the pane project's captured agent sessions (`PaneMetadataModel.agentSessions`) and — on selecting one —
// fetches its raw JSONL via the `readAgentSession` verb and renders it as a human-readable transcript
// (speaker turns + collapsed tool-call summaries + Markdown bodies) instead of raw JSON.
//
// SCOPE (per the E4 mapping notes): E4 LISTS + RENDERS only. otty's "Resume" / "Send to Chat" / "Fork in…"
// are the later agent epics — this viewer is read-only. The JSONL → transcript parse runs through the
// EXISTING `AislopdeskInspector.TranscriptParser` (never a second JSONL parser); each turn's body renders
// through the app's one `MarkdownText` seam (Textual's `StructuredText` + its large-document guard).
//
// The parse path (`AgentTranscript`) + the formatting helpers (relative time, agent label, tool summary,
// clock-time extraction) are PURE + headlessly unit-tested (`InspectorRenderingTests`) — the view only maps
// their result onto `Otty` tokens, so a regression in the bytes→transcript path fails a test, not a render.

#if canImport(SwiftUI)
import AislopdeskInspector
import AislopdeskProtocol
import AislopdeskWorkspaceCore
import SwiftUI

struct AgentSessionHistoryView: View {
    /// The active pane's decoded host metadata — its `agentSessions` list + the `readAgentSession` fetch.
    let model: PaneMetadataModel
    /// Dismisses the viewer (the Info tab clears its `showSessionHistory` flag). Defaults to a no-op so a
    /// preview / test can instantiate the view standalone.
    var onClose: () -> Void = {}

    /// The session whose transcript is open, or `nil` while showing the session LIST (master view).
    @State private var selectedSession: MetadataCodec.AgentSessionInfo?
    /// The parsed transcript of `selectedSession` (empty while loading / on failure / for an empty log).
    @State private var entries: [AgentTranscriptEntry] = []
    /// True while the `readAgentSession` round-trip for `selectedSession` is in flight.
    @State private var loading = false
    /// True when the most recent read failed (a `nil` byte reply) — distinct from a legitimately empty log.
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Rectangle().fill(Otty.Line.divider).frame(height: 1)
            if selectedSession != nil {
                transcriptView
            } else {
                sessionListView
            }
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 560)
        .background(Otty.Surface.content)
    }

    // MARK: Header bar (back · title · close)

    private var headerBar: some View {
        HStack(spacing: Otty.Metric.space2) {
            if selectedSession != nil {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: Otty.Typeface.base, weight: .semibold))
                        .foregroundStyle(Otty.Text.icon)
                }
                .buttonStyle(.plain)
                .help("Back to sessions")
            }
            Text(headerTitle)
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Otty.Metric.space2)
            Button(action: onClose) {
                HStack(spacing: Otty.Metric.space1) {
                    Image(systemName: "xmark")
                    Text("Close")
                }
                .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                .foregroundStyle(Otty.Text.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, Otty.Metric.space3)
        .frame(height: 40)
        .background(Otty.Surface.sidebar)
    }

    private var headerTitle: String {
        if let selectedSession { return displayTitle(selectedSession) }
        return "Session History"
    }

    // MARK: Session list (master)

    @ViewBuilder private var sessionListView: some View {
        if model.agentSessions.isEmpty {
            emptyState(
                "No Sessions",
                systemImage: "clock",
                note: model.isConnected
                    ? "No agent sessions found for this project"
                    : "Connect a pane to see its agent sessions",
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.agentSessions.enumerated()), id: \.offset) { _, session in
                        sessionRow(session)
                        Rectangle().fill(Otty.Line.divider)
                            .frame(height: 1)
                            .padding(.leading, Otty.Metric.space3)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: MetadataCodec.AgentSessionInfo) -> some View {
        Button {
            open(session)
        } label: {
            HStack(spacing: Otty.Metric.space2) {
                Image(systemName: "text.bubble")
                    .font(.system(size: Otty.Typeface.body))
                    .foregroundStyle(Otty.Text.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle(session))
                        .font(.system(size: Otty.Typeface.base))
                        .foregroundStyle(Otty.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: Otty.Metric.space1) {
                        Text(AgentTranscript.agentLabel(session.agentKind))
                            .font(.system(size: Otty.Typeface.small, weight: .medium))
                            .foregroundStyle(Otty.State.accent)
                        if !session.cwd.isEmpty {
                            Text(session.cwd)
                                .font(.system(size: Otty.Typeface.small))
                                .foregroundStyle(Otty.Text.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
                Spacer(minLength: Otty.Metric.space2)
                Text(AgentTranscript.relativeTime(session.mtimeMS))
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: Otty.Typeface.small, weight: .semibold))
                    .foregroundStyle(Otty.Text.icon)
            }
            .padding(.horizontal, Otty.Metric.space3)
            .padding(.vertical, Otty.Metric.space2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Transcript (detail)

    @ViewBuilder private var transcriptView: some View {
        if loading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadFailed {
            emptyState(
                "Could Not Load Session",
                systemImage: "exclamationmark.triangle",
                note: "The session transcript could not be read from the host",
            )
        } else if entries.isEmpty {
            emptyState(
                "Empty Transcript",
                systemImage: "text.bubble",
                note: "This session has no rendered turns yet",
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let selectedSession { sessionMeta(selectedSession) }
                Rectangle().fill(Otty.Line.divider).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            transcriptRow(entry)
                        }
                    }
                }
            }
        }
    }

    private func sessionMeta(_ session: MetadataCodec.AgentSessionInfo) -> some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            Text(displayTitle(session))
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
                .lineLimit(2)
            HStack(spacing: Otty.Metric.space2) {
                Text(AgentTranscript.agentLabel(session.agentKind))
                    .font(.system(size: Otty.Typeface.small, weight: .medium))
                    .foregroundStyle(Otty.State.accent)
                if !session.cwd.isEmpty {
                    Text(session.cwd)
                        .font(.system(size: Otty.Typeface.small))
                        .foregroundStyle(Otty.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: Otty.Metric.space2)
                Text(AgentTranscript.relativeTime(session.mtimeMS))
                    .font(.system(size: Otty.Typeface.small))
                    .foregroundStyle(Otty.Text.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Otty.Metric.space3)
        .padding(.vertical, Otty.Metric.space2)
    }

    private func transcriptRow(_ entry: AgentTranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            rowHeader(entry)
            if !entry.markdown.isEmpty {
                MarkdownText(markdown: entry.markdown)
                    .padding(.leading, Otty.Metric.space3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Otty.Metric.space3)
        .padding(.vertical, Otty.Metric.space2)
        .background(entry.role == .user ? Otty.State.hover : Color.clear)
    }

    private func rowHeader(_ entry: AgentTranscriptEntry) -> some View {
        HStack(spacing: Otty.Metric.space1) {
            switch entry.role {
            case .user:
                OttyStatusDot(color: Otty.Text.icon, size: 6)
            case .assistant:
                Image(systemName: "chevron.right")
                    .font(.system(size: Otty.Typeface.small, weight: .semibold))
                    .foregroundStyle(Otty.Text.icon)
            }
            Text(entry.speaker)
                .font(.system(size: Otty.Typeface.footnote, weight: .semibold))
                .foregroundStyle(Otty.Text.secondary)
            if let detail = entry.detail, !detail.isEmpty {
                Text("· \(detail)")
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let clock = entry.timestamp.flatMap(AgentTranscript.clockTime(fromISO:)) {
                Text(clock)
                    .font(.system(size: Otty.Typeface.small))
                    .foregroundStyle(Otty.Text.tertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Behaviour

    /// Opens `session`: marks it selected, clears the prior transcript, and fetches its raw JSONL off the
    /// pane's `readAgentSession` verb — parsing the bytes through `AgentTranscript` (→ `TranscriptParser`).
    /// A late reply for a session the user has since left (or backed out of) is dropped.
    private func open(_ session: MetadataCodec.AgentSessionInfo) {
        selectedSession = session
        entries = []
        loadFailed = false
        loading = true
        let assistantName = AgentTranscript.agentLabel(session.agentKind)
        Task {
            let bytes = await model.readAgentSession(id: session.id)
            guard selectedSession?.id == session.id else { return }
            if let bytes {
                entries = AgentTranscript.entries(from: bytes, assistantName: assistantName)
                loadFailed = false
            } else {
                entries = []
                loadFailed = true
            }
            loading = false
        }
    }

    /// Returns to the session list (master), discarding the open transcript.
    private func back() {
        selectedSession = nil
        entries = []
        loading = false
        loadFailed = false
    }

    private func displayTitle(_ session: MetadataCodec.AgentSessionInfo) -> String {
        if !session.title.isEmpty { return session.title }
        let leaf = session.id.split(separator: "/").last.map(String.init) ?? session.id
        return leaf.isEmpty ? "Untitled Session" : leaf
    }

    private func emptyState(_ title: String, systemImage: String, note: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(note))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pure transcript parse + formatting (headlessly unit-tested)

/// One flattened, render-ready transcript turn derived from a parsed ``TranscriptLine``. Pure value type so
/// the bytes → transcript path is unit-tested without a view: `markdown` is the body the row renders via
/// ``MarkdownText``; `detail` is a subdued one-liner (the collapsed tool-call summary).
struct AgentTranscriptEntry: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id: Int
    let role: Role
    let speaker: String
    let timestamp: String?
    let markdown: String
    let detail: String?
}

/// Pure JSONL → transcript projection (E4, WI-6). Routes the raw `readAgentSession` bytes through the
/// EXISTING ``TranscriptParser`` line-by-line and flattens each recognised conversation turn into an
/// ``AgentTranscriptEntry`` the viewer renders. Tolerant by construction — a malformed line parses to
/// `.unknown` (dropped here), and non-conversation lines (meta / ignored bookkeeping) are skipped — so a
/// garbled session never traps or drops the whole transcript. Foundation-only; no SwiftUI, no view read.
enum AgentTranscript {
    /// Parses raw session bytes into render-ready turns. UTF-8 **lossy** decode (a session file is trusted
    /// but may carry a stray byte): render what decodes rather than drop the whole log; `TranscriptParser`
    /// is itself tolerant of any resulting line. `assistantName` labels assistant turns (the agent's name).
    static func entries(from data: Data, assistantName: String = "Assistant") -> [AgentTranscriptEntry] {
        // LOSSY by design (not the failable `String(data:encoding:)`): never trap / drop on a stray byte.
        // swiftlint:disable:next optional_data_string_conversion
        entries(from: String(decoding: data, as: UTF8.self), assistantName: assistantName)
    }

    static func entries(from text: String, assistantName: String = "Assistant") -> [AgentTranscriptEntry] {
        var out: [AgentTranscriptEntry] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let line = TranscriptParser.parse(line: String(raw)) else { continue }
            guard let entry = entry(from: line, id: out.count, assistantName: assistantName) else { continue }
            out.append(entry)
        }
        return out
    }

    /// Flattens one parsed line into a turn, or `nil` for lines the transcript view omits: a user line that
    /// is purely a `tool_result` echo (no text), an assistant line with no text AND no tool calls (e.g. a
    /// not-persisted "thinking" placeholder), and every meta / ignored / unknown line.
    private static func entry(from line: TranscriptLine, id: Int, assistantName: String) -> AgentTranscriptEntry? {
        switch line {
        case let .user(user):
            guard let text = user.text, !text.isEmpty else { return nil }
            return AgentTranscriptEntry(
                id: id,
                role: .user,
                speaker: "You",
                timestamp: user.identity.timestamp,
                markdown: text,
                detail: nil,
            )
        case let .assistant(assistant):
            let body = assistant.text ?? ""
            let detail = assistant.toolUses.isEmpty ? nil : toolSummary(assistant.toolUses)
            guard !body.isEmpty || detail != nil else { return nil }
            return AgentTranscriptEntry(
                id: id,
                role: .assistant,
                speaker: assistantName,
                timestamp: assistant.identity.timestamp,
                markdown: body,
                detail: detail,
            )
        case .meta,
             .ignored,
             .unknown:
            return nil
        }
    }

    /// A compact, deterministic summary of an assistant turn's tool calls — grouped by name in first-use
    /// order, a "×N" suffix when a tool repeats (e.g. "Read ×6 · Edit · Bash"). Mirrors otty's collapsed
    /// tool-call summary line.
    static func toolSummary(_ uses: [ToolUseBlock]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for use in uses {
            let name = use.name.isEmpty ? "tool" : use.name
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order
            .map { name in
                let count = counts[name] ?? 1
                return count > 1 ? "\(name) ×\(count)" : name
            }
            .joined(separator: " · ")
    }

    /// The agent's display name for a (forward-tolerant) ``MetadataCodec/AgentKind`` — `nil` (an unknown
    /// future kind byte) falls back to the generic "Agent".
    static func agentLabel(_ kind: MetadataCodec.AgentKind?) -> String {
        switch kind {
        case .claude:
            "Claude Code"
        case .codex:
            "Codex"
        case .opencode:
            "OpenCode"
        case nil:
            "Agent"
        }
    }

    /// A coarse relative-time label for a session's `mtimeMS` (otty's "43s ago" / "3 min ago" / "2h ago" /
    /// "3d ago"). `now` is injectable so the bucketing is unit-tested deterministically. A future timestamp
    /// (clock skew) clamps to "just now".
    static func relativeTime(_ mtimeMS: Int64, now: Date = Date()) -> String {
        let then = Date(timeIntervalSince1970: Double(mtimeMS) / 1000)
        let seconds = Int(now.timeIntervalSince(then))
        if seconds < 0 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// Extracts the "HH:mm:ss" clock portion of an ISO-8601 timestamp (the per-turn time hint), or `nil` if
    /// the string has no parseable time field — never a trap. Pure string slicing (no `DateFormatter`): the
    /// transcript only needs the wall-clock hint otty shows next to each speaker, not a parsed `Date`.
    static func clockTime(fromISO iso: String) -> String? {
        guard let tIndex = iso.firstIndex(of: "T") else { return nil }
        var time = ""
        for char in iso[iso.index(after: tIndex)...] {
            if char == "." || char == "Z" || char == "+" || char == "-" { break }
            time.append(char)
        }
        let isClock = time.count == 8 && time.count(where: { $0 == ":" }) == 2
        return isClock ? time : nil
    }
}
#endif
