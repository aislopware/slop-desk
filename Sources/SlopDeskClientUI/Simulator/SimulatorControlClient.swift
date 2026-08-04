// SimulatorControlClient — the panel's non-streaming half: list and lifecycle, the device's body,
// and every host-side setting (orientation, status bar, screenshot, file drop).
//
// Behind a protocol so the model that drives it is testable without a server: the real client is the
// only thing here that touches `URLSession`, and a test supplies its own. That split is the reason
// this file is three lines of logic and a lot of stated intent — the logic worth testing lives in
// the decoder and the endpoint table, both of which are already pure.
//
// `URLSession` rather than an `NWConnection`, unlike the stream: these are three request/response
// round-trips per poll on a link that is already fast, with no latency-critical write pattern for
// `TCP_NODELAY` to protect. Reaching for the lower-level API here would be cost with no return.

#if os(macOS)
import Foundation

/// What the panel can ask of the host's simulator server. Throwing rather than optional-returning:
/// the caller renders the failure, and an error that says which step failed is worth more than a
/// `nil` that does not.
protocol SimulatorControlling: Sendable {
    func devices(host: String, port: UInt16) async throws -> [SimulatorDevice]
    func boot(host: String, port: UInt16, udid: String) async throws
    func shutdown(host: String, port: UInt16, udid: String) async throws
    /// The device's physical body — bezel geometry and artwork references.
    func chrome(host: String, port: UInt16, udid: String) async throws -> SimulatorChrome
    /// Raw bytes for a reference `chrome` handed back. Untyped because the caller knows what it asked
    /// for; the only consumer today turns them into an image.
    func resource(host: String, port: UInt16, reference: String) async throws -> Data
    func setOrientation(host: String, port: UInt16, udid: String, value: String) async throws
    /// One JPEG of the current screen.
    func screenshot(host: String, port: UInt16, udid: String) async throws -> Data
    /// Override the status bar, or clear every override when `overrides` is empty.
    func setStatusBar(
        host: String, port: UInt16, udid: String, overrides: [String: String],
    ) async throws
    /// Hand the device a file: `.app`/`.ipa` installs, image/video lands in Photos.
    func sendFile(
        host: String, port: UInt16, udid: String, name: String, contents: Data,
    ) async throws
}

enum SimulatorControlError: Error, Equatable {
    /// A degenerate endpoint — no host, or port zero. Not reachable from a ready phase; a bug if seen.
    case noEndpoint
    /// The server answered something other than 2xx.
    case status(Int)
    /// The body was not the envelope this build knows.
    case malformedResponse
}

struct SimulatorControlClient: SimulatorControlling {
    /// A short timeout on purpose. These calls sit behind a poll loop that will simply ask again, so
    /// a request hanging on a wedged server costs a round of freshness rather than a stuck panel —
    /// and the default 60 seconds would keep a dead endpoint looking alive for a minute.
    static let timeout: TimeInterval = 8

