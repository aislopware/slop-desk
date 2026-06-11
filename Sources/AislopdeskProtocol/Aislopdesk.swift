import Foundation

/// Top-level namespace for Aislopdesk wire-protocol constants.
///
/// `AislopdeskProtocol` is **pure Swift with zero platform dependency** (no `Network`,
/// no `Darwin`/`Glibc`): it must build for both macOS and iOS and be unit-testable
/// in isolation. Only `Foundation` (for `Data`/`UUID`) is imported.
public enum Aislopdesk {
    /// Current wire-protocol version, sent in the `hello` handshake.
    ///
    /// Bumped whenever the framing, message-type table, or any body layout changes
    /// in a non-backward-compatible way.
    public static let protocolVersion: UInt16 = 1

    /// Maximum accepted frame payload size: 16 MiB.
    ///
    /// A length prefix larger than this is rejected with ``AislopdeskError/frameTooLarge(_:)``
    /// rather than buffered — it almost certainly means a corrupt or hostile stream,
    /// and we will not allocate unbounded memory for it. The PTY hot path produces
    /// small frames; legitimate output is chunked far below this ceiling.
    public static let maxFramePayloadLength = 16 * 1024 * 1024
}
