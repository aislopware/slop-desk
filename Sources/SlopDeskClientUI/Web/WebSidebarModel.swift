// WebSidebarModel — the right panel's Web surface: find the host's browser, list its pages, and
// point the DevTools frontend at the one the user is on.
//
// TWO LOOPS, separate for ``SimulatorSidebarModel``'s reason. The ENSURE loop polls
// `ensureWebBrowser` (verb 23) until the host's browser reports ready — the host's ensure never
// waits, so readiness is client-side polling by design. The TARGET loop then re-reads `/json/list`
// on a slower cadence, because a page the user opened from within the page (a link with
// `target=_blank`, an OAuth popup) is a tab this panel has to notice.
//
// Scope is a MACHINE, not a project: one host, one browser, one set of tabs.
//
// **The address bar drives the HOST's browser, not this app's web view.** That is the entire point
// of putting the browser on the host: `localhost:5173` typed here reaches the dev server the host
// is running, with the host's certificates and cookies, and no port-forward to arrange.
//
// Kept free of WebKit and of URLSession so the phase machine, the URL builders and the address
// normalisation stay unit-testable under the hang-safety rule; the frontend web view lives in
// ``WebInspectorWebView`` (macOS-only) and every network call behind ``WebTargetControlling``.

#if canImport(SwiftUI)
import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceCore

/// The readiness phases the Web surface renders. One value per distinct surface — the column's body
/// switches over this and nothing else.
enum WebSidebarPhase: Equatable {
    /// The ensure RPC got no answer — no connected pane channel (app offline) or a host too old to
    /// know verb 23. Keep polling: the connection may come up.
    case offline
    /// The host is starting (or probing) its browser — spinner, keep polling.
    case starting
    /// No Chrome-family browser on the host — render the install hint. Still polled (slowly): a
    /// `brew install --cask google-chrome` mid-session is picked up without a restart.
    case unavailable
    /// The browser is reachable at this address — ALREADY LOCALIZED (the loopback relay's
    /// `127.0.0.1:<stable port>`, never the mesh address). Everything else the panel does hangs off
    /// it, and it must be loopback: the DevTools frontend opens its websocket back to `ws://
    /// 127.0.0.1:*` and its own CSP admits nothing else.
    case ready(host: String, port: UInt16)
}

/// One page in the host's browser, as `/json/list` describes it. Only `type == "page"` targets are
/// kept — the list also carries service workers, extension backgrounds and the browser target
/// itself, none of which the address bar can navigate.
struct WebTarget: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let url: String

    /// What the tab menu shows: the page's own title, falling back to its address, falling back to
    /// the id — a row that says nothing is worse than a row that says the truth badly.
    var displayName: String {
        if !title.isEmpty { return title }
        if !url.isEmpty, url != "about:blank" { return url }
        return "Untitled"
    }
}

/// Everything the surface does over the wire, behind a seam: the real implementation talks HTTP and
/// one short-lived websocket to the host's browser, and the hang-safety rule keeps both out of unit
/// tests.
protocol WebTargetControlling: Sendable {
    /// The browser's page targets, newest last. Empty on any failure — the panel keeps what it has.
    func targets(host: String, port: UInt16) async -> [WebTarget]
    /// Points an EXISTING page at `url` (CDP `Page.navigate`), so the frontend stays attached to the
    /// same target across a navigation.
    func navigate(host: String, port: UInt16, targetID: String, url: String) async -> Bool
    /// Opens a new page, returning it.
    func newTarget(host: String, port: UInt16, url: String) async -> WebTarget?
    /// Closes a page.
    func close(host: String, port: UInt16, targetID: String) async -> Bool
}

@MainActor
@Observable
final class WebSidebarModel {
    // MARK: Observable state

    private(set) var phase: WebSidebarPhase = .starting
    private(set) var targets: [WebTarget] = []
    /// The page the frontend is attached to. `nil` until the first list arrives.
    private(set) var selection: String?
    /// The address field's text. Two-way: the user types into it, and a target switch or a page
    /// navigation writes the page's real address back — EXCEPT while the field has focus, which the
    /// view reports through ``beginEditingAddress()`` / ``endEditingAddress()``. A field that
    /// rewrote itself under the cursor would make a slow typist unable to finish a URL.
    var address = ""
    private(set) var isEditingAddress = false
    /// The last failure worth showing, cleared by the next success.
    private(set) var failure: String?

