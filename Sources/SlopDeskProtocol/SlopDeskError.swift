/// The two decode-time faults the metadata and workspace codecs surface to Swift.
///
/// It used to have four cases and describe FRAMING as well: a length prefix too large to be
/// legitimate, and a first byte naming no known message type. Both retired with `docs/63` §G.4 —
/// framing is `rust/slopdesk-wire`'s alone now, and it answers a short read by waiting and an
/// unknown type by dropping the frame, so neither fault ever reaches a Swift `throw`. What is left
/// is what the two surviving decoders genuinely re-raise: the non-OK verdicts
/// `slopdesk_wire_decode_*` hands back for a body it will not accept.
public enum SlopDeskError: Error, Equatable, Sendable {
    /// A body was shorter than its layout requires (e.g. a hook report with no bytes at all).
    /// Distinct from a partial read, which the Rust framer waits on rather than faulting.
    case truncated

    /// A body had the right length but malformed contents (e.g. invalid UTF-8 in a `title`).
    /// Associated value is a short human-readable reason.
    case malformedBody(String)
}
