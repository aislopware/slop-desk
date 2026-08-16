//! The receive state machine for one connection: decoded requests in, effects out.
//!
//! It owns no socket and no filesystem, which is what makes every protocol rule here testable
//! without either. The server executes the effects in the order they are emitted; the impure edges
//! (the TCP stream, the temp files) are its job.
//!
//! Validate-then-drop throughout: a chunk before its offer, a body overrunning the offered size, an
//! over-cap offer, a duplicate id, or an unsanitisable name each produce a `failed` reply plus an
//! abort of whatever partial state exists — never a trap, never an unbounded allocation.

use std::collections::HashMap;

use crate::name::sanitize;
use crate::protocol::{MAX_TRANSFER_BYTES, Reply, Request, VERSION};

/// What the machine asks the server to do, in emission order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    /// Open a destination (create the temp file).
    Open {
        /// Which transfer.
        transfer_id: u32,
        /// The SANITISED leaf name.
        name: String,
    },
    /// Append bytes to the destination.
    Write {
        /// Which transfer.
        transfer_id: u32,
        /// The body bytes.
        data: Vec<u8>,
    },
    /// The body is complete — move the temp file into place.
    Finalize {
        /// Which transfer.
        transfer_id: u32,
    },
    /// Discard any partial destination.
    Abort {
        /// Which transfer.
        transfer_id: u32,
    },
    /// Send this back to the client.
    Send(Reply),
}

/// One transfer between its accepted offer and its finish.
#[derive(Debug)]
struct Transfer {
    expected_size: u64,
    received_bytes: u64,
}

/// The per-connection machine.
#[derive(Debug, Default)]
pub struct ReceiveLogic {
    /// Whether the version handshake completed. An offer before it is refused rather than served.
    did_hello: bool,
    transfers: HashMap<u32, Transfer>,
}

impl ReceiveLogic {
    /// A machine that has not yet been greeted.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Advances the machine for one request, returning the effects to execute in order.
    pub fn handle(&mut self, request: Request) -> Vec<Effect> {
        match request {
            Request::Hello { version } => {
                let accepted = version == VERSION;
                self.did_hello = accepted;
                vec![Effect::Send(Reply::HelloAck { accepted })]
            },
            Request::Offer {
                transfer_id,
                file_size,
                name,
            } => self.offer(transfer_id, file_size, &name),
            Request::Chunk { transfer_id, data } => self.chunk(transfer_id, data),
            Request::Finish { transfer_id } => self.finish(transfer_id),
            Request::Cancel { transfer_id } => {
                if self.transfers.remove(&transfer_id).is_none() {
                    return Vec::new();
                }
                vec![Effect::Abort { transfer_id }]
            },
            // Decoded, then ignored — see `Request::HostBound`.
            Request::HostBound => Vec::new(),
        }
    }

    fn offer(&mut self, transfer_id: u32, file_size: u64, name: &str) -> Vec<Effect> {
        if !self.did_hello {
            return vec![Self::failed(transfer_id, "no handshake")];
        }
        if self.transfers.contains_key(&transfer_id) {
            return vec![Self::failed(transfer_id, "duplicate transfer id")];
        }
        if file_size > MAX_TRANSFER_BYTES {
            return vec![Self::failed(transfer_id, "file too large")];
        }
        let Some(safe_name) = sanitize(name) else {
            return vec![Self::failed(transfer_id, "invalid file name")];
        };
        self.transfers.insert(transfer_id, Transfer {
            expected_size: file_size,
            received_bytes: 0,
        });
        vec![
            Effect::Open {
                transfer_id,
                name: safe_name,
            },
            Effect::Send(Reply::Accept { transfer_id }),
        ]
    }