    /// Bumped by the strip's reload button — part of the surface's `.task` id, so a bump cancels the
    /// settled loop and re-ensures from scratch (restarting a browser that died).
    private(set) var generation = 0

    func requestReload() { generation += 1 }

    // MARK: Wiring

    private let control: any WebTargetControlling

    init(control: any WebTargetControlling = WebTargetControl()) {
        self.control = control
    }

    /// The selected page, if it is still in the list.
    var selectedTarget: WebTarget? {
        guard let selection else { return nil }
        return targets.first { $0.id == selection }
    }

    /// The frontend URL for the current selection — what the web view loads. `nil` while there is
    /// no ready browser or no page to attach to.
    var frontendURL: URL? {
        guard case let .ready(host, port) = phase, let selection else { return nil }
        return Self.frontendURL(host: host, port: port, targetID: selection)
    }

    // MARK: The ensure loop

    /// Poll `ensure` until `.ready` (or cancellation), exactly as the workbench and the two device
    /// surfaces do. `localize` fronts the mesh endpoint with the client's own loopback relay and is
    /// NOT optional in practice: the DevTools frontend refuses to open a debugging websocket to
    /// anything but `127.0.0.1`, so a non-localized endpoint renders a frontend that can never
    /// connect. It must return its input unchanged on failure — never nil, never a trap.
    func poll(
        host: @MainActor () -> String?,
        ensure: () async -> MetadataCodec.ServiceEndpoint?,
        localize: ((_ host: String, _ port: UInt16) async -> (host: String, port: UInt16))? = nil,
        interval: Duration = .milliseconds(900),
    ) async {
        phase = .starting
        while !Task.isCancelled {
            var endpoint = await ensure()
            guard !Task.isCancelled else { return }
            var resolvedHost = host()
            if let localize, let remote = endpoint, remote.state == .ready, let remoteHost = resolvedHost {
                let local = await localize(remoteHost, remote.port)
                guard !Task.isCancelled else { return }
                resolvedHost = local.host
                endpoint = .init(state: .ready, port: local.port)
            }
            phase = Self.phase(for: endpoint, host: resolvedHost)
            switch phase {
            case .ready: return
            case .starting: try? await Task.sleep(for: interval)
            case .offline,
                 .unavailable: try? await Task.sleep(for: interval * 4)
            }
        }
    }

    /// One ensure round's endpoint → the phase to render. Pure — pinned by `WebSidebarModelTests`.
    /// A `ready` endpoint with no host or no port degrades to `.offline`, never a trap.
    static func phase(for endpoint: MetadataCodec.ServiceEndpoint?, host: String?) -> WebSidebarPhase {
        guard let endpoint else { return .offline }
        switch endpoint.state {
        case .unavailable: return .unavailable
        case .starting: return .starting
        case .ready:
            guard let host, !host.isEmpty, endpoint.port != 0 else { return .offline }
            return .ready(host: host, port: endpoint.port)
        }
    }

    // MARK: The target loop

