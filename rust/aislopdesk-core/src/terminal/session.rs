//! Session identifier — a port of the `UUID` used on the terminal-path wire.
//!
//! Swift carries the session id as a `Foundation.UUID` (its 16 raw bytes, canonical
//! order). This crate is zero-dependency, so the port models it as a plain 16-byte
//! newtype: the wire only ever reads/writes the raw bytes, and the only distinguished
//! value is the all-zero [`SessionId::NEW_SESSION`] (Swift `WireMessage.newSessionID`),
//! which `hello` / `channelOpen` use to request a brand-new session.

/// A 16-byte session identifier (the raw bytes of the Swift `UUID`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SessionId(pub [u8; 16]);

impl SessionId {
    /// Number of bytes a session id occupies on the wire (its 16 raw bytes). Matches
    /// Swift `WireMessage.sessionIDByteCount` / `MuxEnvelopeCodec.sessionIDByteCount`.
    pub const BYTE_COUNT: usize = 16;

    /// The all-zero id (`hello` / `channelOpen` use it to request a NEW session). Mirrors
    /// Swift `WireMessage.newSessionID`.
    pub const NEW_SESSION: Self = Self([0u8; 16]);

    /// Builds a session id from exactly 16 raw bytes.
    ///
    /// The decoders always feed exactly [`SessionId::BYTE_COUNT`] bytes (the reader returns
    /// `Truncated` otherwise), so the slice length is an invariant of the caller — Swift's
    /// matching `UUID(dataBytes:)` nil-branch is likewise unreachable on the decode path.
    ///
    /// # Panics
    /// Panics if `bytes.len() != 16` — a programming error, never reachable from the wire.
    #[must_use]
    pub fn from_slice(bytes: &[u8]) -> Self {
        let mut raw = [0u8; 16];
        raw.copy_from_slice(bytes);
        Self(raw)
    }

    /// The 16 raw bytes, in canonical order (what `encode` writes to the wire).
    #[must_use]
    pub const fn bytes(&self) -> &[u8; 16] {
        &self.0
    }
}
