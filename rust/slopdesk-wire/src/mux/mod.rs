//! The TCP mux layer: the envelope that carries many logical channels over one connection, its
//! streaming decoder, the channel table, and per-channel credit flow control.
//!
//! This is stage 2 of moving `slopdesk-hostd` off Swift. Stage 1 was the inner
//! [`WireMessage`](crate::WireMessage) codec; this is the OUTER frame that carries it, so the two
//! together are everything a peer has to speak before any host service can be moved.
//!
//! ## The two framing layers
//! ```text
//! [u32 mux_len][u32 channel_id][u8 mux_type][ [u32 payload_len][u8 msg_type][body…] ]
//! \___________________ MuxFrame ___________________/\_____________ WireMessage ______/
//! ```
//! The inner frame is carried OPAQUELY: [`MuxFrame::ChannelData`] holds bytes, and nothing in this
//! module parses them. That is what lets one connection route pane channels and the workspace
//! document without either knowing the other exists.
//!
//! ## The three questions about one frame
//! [`admission`] answers whether the connection reasons about the frame at all, [`channels`]
//! answers where it goes, and [`admission`] again answers what a channel's ENDING reaches — the two
//! sub-channels a pane rides on and the two tables behind them. They are kept apart from the
//! envelope and the decoder for the reason below: none of the three touches a byte of payload.
//!
//! ## What is here and what is not
//! Everything in this module is a pure function of its inputs — no socket, no clock, no thread. The
//! parts that need those (the router, the send gate, the relay) are the caller's, and they are why
//! [`ChannelTable`] and the three flow-control policies are separated out at all: each is the
//! DECISION without the machinery, so it can be driven from a test instead of from a network.
//!
//! ## Parity
//! `tests/golden_vectors.rs` pins all twelve `muxEnvelopes` vectors from the committed corpus,
//! field-by-field in both directions. That corpus is generated from the Swift codec and predates
//! this module.

pub mod admission;
pub mod channels;
pub mod decoder;
pub mod envelope;
pub mod flow;

pub use channels::{ChannelState, ChannelTable, DropReason, FrameKind, RoutingDecision};
pub use decoder::MuxFrameDecoder;
pub use envelope::{MIN_MUX_FRAME_LENGTH, MuxCloseReason, MuxFrame, MuxFrameType, PREFIX_LENGTH};
pub use flow::{
    BoundedQueuePolicy, ConsumeResult, FlowCreditPolicy, MuxFlowControl, PausableQueueGate,
    ReceiveWindowAccountant,
};

/// What a mux channel is FOR — the `channel_class` byte of a
/// [`ChannelOpen`](MuxFrame::ChannelOpen).
///
/// The field has been encoded, decoded and golden-pinned since the mux landed, and read nowhere.
/// That made it a free seam: the workspace document rides an ordinary open with a different class
/// byte, so no envelope changed shape and no existing client noticed.
///
/// An unknown class from a newer peer is refused with `accepted: false`, never guessed at — which
/// is why [`MuxFrame::ChannelOpen`] carries the raw byte rather than this enum. Guessing would
/// route a workspace channel into the PTY spawn path and fork a shell nobody asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MuxChannelClass {
    /// The PTY channel. One shell per session id; a second open on a live one JOINS it.
    Pane = 0,
    /// The workspace-document channel: at most ONE per mux connection, CONTROL sub-channel only
    /// (the DATA sub-channel the open also creates stays idle).
    Workspace = 1,
    // 2 is spoken for and served by nobody: a peer that sends it is refused like any other class
    // this host does not route. The next class to land takes 3, so one byte never names two things.
}

impl MuxChannelClass {
    /// The class for `byte`, or `None` when this build routes nothing under it.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Pane),
            1 => Some(Self::Workspace),
            _ => None,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

#[cfg(test)]
mod tests {
    use super::MuxChannelClass;

    #[test]
    fn the_two_routed_classes_round_trip() {
        for class in [MuxChannelClass::Pane, MuxChannelClass::Workspace] {
            assert_eq!(MuxChannelClass::from_byte(class.as_byte()), Some(class));
        }
    }

    #[test]
    fn a_class_nobody_routes_is_none_rather_than_a_guess() {
        // Including 2, which is reserved and served by nobody. Guessing would fork a shell for a
        // channel that asked for a document.
        for byte in [2_u8, 3, 0xFF] {
            assert_eq!(MuxChannelClass::from_byte(byte), None);
        }
    }
}
