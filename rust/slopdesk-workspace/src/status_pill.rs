//! The pane's top-trailing status chips: which of them are up, in what order, and what each says.
//!
//! Three pills were ONE shape spelled three times — a lock chip, a secure-input chip and a
//! sync-input chip differing in a word, two sentences of accessibility copy, whether they carry an
//! `×`, and whether their plate is the chrome surface or a fixed vivid tone. Everything else about
//! them agreed, which is what made the drift between them invisible.
//!
//! ## The fill is a KIND, never a colour
//!
//! What crosses is "the chrome plate with its hairline" or "a fixed, theme-independent tone with no
//! border", and each renderer resolves that to its own `Color` / `NSColor`. Not a formality: the
//! POINT of the two vivid pills is that their tone is theme-INDEPENDENT — the shipped themes have
//! `info == accent`, so a security badge derived from the palette goes invisible against the accent
//! — and a decision recorded as a colour literal could not SAY that, only be it.
//!
//! ## The order is a LIST, not a stack of `if`s in a view body
//!
//! The four gates used to live inside `TerminalLeafView`'s body, where only one of the two UI
//! halves can reach them; an `AppKit` column would have re-derived "read-only hides under vi,
//! secure input hides under read-only, sync input hides under nothing" from the same prose and been
//! right by luck. [`visible`] answers it as a SET whose iteration order IS the top-down stacking
//! order, so the two halves cannot stack one order and gate another.

/// The theme-independent tones the vivid pills wear. Named, never valued — see the module header.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Ink {
    /// The fixed security blue. A SAFETY signal that must never collapse into the theme accent.
    Security,
    /// The fixed sync amber. A mode this dangerous never blends with the chrome.
    Sync,
}

/// How a pill's plate is drawn.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Fill {
    /// The chrome plate: the raised surface plus a subtle hairline. It BLENDS with the chrome
    /// rather than standing out — `readonly-mode.png`'s "bordered or subtly filled chip rather
    /// than a brightly coloured badge".
    Chrome,
    /// A fixed vivid tone and NO border: the fill is loud enough that a hairline would only muddy
    /// it.
    Fixed(Ink),
}

impl Fill {
    /// The discriminant a renderer switches on: `0` chrome, `1` security, `2` sync.
    ///
    /// One scalar rather than a pair because the three plates are three drawing routines on both
    /// halves, and a nested `(kind, ink)` would let a caller ask for the chrome plate in the sync
    /// tone — a state neither renderer has.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Chrome => 0,
            Self::Fixed(Ink::Security) => 1,
            Self::Fixed(Ink::Sync) => 2,
        }
    }
}

/// One pane status chip.
///
/// The vi/copy-mode pill is deliberately NOT a case here: its label is the MODEL's
/// (`VI` / `VISUAL` / `VISUAL LINE` / `VISUAL BLOCK`, plus a live repeat count), so it is a reading
/// of pane state rather than a constant, and it lives with the rest of vi mode in
/// [`crate::vi_hints`]. Its PLACE in the stack is still decided here — see [`shows_vi_mode_pill`].
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Pill {
    /// The pane's input gate is armed.
    ReadOnly,
    /// macOS Secure Keyboard Entry is active for this pane.
    SecureInput,
    /// The pane's tab mirrors keystrokes into its siblings.
    SyncInput,
}

impl Pill {
    /// Every chip, in the order they stack top-down. The iteration order IS the drawn order.
    pub const ALL: [Self; 3] = [Self::ReadOnly, Self::SecureInput, Self::SyncInput];

    /// The chip at `index` in [`ALL`](Self::ALL), or `None` past the end.
    #[must_use]
    pub const fn from_index(index: u8) -> Option<Self> {
        match index {
            0 => Some(Self::ReadOnly),
            1 => Some(Self::SecureInput),
            2 => Some(Self::SyncInput),
            _ => None,
        }
    }

    /// This chip's place in [`ALL`](Self::ALL) — the bit it occupies in [`visible`]'s answer.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::ReadOnly => 0,
            Self::SecureInput => 1,
            Self::SyncInput => 2,
        }
    }

    /// The uppercase word on the chip.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::ReadOnly => "READ ONLY",
            Self::SecureInput => "SECURE INPUT",
            Self::SyncInput => "SYNC INPUT",
        }
    }

    /// What `VoiceOver` reads for the chip itself.
    #[must_use]
    pub const fn accessibility_label(self) -> &'static str {
        match self {
            Self::ReadOnly => "Read only",
            Self::SecureInput => "Secure input",
            Self::SyncInput => "Sync input",
        }
    }

    /// The sentence that says what the mode DOES — the part a badge alone cannot.
    #[must_use]
    pub const fn accessibility_hint(self) -> &'static str {
        match self {
            Self::ReadOnly => "Disable read-only mode to allow input again",
            Self::SecureInput => "Secure keyboard entry is active — other apps cannot read your keystrokes",
            Self::SyncInput => "Keystrokes typed here are mirrored into every other pane in this tab",
        }
    }

    /// The `×` plate's tooltip, or `None` for a pill that carries no `×`.
    ///
    /// Secure input has none, and that is a decision rather than an omission: it is a SAFETY
    /// indicator the user does not dismiss with a click. The auto path clears when the password
    /// prompt ends and the manual path clears from the Edit menu or the palette, so an `×` here
    /// would offer to turn off something this chip does not own.
    #[must_use]
    pub const fn dismiss_help(self) -> Option<&'static str> {
        match self {
            Self::ReadOnly => Some("Disable read-only"),
            Self::SecureInput => None,
            Self::SyncInput => Some("Turn off sync input for this tab"),
        }
    }

    /// Whether the chip carries an `×`. Derived from [`dismiss_help`](Self::dismiss_help), because
    /// a chip that can be dismissed is exactly a chip that has a word for dismissing it.
    #[must_use]
    pub const fn is_dismissible(self) -> bool {
        self.dismiss_help().is_some()
    }

    /// The plate this chip stands on.
    #[must_use]
    pub const fn fill(self) -> Fill {
        match self {
            Self::ReadOnly => Fill::Chrome,
            Self::SecureInput => Fill::Fixed(Ink::Security),
            Self::SyncInput => Fill::Fixed(Ink::Sync),
        }
    }
}

