import Foundation

// MARK: - Where a web URL lands

/// Where an opened web URL is placed in the workspace. Defined here because ``DropAction/openWeb`` is
/// the first user; the E18 web-pane store ingress (`WorkspaceStore+WebPane.openWebPane(url:placement:)`,
/// WI-3) REUSES this same type — it is the single source of truth for web placement.
public enum WebPanePlacement: Equatable, Sendable {
    /// Replace the active pane's content in place (Open-In-Place on a URL).
    case current
    /// Open the URL in a brand-new tab.
    case newTab
    /// Split the active pane and open the URL beside it (`leading` = to the left/top).
    case split(leading: Bool)
}

// MARK: - Resolved drop action

/// The concrete action a `(zone, content)` pair resolves to — the PURE output of the drop policy, an
/// instruction the actuator (E18 WI-6) carries out against the store / live terminal / metadata client.
/// Carrying the action as a value (not actuating here) keeps the policy headless + table-testable.
///
/// The case set is terminal/web only — there is intentionally NO remote-window (`.remoteGUI`) creator (E21
/// WI-7): a streamed host window is minted solely by the picker, never by a drop (see ``DropActionResolver``).
public enum DropAction: Equatable, Sendable {
    /// Paste this text/path VERBATIM into the focused terminal (`TerminalViewModel.sendInput`, never
    /// `SendKeysParser`).
    case injectText(String)
    /// Open a new terminal tab rooted at this folder (`newTab(kind:.terminal)` then
    /// `LinkActionPolicy.changeDirectoryCommandLine`, which cd's a file to its PARENT). Folders only.
    case newTabCd(String)
    /// Open this path Open-In-Place ON THE HOST (`MetadataClient.openPath`, verb 9). Files & folders.
    case hostOpen(String)
    /// Split the active terminal pane and target the new pane at this path (`leading` = left/top).
    case splitInjectPath(String, leading: Bool)
    /// Split the active pane and open this URL in a web pane (`leading` = left/top).
    case splitWeb(String, leading: Bool)
    /// Open this URL in a web pane at `placement` (Open-In-Place → `.current`).
    case openWeb(String, placement: WebPanePlacement)
}

// MARK: - Resolver (the (zone × content) policy table)

/// The PURE policy mapping a hovered ``DropZone`` + classified ``DroppedContent`` to a ``DropAction``,
/// or `nil` for a disabled cell (otty `spec/user-interface__drag-and-drop.md`). The spec's table:
///
/// | Dragged thing | Green half / terminal action            | Blue half / pane action          |
/// |---------------|------------------------------------------|----------------------------------|
/// | Folder        | New terminal tab with `cwd = <folder>`   | Folder viewer (host open) / split|
/// | File          | (disabled — no "open as terminal")       | File viewer (host open) / split  |
/// | URL           | (disabled — no "open as terminal")       | URL pane / split web             |
/// | Text snippet  | Pastes into the focused terminal         | Same                             |
///
/// Concretely, by zone:
/// - **New Tab** (green): folder → `newTabCd`; file/URL → `nil` (the disabled green-half cells);
///   text → paste.
/// - **Insert Path** (green): any path/URL/text → paste it verbatim into the focused terminal.
/// - **Open In-Place** (blue): path → host-open; URL → web pane in place; text → paste (no viewer for
///   raw text).
/// - **Split Left / Right** (blue): path → split terminal targeted at the path; URL → split web;
///   text → paste into the focused terminal (the spec's "Same").
///
/// Text always pastes into the focused terminal regardless of zone (the spec lists identical green/blue
/// behavior for a text snippet), so it is handled first as a catch-all.
///
/// **E21 exclusion — no drop-to-create a remote window (`.remoteGUI`).** A `.remoteGUI` pane is a real host
/// window streamed over the PATH-2 UDP video path; it is minted ONLY by the picker / connect overlay
/// (`WorkspaceStore.newRemoteWindowTab(windowID:title:appName:)`), NEVER by a file / URL / text drop. There is
/// deliberately no remote-window arm in this table — ``DropAction`` carries terminal/web cases only — so no
/// `(zone × content)` cell can spawn a video pane (pinned by `RemoteGUIFirstClassPeerTests`). Conversely a
/// foreign drop ONTO an already-mounted `.remoteGUI` target self-guards: the actuator (`PaneDropReceiver`)
/// holds a `nil` `terminalModel` for a video pane and every terminal actuator is `terminalModel?.…`
/// (optional-chained), so the terminal-targeting actions (`injectText` / `hostOpen`) no-op without a crash,
/// while the store-level split / reorder geometry stays kind-generic (a video pane tiles and splits as a
/// first-class peer once minted — see `WorkspaceTreeOps.splitPane`). E21 WI-7.
public enum DropActionResolver {
    public static func resolve(zone: DropZone, content: DroppedContent) -> DropAction? {
        // Text snippet: pastes into the focused terminal in EVERY zone ("Same" for both halves).
        if case let .text(value) = content {
            return .injectText(value)
        }

        switch zone {
        case .newTab:
            switch content {
            case let .folder(path): return .newTabCd(path)
            // The disabled green-half cells: there is no "open as terminal" for a file or a URL.
            case .file,
                 .url: return nil
            case .text: return nil // unreachable (handled above) — exhaustiveness only
            }

        case .insertPath:
            switch content {
            case let .folder(path),
                 let .file(path): return .injectText(path)
            case let .url(value): return .injectText(value)
            case .text: return nil // unreachable
            }

        case .openInPlace:
            switch content {
            case let .folder(path),
                 let .file(path): return .hostOpen(path)
            case let .url(value): return .openWeb(value, placement: .current)
            case .text: return nil // unreachable
            }

        case .splitLeft:
            return splitAction(content: content, leading: true)

        case .splitRight:
            return splitAction(content: content, leading: false)
        }
    }

    /// The set of zones that can ACT on `content` — i.e. the zones whose `(zone, content)` cell resolves to
    /// a non-`nil` ``DropAction``. The single source of truth the drop overlay (E18 WI-5) uses to gate which
    /// blobs are targetable / highlightable: a disabled cell (a file or URL over New Tab — there is no
    /// "open as terminal") is NOT in the set, so the overlay renders it muted and the receiver never lets it
    /// become the active zone. Derived from ``resolve(zone:content:)`` so the overlay gating can never drift
    /// from the policy table. Pure + headless (no view code) → unit-tested in `DropActionResolverTests`.
    public static func allowedZones(for content: DroppedContent) -> Set<DropZone> {
        Set(DropZone.allCases.filter { resolve(zone: $0, content: content) != nil })
    }

    /// Split-zone resolution (the L/R cells differ only by `leading`).
    private static func splitAction(content: DroppedContent, leading: Bool) -> DropAction? {
        switch content {
        case let .folder(path),
             let .file(path): .splitInjectPath(path, leading: leading)
        case let .url(value): .splitWeb(value, leading: leading)
        case .text: nil // unreachable (text handled before the zone switch)
        }
    }
}
