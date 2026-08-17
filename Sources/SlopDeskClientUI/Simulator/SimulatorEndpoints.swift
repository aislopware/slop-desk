// SimulatorEndpoints — every URL the panel builds against the host's simulator server, in one pure
// place so the route table is pinned by tests rather than spelled out at four call sites.
//
// Plain `http`/`ws` on the WireGuard mesh, by the project's security invariant: there is no
// app-layer auth and TLS would only add a certificate-trust problem to a link that is already the
// boundary. No credentials appear in any of these.
//
// The panel talks to the server DIRECTLY at its mesh address. The loopback relay the workbench needs
// is deliberately not in this path: that relay exists to give a BROWSER a secure context and a
// stable origin for its per-origin storage, and a native panel has neither concern — it has no
// origin, no storage keyed by one, and no secure-context gate on the sockets it opens.

#if os(macOS)
import Foundation

enum SimulatorEndpoints {
    /// The version token on the stream socket. `1`-style pinning per the project's no-negotiation
    /// rule — the value is the server's own `v2` dialect tag, sent as a constant, never negotiated.
    static let streamDialect = "v2"

    /// `GET` — the device set. Never cached: the whole point of a poll is to see a boot land.
    static func deviceList(host: String, port: UInt16) -> URL? {
        url(host: host, port: port, path: "/simulators.json")
    }

    /// `POST`, empty body — start the device. The UDID lives in the path; there is no payload.
    static func boot(host: String, port: UInt16, udid: String) -> URL? {
        action(host: host, port: port, udid: udid, action: "boot")
    }

    /// `POST`, empty body — stop the device.
    static func shutdown(host: String, port: UInt16, udid: String) -> URL? {
        action(host: host, port: port, udid: udid, action: "shutdown")
    }

    /// `GET` — the device's physical body in the shape the panel draws it: viewport-relative
    /// percentages and ready-made image references. The server also serves `chrome.json`, which is
    /// the same bezel in absolute points; the percentages are what scale to a sidebar's width without
    /// a second layout pass. Answers for a shut-down device too, since it is model data rather than
    /// process state.
    static func definition(host: String, port: UInt16, udid: String) -> URL? {
        action(host: host, port: port, udid: udid, action: "definition.json")
    }

    /// `POST` — set the interface orientation. The value rides the query string, matching the
    /// server's own route; the body is empty.
    static func orientation(
        host: String, port: UInt16, udid: String, value: String,
    ) -> URL? {
        guard var components = components(host: host, port: port) else { return nil }
        components.percentEncodedPath = "/simulators/\(escape(udid))/orientation"
        components.queryItems = [URLQueryItem(name: "value", value: value)]
        return components.url
    }

    /// `GET` — one JPEG of the current screen. The cache-buster is the server's own idiom: without it
    /// a second capture inside the same session can come back from `URLSession`'s cache.
    ///
    /// `scale` (an INTEGER downscale divisor) and `quality` (0–1) are the flags `baguette screenshot`
    /// documents for its CLI, and the HTTP route honours both even though nothing on the server's own
    /// page sends them — measured 2026-08-04 against the live server: native is 1206 × 2622 for
    /// 480 KB in 30 ms, `scale=4` is 302 × 656 for 55 KB, and `scale=6&quality=0.5` is 202 × 438 for
    /// **13.5 KB in 22 ms**. That last one is what makes the list's live cards affordable at all: a
    /// fifth of what the idle VIDEO stream costs for the same device (33 KB/s, measured the same day),
    /// where a native-resolution poll would have been seven times more.
    ///
    /// Both are omitted from the query when left at their defaults, so a full-resolution capture
    /// builds the same URL it always did.
    static func screenshot(
        host: String, port: UInt16, udid: String, nonce: UInt64,
        scale: Int = 1, quality: Double? = nil,
    ) -> URL? {
        guard var components = components(host: host, port: port) else { return nil }
        components.percentEncodedPath = "/simulators/\(escape(udid))/screenshot.jpg"
        var items = [URLQueryItem(name: "t", value: String(nonce))]
        if scale > 1 { items.append(URLQueryItem(name: "scale", value: String(scale))) }
        if let quality { items.append(URLQueryItem(name: "quality", value: String(quality))) }
        components.queryItems = items
        return components.url
    }

