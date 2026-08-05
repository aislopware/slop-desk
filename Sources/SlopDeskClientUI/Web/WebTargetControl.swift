// WebTargetControl — the Web surface's wire to the host's browser.
//
// Two protocols, both the browser's own. The page LIST and the tab open/close are Chrome's
// `/json/*` HTTP endpoints; a NAVIGATION is a Chrome DevTools Protocol message, because there is no
// HTTP endpoint that points an existing page somewhere (`/json/new` only ever makes another one,
// and a new page means a new DevTools session, which is the one thing the address bar must not
// cost). Measured 2026-08-05 against Chrome: `/json/new` refuses GET and requires PUT, and
// `Page.navigate` over a short-lived websocket both answers and moves the page.
//
// Everything here runs through the client's LOOPBACK relay, which is why the addresses below are
// `127.0.0.1` — see `CodeSidebarProxyPool` and `WebSidebarPhase.ready`.
//
// Hang-safety: URLSession tasks are real network objects. Nothing in the unit-test closure may
// construct this — the model takes it behind ``WebTargetControlling``.

#if os(macOS)
import Foundation

/// The production ``WebTargetControlling``.
struct WebTargetControl: WebTargetControlling {
    /// Short timeouts throughout: every call here is loopback-to-relay-to-loopback, so a request
    /// that has not answered in a few seconds is not slow, it is gone — and the panel polls again
    /// anyway.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        // The browser's endpoints answer with no-store anyway; an app-side cache of a tab list
        // would be a list that lies.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func targets(host: String, port: UInt16) async -> [WebTarget] {
        guard let url = Self.endpoint(host: host, port: port, path: "/json/list") else { return [] }
        guard let (data, _) = try? await Self.session.data(from: url) else { return [] }
        return Self.decodeTargets(data)
    }

    func navigate(host: String, port: UInt16, targetID: String, url: String) async -> Bool {
        guard let socketURL = URL(string: "ws://\(host):\(port)/devtools/page/\(targetID)") else { return false }
        let task = Self.session.webSocketTask(with: socketURL)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        let message = Self.navigateMessage(url: url)
        guard await (try? task.send(.string(message))) != nil else { return false }
        // Await the reply rather than assuming: a send that Chrome rejects (a URL it refuses, a
        // target that has just gone) is otherwise indistinguishable from a navigation that worked,
        // and the address bar would keep showing a page it never reached.
        guard let reply = try? await task.receive() else { return false }
        return Self.isNavigateSuccess(reply)
    }

    func newTarget(host: String, port: UInt16, url: String) async -> WebTarget? {
        // The query carries the target URL verbatim, percent-encoded — and the verb is PUT: Chrome
        // 111+ answers GET on this endpoint with "Using unsafe HTTP verb GET" and nothing else.
        let encoded = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
        guard let endpoint = Self.endpoint(host: host, port: port, path: "/json/new"),
              let url = URL(string: endpoint.absoluteString + "?" + encoded)
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        guard let (data, _) = try? await Self.session.data(for: request) else { return nil }
        return Self.decodeTarget(data)
    }

    func close(host: String, port: UInt16, targetID: String) async -> Bool {
        guard let url = Self.endpoint(host: host, port: port, path: "/json/close/\(targetID)") else { return false }
        guard let (_, response) = try? await Self.session.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: Pure parts (pinned by `WebTargetControlTests`)

    static func endpoint(host: String, port: UInt16, path: String) -> URL? {
        guard !host.isEmpty, port != 0 else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = path
        return components.url
    }

    /// The one CDP message the panel sends. Hand-built rather than `JSONEncoder`'d for the URL's
    /// sake: it must survive quotes and backslashes, which `JSONSerialization` escapes correctly.
    static func navigateMessage(url: String) -> String {
        let body: [String: Any] = ["id": 1, "method": "Page.navigate", "params": ["url": url]]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    /// Whether a CDP reply says the navigation happened. A reply carrying `error` is a refusal
    /// (an unsupported scheme, a target that closed mid-flight) and must NOT read as success.
    static func isNavigateSuccess(_ message: URLSessionWebSocketTask.Message) -> Bool {
        guard case let .string(text) = message,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["error"] == nil && object["result"] != nil
    }

    /// `/json/list` → the PAGE targets only. The list also carries extension background pages,
    /// service workers and the browser target itself; none of those is a tab the address bar can
    /// move, and showing them would fill the tab menu with things the user never opened.
    static func decodeTargets(_ data: Data) -> [WebTarget] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { entry in
            guard entry["type"] as? String == "page" else { return nil }
            return target(from: entry)
        }
    }

    /// `/json/new` → the one target it made.
    static func decodeTarget(_ data: Data) -> WebTarget? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return target(from: object)
    }

    private static func target(from entry: [String: Any]) -> WebTarget? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        return WebTarget(
            id: id, title: entry["title"] as? String ?? "", url: entry["url"] as? String ?? "",
        )
    }
}
#endif
