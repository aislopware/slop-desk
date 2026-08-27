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
//
// What is left here is the CONNECTION, not the grammar. Every request line is
// ``AndroidBridgeRequest``'s and every field read out of a reply is a door's
// (`slopdesk_devicepanel::android_bridge`), which is where the daemon's own decoder already lived:
// this file used to hold a second spelling of `op`, `output` and `bytes`, plus a 16 MiB ceiling
// written on the side that does not read the claim it bounds. Nothing here touches
// `JSONSerialization` any more.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

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
        switch await request(AndroidBridgeRequest.list) {
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
        if case let .failure(failure) = await request(AndroidBridgeRequest.boot(avd: avd)) {
            return failure.message
        }
        return nil
    }

    package func shutdown(serial: String) async -> String? {
        if case let .failure(failure) = await request(AndroidBridgeRequest.shutdown(serial: serial)) {
            return failure.message
        }
        return nil
    }

    package func console(_ command: String, serial: String) async -> Result<String, AndroidBridgeFailure> {
        switch await request(AndroidBridgeRequest.console(command, serial: serial)) {
        case let .success(line):
            // An absent `output` and an empty one are the same answer — the console prints nothing
            // either way — so the door folds them together and this reads one string.
            .success(devicePanelLend(line) { bytes, length in
                wsAnswer { out, cap in
                    slopdesk_android_bridge_console_output(bytes, length, out, cap)
                } ?? ""
            })
        case let .failure(failure):
            .failure(failure)
        }
    }

    /// One capture of the device's screen. The reply names a byte count and the PNG follows it, so
    /// this is the one request that keeps reading after the ack.
    ///
    /// A ceiling and a deadline, both because the length is the HOST's claim about what is coming: a
    /// count that never arrives in full would otherwise hold the continuation open forever. The
    /// ceiling is `slopdesk_android_bridge_screenshot_bytes`', so the number this panel will not
    /// exceed is written once, on the side that reads the claim.
    package func screenshot(serial: String) async -> Result<Data, AndroidBridgeFailure> {
        guard let endpoint else {
            return .failure(AndroidBridgeFailure("The host has no Android bridge yet."))
        }
        guard let line = AndroidBridgeRequest.screenshot(serial: serial) else {
            return .failure(AndroidBridgeFailure("The request could not be encoded."))
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
                request: line,
                onReply: { reply in
                    switch reply {
                    case let .ok(line):
                        // The ceiling and the "no such count" refusals are one answer: the door
                        // reports `0` for an absent count, a non-positive one and one past the cap
                        // alike, because this side does the same thing with each.
                        let bytes = devicePanelLend(line) { pointer, length in
                            slopdesk_android_bridge_screenshot_bytes(pointer, length)
                        }
                        guard bytes > 0 else {
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
            box = socket
            inFlight[ObjectIdentifier(socket)] = socket
            socket.connect(host: endpoint.host, port: endpoint.port)
        }
    }

    // MARK: Plumbing

    /// `line` is `nil` for a request ``AndroidBridgeRequest`` refused to build — a required field
    /// that is empty. ONE arm, where there used to be one per operation guarding a JSON encoder
    /// that raised rather than threw.
    private func request(_ line: Data?) async -> Result<Data, AndroidBridgeFailure> {
        guard let endpoint else {
            return .failure(AndroidBridgeFailure("The host has no Android bridge yet."))
        }
        guard let line else {
            return .failure(AndroidBridgeFailure("The request could not be encoded."))
        }
        return await withCheckedContinuation { continuation in
            // The socket has to exist before its completion can retain it, and the completion has to
            // be able to find it to let it go. `box` breaks that cycle.
            var box: AndroidBridgeSocket?
            let socket = AndroidBridgeSocket(request: line) { [weak self] reply in
                if let box { self?.inFlight.removeValue(forKey: ObjectIdentifier(box)) }
                box?.close()
                switch reply {
                case let .ok(line):
                    continuation.resume(returning: .success(line))
                case let .failed(message):
                    continuation.resume(returning: .failure(AndroidBridgeFailure(message)))
                }
            }
            box = socket
            inFlight[ObjectIdentifier(socket)] = socket
            socket.connect(host: endpoint.host, port: endpoint.port)
        }
    }
}