    fn chunk(&mut self, transfer_id: u32, data: Vec<u8>) -> Vec<Effect> {
        let Some(transfer) = self.transfers.get_mut(&transfer_id) else {
            // A chunk with no live offer: nothing to abort, just refuse it.
            return vec![Self::failed(transfer_id, "no such transfer")];
        };
        // Saturating rather than wrapping: the comparison below is the check, and an addition that
        // wrapped would turn an overrun into an accepted write.
        let total = transfer.received_bytes.saturating_add(data.len() as u64);
        if total > transfer.expected_size {
            self.transfers.remove(&transfer_id);
            return vec![
                Effect::Abort { transfer_id },
                Self::failed(transfer_id, "body exceeds offered size"),
            ];
        }
        transfer.received_bytes = total;
        vec![Effect::Write { transfer_id, data }]
    }

    fn finish(&mut self, transfer_id: u32) -> Vec<Effect> {
        let Some(transfer) = self.transfers.remove(&transfer_id) else {
            return vec![Self::failed(transfer_id, "no such transfer")];
        };
        if transfer.received_bytes == transfer.expected_size {
            return vec![
                Effect::Finalize { transfer_id },
                Effect::Send(Reply::Complete { transfer_id }),
            ];
        }
        vec![
            Effect::Abort { transfer_id },
            Self::failed(transfer_id, "incomplete body"),
        ]
    }

