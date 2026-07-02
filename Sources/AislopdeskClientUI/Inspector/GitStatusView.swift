// GitStatusView — the git status/diff detail view (E4, WI-5): the old standalone Git tab merged into the
// Info tab, which carries only a one-row summary (branch + change count) — the full view opens as a REAL
// auxiliary window on macOS (`GitDetailsWindow.swift`, user-directed) / a popover anchored to the row on
// iOS (`GitDetailsPopover` below).
//
// The detail view (spec/user-interface__details-panel.md §"Git Tab"): the changed-file list (each file a
// status badge + name + dir) and an inline unified-diff OVERLAY that floats over the panel when a file row
// is selected — its bytes fetched on demand via the pane's `gitDiff` verb. The branch/remote/delta header
// lives on the HOSTING popover's header (`GitDetailsPopover`) — the view rendering it too doubled the
// header (two branch icons stacked). READ-ONLY: Commit / Fork
// toolbar buttons are deferred (they require host-side mutation — see the E4 mapping notes), so this view
// renders status + diff only.
//
// All structured rendering reads `PaneMetadataModel.gitStatus` (the folded branch+remote+ahead/behind+files
// `GitStatusPayload`, `gitBranch` subsumed). The status-byte unpacking (`GitStatusPresentation`) and the
// diff-line classification (`GitDiffPresentation`) are PURE + headlessly unit-tested; the view only maps
// their result to `Slate` tokens. `GitStatusPresentation` mirrors the host's porcelain-nibble packing in
// `HostMetadataProbe.statusNibble` (kept in lockstep — a guard test pins the inverse).

#if canImport(SwiftUI)
import AislopdeskProtocol
import AislopdeskWorkspaceCore
import SwiftUI

struct GitStatusView: View {
    let model: PaneMetadataModel

    /// The repo-relative path of the file whose diff overlay is open, or `nil` for none. Reset per-pane
    /// via the inspector's `.id(activePaneID)`, and ignored when it no longer names a changed file.
    @State private var selectedFile: String?
    /// The fetched raw `git diff` bytes for `selectedFile` (`nil` while loading / on failure).
    @State private var diffBytes: Data?
    @State private var diffLoading = false

