//! The two `OSStatus` codes both halves of this crate speak, on every Apple slice.
//!
//! They live apart from either session module because the crate's two framework areas are gated
//! differently — compression is the host's and macOS-only, decompression is every client's — and a
//! constant that both use cannot sit in the narrower one. `session.rs` keeps the code that is only
//! the encoder's: [`crate::XPC_CREATE_RACE`] names an encoder-service restart and has no decode
//! counterpart.

/// `noErr` — the framework's success code, which every call in this crate compares against.
pub const NO_ERR: i32 = 0;

/// `kVTInvalidSessionErr` — what a caller gets when it asks a session that was never created.
///
/// Also what this crate reports for a refusal it makes on the framework's behalf: an empty
/// parameter set, a create that answered success and wrote no pointer, a decode that reported
/// success and emitted no image. In each the caller's situation is the same as a stale session's —
/// there is nothing to decode against — and inventing a second code would only ask the caller to
/// handle two.
pub const INVALID_SESSION: i32 = -12903;
