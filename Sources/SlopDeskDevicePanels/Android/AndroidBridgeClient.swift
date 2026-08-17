// AndroidBridgeClient — the panel's request/response half of the bridge: list, boot, shut down,
// console.
//
// One connection per request, deliberately. A pooled connection would have to multiplex, and the
// bridge has no request ids because two of its four operations take the socket over entirely
// (`logcat` and `open` never give it back). A TCP connect over the mesh costs one round trip; the
// operations here are a poll every couple of seconds and a handful of user actions, so the pool would
// buy nothing and cost the panel a state machine.
//
// The model holds one of these through ``AndroidBridging`` rather than the concrete class, so a test
// can drive the whole panel — list, select, boot, failure — without a socket. Constructing an
// `NWConnection` in a unit test is exactly the hang-safety rule this project keeps.

#if os(macOS)
import Foundation

/// Why a bridge request did not produce an answer, in the words the panel shows.
///
/// A sentence rather than a code, because every one of these is written to be read by the person in
/// front of the panel and there is nothing for the code to branch on: the host already decided which
/// failures are distinguishable when it chose its own error strings.
package struct AndroidBridgeFailure: Error, Equatable {
    package let message: String
    package init(_ message: String) { self.message = message }
}

/// The bridge's request/response operations, as the panel uses them.
@MainActor
package protocol AndroidBridging: AnyObject {
    /// Where the bridge is. Set once an ensure round has answered; requests before that fail
    /// immediately rather than dialling nothing.
    var endpoint: (host: String, port: UInt16)? { get set }
    func devices() async -> Result<[AndroidDevice], AndroidBridgeFailure>
    func boot(avd: String) async -> String?
    func shutdown(serial: String) async -> String?
    func console(_ command: String, serial: String) async -> Result<String, AndroidBridgeFailure>
    func screenshot(serial: String) async -> Result<Data, AndroidBridgeFailure>
}

@MainActor
package final class AndroidBridgeClient: AndroidBridging {
    package var endpoint: (host: String, port: UInt16)?

    /// Live one-shot sockets, held only so ARC does not free one out from under its own completion.
    /// Each removes itself when it replies.
    private var inFlight: [ObjectIdentifier: AndroidBridgeSocket] = [:]

    package init() {}

    package func devices() async -> Result<[AndroidDevice], AndroidBridgeFailure> {
        switch await request(["op": "list"]) {
        case let .success(line):
            guard let devices = AndroidDevice.decodeList(line) else {
                return .failure(AndroidBridgeFailure("The device list made no sense."))
            }
            return .success(devices)
        case let .failure(failure):
            return .failure(failure)
        }
    }

    package func boot(avd: String) async -> String? {
        if case let .failure(failure) = await request(["op": "boot", "avd": avd]) {
            return failure.message
        }
        return nil
    }

    package func shutdown(serial: String) async -> String? {
        if case let .failure(failure) = await request(["op": "shutdown", "serial": serial]) {
            return failure.message
        }
        return nil
    }

    package func console(_ command: String, serial: String) async -> Result<String, AndroidBridgeFailure> {
        switch await request(["op": "console", "serial": serial, "command": command]) {
        case let .success(line):
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            return .success((object?["output"] as? String) ?? "")
        case let .failure(failure):
            return .failure(failure)
        }
    }

    /// One capture of the device's screen. The reply names a byte count and the PNG follows it, so
    /// this is the one request that keeps reading after the ack.
    ///
    /// A ceiling and a deadline, both because the length is the HOST's claim about what is coming: a
    /// count that never arrives in full would otherwise hold the continuation open forever.
    package func screenshot(serial: String) async -> Result<Data, AndroidBridgeFailure> {
        guard let endpoint else {
            return .failure(AndroidBridgeFailure("The host has no Android bridge yet."))
        }
        return await withCheckedContinuation { continuation in
            var box: AndroidBridgeSocket?
            var expected = 0
            var collected = Data()
            var isSettled = false
            let settle: (Result<Data, AndroidBridgeFailure>) -> Void = { [weak self] result in
                guard !isSettled else { return }
                isSettled = true
                if let box { self?.inFlight.removeValue(forKey: ObjectIdentifier(box)) }
                box?.close()
                continuation.resume(returning: result)
            }
            let socket = AndroidBridgeSocket(
                request: ["op": "screenshot", "serial": serial],
                onReply: { reply in
                    switch reply {
                    case let .ok(line):
                        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                        let bytes = (object?["bytes"] as? Int) ?? 0
                        guard bytes > 0, bytes <= Self.screenshotLimit else {
                            settle(.failure(AndroidBridgeFailure("The screenshot made no sense.")))
                            return
                        }
                        expected = bytes
                    case let .failed(message):
                        settle(.failure(AndroidBridgeFailure(message)))
                    }
                },
                onBytes: { data in
                    collected.append(data)
                    guard expected > 0, collected.count >= expected else { return }
                    settle(.success(Data(collected.prefix(expected))))
                },
                onEnd: { _ in
                    settle(.failure(AndroidBridgeFailure("The screenshot was cut short.")))
                },
            )
            guard let socket else {
                settle(.failure(AndroidBridgeFailure("The request could not be encoded.")))
                return
            }
            box = socket
            inFlight[ObjectIdentifier(socket)] = socket
            socket.connect(host: endpoint.host, port: endpoint.port)
        }
    }

    /// The largest capture this will accept. A 4K tablet's PNG is a few megabytes; sixteen is well
    /// past any real screen and short of a number that could be an allocation attack.
    package static let screenshotLimit = 16 << 20

    // MARK: Plumbing

    private func request(_ body: [String: Any]) async -> Result<Data, AndroidBridgeFailure> {
        guard let endpoint else {
            return .failure(AndroidBridgeFailure("The host has no Android bridge yet."))
        }
        return await withCheckedContinuation { continuation in
            // The socket has to exist before its completion can retain it, and the completion has to
            // be able to find it to let it go. `box` breaks that cycle.
            var box: AndroidBridgeSocket?
            let socket = AndroidBridgeSocket(request: body) { [weak self] reply in
                if let box { self?.inFlight.removeValue(forKey: ObjectIdentifier(box)) }
                box?.close()
                switch reply {
                case let .ok(line):
                    continuation.resume(returning: .success(line))
                case let .failed(message):
                    continuation.resume(returning: .failure(AndroidBridgeFailure(message)))
                }
            }
            guard let socket else {
                continuation.resume(
                    returning: .failure(AndroidBridgeFailure("The request could not be encoded.")),
                )
                return
            }
            box = socket
            inFlight[ObjectIdentifier(socket)] = socket
            socket.connect(host: endpoint.host, port: endpoint.port)
        }
    }
}
#endif