    var body: some View {
        ZStack(alignment: .top) {
            content
            if let path = effectiveSelectedFile {
                diffOverlay(for: path)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let status = model.gitStatus {
            if status.hasRepo {
                repoBody(status)
            } else {
                emptyState(
                    "Not a Git Repository",
                    systemImage: "arrow.triangle.branch",
                    note: "The working directory is not inside a git repo",
                )
            }
        } else {
            emptyState(
                "No Changes",
                systemImage: "arrow.triangle.branch",
                note: model.isConnected ? "Git status will appear here" : "Connect a pane to see git status",
            )
        }
    }

    private func repoBody(_ status: MetadataCodec.GitStatusPayload) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if status.files.isEmpty {
                cleanState
            } else {
                SlateSectionHeader("Changed (\(status.files.count))")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(status.files.enumerated()), id: \.offset) { _, file in
                            fileRow(file)
                        }
                    }
                }
            }
        }
        .font(.system(size: Slate.Typeface.base))
    }

    private func fileRow(_ file: MetadataCodec.GitFileChange) -> some View {
        let isSelected = selectedFile == file.path
        return Button {
            select(file: file.path)
        } label: {
            HStack(spacing: Slate.Metric.space2) {
                Text(GitStatusPresentation.badge(file.statusCode))
                    .font(.system(size: Slate.Typeface.small, weight: .bold))
                    .foregroundStyle(tint(for: GitStatusPresentation.category(file.statusCode)))
                    .frame(width: 12, alignment: .center)
                Text(leafName(file.path))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(parentDir(file.path))
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Slate.Metric.space3)
            .padding(.vertical, 3)
            .background(isSelected ? Slate.State.selected : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Diff overlay

    /// `selectedFile` only while it still names a changed file in the CURRENT status (so a pane switch /
    /// refresh that drops the file auto-closes the overlay instead of showing a stale diff).
    private var effectiveSelectedFile: String? {
        guard let selectedFile,
              model.gitStatus?.files.contains(where: { $0.path == selectedFile }) == true
        else { return nil }
        return selectedFile
    }

    private func diffOverlay(for path: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Slate.Metric.space2) {
                Text(leafName(path))
                    .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button { closeDiff() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Slate.Typeface.base))
                        .foregroundStyle(Slate.Text.icon)
                }
                .buttonStyle(.plain)
                .help("Close diff")
            }
            .padding(.horizontal, Slate.Metric.space3)
            .padding(.vertical, Slate.Metric.space2)
            Rectangle().fill(Slate.Line.divider).frame(height: 1)
            diffContent
        }
        .background(Slate.Surface.element)
        .clipShape(RoundedRectangle(cornerRadius: Slate.Metric.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusCard, style: .continuous)
                .strokeBorder(Slate.Line.subtle, lineWidth: 1),
        )
        .shadow(color: Slate.State.shadow, radius: 12, y: 4)
        .padding(Slate.Metric.space3)
        .frame(maxHeight: 380)
    }

    @ViewBuilder private var diffContent: some View {
        if diffLoading {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(Slate.Metric.space4)
        } else if let diffBytes, !diffBytes.isEmpty {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(GitDiffPresentation.lines(from: diffBytes)) { line in
                        diffLineView(line)
                    }
                }
            }
        } else {
            Text("No diff")
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
                .frame(maxWidth: .infinity)
                .padding(Slate.Metric.space4)
        }
    }

    private func diffLineView(_ line: GitDiffPresentation.Line) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: Slate.Typeface.footnote, design: .monospaced))
            .foregroundStyle(diffTint(line.kind))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, 1)
            .background(diffBackground(line.kind))
            .textSelection(.enabled)
    }

    // MARK: Empty / clean states

    private var cleanState: some View {
        VStack(spacing: Slate.Metric.space2) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: Slate.Typeface.display / 2))
                .foregroundStyle(Slate.Status.ok)
            Text("Working tree clean")
                .font(.system(size: Slate.Typeface.base))
                .foregroundStyle(Slate.Text.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ title: String, systemImage: String, note: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(note))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Behaviour

    private func select(file path: String) {
        if selectedFile == path {
            closeDiff()
            return
        }
        selectedFile = path
        diffBytes = nil
        diffLoading = true
        Task {
            let bytes = await model.gitDiff(file: path)
            // Drop a late reply for a file the user has since switched away from.
            guard selectedFile == path else { return }
            diffBytes = bytes
            diffLoading = false
        }
    }

    private func closeDiff() {
        selectedFile = nil
        diffBytes = nil
        diffLoading = false
    }

    // MARK: Token mapping (the only theme-coupled part — kept out of the pure helpers)

    private func tint(for category: GitStatusPresentation.Category) -> Color {
        switch category {
        case .added,
             .copied,
             .untracked: Slate.Status.ok
        case .modified,
             .renamed,
             .typeChanged: Slate.Status.warn
        case .deleted,
             .unmerged: Slate.Status.err
        case .ignored,
             .unknown: Slate.Text.tertiary
        }
    }

    private func diffTint(_ kind: GitDiffPresentation.LineKind) -> Color {
        switch kind {
        case .added: Slate.Status.ok
        case .removed: Slate.Status.err
        case .hunk: Slate.Status.info
        case .fileHeader,
             .meta: Slate.Text.tertiary
        case .context: Slate.Text.secondary
        }
    }

    private func diffBackground(_ kind: GitDiffPresentation.LineKind) -> Color {
        switch kind {
        case .added: Slate.Status.ok.opacity(0.12)
        case .removed: Slate.Status.err.opacity(0.12)
        default: Color.clear
        }
    }

    // MARK: Path helpers

    private func leafName(_ path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    private func parentDir(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }
}

