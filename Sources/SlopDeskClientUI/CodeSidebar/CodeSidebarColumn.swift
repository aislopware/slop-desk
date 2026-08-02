// CodeSidebarColumn — the RIGHT sidebar: the project-scoped embedded VS Code (code-server in a
// pooled WKWebView). Project-scoped means the ACTIVE pane picks the project (its host-pushed
// `projectKey` — the same key the left panel's sections group by), and every pane of that project
// shares the ONE workbench opened at the project root; focusing a pane of another project swaps the
// warm webview for THAT project back in (see `CodeSidebarWebViewPool`).
//
// The column is macOS-only chrome hosted in its own plain `NSSplitViewItem` (a THIRD column beside
// navigator | content — never `.inspector`, whose collapse unmounts the content and would kill the
// webview's layout). While collapsed the split item unparents this view, SwiftUI cancels the
// `.task`, and the poll loop stops — the code-server is only ever ensured when the panel is open.

#if os(macOS)
import SFSafeSymbols
import SlopDeskProtocol
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct CodeSidebarColumn: View {
    let store: WorkspaceStore
    /// The app-global connection — the workbench URL speaks to the SAME host every pane dials
    /// (`target.host`), on the shared code-server port the ensure RPC reports.
    let connection: AppConnection
    /// The shared chrome state — the strip's collapse toggle flips `codeSidebarCollapsed`, the same
    /// flag ⌘⇧R and the titlebar reopen button drive (the host-rail split of duties: the EXPANDED
    /// toggle lives in this column's strip, the collapsed reopen in the titlebar).
    let chrome: WorkspaceChromeState

    @State private var model = CodeSidebarModel()
    /// Pointer-in-top-strip — the hover-reveal gate for the strip's collapse toggle.
    @State private var stripHover = false

    private var activePane: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    /// The active pane's project root — the HOST-pushed `projectKey` (wire type 34) ONLY, never the
    /// cwd fallback the sidebar sections tolerate (`paneProjectKey`). Ensuring on the transient
    /// pre-push cwd spawns a code-server for a root the project does not have (observed: the shell's
    /// start directory vs the git toplevel — two Node processes for one project, one stranded).
    /// `nil` ⇒ no pane focused, or the push hasn't landed yet (see `awaitingProjectKey`).
    private var activeProjectRoot: String? {
        guard let pane = activePane else { return nil }
        return store.hostPushedProjectKey(pane)
    }

    /// Whether the focused pane already has a SECTION identity (the cwd fallback) but no host-pushed
    /// key yet — the first push is in flight, so render a brief waiting surface instead of the
    /// no-project placeholder. The mirror write re-renders this view the moment the key lands.
    private var awaitingProjectKey: Bool {
        guard let pane = activePane, activeProjectRoot == nil else { return false }
        return store.paneProjectKey(pane) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            strip
            header
            if let root = activeProjectRoot {
                content(projectRoot: root)
                    // Restart the poll on a project switch or a manual reload — SwiftUI cancels the
                    // running loop with the old id, so at most one loop ensures at a time.
                    .task(id: "\(root)#\(model.generation)") {
                        await model.poll(
                            projectRoot: root,
                            host: { [connection] in connection.target.host },
                            ensure: { [store] in await Self.ensureEndpoint(projectRoot: $0, store: store) },
                            // Front the remote endpoint with the loopback relay: a secure browser
                            // context (no insecure-context toast) on an origin that survives
                            // respawns. On bind failure the remote address rides through — the ATS
                            // arbitrary-loads exception keeps that fallback loadable.
                            localize: { host, port in
                                await CodeSidebarProxyPool.shared.endpoint(host: host, port: port)
                                    ?? (host, port)
                            },
                        )
                    }
            } else if awaitingProjectKey {
                waiting("Resolving project…")
            } else {
                placeholder(
                    symbol: .folder,
                    title: "No project in focus",
                    detail: "Focus a terminal pane to open its project here.",
                )
            }
        }
        .background(Slate.Surface.ground)
    }

    /// Traffic-light-row strip: ONLY the panel-collapse toggle, top-LEADING (the mirror of the left
    /// rail's top-trailing toggle — each toggle hugs its column's inner edge; the host-rail anatomy,
    /// restored). Same settled-state choreography: hide instantly on collapse, fade back after the
    /// slide settles — plus the hover-reveal gate (the otty behavior): at rest the strip is empty.
    /// The glyph is the CODE one (`</>`), matching the titlebar reopen button — deliberately
    /// distinct from the left `sidebar.left`.
    private var strip: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            PlateIconButton(symbol: .chevronLeftForwardslashChevronRight) { chrome.toggleCodeSidebar() }
                .opacity(!chrome.codeSidebarCollapsed && stripHover ? 1 : 0)
                .allowsHitTesting(!chrome.codeSidebarCollapsed && stripHover)
                .animation(
                    chrome.codeSidebarCollapsed ? nil : Slate.Anim.standard.delay(0.25),
                    value: chrome.codeSidebarCollapsed,
                )
                .animation(Slate.Anim.smallFade, value: stripHover)
                .padding(.top, 3)
                .padding(.leading, 8)
        }
        .frame(height: Slate.Metric.titlebarHeight)
        .background(HoverSensor { stripHover = $0 })
    }

    /// The panel label — instrument voice, same register as the left rail's "TABS" (the host-rail
    /// header anatomy): "CODE" leading, the active project's folder name trailing beside the reload
    /// button.
    private var header: some View {
        HStack(spacing: Slate.Metric.space2) {
            Text("CODE")
                .font(Slate.Typeface.instrument(Slate.Typeface.footnote, weight: .semibold))
                .tracking(Slate.Typeface.instrumentTracking)
                .foregroundStyle(Slate.State.header)
            Spacer(minLength: 0)
            if let root = activeProjectRoot {
                Text(URL(fileURLWithPath: root).lastPathComponent)
                    .font(Slate.Typeface.instrument(Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(root)
                Button {
                    CodeSidebarWebViewPool.shared.reload(projectRoot: root)
                    model.requestReload()
                } label: {
                    Image(systemSymbol: .arrowClockwise)
                        .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                        .foregroundStyle(Slate.State.header)
                }
                .buttonStyle(.plain)
                .help("Reload the embedded editor")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    /// The phase surface for the active project. The webview mounts ONLY in `.ready` — the pooled
    /// instance underneath survives the unmount (project switches are warm swaps).
    @ViewBuilder
    private func content(projectRoot: String) -> some View {
        switch model.phase {
        case let .ready(url):
            webContent(projectRoot: projectRoot, url: url)
        case .starting:
            waiting("Starting code-server…")
        case .unavailable:
            placeholder(
                symbol: .shippingbox,
                title: "code-server not found on host",
                detail: "brew install code-server",
                detailIsCommand: true,
            )
        case .offline:
            placeholder(
                symbol: .boltSlash,
                title: "Host unreachable",
                detail: "The editor opens once a pane is connected.",
            )
        }
    }

    /// The mounted webview under its first-paint VEIL: the dark waiting surface stays on top from
    /// load-start until the main-frame navigation settles, then fades — without it the boot reads
    /// as black → WebKit's white canvas → workbench. The veil state is per-project and pooled with
    /// the webview, so a warm project swap mounts unveiled (no spurious spinner).
    @ViewBuilder
    private func webContent(projectRoot: String, url: URL) -> some View {
        let veiled = CodeSidebarWebViewPool.shared.loadState(for: projectRoot).veiled
        CodeSidebarWebView(projectRoot: projectRoot, url: url)
            .overlay {
                if veiled {
                    waiting("Opening workbench…")
                        .background(Slate.Surface.ground)
                        .transition(.opacity)
                }
            }
            .animation(Slate.Anim.smallFade, value: veiled)
    }

    /// The centered spinner surface — the code-server boot and the pre-push projectKey wait share
    /// it (both are short-lived, both resolve on their own).
    private func waiting(_ label: String) -> some View {
        VStack(spacing: Slate.Metric.space2) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A centered empty-state: dim glyph, one-line title, secondary detail (optionally set in the
    /// instrument face for a copyable shell command).
    private func placeholder(
        symbol: SFSymbol, title: String, detail: String, detailIsCommand: Bool = false,
    ) -> some View {
        VStack(spacing: Slate.Metric.space2) {
            Image(systemSymbol: symbol)
                .font(.system(size: Slate.Typeface.display * 0.6))
                .foregroundStyle(Slate.Text.tertiary)
            Text(title)
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .foregroundStyle(Slate.Text.primary)
            Text(detail)
                .font(
                    detailIsCommand
                        ? Slate.Typeface.instrument(Slate.Typeface.footnote)
                        : .system(size: Slate.Typeface.footnote),
                )
                .foregroundStyle(Slate.Text.secondary)
                .textSelection(.enabled)
        }
        .multilineTextAlignment(.center)
        .padding(Slate.Metric.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One ensure round: verb 18 through whichever pane carries a live metadata channel (resolved
    /// per call, like the host-info/vitals fetchers — survives pane churn/reconnects). `nil` when no
    /// pane is connected (→ `.offline`, and the loop keeps polling).
    private static func ensureEndpoint(
        projectRoot: String, store: WorkspaceStore,
    ) async -> MetadataCodec.CodeServerEndpoint? {
        guard let client = firstConnectedMetadataClient(store) else { return nil }
        return await client.ensureCodeServer(projectRoot: projectRoot)
    }

    private static func firstConnectedMetadataClient(_ store: WorkspaceStore) -> MetadataClient? {
        for id in store.tree.activeSession?.allPaneIDs() ?? [] {
            if let client = (store.handle(for: id) as? LivePaneSession)?.connection?.activeMetadataClient {
                return client
            }
        }
        return nil
    }
}
#endif
