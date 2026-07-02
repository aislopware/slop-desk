// BlockHistoryView — the Commands inspector panel (REBUILD-V2, L3): a first-class, Warp-style command
// navigator bound to the ACTIVE terminal pane's `TerminalBlockModel`.
//
// Header ("Commands") + a "Failed only" toggle, a native `List(selection:)` of the model's newest-first
// `navigatorBlocks` (filtered) rendered via `BlockRowView`, and a detail area below the list that expands
// the selected block's output (`BlockOutputView`). Selecting a block REQUESTS its captured output via the
// injected `requestOutput` closure (the pane's `TerminalViewModel.copyBlockOutput`, which fires wire type
// 15 and resolves with VT-stripped plain text). Per-row `.contextMenu`: jump to the command in the
// scrollback / copy command / copy output / star-unstar (the model's bookmarks API). ⌘↑/⌘↓ move the
// selection. Empty state via `ContentUnavailableView`.
//
// This panel ABSORBED the old standalone Outline tab (E9): each row shows the clock time the command
// ran (its client-receive first-seen stamp), and the row jump — the context menu's "Jump to Command" —
// routes to the injected `onJump` (the store's `jumpToNavigatorBlockInActivePane`, the shared
// ordinal-anchored `BlockJump`). No per-row jump icon: the menu is the single jump affordance.
//
// Slate tokens + SF Symbols (the Outline-merge restyle — the panel matches the Info tab's other
// sections: a SlateSectionHeader, flat separator-less rows, a hover-revealed jump arrow). The block
// model + sanitizer are pure; this view holds selection + a per-index fetched-output cache as `@State`.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct BlockHistoryView: View {
    /// The active pane's pure block store (newest-first `navigatorBlocks`, bookmarks API).
    let model: TerminalBlockModel
    /// Fires the output-request flow for a block index, calling back with the RAW captured VT bytes
    /// (`nil` when evicted / unavailable / disconnected). Injected from the active pane's
    /// `TerminalViewModel.requestBlockOutputBytes(index:onResult:)` so this view stays free of the client
    /// actor. The bytes keep their SGR colour runs — `BlockOutputView` renders them coloured; the copy path
    /// strips them through `BlockOutputSanitizer`.
    let requestOutput: (UInt32, @escaping (Data?) -> Void) -> Void
    /// Jumps the pane's scrollback to a block index (the store's `jumpToNavigatorBlockInActivePane`).
    /// Injected so this view stays free of the store/client actor; the no-op default keeps the panel
    /// standalone-mountable (previews / tests).
    var onJump: (UInt32) -> Void = { _ in }

    @State private var selection: UInt32?
    @State private var failedOnly = false
    /// Whether the Commands list owns keyboard focus. Gates the ⌘↑/⌘↓ stepper so the shortcut is LIVE only
    /// while the inspector list is focused — otherwise the window-global `.keyboardShortcut` would swallow
    /// ⌘↑/⌘↓ even when a terminal pane is focused (a disabled control does not fire its shortcut).
    @FocusState private var listFocused: Bool
    /// The fetched RAW output bytes per block index. A present key = fetch resolved (value may be `nil`
    /// for unavailable); an absent key + `fetching` membership = a request is in flight.
    @State private var outputCache: [UInt32: Data?] = [:]
    @State private var fetching: Set<UInt32> = []

    /// The currently-displayed blocks: newest-first, optionally filtered to failures.
    private var blocks: [CommandBlock] {
        model.blocks(filter: failedOnly ? .failed : .all)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if blocks.isEmpty {
                emptyState
            } else {
                list
                if let selected = selectedBlock {
                    Divider()
                    detail(for: selected)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Header

    /// The section header — the SAME `SlateSectionHeader` idiom as the Info tab's other sections
    /// (Working Directory / Claude Code), with the failed-only filter as a quiet trailing icon that
    /// tints red only while active.
    private var header: some View {
        SlateSectionHeader("Commands") {
            Button {
                failedOnly.toggle()
            } label: {
                Image(systemName: "xmark.octagon")
                    .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                    .foregroundStyle(failedOnly ? Slate.Status.err : Slate.Text.icon)
                    .padding(2)
                    .background(
                        failedOnly ? Slate.State.hover : .clear,
                        in: .rect(cornerRadius: Slate.Metric.radiusSmall),
                    )
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show failed commands only")
            .accessibilityLabel("Show failed commands only")
        }
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            ForEach(blocks) { block in
                row(for: block)
                    .tag(block.index)
                    .contextMenu { rowMenu(for: block) }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: 0, leading: Slate.Metric.space2,
                        bottom: 0, trailing: Slate.Metric.space2,
                    ))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .focused($listFocused)
        .onChange(of: selection) { _, newValue in
            if let index = newValue { fetchIfNeeded(index) }
        }
        // Completion edge: a block selected WHILE RUNNING resolves to `nil` (the host only holds output for
        // COMPLETED blocks). When it later completes (or its byte count grows), invalidate the poisoned nil
        // and refetch — otherwise the detail would read "Output unavailable" forever. Keyed on the selected
        // block's completion + byte count so a running→done transition (or a growing tail) re-fires it.
        .onChange(of: selectedBlockRevision) { _, _ in
            if let index = selection { fetchIfNeeded(index) }
        }
        // Reconnect edge: a fresh session (`blocks.reset()`) bumps the model epoch and re-segments block
        // indices from 0. Discard the whole index-keyed cache so a reused index can't serve the dead
        // session's bytes (the `.id(activePaneID)` in InspectorColumn covers pane switches; this covers a
        // reconnect within the SAME pane).
        .onChange(of: model.epoch) { _, _ in
            outputCache.removeAll()
            fetching.removeAll()
        }
        // ⌘↑ / ⌘↓ step the selection through the (filtered) newest-first list.
        .overlay(keyboardStepper)
    }

    /// One Commands row: the block row with the clock time the command ran (its first-seen stamp,
    /// rendered by the pure `BlockClockTime.label`). The jump lives in the row's context menu only.
    private func row(for block: CommandBlock) -> some View {
        BlockRowView(
            block: block,
            isBookmarked: model.isBookmarked(block.index),
            clockTime: model.firstSeen(index: block.index).map { BlockClockTime.label(for: $0) },
        )
    }

    /// Invisible buttons carrying ⌘↑ / ⌘↓ so selection-stepping works without stealing other keys. DISABLED
    /// unless the list is focused: a window-global `.keyboardShortcut` fires regardless of focus, so an
    /// always-enabled stepper would capture ⌘↑/⌘↓ away from a focused terminal pane. A disabled control does
    /// not respond to its keyboard shortcut, so gating on `listFocused` scopes the binding to the inspector.
    private var keyboardStepper: some View {
        ZStack {
            Button("") { step(by: -1) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("") { step(by: 1) }.keyboardShortcut(.downArrow, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .disabled(!listFocused)
    }

    // MARK: Detail

    private func detail(for block: CommandBlock) -> some View {
        BlockOutputView(
            bytes: cachedBytes(for: block.index),
            isFetching: fetching.contains(block.index),
            outputLen: block.outputLen,
        )
        .padding(12)
        .frame(maxHeight: 260)
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            failedOnly ? "No Failed Commands" : "No Commands",
            systemImage: "terminal",
            description: Text(failedOnly ? "No command has failed yet" : "Run a command to see it here"),
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Row context menu

    @ViewBuilder
    private func rowMenu(for block: CommandBlock) -> some View {
        Button {
            onJump(block.index)
        } label: {
            Label("Jump to Command", systemImage: "arrow.right.to.line")
        }

        Divider()

        Button {
            copyToPasteboard(block.commandText)
        } label: {
            Label("Copy Command", systemImage: "doc.on.doc")
        }
        .disabled(block.commandText.isEmpty)

        Button {
            copyOutput(for: block.index)
        } label: {
            Label("Copy Output", systemImage: "text.alignleft")
        }
        .disabled(block.outputLen == 0)

        Divider()

        Button {
            model.toggleBookmark(index: block.index)
        } label: {
            Label(
                model.isBookmarked(block.index) ? "Unstar" : "Star",
                systemImage: model.isBookmarked(block.index) ? "star.slash" : "star",
            )
        }
    }

    // MARK: Selection + fetch

    private var selectedBlock: CommandBlock? {
        guard let selection else { return nil }
        return blocks.first { $0.index == selection }
    }

    /// A cheap Equatable digest of the selected block's OUTPUT-AVAILABILITY state (its completion flag +
    /// held byte count) — the trigger for a completion-edge refetch. A running→complete transition, or a
    /// growing captured-output length, changes it and re-runs `fetchIfNeeded` for the selected index.
    private var selectedBlockRevision: String {
        guard let block = selectedBlock else { return "" }
        return "\(block.complete)-\(block.outputLen)"
    }

    /// The resolved output bytes for a cached index. The cache value is itself optional (`nil` = fetched
    /// but unavailable), so a `case let` unwraps the OUTER optional (present = resolved) and yields the
    /// inner value; an absent key (not yet fetched) is `nil`.
    private func cachedBytes(for index: UInt32) -> Data? {
        if case let .some(value) = outputCache[index] { return value }
        return nil
    }

    /// Moves the selection by `delta` positions within the current (filtered, newest-first) list, clamped.
    private func step(by delta: Int) {
        guard !blocks.isEmpty else { return }
        let current = selection.flatMap { sel in blocks.firstIndex { $0.index == sel } }
        let next: Int =
            if let current {
                min(max(current + delta, 0), blocks.count - 1)
            } else {
                delta >= 0 ? 0 : blocks.count - 1
            }
        let index = blocks[next].index
        selection = index
        fetchIfNeeded(index)
    }

    /// Requests `index`'s output, caching the result so a re-select does not re-fire the wire request.
    /// A cached NON-nil result is final. A cached `nil` (host had nothing — typically a block that was
    /// STILL RUNNING when first selected) is NOT permanent: it is refetched once the block reports held
    /// output (`outputLen > 0`), so a running→complete block recovers instead of reading "Output
    /// unavailable" forever.
    private func fetchIfNeeded(_ index: UInt32) {
        guard !fetching.contains(index) else { return }
        if case let .some(cached) = outputCache[index] {
            if cached != nil { return } // real bytes already cached — never refetch
            // A cached nil: only refetch once the host actually holds output for the block now.
            guard let block = blocks.first(where: { $0.index == index }), block.outputLen > 0 else { return }
        }
        fetching.insert(index)
        requestOutput(index) { result in
            fetching.remove(index)
            outputCache[index] = result
        }
    }

    /// Copies a block's output to the pasteboard as VT-stripped plain text, fetching the raw bytes first if
    /// not cached (the clipboard always gets clean text — the SGR colour runs are for the on-screen render).
    private func copyOutput(for index: UInt32) {
        // Real bytes already cached → copy them. An ABSENT key OR a cached `nil` (e.g. the block was
        // selected while still running) both (re)fetch: a copy is an explicit user action gated on
        // `outputLen > 0`, so a fresh request is cheap and recovers a block whose earlier nil is now stale.
        if case let .some(bytes)? = outputCache[index] {
            copyToPasteboard(BlockOutputSanitizer.plainText(from: bytes))
            return
        }
        requestOutput(index) { result in
            outputCache[index] = result
            if let bytes = result { copyToPasteboard(BlockOutputSanitizer.plainText(from: bytes)) }
        }
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Pure formatting for the Commands row's run-time column: the block's first-seen instant as a LOCAL
/// wall-clock stamp ("19:32:05" — the `AgentTranscript.clockTime` shape). A cached fixed-format
/// formatter (`en_US_POSIX`, 24h) so the label never re-shapes under a locale's 12-hour preference and
/// row rendering never mints a `DateFormatter` per call.
enum BlockClockTime {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// The local wall-clock label for a first-seen instant.
    static func label(for date: Date) -> String {
        formatter.string(from: date)
    }
}
#endif
