// SimulatorControlClient — list, boot, shutdown. The panel's non-streaming half.
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

    private func post(_ url: URL?) async throws {
        guard let url else { throw SimulatorControlError.noEndpoint }
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        // No body by design — the server's route table takes the UDID from the path and reads
        // nothing. Sending one would be ignored at best.
        let (_, response) = try await session.data(for: request)
        try Self.check(response)
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