/// Everything the gates read, taken once per render so the decision is pure.
#[expect(
    clippy::struct_excessive_bools,
    reason = "this IS the list of gates a render reads at once; collapsing it into a bitset here would hide \
              that they are independent, and `bits` already offers the packed form for the one place that \
              needs it"
)]
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
pub struct Conditions {
    /// The pane's input gate is armed.
    pub read_only: bool,
    /// The pane is in vi / copy mode.
    pub copy_mode: bool,
    /// Hint mode is armed on top of vi mode.
    pub hint_mode: bool,
    /// macOS Secure Keyboard Entry is active for this pane.
    pub secure_input: bool,
    /// The "Show Secure Input Indicator" setting is on.
    pub secure_input_indicator: bool,
    /// The pane's TAB is armed for synchronized input.
    pub sync_input: bool,
}

impl Conditions {
    /// The six gates read out of one byte, LOW BIT FIRST in declaration order.
    ///
    /// A bitmask rather than six arguments because the whole point of the struct is that the gates
    /// are read ONCE per render: six separate scalars across a boundary would be six chances for a
    /// caller to read the fourth into the fifth's slot, and the compiler could not tell.
    #[must_use]
    pub const fn from_bits(bits: u8) -> Self {
        Self {
            read_only: bits & 1 != 0,
            copy_mode: bits & 2 != 0,
            hint_mode: bits & 4 != 0,
            secure_input: bits & 8 != 0,
            secure_input_indicator: bits & 16 != 0,
            sync_input: bits & 32 != 0,
        }
    }

    /// The inverse of [`from_bits`](Self::from_bits).
    #[must_use]
    pub const fn bits(self) -> u8 {
        let mut bits = 0_u8;
        if self.read_only {
            bits |= 1;
        }
        if self.copy_mode {
            bits |= 2;
        }
        if self.hint_mode {
            bits |= 4;
        }
        if self.secure_input {
            bits |= 8;
        }
        if self.secure_input_indicator {
            bits |= 16;
        }
        if self.sync_input {
            bits |= 32;
        }
        bits
    }
}

/// The chips that are up, as a bitmask over [`Pill::index`] — bit `n` set means chip `n` draws.
///
/// Read low bit first and the mask IS the top-down stacking order, which is why the answer is not
/// a list: a set whose order is its own indices cannot be reordered in transit.
///
/// Three exclusions, and each is a rule rather than a preference:
///
/// - READ-ONLY steps aside under vi/copy mode. Copy mode's keybindings drive a selection rather
///   than the shell, so the lock is not what the user is being told about; the lock itself stays on
///   and the chip returns the moment copy mode exits.
/// - SECURE INPUT steps aside under read-only. No input path can fire there, so the cue is moot.
/// - SYNC INPUT steps aside for NOTHING, and that asymmetry is the point. The mode leaks INTO this
///   pane from its siblings regardless of this pane's own input gate, so a gate that hid it would
///   hide a cross-pane input leak the user cannot otherwise explain.
///
/// The order puts the two gated chips above the ungated one so a chip appearing or leaving never
/// makes the safety warning jump.
#[must_use]
pub const fn visible(conditions: Conditions) -> u8 {
    let mut mask = 0_u8;
    if conditions.read_only && !conditions.copy_mode {
        mask |= 1 << Pill::ReadOnly.index();
    }
    if conditions.secure_input && conditions.secure_input_indicator && !conditions.read_only {
        mask |= 1 << Pill::SecureInput.index();
    }
    if conditions.sync_input {
        mask |= 1 << Pill::SyncInput.index();
    }
    mask
}

/// Whether the vi/copy-mode pill stands ABOVE [`visible`]'s chips.
///
/// It is mutually exclusive with the read-only chip by construction (that one is gated on
/// `!copy_mode`), so the two never fight for the top slot. What it also has to yield to is HINT
/// MODE: the `HINTS` badge owns the same corner from a different overlay, and without this gate the
/// two drew on top of each other. One corner, one mode chip.
#[must_use]
pub const fn shows_vi_mode_pill(conditions: Conditions) -> bool {
    conditions.copy_mode && !conditions.hint_mode
}

