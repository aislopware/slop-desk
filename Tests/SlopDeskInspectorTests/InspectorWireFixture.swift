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
    ///
    /// Takes the body as TEXT, not as an event value: since `docs/66` there is no event type on this
    /// side to encode from, and the frames a framing test needs never depended on there being one.
    static func eventFrame(_ json: String) -> Data {
        eventFrame(Data(json.utf8))
    }

    /// Tag `1` — an event whose body is already bytes, which is how it crosses the seam.
    static func eventFrame(_ body: Data) -> Data {
        frame(tag: 1, body: body)
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