#if !os(macOS)
/// The Git details POPOVER — iOS ONLY (macOS opens a real auxiliary window instead, `GitDetailsWindow.swift`;
/// there is no auxiliary-window idiom on iOS, so the row anchors this popover, adapting to a sheet on
/// compact). Sizes to its content (a clean tree gets a small card, not a field of empty), dismisses on
/// click-away. The compact header carries the branch + ahead/behind deltas + remote + an inline refresh;
/// `GitStatusView` below renders the changed-file list + the on-demand diff overlay.
struct GitDetailsPopover: View {
    /// The active pane's decoded host metadata — its `gitStatus` + the `gitDiff`/`refresh` verbs.
    let model: PaneMetadataModel

    /// True while the header refresh's metadata round-trip is in flight (drives the button's spinner).
    @State private var refreshing = false

    /// Whether there is a changed-file list to give real estate to — a clean/absent tree hugs a compact
    /// card instead.
    private var hasChanges: Bool { !(model.gitStatus?.files.isEmpty ?? true) }

    /// The header title: the branch name (the one fact that identifies the repo state), falling back to
    /// a generic "Git Status" while the pane has no repo/metadata.
    private var title: String {
        guard let status = model.gitStatus, status.hasRepo else { return "Git Status" }
        return status.branch.isEmpty ? "detached" : status.branch
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Slate.Line.divider).frame(height: 1)
            GitStatusView(model: model)
        }
        .background(Slate.Surface.content)
        .frame(
            width: hasChanges ? 560 : 340,
            height: hasChanges ? 480 : 150,
        )
    }

    /// The popover header: branch (+ ↑↓ deltas) over the remote URL, with the inline refresh trailing.
    private var header: some View {
        HStack(alignment: .center, spacing: Slate.Metric.space2) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Slate.Text.icon)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Slate.Metric.space2) {
                    Text(title)
                        .font(.system(size: Slate.Typeface.base, weight: .semibold))
                        .foregroundStyle(Slate.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let status = model.gitStatus, status.hasRepo {
                        if status.ahead != 0 { delta(symbol: "arrow.up", count: status.ahead, tint: Slate.Status.ok) }
                        if status.behind != 0 { delta(
                            symbol: "arrow.down",
                            count: status.behind,
                            tint: Slate.Status.warn,
                        ) }
                    }
                }
                if let remote = model.gitStatus?.remoteURL, !remote.isEmpty {
                    Text(remote)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: Slate.Metric.space3)
            refreshButton
        }
        .padding(.horizontal, Slate.Metric.space3)
        .padding(.vertical, Slate.Metric.space2)
    }

    private func delta(symbol: String, count: Int32, tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: Slate.Typeface.small, weight: .semibold))
            Text(String(count)).font(.system(size: Slate.Typeface.footnote)).monospacedDigit()
        }
        .foregroundStyle(tint)
    }

    /// The header refresh action — with CLICK FEEDBACK: the icon yields to a small spinner while the
    /// metadata round-trip is in flight (and the button disarms), so a click never reads as a no-op.
    private var refreshButton: some View {
        Button {
            refreshing = true
            Task {
                await model.refresh()
                refreshing = false
            }
        } label: {
            Group {
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: Slate.Typeface.base))
                        .foregroundStyle(Slate.Text.icon)
                }
            }
            // Fixed 16×16 — the icon↔spinner swap must not resize the button and shift the header row.
            .frame(width: 16, height: 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!model.isConnected || refreshing)
        .help("Refresh")
        .accessibilityLabel("Refresh git status")
    }
}
#endif

/// Pure unpacking of a `GitFileChange.statusCode` (porcelain `XY` packed by the host) into a render-ready
/// category + badge letter — the INVERSE of `HostMetadataProbe.statusNibble`/`packStatus` (high nibble = X
/// index, low nibble = Y worktree). Kept pure (no SwiftUI `Color`) so a guard test pins the inverse
/// mapping; the view maps `Category` → `Slate` tint separately.
enum GitStatusPresentation {
    enum Category: Equatable {
        case modified
        case added
        case deleted
        case renamed
        case copied
        case unmerged
        case untracked
        case ignored
        case typeChanged
        case unknown
    }