/// Whether the vi key-hint bar stands along the pane's BOTTOM.
///
/// In vi mode, with the per-session `⌘/` toggle on. The copy-mode gate makes teardown
/// unconditional, so the card can never linger after vi mode exits.
#[must_use]
pub const fn shows_vi_key_hint_bar(conditions: Conditions, hints_toggled: bool) -> bool {
    conditions.copy_mode && hints_toggled
}

#[cfg(test)]
mod tests {
    use super::{Conditions, Fill, Ink, Pill, shows_vi_key_hint_bar, shows_vi_mode_pill, visible};

    /// The mask, read back as the chips it names, low bit first.
    fn chips(conditions: Conditions) -> Vec<Pill> {
        let mask = visible(conditions);
        Pill::ALL
            .into_iter()
            .filter(|pill| mask & (1 << pill.index()) != 0)
            .collect()
    }

    #[test]
    fn every_index_round_trips_through_the_mask_bit_it_owns() {
        for (position, pill) in Pill::ALL.into_iter().enumerate() {
            assert_eq!(Pill::from_index(pill.index()), Some(pill));
            assert_eq!(usize::from(pill.index()), position, "the bit IS the draw order");
        }
        assert_eq!(Pill::from_index(3), None);
    }

    #[test]
    fn the_six_gates_round_trip_through_one_byte() {
        for bits in 0..64_u8 {
            assert_eq!(Conditions::from_bits(bits).bits(), bits);
        }
    }

    #[test]
    fn read_only_steps_aside_under_copy_mode_and_returns_when_it_exits() {
        let armed = Conditions {
            read_only: true,
            ..Conditions::default()
        };
        assert_eq!(chips(armed), vec![Pill::ReadOnly]);
        assert_eq!(
            chips(Conditions {
                copy_mode: true,
                ..armed
            }),
            vec![],
        );
    }

    #[test]
    fn secure_input_needs_its_setting_and_yields_to_the_lock() {
        let secure = Conditions {
            secure_input: true,
            secure_input_indicator: true,
            ..Conditions::default()
        };
        assert_eq!(chips(secure), vec![Pill::SecureInput]);
        assert_eq!(
            chips(Conditions {
                secure_input_indicator: false,
                ..secure
            }),
            vec![],
            "the indicator setting is a gate, not a preference about the tone",
        );
        assert_eq!(
            chips(Conditions {
                read_only: true,
                ..secure
            }),
            vec![Pill::ReadOnly],
        );
    }

    /// The asymmetry that is the whole point: sync input reports a leak from ELSEWHERE, so this
    /// pane's own gates cannot hide it.
    #[test]
    fn sync_input_steps_aside_for_nothing() {
        for bits in 0..64_u8 {
            let conditions = Conditions {
                sync_input: true,
                ..Conditions::from_bits(bits)
            };
            assert!(
                chips(conditions).contains(&Pill::SyncInput),
                "hidden at {bits:#08b}"
            );
        }
    }

    #[test]
    fn the_mode_chip_yields_the_corner_to_hint_mode() {
        let vi = Conditions {
            copy_mode: true,
            ..Conditions::default()
        };
        assert!(shows_vi_mode_pill(vi));
        assert!(!shows_vi_mode_pill(Conditions {
            hint_mode: true,
            ..vi
        }));
        assert!(!shows_vi_mode_pill(Conditions::default()));
    }

    /// Hint mode hides the CHIP but not the BAR — the bar is the `⌘/` toggle's, and vi mode is the
    /// only thing that tears it down.
    #[test]
    fn the_hint_bar_answers_only_to_vi_mode_and_its_toggle() {
        let vi = Conditions {
            copy_mode: true,
            ..Conditions::default()
        };
        assert!(shows_vi_key_hint_bar(vi, true));
        assert!(!shows_vi_key_hint_bar(vi, false));
        assert!(!shows_vi_key_hint_bar(Conditions::default(), true));
        assert!(shows_vi_key_hint_bar(
            Conditions {
                hint_mode: true,
                ..vi
            },
            true
        ));
    }

    #[test]
    fn only_the_dismissible_chips_carry_a_word_for_dismissing_them() {
        assert!(Pill::ReadOnly.is_dismissible());
        assert!(Pill::SyncInput.is_dismissible());
        assert!(
            !Pill::SecureInput.is_dismissible(),
            "a safety indicator this chip does not own cannot be turned off from it",
        );
    }

    /// The three plates are three drawing routines, so the discriminant is dense and total.
    #[test]
    fn each_plate_has_its_own_code() {
        assert_eq!(Pill::ReadOnly.fill().code(), 0);
        assert_eq!(Pill::SecureInput.fill().code(), 1);
        assert_eq!(Pill::SyncInput.fill().code(), 2);
        assert_eq!(Fill::Fixed(Ink::Security), Pill::SecureInput.fill());
    }
}
