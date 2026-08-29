//! Which UI half draws a row.
//!
//! Two tables in this crate answer the same question about their own rows — [`crate::bindings`]
//! for a chord, [`crate::palette_rows`] for a palette verb — and both need the same three-valued
//! answer, so it is spelled once here.
//!
//! It used to live beside the settings page table, which was the only other table asking. That
//! table is gone (settings are a FILE now, with no window to lay out), and the question outlived
//! it: a chord that resolves to a macOS-only action must not be bound on a phone whether or not
//! anything draws a settings row for it.
//!
//! GOLDEN-SAFE: metadata only. Nothing here reads or writes a value or touches a wire codec.

/// Which half of the client a row belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    /// Drawn by both halves.
    Both,
    /// macOS only — the backing API does not exist on iOS.
    Mac,
    /// iOS only.
    Phone,
}

impl Platform {
    /// Whether a half that identifies as `mac` draws this.
    #[must_use]
    pub const fn shown_on(self, mac: bool) -> bool {
        match self {
            Self::Both => true,
            Self::Mac => mac,
            Self::Phone => !mac,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Platform;

    #[test]
    fn each_half_is_shown_exactly_what_it_owns_plus_everything_shared() {
        assert!(Platform::Both.shown_on(true) && Platform::Both.shown_on(false));
        assert!(Platform::Mac.shown_on(true) && !Platform::Mac.shown_on(false));
        assert!(!Platform::Phone.shown_on(true) && Platform::Phone.shown_on(false));
    }
}
