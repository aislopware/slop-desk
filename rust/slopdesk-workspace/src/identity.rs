//! The identities of the session → tab → pane hierarchy.
//!
//! Each is a newtype over the sixteen bytes of a UUID, so a value crosses to
//! [`slopdesk-wire`](https://docs.rs/slopdesk-wire)'s `RawUuid` with no conversion and no allocation.
//! They are distinct types rather than one alias because passing a tab id where a pane id belongs
//! is the kind of mistake a workspace document should not be able to express.
//!
//! ## Nothing here mints
//!
//! There is no `new()` that invents an identity. This crate has no clock and no randomness — every
//! operation that needs a fresh id takes it as an argument, and the runtime that owns the entropy
//! supplies it. That is the same line the video crate's lane allocator draws, and it is what keeps
//! every function here replayable: the same inputs give the same tree, forever.
//!
//! The byte order is the UUID's own, so the derived [`Ord`] is the lexicographic order of the
//! canonical string form. Anything sorted by an id is therefore sorted the same way on both sides
//! of the wire.

macro_rules! identity {
    ($(#[$meta:meta])* $name:ident, $what:literal) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct $name([u8; 16]);

        impl $name {
            #[doc = concat!("The ", $what, " named by these sixteen UUID bytes.")]
            #[must_use]
            pub const fn from_bytes(raw: [u8; 16]) -> Self {
                Self(raw)
            }

            #[doc = concat!("The sixteen UUID bytes naming this ", $what, ".")]
            #[must_use]
            pub const fn bytes(self) -> [u8; 16] {
                self.0
            }

        }
    };
}

/// Sixteen bytes as canonical hyphenated UUID text, UPPERCASE.
///
/// Uppercase because that is what Swift's `uuidString` wrote, and every persisted file already on
/// disk carries that form. The parser below takes either case, so the choice only decides what NEW
/// files look like — but a save that rewrote every id to lowercase would land as a whole-file diff
/// saying nothing changed.
#[must_use]
pub fn uuid_text(raw: [u8; 16]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789ABCDEF";
    let digit = |nibble: u8| char::from(DIGITS.get(usize::from(nibble)).copied().unwrap_or(b'0'));
    let mut out = String::with_capacity(36);
    for (index, byte) in raw.into_iter().enumerate() {
        if matches!(index, 4 | 6 | 8 | 10) {
            out.push('-');
        }
        out.push(digit(byte >> 4));
        out.push(digit(byte & 0x0F));
    }
    out
}

/// Parses either case of the hyphenated form.
///
/// `None` for anything else — a wrong length, a stray character, a hyphen out of place. Strict
/// rather than lenient because the id is a JOIN KEY: a near-miss that parsed would silently point a
/// restored layout at a pane that is not the one it named.
#[must_use]
pub fn parse_uuid(text: &str) -> Option<[u8; 16]> {
    if text.len() != 36 {
        return None;
    }
    let mut digits = [0_u8; 32];
    let mut filled = 0;
    for (index, character) in text.chars().enumerate() {
        if character == '-' {
            if !matches!(index, 8 | 13 | 18 | 23) {
                return None;
            }
            continue;
        }
        let value = character.to_digit(16)?;
        let slot = digits.get_mut(filled)?;
        *slot = u8::try_from(value).ok()?;
        filled += 1;
    }
    if filled != 32 {
        return None;
    }
    let mut out = [0_u8; 16];
    for (byte, &[high, low]) in out.iter_mut().zip(digits.as_chunks::<2>().0) {
        *byte = (high << 4) | low;
    }
    Some(out)
}

identity!(
    /// A pane — one terminal, one video surface, one panel — and the join to the live-session
    /// registry that owns its process.
    PaneId,
    "pane"
);

identity!(
    /// A tab: one tiled split tree inside a session.
    TabId,
    "tab"
);

identity!(
    /// A session: a named, host-scoped group of tabs.
    SessionId,
    "session"
);

identity!(
    /// A named launch configuration — a command and the panes it opens into.
    LaunchPresetId,
    "launch preset"
);

identity!(
    /// A named project profile: a whole session's layout, with each pane's launch intent.
    SessionTemplateId,
    "template"
);

identity!(
    /// An interior split node.
    ///
    /// Unlike a [`PaneId`] this joins to nothing outside the tree — it names a DIVIDER GROUP, so a
    /// resize can target one split without an ambiguous path through the tree, and a saved divider
    /// position still refers to the same seam after a restore.
    SplitNodeId,
    "split"
);

/// Where a fresh identity comes from.
///
/// This crate has no clock and no randomness, and [the module header](self) says why: every
/// operation here has to be replayable. An op that needs a new pane, tab, session or split takes
/// this instead, and the runtime that owns the entropy supplies it. A test supplies a counter and
/// gets the same tree every run.
pub trait IdSource {
    /// A fresh pane identity.
    fn pane(&mut self) -> PaneId;
    /// A fresh tab identity.
    fn tab(&mut self) -> TabId;
    /// A fresh session identity.
    fn session(&mut self) -> SessionId;
    /// A fresh split identity.
    fn split(&mut self) -> SplitNodeId;
}

#[cfg(test)]
mod tests {
    use super::{PaneId, SplitNodeId, parse_uuid, uuid_text};

    #[test]
    fn sixteen_bytes_become_the_canonical_uppercase_text() {
        let raw = [
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0, 1, 2, 3, 4, 5, 6, 7,
        ];
        assert_eq!(uuid_text(raw), "01234567-89AB-CDEF-0001-020304050607");
    }

    #[test]
    fn a_near_miss_is_refused_rather_than_pointed_at_the_wrong_pane() {
        for hostile in [
            "",
            "0123456789ABCDEF0001020304050607",
            "01234567-89AB-CDEF-0001-02030405060",
            "01234567-89AB-CDEF-0001-0203040506078",
            "0123456-789AB-CDEF-0001-0203040506070",
            "0123456g-89AB-CDEF-0001-020304050607",
        ] {
            assert_eq!(parse_uuid(hostile), None, "{hostile:?} is not a uuid");
        }
    }

    #[test]
    fn the_byte_order_is_the_sort_order() {
        let mut ids = [
            PaneId::from_bytes([2; 16]),
            PaneId::from_bytes([0; 16]),
            PaneId::from_bytes([1; 16]),
        ];
        ids.sort_unstable();
        assert_eq!(ids[0], PaneId::from_bytes([0; 16]));
        assert_eq!(ids[2], PaneId::from_bytes([2; 16]));
    }

    #[test]
    fn the_bytes_survive_the_round_trip_untouched() {
        let raw = [9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 10, 11, 12, 13, 14, 15];
        assert_eq!(SplitNodeId::from_bytes(raw).bytes(), raw);
    }
}
