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
//
// Nor does it word its own failures. The six sentences it used to spell as literals are
// `slopdesk_devicepanel::android_bridge::Refusal`'s, for the reason every other copy table in this
// target is the crate's: the panel is drawn by TWO renderers, and a sentence with one speller by
// accident is one edit away from having two.

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

    /// A failure the HOST worded, forwarded verbatim.
    package init(_ message: String) { self.message = message }

    /// One of the panel's own, read from the crate's table.
    package init(_ refusal: AndroidBridgeRefusal) { message = refusal.message }
}

/// The refusals the panel words ITSELF, because the host never saw them: a request that did not
/// leave, or an answer refused on this side.
///
/// The cases are `slopdesk_devicepanel::android_bridge::Refusal`'s, and the position each reads from
/// is the crate's own code, taken from the header rather than typed here — the arrangement
/// ``AndroidSidebarNotice`` already uses, so a sentence added on one side and not the other reads as
/// one this build cannot ask for rather than as a silently different one.
package enum AndroidBridgeRefusal: CaseIterable, Sendable {
    /// No ensure round has answered, so there is no address to dial.
    case noEndpoint
    /// ``AndroidBridgeRequest`` declined to build the line — a required field that is empty.
    case unbuildableRequest
    /// The same, for the console's subscription, which names `logcat`: the stream simply ends, and
    /// the row that says why is the only thing on screen.
    case unbuildableLogcat
    /// The `list` ack carried no rows this build could read.
    case unreadableDeviceList
    /// The screenshot ack named no byte count the panel will collect.
    case unreadableScreenshot
    /// The socket ended before the count the ack named had arrived.
    case truncatedScreenshot

    /// Which field of the refusals delivery holds this one's sentence.
    var ffiField: Int {
        switch self {
        case .noEndpoint: Int(SLOPDESK_ANDROID_BRIDGE_REFUSAL_NO_ENDPOINT)
        case .unbuildableRequest: Int(SLOPDESK_ANDROID_BRIDGE_REFUSAL_UNBUILDABLE_REQUEST)
        case .unbuildableLogcat: Int(SLOPDESK_ANDROID_BRIDGE_REFUSAL_UNBUILDABLE_LOGCAT)
        case .unreadableDeviceList: Int(SLOPDESK_ANDROID_BRIDGE_REFUSAL_UNREADABLE_DEVICE_LIST)
        case .unreadableScreenshot: Int(SLOPDESK_ANDROID_BRIDGE_REFUSAL_UNREADABLE_SCREENSHOT)
        case .truncatedScreenshot: Int(SLOPDESK_ANDROID_BRIDGE_REFUSAL_TRUNCATED_SCREENSHOT)
        }
    }

    /// The sentence.
    package var message: String {
        let field = ffiField
        return Self.sentences.indices.contains(field) ? Self.sentences[field] : ""
    }

    /// Every sentence, in the order `slopdesk_android_bridge_refusals` documents. Read ONCE — these
    /// six strings never change within a process.
    ///
    /// PADDED, never trusted: ``DevicePanelBlob/texts(_:)`` fills a short delivery with empties
    /// rather than shifting, so a crate and a face that disagree about the layout lose ONE sentence
    /// instead of wearing each other's from the gap onward.
    private static let sentences: [String] = {
        var blob = DevicePanelBlob { out, cap in slopdesk_android_bridge_refusals(out, cap) }
        return blob.texts(Self.allCases.count)
    }()
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
                return .failure(AndroidBridgeFailure(.unreadableDeviceList))
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
            return .failure(AndroidBridgeFailure(.noEndpoint))
        }
        guard let line = AndroidBridgeRequest.screenshot(serial: serial) else {
            return .failure(AndroidBridgeFailure(.unbuildableRequest))
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
                            settle(.failure(AndroidBridgeFailure(.unreadableScreenshot)))
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
                    settle(.failure(AndroidBridgeFailure(.truncatedScreenshot)))
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
            return .failure(AndroidBridgeFailure(.noEndpoint))
        }
        guard let line else {
            return .failure(AndroidBridgeFailure(.unbuildableRequest))
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