    /// The porcelain `X` (index) and `Y` (worktree) status chars a packed byte carries.
    static func xy(_ statusCode: UInt8) -> (x: Character, y: Character) {
        (statusChar(statusCode >> 4), statusChar(statusCode & 0x0F))
    }

    /// The category of a packed status: the worktree char `Y` wins when set, else the index char `X`
    /// (a staged-only change still reads as its kind).
    static func category(_ statusCode: UInt8) -> Category {
        let (x, y) = xy(statusCode)
        return category(of: y == " " ? x : y)
    }

    /// The one-char badge for a packed status (the effective git char; `unknown` → "•").
    static func badge(_ statusCode: UInt8) -> String {
        let (x, y) = xy(statusCode)
        let effective = y == " " ? x : y
        return category(of: effective) == .unknown ? "•" : String(effective)
    }

    /// Inverse of `HostMetadataProbe.statusNibble` (space=0 M=1 A=2 D=3 R=4 C=5 U=6 ?=7 !=8 T=9; other=15).
    private static func statusChar(_ nibble: UInt8) -> Character {
        switch nibble {
        case 0: " "
        case 1: "M"
        case 2: "A"
        case 3: "D"
        case 4: "R"
        case 5: "C"
        case 6: "U"
        case 7: "?"
        case 8: "!"
        case 9: "T"
        default: " " // 15 / unrecognised — no meaningful char (renders via `unknown`)
        }
    }

    private static func category(of char: Character) -> Category {
        switch char {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "U": .unmerged
        case "?": .untracked
        case "!": .ignored
        case "T": .typeChanged
        default: .unknown
        }
    }
}

/// Pure unified-`git diff` classification: splits raw diff bytes into lines tagged by kind (added / removed
/// / hunk header / file header / meta / context) so the view can tint each. UTF-8-lossy decode (a diff may
/// carry non-UTF-8 bytes — never trap). Headlessly unit-tested.
enum GitDiffPresentation {
    enum LineKind: Equatable {
        case added
        case removed
        case hunk
        case fileHeader
        case meta
        case context
    }

    struct Line: Identifiable, Equatable {
        let id: Int
        let kind: LineKind
        let text: String
    }

    static func lines(from data: Data) -> [Line] {
        // LOSSY by design (not the failable `String(bytes:encoding:)`): a git diff may carry non-UTF-8
        // bytes (a touched binary, a latin-1 hunk) — render what we can (U+FFFD for the rest) rather than
        // drop the whole diff to `nil`. Pure display of trusted-mesh bytes, never a trap.
        // swiftlint:disable:next optional_data_string_conversion
        lines(from: String(decoding: data, as: UTF8.self))
    }

    static func lines(from text: String) -> [Line] {
        var out: [Line] = []
        var index = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            out.append(Line(id: index, kind: classify(String(raw)), text: String(raw)))
            index += 1
        }
        // A trailing newline yields a final empty element — drop it so the view shows no phantom blank line.
        if out.last?.text.isEmpty == true { out.removeLast() }
        return out
    }

    /// Classify one diff line. ORDER MATTERS: the `+++`/`---` file markers must be checked before the
    /// bare `+`/`-` add/remove prefixes (they share a leading char).
    static func classify(_ line: String) -> LineKind {
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .fileHeader }
        if line.hasPrefix("diff ") || line.hasPrefix("index ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file")
            || line.hasPrefix("old mode") || line.hasPrefix("new mode")
            || line.hasPrefix("rename ") || line.hasPrefix("copy ")
            || line.hasPrefix("similarity ") || line.hasPrefix("dissimilarity ")
            || line.hasPrefix("Binary ") || line.hasPrefix("\\ ")
        {
            return .meta
        }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }
}
#endif