    /// Uploads get their own budget: an `.app` bundle is megabytes over the mesh, and the control
    /// timeout would abort an install that is simply still running.
    static let uploadTimeout: TimeInterval = 300

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func devices(host: String, port: UInt16) async throws -> [SimulatorDevice] {
        guard let url = SimulatorEndpoints.deviceList(host: host, port: port)
        else { throw SimulatorControlError.noEndpoint }
        // `reloadIgnoringLocalCacheData`: the whole point of asking again is to see a boot land, and
        // a cached device list would show the state the panel already believed.
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout,
        )
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        guard let devices = SimulatorDevice.decodeList(data)
        else { throw SimulatorControlError.malformedResponse }
        return devices
    }

    func boot(host: String, port: UInt16, udid: String) async throws {
        try await post(SimulatorEndpoints.boot(host: host, port: port, udid: udid))
    }

    func shutdown(host: String, port: UInt16, udid: String) async throws {
        try await post(SimulatorEndpoints.shutdown(host: host, port: port, udid: udid))
    }

    func chrome(host: String, port: UInt16, udid: String) async throws -> SimulatorChrome {
        let data = try await get(SimulatorEndpoints.definition(host: host, port: port, udid: udid))
        guard let chrome = SimulatorChrome.decode(data)
        else { throw SimulatorControlError.malformedResponse }
        return chrome
    }

    func resource(host: String, port: UInt16, reference: String) async throws -> Data {
        // Bezel artwork is per MODEL and never changes, so this one is deliberately left on the
        // default cache policy — the opposite of the device list, which must not be cached at all.
        try await get(SimulatorEndpoints.resolve(reference, host: host, port: port), fresh: false)
    }

    func setOrientation(host: String, port: UInt16, udid: String, value: String) async throws {
        try await post(SimulatorEndpoints.orientation(
            host: host, port: port, udid: udid, value: value,
        ))
    }

    func screenshot(host: String, port: UInt16, udid: String) async throws -> Data {
        // The nonce is the server's own cache-buster. A capture must be of NOW, and a second one in
        // the same session is exactly the request a cache would answer from its copy of the first.
        let nonce = UInt64(Date().timeIntervalSince1970 * 1000)
        return try await get(SimulatorEndpoints.screenshot(
            host: host, port: port, udid: udid, nonce: nonce,
        ))
    }

    func setStatusBar(
        host: String, port: UInt16, udid: String, overrides: [String: String],
    ) async throws {
        let url = SimulatorEndpoints.statusBar(host: host, port: port, udid: udid)
        guard !overrides.isEmpty else {
            try await send(Self.statusBarMethod(for: [:]), url)
            return
        }
        try await send(
            Self.statusBarMethod(for: overrides), url,
            body: try? JSONSerialization.data(withJSONObject: overrides),
            contentType: "application/json",
        )
    }

    func sendFile(
        host: String, port: UInt16, udid: String, name: String, contents: Data,
    ) async throws {
        try await post(
            SimulatorEndpoints.files(host: host, port: port, udid: udid, name: name),
            body: contents,
            contentType: "application/octet-stream",
            // Uploading an .app is orders of magnitude more than a control call, and timing it out at
            // eight seconds would fail every install that is actually working.
            timeout: Self.uploadTimeout,
        )
    }

    private func get(_ url: URL?, fresh: Bool = true) async throws -> Data {
        guard let url else { throw SimulatorControlError.noEndpoint }
        let request = URLRequest(
            url: url,
            cachePolicy: fresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy,
            timeoutInterval: Self.timeout,
        )
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return data
    }

    private func post(
        _ url: URL?,
        body: Data? = nil,
        contentType: String? = nil,
        timeout: TimeInterval = Self.timeout,
    ) async throws {
        try await send("POST", url, body: body, contentType: contentType, timeout: timeout)
    }

    private func send(
        _ method: String,
        _ url: URL?,
        body: Data? = nil,
        contentType: String? = nil,
        timeout: TimeInterval = Self.timeout,
    ) async throws {
        guard let url else { throw SimulatorControlError.noEndpoint }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        // Most of these routes take the UDID from the path and read no body at all; the ones that do
        // say so by passing one. Sending an unwanted body would be ignored at best.
        if let body {
            request.httpBody = body
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        let (_, response) = try await session.data(for: request)
        try Self.check(response)
    }

    /// One route, two verbs. Clearing is a DELETE, not a flag in the body — measured 2026-08-04, the
    /// server answers an empty or flag-only POST with 400 "set at least one status-bar field", so an
    /// override-shaped clear does not merely no-op, it fails. Pure so a test pins the rule rather
    /// than only the one line that spells it.
    static func statusBarMethod(for overrides: [String: String]) -> String {
        overrides.isEmpty ? "DELETE" : "POST"
    }

    /// A non-2xx answer is an error even when the body parses: the server reports a refused boot
    /// that way, and treating it as success would leave the panel claiming a device is starting when
    /// nothing happened.
    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SimulatorControlError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SimulatorControlError.status(http.statusCode)
        }
    }
}
#endif
