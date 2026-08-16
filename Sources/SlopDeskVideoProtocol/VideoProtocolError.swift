/// Errors raised while decoding video-path wire messages.
///
/// Every codec in this target now reaches `rust/slopdesk-video` through `slopdesk-ffi`, so this is
/// the whole of what the target still owns about the wire: the two ways a datagram can be refused,
/// in the shape the routers and the transports already match on. The byte-layout toolkit that used
/// to live beside it — `Data.appendBE` and `VideoByteReader` — went with the last hand-rolled
/// codec; what the tests still need to build a hostile datagram lives in the test target, where a
/// second speller cannot become a second implementation.
public enum VideoProtocolError: Error, Equatable, Sendable {
    /// Not enough bytes remained to satisfy a fixed-size field.
    case truncated
    /// A field held a value outside its permitted range (e.g. an unknown tag).
    case malformed(String)
}
