//! The two escapings a terminal writes a path or a command line in, inverted.
//!
//! Both are byte scanners over text a foreign program chose, which is why they live beside
//! [`vtscan`](crate::vtscan) and [`width`](crate::width) rather than in whichever caller reached
//! for them first. Each had TWO implementations before this module existed:
//!
//! - `\xNN` — the shell shim's escaping of `;`, `\`, ESC, BEL, CR and LF inside an OSC `133;E`
//!   command field, spelled once in [`distill`](crate::distill) and once in superd's block
//!   segmenter, one with `(high << 4) | low` and the other with `high * 16 + low`.
//! - `%NN` — percent-encoding, in superd's OSC 7 / OSC 99 reader and in the client's link scanner,
//!   byte-for-byte identical apart from the name of the nibble helper.
//!
//! ## Why not the `percent-encoding` crate
//!
//! It is LENIENT by design: a malformed `%ZZ` survives as literal text and the decode cannot fail.
//! Both call sites here refuse malformed input on purpose — one feeds a desktop alert, the other a
//! path the user is invited to click — and "this was not percent-encoded after all" is a different
//! answer from "this is half-decoded". A crate that cannot express the requirement is not the wheel
//! that was about to be reinvented.

/// One hex character's value.
///
/// `char::to_digit` rather than a match over three ranges, which is what all three copies of this
/// spelled out: the standard library already knows what a hex digit is worth.
#[must_use]
pub fn hex_nibble(byte: u8) -> Option<u8> {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "a radix-16 digit's value is 0..=15, which the `to_digit` bound guarantees"
    )]
    let nibble = char::from(byte).to_digit(16)? as u8;
    Some(nibble)
}

/// Two hex characters as the byte they spell, or `None` if either is not a hex digit.
#[must_use]
pub fn hex_byte(high: u8, low: u8) -> Option<u8> {
    Some((hex_nibble(high)? << 4) | hex_nibble(low)?)
}

/// Inverts the shell shim's `\xNN` escaping of `;`, `\`, ESC, BEL, CR and LF.
///
/// The shim escapes exactly those six, so the field carries no separator or terminator byte and
/// inverting it recovers the command exactly; multi-byte UTF-8 rides through untouched, since none
/// of its bytes are in the escaped set. A `\` not followed by `xHH` is emitted LITERALLY — the shim
/// never writes one, but a hostile stream might, and dropping it would let a crafted field shorten
/// the command a person is shown.
#[must_use]
pub fn unescape_command(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        let escaped = (byte == b'\\' && bytes.get(index + 1) == Some(&b'x'))
            .then(|| hex_byte(bytes.get(index + 2).copied()?, bytes.get(index + 3).copied()?))
            .flatten();
        if let Some(value) = escaped {
            out.push(value);
            index += 4;
        } else {
            out.push(byte);
            index += 1;
        }
    }
    out
}

/// Percent-decodes `text`, or `None` if an escape is malformed or the bytes are not UTF-8.
///
/// All-or-nothing on purpose, which is the contract the Foundation call this replaces had: a caller
/// that falls back to the undecoded text is then saying "this was not percent-encoded after all",
/// not "here is half of it".
#[must_use]
pub fn percent_decoded(text: &str) -> Option<String> {
    if !text.contains('%') {
        return Some(text.to_owned());
    }
    let bytes = text.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        if byte == b'%' {
            decoded.push(hex_byte(
                bytes.get(index + 1).copied()?,
                bytes.get(index + 2).copied()?,
            )?);
            index += 3;
        } else {
            decoded.push(byte);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

#[cfg(test)]
mod tests {
    use super::{hex_byte, hex_nibble, percent_decoded, unescape_command};

    #[test]
    fn a_hex_digit_is_worth_what_the_standard_library_says() {
        assert_eq!(hex_nibble(b'0'), Some(0));
        assert_eq!(hex_nibble(b'9'), Some(9));
        assert_eq!(hex_nibble(b'a'), Some(10));
        assert_eq!(hex_nibble(b'F'), Some(15));
        assert_eq!(hex_nibble(b'g'), None);
        assert_eq!(hex_nibble(b' '), None);
        assert_eq!(hex_byte(b'4', b'1'), Some(b'A'));
        assert_eq!(hex_byte(b'4', b'z'), None);
    }

    #[test]
    fn the_shims_escaping_round_trips_and_a_stray_backslash_survives() {
        assert_eq!(unescape_command(b"git commit -m \\x3b ok"), b"git commit -m ; ok");
        assert_eq!(unescape_command(b"a\\x5cb"), b"a\\b");
        // Multi-byte UTF-8 has no byte in the escaped set, so it rides through.
        assert_eq!(unescape_command("echo é".as_bytes()), "echo é".as_bytes());
        // A `\` the shim would never write is emitted literally rather than eating the command.
        assert_eq!(unescape_command(b"a\\xZZb"), b"a\\xZZb");
        assert_eq!(unescape_command(b"trailing\\x4"), b"trailing\\x4");
    }

    #[test]
    fn percent_decoding_is_all_or_nothing() {
        assert_eq!(percent_decoded("/plain/path"), Some("/plain/path".to_owned()));
        assert_eq!(
            percent_decoded("/Users/me/My%20Project"),
            Some("/Users/me/My Project".to_owned())
        );
        assert_eq!(percent_decoded("%ZZ"), None, "a malformed escape refuses");
        assert_eq!(percent_decoded("%4"), None, "a truncated escape refuses");
        assert_eq!(percent_decoded("%FF"), None, "not UTF-8 once decoded");
    }
}
