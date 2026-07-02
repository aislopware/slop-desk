// GitStatusView — the git status/diff detail view (E4, WI-5), the content of the REAL auxiliary Git window
// on macOS (`GitDetailsWindow.swift` — opened from the palette / View menu "Git Status", keyboard-centric;
// the old inspector Details panel that carried a git-summary launcher row is removed, and iOS has no entry).
//
// The detail view (spec/user-interface__details-panel.md §"Git Tab"): the changed-file list (each file a
// status badge + name + dir) and an inline unified-diff OVERLAY that floats over the panel when a file row
// is selected — its bytes fetched on demand via the pane's `gitDiff` verb. The branch/remote/delta header
// lives on the HOSTING window's titlebar (`GitDetailsWindowRoot`) — the view rendering it too doubled the
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
