//! The one way this crate turns a set of files into a stamp.
//!
//! Two gates want the same number for different reasons — [`super::stamp`] decides whether an
//! Xcode build is warm, [`super::ffi`] whether the xcframework is — and they were computing it with
//! the same four lines each. One spelling of "hash each file, fold its hex and its path into an
//! outer hash" is what keeps the two stamps comparable: a change to the framing in one place would
//! silently make the other gate's cache answer a different question.
//!
//! The hex is written out a nibble at a time rather than through `{:x}`. `sha2` 0.11 answers an
//! `Array` that does not implement `LowerHex`, and a formatter that only exists on some versions of
//! a dependency is a formatter this crate should not depend on.

use sha2::{Digest, Sha256};

/// Lower-case hex, two digits a byte.
#[must_use]
pub fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(nibble(byte >> 4));
        out.push(nibble(byte & 0x0F));
    }
    out
}

/// One hex digit for the low four bits of `value`.
const fn nibble(value: u8) -> char {
    match value & 0x0F {
        0..=9 => (b'0' + value) as char,
        other => (b'a' + other - 10) as char,
    }
}

/// A stamp over a list of files, built one at a time.
///
/// The framing is `sha256sum`'s — `<hex>  <path>\n` per file, hashed again — so a stamp can be
/// eyeballed against the tool every developer already has, and so a file that MOVED changes the
/// stamp even when its bytes did not.
#[derive(Debug)]
pub struct TreeStamp {
    outer: Sha256,
}

impl Default for TreeStamp {
    fn default() -> Self {
        Self::new()
    }
}

impl TreeStamp {
    /// An empty stamp.
    #[must_use]
    pub fn new() -> Self {
        Self { outer: Sha256::new() }
    }

    /// Folds one file in, under the path the caller names it by.
    pub fn push(&mut self, path: &str, bytes: &[u8]) {
        let mut inner = Sha256::new();
        inner.update(bytes);
        self.outer.update(hex(&inner.finalize()));
        self.outer.update("  ");
        self.outer.update(path);
        self.outer.update("\n");
    }

    /// The stamp.
    #[must_use]
    pub fn finish(self) -> String {
        hex(&self.outer.finalize())
    }
}

#[cfg(test)]
mod tests {
    use super::{TreeStamp, hex};

    #[test]
    fn hex_is_lower_case_and_two_digits_a_byte() {
        assert_eq!(hex(&[0x00, 0x0F, 0xA5, 0xFF]), "000fa5ff");
        assert_eq!(hex(&[]), "");
    }

    #[test]
    fn the_stamp_reads_the_path_as_well_as_the_bytes() {
        let mut moved = TreeStamp::new();
        moved.push("b.rs", b"same bytes");

        let mut stayed = TreeStamp::new();
        stayed.push("a.rs", b"same bytes");

        assert_ne!(
            moved.finish(),
            stayed.finish(),
            "a file that moved has to invalidate the cache it was hashed into"
        );
    }

    #[test]
    fn the_stamp_is_stable_and_the_order_is_part_of_it() {
        let stamp = |order: [(&str, &[u8]); 2]| {
            let mut out = TreeStamp::new();
            for (path, bytes) in order {
                out.push(path, bytes);
            }
            out.finish()
        };

        let forwards = stamp([("a", b"one"), ("b", b"two")]);
        assert_eq!(forwards, stamp([("a", b"one"), ("b", b"two")]));
        assert_ne!(forwards, stamp([("b", b"two"), ("a", b"one")]));
        assert_eq!(forwards.len(), 64);
    }
}