    /// Re-read the page list until cancelled. Slower than the ensure loop for the reason the device
    /// surfaces record: a list that exists changes on human time, and this one costs the host a
    /// browser round trip per round.
    func watchTargets(interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refreshTargets()
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: interval)
        }
    }

    /// One list round: keep the selection if that page still exists, else fall back to the first.
    func refreshTargets() async {
        guard case let .ready(host, port) = phase else { return }
        let listed = await control.targets(host: host, port: port)
        guard !listed.isEmpty else { return }
        targets = listed
        let resolved = Self.resolvedSelection(current: selection, targets: listed)
        if resolved != selection {
            selection = resolved
            // A target SWITCH always rewrites the field: it is a different page, so whatever was
            // typed for the old one no longer refers to anything.
            address = listed.first { $0.id == resolved }?.url ?? ""
        } else if !isEditingAddress, let live = listed.first(where: { $0.id == resolved })?.url {
            // The page navigated on its own (a link, a redirect, a router push) — the field follows,
            // which is what makes it a readout as well as an input.
            address = live
        }
    }

    /// Which page the frontend should be on after a list round. Pure — pinned by tests. Keeping a
    /// still-present selection is what stops the frontend from being torn down and rebuilt every two
    /// seconds; the first-page fallback is what makes a fresh browser land somewhere.
    static func resolvedSelection(current: String?, targets: [WebTarget]) -> String? {
        if let current, targets.contains(where: { $0.id == current }) { return current }
        return targets.first?.id
    }

    // MARK: Actions

    func select(_ id: String) {
        guard id != selection else { return }
        selection = id
        address = targets.first { $0.id == id }?.url ?? ""
    }

    func beginEditingAddress() { isEditingAddress = true }
    func endEditingAddress() { isEditingAddress = false }

    /// Submit the address field: point the CURRENT page at it. Navigating the existing target rather
    /// than opening a new one is what keeps the inspector attached — DevTools survives a navigation
    /// within its target, but a new target means a new frontend and a lost session.
    func submitAddress() async {
        guard case let .ready(host, port) = phase else { return }
        guard let url = Self.normalizedAddress(address) else { return }
        address = url
        guard let target = selection else {
            await openTab(url: url)
            return
        }
        if await control.navigate(host: host, port: port, targetID: target, url: url) {
            failure = nil
        } else {
            failure = "Could not open \(url)"
        }
        await refreshTargets()
    }

    /// Open a new page and select it.
    func openTab(url: String = "about:blank") async {
        guard case let .ready(host, port) = phase else { return }
        guard let opened = await control.newTarget(host: host, port: port, url: url) else {
            failure = "Could not open a new tab"
            return
        }
        failure = nil
        targets.append(opened)
        selection = opened.id
        address = opened.url
        await refreshTargets()
    }

    /// Close a page. The selection moves in the same round the list is re-read, so the frontend
    /// never points at a target that is gone.
    func closeTab(_ id: String) async {
        guard case let .ready(host, port) = phase else { return }
        guard await control.close(host: host, port: port, targetID: id) else {
            failure = "Could not close that tab"
            return
        }
        failure = nil
        targets.removeAll { $0.id == id }
        if selection == id {
            selection = targets.first?.id
            address = targets.first?.url ?? ""
        }
        await refreshTargets()
    }

    // MARK: Pure builders

    /// The DevTools frontend URL for one page: the frontend is served by the BROWSER itself
    /// (`/devtools/inspector.html`), so it is always the version that matches the protocol behind
    /// it and there is nothing to vendor or keep in step.
    ///
    /// The `ws` query carries the debugging socket WITHOUT its scheme — that is the frontend's own
    /// format (it prepends `ws://`), and passing a full URL there yields a frontend that loads and
    /// never connects. Pure — pinned by `WebSidebarModelTests`.
    static func frontendURL(host: String, port: UInt16, targetID: String) -> URL? {
        guard !host.isEmpty, port != 0, !targetID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/devtools/inspector.html"
        components.queryItems = [
            URLQueryItem(name: "ws", value: "\(host):\(port)/devtools/page/\(targetID)"),
        ]
        return components.url
    }

    /// What a typed address means. Pure — pinned by `WebSidebarModelTests`.
    ///
    /// - An address that already names a scheme is taken as written (including `about:`, `file:`
    ///   and `chrome:`, which are exactly the addresses a person types deliberately).
    /// - A bare host on the loopback family gets `http://`, because that is what a dev server on
    ///   the host serves and an `https://localhost:5173` that nothing answers is a worse default
    ///   than a redirect.
    /// - Everything else that looks like a host gets `https://`.
    /// - Anything with no dot, no colon and no leading slash is NOT a URL — this is an address bar,
    ///   not a search box, so it resolves to `nil` and the field keeps what was typed rather than
    ///   silently sending the text to a search engine.
    static func normalizedAddress(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let schemeEnd = trimmed.firstIndex(of: ":"),
           trimmed[trimmed.startIndex..<schemeEnd].allSatisfy(\.isLetter),
           schemeEnd > trimmed.startIndex,
           !isPortColon(trimmed, at: schemeEnd)
        {
            return trimmed
        }
        let hostPart = trimmed.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let bareHost = hostPart.prefix { $0 != ":" }
        guard hostPart.contains(":") || bareHost.contains(".") else { return nil }
        return (isLoopbackHost(String(bareHost)) ? "http://" : "https://") + trimmed
    }

    /// Whether the colon at `index` separates a host from a PORT rather than a scheme from its
    /// body — `localhost:5173` is a host, `https:` is a scheme.
    private static func isPortColon(_ text: String, at index: String.Index) -> Bool {
        let after = text[text.index(after: index)...].prefix { $0 != "/" }
        return !after.isEmpty && after.allSatisfy(\.isNumber)
    }

    /// The host's OWN machine, from the browser's point of view — where a dev server lives.
    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host.hasSuffix(".localhost")
    }
}
#endif
