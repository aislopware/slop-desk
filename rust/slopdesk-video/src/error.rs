//! The error type every video-path decoder answers with.
//!
//! The variant is the contract callers branch on — truncated versus malformed. The `Malformed`
//! payload is a human-readable field hint that is NOT part of the wire format, so parity tests
//! assert on the variant and never on the string.
//!
//! ## Why this is not `slopdesk_wire::WireError`
//!
//! Same reason `VideoProtocolError` is not `SlopDeskProtocol`'s error in Swift: the two transports
//! answer differently to the same shape of damage. A malformed TERMINAL frame fails the session,
//! because the terminal has no way to skip a byte and stay in sync. A malformed video DATAGRAM is
//! dropped and the frame is repaired or re-requested. Sharing one error type across that line would
//! read as if the two paths handled failure the same way, and they must not.

use core::fmt;

/// Errors raised while decoding video-path wire messages.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VideoProtocolError {
    /// Not enough bytes remained to satisfy a fixed-size field.
    Truncated,
    /// A field held a value outside its permitted range — an unknown tag, a non-finite float, an
    /// out-of-range enum discriminant.
    Malformed(String),
}

impl VideoProtocolError {
    /// Builds a [`VideoProtocolError::Malformed`] from any displayable hint.
    pub fn malformed(hint: impl Into<String>) -> Self {
        Self::Malformed(hint.into())
    }
}

impl fmt::Display for VideoProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Truncated => f.write_str("truncated"),
            Self::Malformed(hint) => write!(f, "malformed: {hint}"),
        }
    }
}

impl std::error::Error for VideoProtocolError {}

/// Result alias for the video-path codecs.
pub type Result<T> = core::result::Result<T, VideoProtocolError>;