    fn failed(transfer_id: u32, reason: &str) -> Effect {
        Effect::Send(Reply::Failed {
            transfer_id,
            reason: reason.to_owned(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{Effect, ReceiveLogic};
    use crate::protocol::{MAX_TRANSFER_BYTES, Reply, Request, VERSION};

    fn greeted() -> ReceiveLogic {
        let mut logic = ReceiveLogic::new();
        let effects = logic.handle(Request::Hello { version: VERSION });
        assert_eq!(effects, vec![Effect::Send(Reply::HelloAck { accepted: true })]);
        logic
    }

    fn offer(logic: &mut ReceiveLogic, id: u32, size: u64, name: &str) -> Vec<Effect> {
        logic.handle(Request::Offer {
            transfer_id: id,
            file_size: size,
            name: name.to_owned(),
        })
    }

    #[test]
    fn a_wrong_version_is_refused_and_leaves_the_machine_ungreeted() {
        let mut logic = ReceiveLogic::new();
        assert_eq!(logic.handle(Request::Hello { version: VERSION + 1 }), vec![
            Effect::Send(Reply::HelloAck { accepted: false })
        ]);
        assert_eq!(offer(&mut logic, 1, 4, "a.txt"), vec![Effect::Send(
            Reply::Failed {
                transfer_id: 1,
                reason: "no handshake".to_owned(),
            }
        )]);
    }

    #[test]
    fn the_happy_path_opens_accepts_writes_finalizes_and_completes() {
        let mut logic = greeted();
        assert_eq!(
            offer(&mut logic, 1, 5, "dir/a.txt"),
            vec![
                Effect::Open {
                    transfer_id: 1,
                    name: "a.txt".to_owned(),
                },
                Effect::Send(Reply::Accept { transfer_id: 1 }),
            ],
            "the name reaching the sink is the sanitised leaf, never the client's spelling"
        );
        assert_eq!(
            logic.handle(Request::Chunk {
                transfer_id: 1,
                data: b"hello".to_vec(),
            }),
            vec![Effect::Write {
                transfer_id: 1,
                data: b"hello".to_vec(),
            }]
        );
        assert_eq!(logic.handle(Request::Finish { transfer_id: 1 }), vec![
            Effect::Finalize { transfer_id: 1 },
            Effect::Send(Reply::Complete { transfer_id: 1 }),
        ]);
    }

    #[test]
    fn a_body_longer_than_its_offer_aborts_rather_than_writing() {
        let mut logic = greeted();
        drop(offer(&mut logic, 1, 2, "a.txt"));
        assert_eq!(
            logic.handle(Request::Chunk {
                transfer_id: 1,
                data: b"far too much".to_vec(),
            }),
            vec![
                Effect::Abort { transfer_id: 1 },
                Effect::Send(Reply::Failed {
                    transfer_id: 1,
                    reason: "body exceeds offered size".to_owned(),
                }),
            ]
        );
        // ...and the transfer is gone, so a follow-up chunk is not silently accepted either.
        assert_eq!(
            logic.handle(Request::Chunk {
                transfer_id: 1,
                data: b"x".to_vec(),
            }),
            vec![Effect::Send(Reply::Failed {
                transfer_id: 1,
                reason: "no such transfer".to_owned(),
            })]
        );
    }

    #[test]
    fn a_short_body_at_finish_aborts_rather_than_finalizing() {
        let mut logic = greeted();
        drop(offer(&mut logic, 1, 10, "a.txt"));
        drop(logic.handle(Request::Chunk {
            transfer_id: 1,
            data: b"four".to_vec(),
        }));
        assert_eq!(logic.handle(Request::Finish { transfer_id: 1 }), vec![
            Effect::Abort { transfer_id: 1 },
            Effect::Send(Reply::Failed {
                transfer_id: 1,
                reason: "incomplete body".to_owned(),
            }),
        ]);
    }

    #[test]
    fn a_duplicate_id_an_oversized_offer_and_a_bad_name_are_each_refused() {
        let mut logic = greeted();
        drop(offer(&mut logic, 1, 1, "a.txt"));
        assert_eq!(offer(&mut logic, 1, 1, "b.txt"), vec![Effect::Send(
            Reply::Failed {
                transfer_id: 1,
                reason: "duplicate transfer id".to_owned(),
            }
        )]);
        assert_eq!(offer(&mut logic, 2, MAX_TRANSFER_BYTES + 1, "big.bin"), vec![
            Effect::Send(Reply::Failed {
                transfer_id: 2,
                reason: "file too large".to_owned(),
            })
        ]);
        assert_eq!(offer(&mut logic, 3, 1, "../.."), vec![Effect::Send(
            Reply::Failed {
                transfer_id: 3,
                reason: "invalid file name".to_owned(),
            }
        )]);
    }

    #[test]
    fn a_cancel_aborts_a_live_transfer_and_says_nothing_about_an_unknown_one() {
        let mut logic = greeted();
        drop(offer(&mut logic, 1, 4, "a.txt"));
        assert_eq!(logic.handle(Request::Cancel { transfer_id: 1 }), vec![
            Effect::Abort { transfer_id: 1 }
        ]);
        assert_eq!(logic.handle(Request::Cancel { transfer_id: 99 }), Vec::new());
    }

    #[test]
    fn two_transfers_interleave_without_touching_each_other() {
        let mut logic = greeted();
        drop(offer(&mut logic, 1, 3, "a.txt"));
        drop(offer(&mut logic, 2, 3, "b.txt"));
        drop(logic.handle(Request::Chunk {
            transfer_id: 1,
            data: b"aaa".to_vec(),
        }));
        drop(logic.handle(Request::Chunk {
            transfer_id: 2,
            data: b"bb".to_vec(),
        }));
        assert_eq!(logic.handle(Request::Finish { transfer_id: 1 }), vec![
            Effect::Finalize { transfer_id: 1 },
            Effect::Send(Reply::Complete { transfer_id: 1 }),
        ]);
        assert_eq!(logic.handle(Request::Finish { transfer_id: 2 }), vec![
            Effect::Abort { transfer_id: 2 },
            Effect::Send(Reply::Failed {
                transfer_id: 2,
                reason: "incomplete body".to_owned(),
            }),
        ]);
    }

    #[test]
    fn a_zero_byte_file_completes_without_a_single_chunk() {
        let mut logic = greeted();
        drop(offer(&mut logic, 1, 0, "empty.txt"));
        assert_eq!(logic.handle(Request::Finish { transfer_id: 1 }), vec![
            Effect::Finalize { transfer_id: 1 },
            Effect::Send(Reply::Complete { transfer_id: 1 }),
        ]);
    }
}
