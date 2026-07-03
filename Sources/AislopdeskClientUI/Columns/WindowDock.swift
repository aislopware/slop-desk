// WindowDock — the GUI column's macOS-dock-like window strip (the TabSide partition's right-column
// header). One tile per HOST window (discovered over the video control channel's `listWindows`) plus a
// tile for any open remote-window tab whose host window has since vanished from the list: app icon
// (resolved LOCALLY from the wire `bundleID` via NSWorkspace — both ends are Macs; letter-avatar
// fallback), the window title beneath, and a running DOT under the open ones (the macOS-dock idiom).
// Clicking an open tile focuses its tab; clicking a closed one opens a new remote-window tab streaming
// that window. Pure derivation (`WindowDockModel`) is separated from the view so the merge/order rules
// are headlessly pinned.

#if os(macOS)
import AislopdeskWorkspaceCore
import AppKit
import SFSafeSymbols
import SwiftUI

// MARK: - Pure dock derivation

/// One dock tile. `tabID != nil` ⇒ the window is OPEN in a remote-window tab (the running dot; click
/// focuses); else click opens a new tab streaming `windowID`.
struct WindowDockItem: Identifiable, Equatable {
    let id: String
    /// The host CGWindowID to stream (`nil` only for an open tab whose endpoint is missing — legacy).
    let windowID: UInt32?
    /// The open remote-window tab showing this window, if any.
    let tabID: TabID?
    let title: String
    let appName: String
    let bundleID: String

    var isOpen: Bool { tabID != nil }
}

/// The pure host-windows × open-tabs merge the dock renders. Headless + static for tests.
enum WindowDockModel {
    /// Builds the dock tiles: every OPEN remote-window tab first (tab-bar order — these are the user's
    /// working set), then the remaining host windows in discovery order (host sorts by app name). An open
    /// tab is matched to a host window by its bound `windowID`; a match enriches the tab tile with the
    /// discovery `bundleID` (the endpoint doesn't persist one). An open tab whose window vanished from
    /// the host list still gets a tile (letter-avatar icon) so it stays reachable.
    static func items(windows: [RemoteWindowSummary], session: Session?) -> [WindowDockItem] {
        var out: [WindowDockItem] = []
        var openWindowIDs: Set<UInt32> = []
        for tab in session?.tabs(on: .gui) ?? [] {
            guard let session else { continue }
            let pane = tab.activePane ?? tab.allPaneIDs().first
            let spec = pane.flatMap { session.specs[$0] }
            let endpoint = spec?.video
            if let id = endpoint?.windowID { openWindowIDs.insert(id) }
            let discovered = windows.first { $0.windowID == endpoint?.windowID }
            let title = spec?.lastKnownTitle ?? spec?.title ?? endpoint?.title ?? "Window"
            out.append(WindowDockItem(
                id: "tab:\(tab.id.raw.uuidString)",
                windowID: endpoint?.windowID,
                tabID: tab.id,
                title: title.isEmpty ? (endpoint?.appName ?? "Window") : title,
                appName: endpoint?.appName ?? discovered?.appName ?? "",
                bundleID: discovered?.bundleID ?? "",
            ))
        }
        for window in windows where !openWindowIDs.contains(window.windowID) {
            out.append(WindowDockItem(
                id: "win:\(window.windowID)",
                windowID: window.windowID,
                tabID: nil,
                title: window.title.isEmpty ? window.appName : window.title,
                appName: window.appName,
                bundleID: window.bundleID,
            ))
        }
        return out
    }
}

// MARK: - Local app-icon resolution (bundleID → NSWorkspace icon, letter-avatar fallback)

/// Resolves a HOST app's icon from its bundle identifier against the LOCAL machine's installed apps
/// (`NSWorkspace` — both ends are Macs, so the app usually exists client-side). Cached per bundleID
/// (misses too — a lookup walks LaunchServices). `nil` ⇒ the caller draws the letter avatar.
@MainActor
enum AppIconResolver {
    private static var cache: [String: NSImage?] = [:]

    static func icon(bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] { return cached }
        var resolved: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            resolved = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache[bundleID] = resolved
        return resolved
    }

    /// A stable 0…1 hue for the letter-avatar fallback — djb2 over the app name (NOT `hashValue`, which
    /// is per-launch randomized and would recolor the dock every start). Pure + static for tests.
    static func stableHue(for name: String) -> Double {
        var hash: UInt32 = 5381
        for byte in name.utf8 {
            hash = hash &* 33 &+ UInt32(byte)
        }
        return Double(hash % 360) / 360.0
    }
}

// MARK: - The dock strip view

struct WindowDockStrip: View {
    let items: [WindowDockItem]
    /// The tile that reads selected — the GUI side's displayed tab.
    let selectedTabID: TabID?
    let onSelect: (WindowDockItem) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Slate.Metric.space1) {
                ForEach(items) { item in
                    WindowDockTile(
                        item: item,
                        selected: item.tabID != nil && item.tabID == selectedTabID,
                        onSelect: { onSelect(item) },
                    )
                }
            }
            .padding(.horizontal, Slate.Metric.space2)
        }
        .scrollIndicators(.hidden)
    }
}

/// One dock tile: 28pt app icon (local lookup / letter avatar), the title caption beneath, and the
/// running dot under an OPEN window (the macOS-dock idiom). Selected = card fill + active border.
private struct WindowDockTile: View {
    let item: WindowDockItem
    let selected: Bool
    let onSelect: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 2) {
                iconView
                    .frame(width: 28, height: 28)
                Text(item.title)
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(selected ? Slate.Text.primary : Slate.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 72)
                Circle()
                    .fill(Slate.Status.ok)
                    .frame(width: 4, height: 4)
                    .opacity(item.isOpen ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Slate.Metric.space1)
            .padding(.vertical, Slate.Metric.space1)
            .background(
                selected ? AnyShapeStyle(Slate.Surface.card) : AnyShapeStyle(hover ? Slate.State.hover : .clear),
                in: .rect(cornerRadius: Slate.Metric.radiusControl),
            )
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                    .strokeBorder(selected ? Slate.Line.active : .clear, lineWidth: Slate.Metric.hairline),
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Slate.Anim.smallFade, value: hover)
        .help(dockHelp)
        .accessibilityLabel(dockHelp)
    }

    private var dockHelp: String {
        let head = item.appName.isEmpty ? item.title : "\(item.appName) — \(item.title)"
        return item.isOpen ? "\(head) (open — click to focus)" : "\(head) (click to open)"
    }

    @ViewBuilder private var iconView: some View {
        if let icon = AppIconResolver.icon(bundleID: item.bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            // Letter avatar: a stable app-name-keyed hue + the first letter (the "unknown local app"
            // fallback — the host app isn't installed on this Mac).
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .fill(Color(
                    hue: AppIconResolver.stableHue(for: item.appName.isEmpty ? item.title : item.appName),
                    saturation: 0.45, brightness: 0.62,
                ))
                .overlay(
                    Text(String((item.appName.isEmpty ? item.title : item.appName).prefix(1)).uppercased())
                        .font(.system(size: Slate.Typeface.body, weight: .semibold))
                        .foregroundStyle(.white),
                )
        }
    }
}
#endif
