import Foundation
@testable import SlopDeskInspector

/// Builds the frames `slopdesk-inspectord` sends, by hand.
///
/// The Swift end of this protocol is the CLIENT end: it encodes `subscribe` and decodes events and
/// keep-alives, and there is deliberately no event encoder here to pair with (`docs/54`). So a test
/// that needs a host → client frame spells the wire out — `[UInt32 BE payloadLength][UInt8
/// tag][body]` — rather than round-tripping through an encoder of our own.
///
/// That is not a workaround, it is the stronger test: a round trip through one codebase's encoder
/// and decoder passes just as happily when BOTH ends have drifted from the wire, which is exactly
/// the failure a two-language protocol has. These bytes are the contract, written out.
enum InspectorWireFixture {
    /// Tag `1` — an event, JSON body.
    static func eventFrame(_ event: InspectorEvent) throws -> Data {
        try frame(tag: 1, body: JSONEncoder().encode(event))
    }

    /// Tag `2` — a keep-alive, empty body.
    static var keepAliveFrame: Data {
        frame(tag: 2, body: Data())
    }

    /// `[UInt32 BE payloadLength][tag][body]`, where `payloadLength` counts the tag.
    static func frame(tag: UInt8, body: Data) -> Data {
        var payload = Data([tag])
        payload.append(body)
        let length = UInt32(payload.count)
        var out = Data()
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload)
        return out
    }
}
