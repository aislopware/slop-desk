//! The simulator's transport: RFC 6455 over a plain TCP socket.
//!
//! Split three ways on purpose. [`handshake`] and [`frame`] are pure and hold every rule the
//! protocol has; [`lane`] is the socket and the thread. A websocket bug is a framing bug about nine
//! times in ten, and none of those nine needs a server to reproduce.

pub mod frame;
pub mod handshake;
pub mod lane;
