//! The decode-time fault type.
//!
//! Every variant here is a *permanent* fault: a frame too large to be legitimate, a complete body
//! shorter than its type requires, an unrecognised type byte, or a body whose contents do not match
//! the layout its type declares. A PARTIAL frame — one that might still complete when more TCP
//! bytes arrive — is deliberately not represented, because it is not an error;
//! [`crate::FrameDecoder`] answers `None` and waits.
//!
//! Resurrected from the retired core's `terminal/error.rs`, which the Swift `SlopDeskError` has
//! tracked ever since. The VARIANT is the contract callers branch on; the `FrameTooLarge` length
//! and the `MalformedBody` hint are diagnostics and are not part of the wire format.

use core::fmt;

/// A fault raised while decoding a terminal-path wire frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireError {
    /// A frame's length prefix exceeded [`crate::MAX_FRAME_PAYLOAD_LENGTH`].
    ///
    /// Carries the offending claimed payload length.
    FrameTooLarge(usize),

    /// A complete frame's body was shorter than its message type requires — an `exit` whose
    /// payload is under 4 bytes, say. Distinct from a partial TCP read, which is not an error.
    Truncated,

    /// The frame's first byte was not a recognised message type.
    ///
    /// Carries the unknown type byte. A peer that meets a type it does not know DROPS the frame;
    /// that is what makes a new type additive within wire version 1.
    UnknownMessageType(u8),

    /// A body had the right length but malformed contents.
    ///
    /// Carries a short human-readable reason, for logs only.
    MalformedBody(String),
}

impl WireError {
    /// Builds a [`WireError::MalformedBody`] from any displayable hint.
    pub fn malformed(hint: impl Into<String>) -> Self {
        Self::MalformedBody(hint.into())
    }
}

impl fmt::Display for WireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::FrameTooLarge(len) => write!(f, "frame too large: {len}"),
            Self::Truncated => f.write_str("truncated"),
            Self::UnknownMessageType(byte) => write!(f, "unknown message type: {byte}"),
            Self::MalformedBody(hint) => write!(f, "malformed body: {hint}"),
        }
    }
}

impl std::error::Error for WireError {}

/// Result alias for the codecs in this crate.
pub type Result<T> = core::result::Result<T, WireError>;