    /// `POST`, JSON body — override or clear the status bar (time, bars, battery).
    static func statusBar(host: String, port: UInt16, udid: String) -> URL? {
        action(host: host, port: port, udid: udid, action: "status-bar")
    }

    /// `POST` JSON `{latitude, longitude}` — pin the device's simulated GPS position. `DELETE` on
    /// the same route restores live values. The server also accepts a `{waypoints}` route and a
    /// bearing/speed walk on this route; the panel sends neither (see ``SimulatorPlace``).
    static func location(host: String, port: UInt16, udid: String) -> URL? {
        action(host: host, port: port, udid: udid, action: "location")
    }

    /// The console's websocket. `style=compact` is not a preference — it is the only style whose
    /// line shape ``DeviceLogLine`` can colour by severity. `level` is passed to the server's own
    /// `log stream --level`, so only ``SimulatorLogLevel``'s closed set may reach it: an invented
    /// level still upgrades the socket and then dies when the child refuses it.
    static func logs(host: String, port: UInt16, udid: String, level: String) -> URL? {
        guard var components = components(host: host, port: port) else { return nil }
        components.scheme = "ws"
        components.path = "/simulators/\(escape(udid))/logs"
        components.queryItems = [
            URLQueryItem(name: "level", value: level),
            URLQueryItem(name: "style", value: "compact"),
        ]
        return components.url
    }

    /// `POST`, raw file bytes — hand the device a file. The server routes on the extension: an
    /// `.app`/`.ipa` is installed, an image or video lands in Photos. The name rides the query string
    /// because the body is the file itself.
    static func files(host: String, port: UInt16, udid: String, name: String) -> URL? {
        guard var components = components(host: host, port: port) else { return nil }
        components.percentEncodedPath = "/simulators/\(escape(udid))/files"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    /// Resolve a reference the SERVER handed back — a bezel or button image path out of
    /// ``SimulatorChrome``. `URL(string:relativeTo:)` rather than this file's own builder on purpose:
    /// the server's references carry a query (`bezel.png?buttons=false`) and are already escaped, and
    /// re-escaping a whole reference is precisely the double-encoding trap the UDID routes avoid.
    static func resolve(_ reference: String, host: String, port: UInt16) -> URL? {
        guard let base = components(host: host, port: port)?.url else { return nil }
        return URL(string: reference, relativeTo: base)
    }

    /// The frame + input websocket. Both directions ride this one socket: H.264 down, gesture JSON
    /// up. `format=avcc` asks for length-prefixed NALs rather than Annex-B, which is what
    /// `CMVideoFormatDescription` wants and saves a start-code rewrite per access unit.
    static func stream(host: String, port: UInt16, udid: String) -> URL? {
        guard var components = components(host: host, port: port) else { return nil }
        components.scheme = "ws"
        components.path = "/simulators/\(escape(udid))/stream"
        components.queryItems = [
            URLQueryItem(name: "format", value: "avcc"),
            URLQueryItem(name: "version", value: streamDialect),
        ]
        return components.url
    }

    // MARK: Building blocks

    private static func action(host: String, port: UInt16, udid: String, action: String) -> URL? {
        url(host: host, port: port, path: "/simulators/\(escape(udid))/\(action)")
    }

    /// `path` arrives already escaped, so it is assigned to `percentEncodedPath`. Assigning
    /// `.path` instead would escape a SECOND time (`%2F` → `%252F`) while still treating a raw
    /// slash as a separator — the worst of both.
    private static func url(host: String, port: UInt16, path: String) -> URL? {
        guard var components = components(host: host, port: port) else { return nil }
        components.percentEncodedPath = path
        return components.url
    }

    /// A degenerate endpoint (no host, or port zero) yields `nil` rather than a URL that would fail
    /// at connect time — the phase machine reads that nil as "not ready", which is the truth.
    private static func components(host: String, port: UInt16) -> URLComponents? {
        guard !host.isEmpty, port != 0 else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        return components
    }

    /// UDIDs are hex and dashes today, so this escapes nothing in practice. It is here because the
    /// value is interpolated into a PATH: the day the server accepts a device-set-relative name, an
    /// unescaped slash in it would silently address a different route. The allowed set is
    /// path-legal characters MINUS the separator — escaping the whole alphabet instead would send
    /// `%2D` for every dash in a UDID and hand the server a string it may compare raw.
    private static let pathComponentAllowed = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "/"))

    private static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: pathComponentAllowed) ?? component
    }
}
#endif
