#if canImport(SwiftUI)
import SwiftUI

// Read-only SwiftUI render of the inspector data. These views are logic-free: every
// projection lives in `InspectorViewModel`; views only lay out + style. They compile
// in the macOS/iOS library target.

/// The top-level inspector pane: session header + tool timeline, subagent tree, todos,
/// and the thinking-placeholder indicator. Drive it from a view-model fed by the
/// `InspectorClient` event stream (e.g. in a `.task { await vm.consume(client.events()) }`).
public struct InspectorPane: View {
    private let model: InspectorViewModel

    public init(model: InspectorViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionHeaderView(session: model.session, workflow: model.workflow)
            Divider()
            if model.feedState != .live {
                FeedStateBannerView(state: model.feedState)
            }
            ScrollView {
                if !model.hasRenderableActivity {
                    InspectorEmptyStateView(feedState: model.feedState)
                        .padding(.top, 48)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ThinkingIndicatorView(marker: model.lastThinking, count: model.thinkingCount)
                        if !model.todos.isEmpty {
                            TodoListView(todos: model.todos)
                        }
                        if model.evictedToolCardCount > 0 {
                            // The drop-oldest cap truncated the START of a long session's timeline —
                            // disclose it instead of silently losing the early steps (UI/UX pass-3 #9).
                            Label("\(model.evictedToolCardCount) earlier steps hidden",
                                  systemImage: "clock.arrow.circlepath")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityLabel("\(model.evictedToolCardCount) earlier tool calls hidden to bound memory")
                        }
                        if model.droppedReplayEventCount > 0 {
                            // The HOST replay log dropped the oldest events (retention overflow) before
                            // the prefix we subscribed from — the timeline starts mid-transcript, so
                            // disclose it rather than presenting a truncated history as complete (R17 INSP-WIRE-1).
                            Label("\(model.droppedReplayEventCount) earlier steps dropped before this point",
                                  systemImage: "scissors")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityLabel("\(model.droppedReplayEventCount) earlier inspector events dropped by the host retention limit")
                        }
                        ToolCardListView(title: "Tool calls", cards: model.toolCards)
                        if !model.subagentTree.isEmpty {
                            SubagentTreeView(roots: model.subagentTree)
                        }
                        if model.unknownLineCount > 0 {
                            UnknownLinesView(count: model.unknownLineCount, lines: model.recentUnknownLines)
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

/// Centered placeholder shown while the timeline has no renderable activity yet — so the on-demand
/// panel reads as "waiting", not "broken/empty void".
struct InspectorEmptyStateView: View {
    let feedState: InspectorViewModel.FeedState

    var body: some View {
        VStack(spacing: 10) {
            if feedState == .live {
                ProgressView()
                Text("Waiting for session activity…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "wifi.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(feedState == .failed ? "Inspector feed ended unexpectedly" : "No session activity")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A thin banner shown when the feed is no longer live, so frozen cards don't masquerade as current.
struct FeedStateBannerView: View {
    let state: InspectorViewModel.FeedState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state == .failed ? "exclamationmark.triangle.fill" : "pause.circle.fill")
            Text(state == .failed ? "Feed disconnected — showing last received state" : "Feed ended — showing final state")
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(state == .failed ? Color.orange : Color.secondary)
        .padding(.horizontal)
        .padding(.vertical, 5)
        .background(.background.secondary)
    }
}

/// Turns the bare unrecognised-line COUNT into an inspectable disclosure (the recent raw lines), so
/// a schema-evolution alarm becomes debuggable instead of a dead end. The count stays the true total.
struct UnknownLinesView: View {
    let count: Int
    let lines: [String]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Text("\(count) unrecognised transcript line(s)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SessionHeaderView: View {
    let session: SessionInfo?
    let workflow: WorkflowMarker.State

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session?.model ?? "Claude Code").font(.headline)
                if let cwd = session?.cwd {
                    Text(cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if workflow == .running {
                Label("workflow running", systemImage: "gearshape.2")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// A timeline / list of tool cards (input + output + status).
public struct ToolCardListView: View {
    let title: String
    let cards: [ToolCard]

    public init(title: String, cards: [ToolCard]) {
        self.title = title
        self.cards = cards
    }

    public var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.subheadline.bold())
                ForEach(cards) { card in
                    ToolCardView(card: card)
                }
            }
        }
    }
}

struct ToolCardView: View {
    let card: ToolCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(card.name).font(.callout.bold())
                Spacer()
            }
            Text(card.input.displayString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(6)
            if let output = card.output, !output.isEmpty {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(8)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusIcon: String {
        switch card.status {
        case .pending: return "clock"
        case .completed: return "checkmark.circle"
        case .errored: return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch card.status {
        case .pending: return .secondary
        case .completed: return .green
        case .errored: return .red
        }
    }
}

/// The todo / task list with status glyphs.
public struct TodoListView: View {
    let todos: [TodoItem]

    public init(todos: [TodoItem]) {
        self.todos = todos
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Todos").font(.subheadline.bold())
            ForEach(todos) { todo in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: glyph(todo.status))
                        .foregroundStyle(color(todo.status))
                    Text(todo.status == .inProgress ? (todo.activeForm ?? todo.content) : todo.content)
                        .strikethrough(todo.status == .completed)
                        .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                }
                .font(.callout)
            }
        }
    }

    private func glyph(_ status: TodoItem.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func color(_ status: TodoItem.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        }
    }
}

/// A collapsible subagent tree (each node shows its type/status + its own tool cards).
public struct SubagentTreeView: View {
    let roots: [SubagentTreeNode]

    public init(roots: [SubagentTreeNode]) {
        self.roots = roots
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subagents").font(.subheadline.bold())
            ForEach(roots) { root in
                SubagentNodeView(node: root)
            }
        }
    }
}

struct SubagentNodeView: View {
    let node: SubagentTreeNode

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let last = node.node.lastAssistantMessage, !last.isEmpty {
                    Text(last).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(node.cards) { card in
                    ToolCardView(card: card)
                }
                ForEach(node.children) { child in
                    SubagentNodeView(node: child)
                        .padding(.leading, 12)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                // Use the same in-progress glyph the todo list uses (both already `.blue`) so "running"
                // reads consistently across the inspector.
                Image(systemName: node.node.status == .running ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .foregroundStyle(node.node.status == .running ? .blue : .green)
                Text(node.node.agentType ?? node.node.id).font(.callout.bold())
                if let description = node.node.description {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// The thinking-placeholder indicator (doc 16: placeholder only, empty-aware).
public struct ThinkingIndicatorView: View {
    let marker: ThinkingMarker?
    let count: Int

    public init(marker: ThinkingMarker?, count: Int) {
        self.marker = marker
        self.count = count
    }

    public var body: some View {
        if let marker {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .foregroundStyle(.purple)
                if marker.isPlaceholder {
                    Text("Thinking (not persisted)")
                        .italic()
                        .foregroundStyle(.secondary)
                    if let signature = marker.signature {
                        Text(String(signature.prefix(8)))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                } else if let text = marker.text {
                    Text(text).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer()
                if count > 1 {
                    Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
        }
    }
}
#endif
