// SimulatorControlClient — the panel's non-streaming half: list and lifecycle, the device's body,
// and every host-side setting (orientation, status bar, screenshot, file drop, simulated GPS).
//
// Behind a protocol so the model that drives it is testable without a server: the real client is the
// only thing here that touches `URLSession`, and a test supplies its own.
//
// `URLSession` rather than an `NWConnection`, unlike the stream: these are three request/response
// round-trips per poll on a link that is already fast, with no latency-critical write pattern for
// `TCP_NODELAY` to protect. Reaching for the lower-level API here would be cost with no return.
//
// ## What is left in Swift, and why exactly this much
//
// The `URLSession` LIFETIME is the reason this file exists at all — `docs/55` §1 picks by lifetime,
// and a session owned by a Swift model, cancelled with its task, is in-process by necessity. What
// is NOT a lifetime is everything the file used to spell around it: a verb, a timeout, a cache
// policy, a content type, the 2xx window, the thumbnail's operating point, and the two JSON bodies
// it posts. Those were eleven call sites each choosing for itself, and they are now
// `slopdesk_devicepanel::sim_control` — one table, read through ``SimulatorControlPlan``.
//
// So the shape is: the endpoint table says WHERE (`SimulatorEndpoints`), the plan says HOW, and this
// file does the one thing neither can — hold the session and await the round trip.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

/// What the panel can ask of the host's simulator server. Throwing rather than optional-returning:
/// the caller renders the failure, and an error that says which step failed is worth more than a
/// `nil` that does not.
package protocol SimulatorControlling: Sendable {
    func devices(host: String, port: UInt16) async throws -> [SimulatorDevice]
    func boot(host: String, port: UInt16, udid: String) async throws
    func shutdown(host: String, port: UInt16, udid: String) async throws
    /// The device's physical body — bezel geometry and artwork references.
    func chrome(host: String, port: UInt16, udid: String) async throws -> SimulatorChrome
    /// Raw bytes for a reference `chrome` handed back. Untyped because the caller knows what it asked
    /// for; the only consumer today turns them into an image.
    func resource(host: String, port: UInt16, reference: String) async throws -> Data
    func setOrientation(host: String, port: UInt16, udid: String, value: String) async throws
    /// One JPEG of the current screen, at the device's own resolution — the capture that goes to the
    /// pasteboard, where a downscale would be a worse picture for no saving anyone asked for.
    func screenshot(host: String, port: UInt16, udid: String) async throws -> Data
    /// A SMALL JPEG of the current screen, for a card in the device list. Separate from ``screenshot``
    /// rather than a parameter on it because the two have opposite budgets: one is captured once and
    /// kept, the other arrives every couple of seconds for as long as the list is on screen.
    func thumbnail(host: String, port: UInt16, udid: String) async throws -> Data
    /// Apply the demo status bar, or clear every override.
    ///
    /// A flag rather than the dictionary this used to take: the panel ships ONE preset — the only
    /// reason anyone overrides a status bar is a clean capture — and the eight pairs that make it
    /// are `slopdesk_sim_status_bar_body`'s, so there is nothing left for a caller to compose.
    func setStatusBar(host: String, port: UInt16, udid: String, demo: Bool) async throws
    /// Hand the device a file: `.app`/`.ipa` installs, image/video lands in Photos.
    func sendFile(
        host: String, port: UInt16, udid: String, name: String, contents: Data,
    ) async throws
    /// Pin the device's simulated GPS position, or restore live values when `coordinate` is nil.
    func setLocation(
        host: String, port: UInt16, udid: String, coordinate: SimulatorCoordinate?,
    ) async throws
}

package enum SimulatorControlError: Error, Equatable {
    /// A degenerate endpoint — no host, or port zero. Not reachable from a ready phase; a bug if seen.
    case noEndpoint
    /// The server answered something other than 2xx.
    case status(Int)
    /// The body was not the envelope this build knows — or, for one unreachable arm, the linked
    /// library had no plan for an operation this header declares, which is a stale artifact rather
    /// than anything the server did.
    case malformedResponse
}

/// Which request is being made. The codes are the crate's own discriminants, in its order, so the
/// enum is a Swift spelling of `slopdesk_devicepanel::sim_control::Operation` rather than a second
/// list that has to be kept beside it.
package enum SimulatorControlOperation: UInt32, CaseIterable, Sendable {
    case devices = 0
    case boot = 1
    case shutdown = 2
    case chrome = 3
    case resource = 4
    case orientation = 5
    case screenshot = 6
    case thumbnail = 7
    case statusBar = 8
    case files = 9
    case location = 10
}

/// Everything about one request that is not its URL.
///
/// Read from `slopdesk_sim_control_plan` rather than written at the call site, because these four
/// fields are where the panel's HTTP dialect actually lives and eleven call sites each spelling
/// their own was eleven chances to give a poll a cache or an install eight seconds.
package struct SimulatorControlPlan: Equatable, Sendable {
    package let method: String
    /// The `Content-Type` for a request that carries a body, and `nil` for one that does not — most
    /// of these routes take the UDID from the path and read no body at all.
    package let contentType: String?
    package let timeout: TimeInterval
    /// Whether the request must bypass the URL cache. True for the polls, false for the bezel
    /// artwork, which is per MODEL and never changes.
    package let ignoresCache: Bool

    /// `nil` only when the linked library has no case for this operation — impossible for a value of
    /// ``SimulatorControlOperation``, and a stale `.xcframework` if it ever happens.
    package init?(_ operation: SimulatorControlOperation, hasPayload: Bool = false) {
        var blob = DevicePanelBlob { out, cap in
            slopdesk_sim_control_plan(operation.rawValue, hasPayload, out, cap)
        }
        guard !blob.isRefusal else { return nil }
        ignoresCache = blob.byte() != 0
        timeout = blob.number()
        method = blob.text()
        let type = blob.text()
        contentType = type.isEmpty ? nil : type
    }
}

package struct SimulatorControlClient: SimulatorControlling {
    private let session: URLSession

    package init(session: URLSession = .shared) {
        self.session = session
    }

    package func devices(host: String, port: UInt16) async throws -> [SimulatorDevice] {
        let data = try await fetch(
            .devices, SimulatorEndpoints.deviceList(host: host, port: port),
        )
        guard let devices = SimulatorDevice.decodeList(data)
        else { throw SimulatorControlError.malformedResponse }
        return devices
    }

    package func boot(host: String, port: UInt16, udid: String) async throws {
        try await send(.boot, SimulatorEndpoints.boot(host: host, port: port, udid: udid))
    }

    package func shutdown(host: String, port: UInt16, udid: String) async throws {
        try await send(.shutdown, SimulatorEndpoints.shutdown(host: host, port: port, udid: udid))
    }

    package func chrome(host: String, port: UInt16, udid: String) async throws -> SimulatorChrome {
        let data = try await fetch(
            .chrome, SimulatorEndpoints.definition(host: host, port: port, udid: udid),
        )
        guard let chrome = SimulatorChrome.decode(data)
        else { throw SimulatorControlError.malformedResponse }
        return chrome
    }

    package func resource(host: String, port: UInt16, reference: String) async throws -> Data {
        try await fetch(.resource, SimulatorEndpoints.resolve(reference, host: host, port: port))
    }

    package func setOrientation(host: String, port: UInt16, udid: String, value: String) async throws {
        try await send(.orientation, SimulatorEndpoints.orientation(
            host: host, port: port, udid: udid, value: value,
        ))
    }

    package func screenshot(host: String, port: UInt16, udid: String) async throws -> Data {
        try await fetch(.screenshot, SimulatorEndpoints.screenshot(
            host: host, port: port, udid: udid, nonce: Self.captureNonce(),
        ))
    }

    package func thumbnail(host: String, port: UInt16, udid: String) async throws -> Data {
        try await fetch(.thumbnail, SimulatorEndpoints.screenshot(
            host: host, port: port, udid: udid, nonce: Self.captureNonce(),
            scale: Int(slopdesk_sim_thumbnail_scale()), quality: slopdesk_sim_thumbnail_quality(),
        ))
    }

    /// The server's own cache-buster. A capture must be of NOW, and a second one in the same session
    /// is exactly the request a cache would answer from its copy of the first — which for a card
    /// polling every two seconds would mean a picture that never moves again.
    private static func captureNonce() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    package func setStatusBar(host: String, port: UInt16, udid: String, demo: Bool) async throws {
        let url = SimulatorEndpoints.statusBar(host: host, port: port, udid: udid)
        guard demo else {
            try await send(.statusBar, url)
            return
        }
        try await send(
            .statusBar, url,
            body: Data(wsAnswerBytes { out, cap in slopdesk_sim_status_bar_body(out, cap) }),
        )
    }

    package func sendFile(
        host: String, port: UInt16, udid: String, name: String, contents: Data,
    ) async throws {
        try await send(
            .files, SimulatorEndpoints.files(host: host, port: port, udid: udid, name: name),
            body: contents,
        )
    }

    package func setLocation(
        host: String, port: UInt16, udid: String, coordinate: SimulatorCoordinate?,
    ) async throws {
        let url = SimulatorEndpoints.location(host: host, port: port, udid: udid)
        guard let coordinate else {
            try await send(.location, url)
            return
        }
        try await send(
            .location, url,
            body: Data(wsAnswerBytes { out, cap in
                slopdesk_sim_location_body(coordinate.latitude, coordinate.longitude, out, cap)
            }),
        )
    }

    /// One round trip whose BODY is the answer.
    private func fetch(_ operation: SimulatorControlOperation, _ url: URL?) async throws -> Data {
        try await round(operation, url, body: nil).0
    }

    /// One round trip whose STATUS is the answer. A body, where there is one, decides the verb: the
    /// status bar and the location each have a set form and a clear form on the same route.
    private func send(
        _ operation: SimulatorControlOperation, _ url: URL?, body: Data? = nil,
    ) async throws {
        _ = try await round(operation, url, body: body)
    }

    private func round(
        _ operation: SimulatorControlOperation, _ url: URL?, body: Data?,
    ) async throws -> (Data, URLResponse) {
        guard let url else { throw SimulatorControlError.noEndpoint }
        guard let plan = SimulatorControlPlan(operation, hasPayload: body != nil)
        else { throw SimulatorControlError.malformedResponse }
        var request = URLRequest(
            url: url,
            cachePolicy: plan.ignoresCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy,
            timeoutInterval: plan.timeout,
        )
        request.httpMethod = plan.method
        if let body {
            request.httpBody = body
            if let contentType = plan.contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }
        let answer = try await session.data(for: request)
        try Self.check(answer.1)
        return answer
    }

    /// A non-2xx answer is an error even when the body parses: the server reports a refused boot
    /// that way, and treating it as success would leave the panel claiming a device is starting when
    /// nothing happened. The WINDOW is `slopdesk_sim_control_status_ok`'s — `files` answers 201 for
    /// an install, so a `== 200` here would fail every upload that worked.
    package static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse
        else { throw SimulatorControlError.malformedResponse }
        guard slopdesk_sim_control_status_ok(UInt16(clamping: http.statusCode)) else {
            throw SimulatorControlError.status(http.statusCode)
        }
    }
}
