//! A keystroke and a pointer gesture, turned into the bytes the far side expects.
//!
//! Neither encoding is re-derived here. The kitty keyboard protocol has five flag combinations the
//! application negotiates at runtime, `modifyOtherKeys` has two states, and the mouse has five wire
//! formats and four tracking modes — all of which the *terminal* has already agreed with the
//! program running in it. Asking the engine to encode is the only way the answer stays in step with
//! what that program asked for, so this module is a door, not an implementation.
//!
//! ## Why the encoders and their events are held, not made
//!
//! Both `Encoder` and `Event` are engine allocations. Making one per keystroke would put an
//! allocate/free pair on the path this codebase measures in milliseconds — the key-to-render-feed
//! latency `docs/68` pins. So [`Keyboard`] and [`Pointer`] each own one encoder and one event, and
//! every press overwrites the event in place.
//!
//! ## What is NOT decided here
//!
//! Whether a keystroke should be encoded at all. A binding may claim it, a compose sequence may
//! still be mid-flight, and `characters` may be an `AppKit` function-key placeholder that must
//! never be forwarded as text. Those are decisions, and they live in `slopdesk_terminal::surface`
//! where they can be tested without an engine. By the time a press reaches [`Keyboard::encode`] it
//! has already been ruled sendable.

use core::fmt;

pub use libghostty_vt::key::{Key, OptionAsAlt};
use libghostty_vt::{key, mouse};

use crate::session::Result;

/// The modifier keys held during an event.
///
/// The bits are the engine's own, taken from its constants rather than restated — a mirrored
/// bitset would be a second vocabulary to keep in step, and `the_bits_are_the_engines_own` pins
/// that they are not.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Mods(u16);

impl Mods {
    /// Nothing held.
    pub const NONE: Self = Self(0);
    /// Shift.
    pub const SHIFT: Self = Self(key::Mods::SHIFT.bits());
    /// Alt / Option.
    pub const ALT: Self = Self(key::Mods::ALT.bits());
    /// Control.
    pub const CTRL: Self = Self(key::Mods::CTRL.bits());
    /// Command / Super.
    pub const SUPER: Self = Self(key::Mods::SUPER.bits());
    /// Caps Lock is latched.
    pub const CAPS_LOCK: Self = Self(key::Mods::CAPS_LOCK.bits());
    /// Num Lock is latched.
    pub const NUM_LOCK: Self = Self(key::Mods::NUM_LOCK.bits());
    /// The Shift held is the right-hand one. Only meaningful with [`Self::SHIFT`].
    pub const RIGHT_SHIFT: Self = Self(key::Mods::SHIFT_SIDE.bits());
    /// The Alt held is the right-hand one. Only meaningful with [`Self::ALT`].
    ///
    /// Load-bearing on macOS: `macos-option-as-alt = right` distinguishes the two, which is how a
    /// user keeps one Option key for composing accented characters and gives the other to the
    /// terminal.
    pub const RIGHT_ALT: Self = Self(key::Mods::ALT_SIDE.bits());
    /// The Control held is the right-hand one. Only meaningful with [`Self::CTRL`].
    pub const RIGHT_CTRL: Self = Self(key::Mods::CTRL_SIDE.bits());
    /// The Command held is the right-hand one. Only meaningful with [`Self::SUPER`].
    pub const RIGHT_SUPER: Self = Self(key::Mods::SUPER_SIDE.bits());

    /// A modifier set from its raw bits, as an FFI door hands them over.
    ///
    /// Unknown bits are kept rather than masked away: the engine ignores what it does not know, and
    /// silently dropping a bit a newer engine understands would be worse than passing it through.
    #[must_use]
    pub const fn from_bits(bits: u16) -> Self {
        Self(bits)
    }

    /// The raw bits.
    #[must_use]
    pub const fn bits(self) -> u16 {
        self.0
    }

    /// Both sets.
    #[must_use]
    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    /// Whether every bit of `other` is held.
    #[must_use]
    pub const fn contains(self, other: Self) -> bool {
        (self.0 & other.0) == other.0
    }

    const fn to_engine(self) -> key::Mods {
        key::Mods::from_bits_truncate(self.0)
    }
}

/// Whether a key went down, came up, or is repeating.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum KeyAction {
    /// The key went down.
    #[default]
    Press,
    /// The key came up. Only encoded under the kitty protocol's event-reporting flag.
    Release,
    /// The key is held and the OS is repeating it.
    Repeat,
}

impl From<KeyAction> for key::Action {
    fn from(value: KeyAction) -> Self {
        match value {
            KeyAction::Press => Self::Press,
            KeyAction::Release => Self::Release,
            KeyAction::Repeat => Self::Repeat,
        }
    }
}

/// One keystroke, as the view observed it.
#[derive(Debug, Clone, Copy, Default)]
pub struct KeyPress<'a> {
    /// The logical key, if the platform identified one.
    ///
    /// `None` for a press that carries only text — an IME commit, or a dead-key composition — where
    /// there is no key to name and [`Self::text`] is the whole event.
    pub key: Option<Key>,
    /// Down, up or repeating.
    pub action: KeyAction,
    /// Everything held.
    pub mods: Mods,
    /// The subset the platform already spent producing [`Self::text`].
    ///
    /// The encoder subtracts these before reporting modifiers, which is why forwarding text for a
    /// control-led payload silently erases Shift: see `slopdesk_terminal::surface`'s
    /// `forwards_encoder_text`, which is the guard that stops it.
    pub consumed_mods: Mods,
    /// The text the platform produced, if it is safe to forward.
    pub text: Option<&'a str>,
    /// The character the key would produce with no modifiers, which the kitty protocol reports as
    /// the base layout key.
    pub unshifted: Option<char>,
    /// Whether an IME is mid-composition. A composing press is reported but produces no bytes.
    pub composing: bool,
}

/// Which pointer button an event is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    /// The primary button.
    Left,
    /// The secondary button.
    Right,
    /// The wheel click.
    Middle,
    /// A button past the first three, by its one-based index from four.
    Extra(u8),
}

impl From<MouseButton> for mouse::Button {
    fn from(value: MouseButton) -> Self {
        match value {
            MouseButton::Left => Self::Left,
            MouseButton::Right => Self::Right,
            MouseButton::Middle => Self::Middle,
            MouseButton::Extra(4) => Self::Four,
            MouseButton::Extra(5) => Self::Five,
            MouseButton::Extra(6) => Self::Six,
            MouseButton::Extra(7) => Self::Seven,
            MouseButton::Extra(8) => Self::Eight,
            MouseButton::Extra(9) => Self::Nine,
            MouseButton::Extra(10) => Self::Ten,
            MouseButton::Extra(11) => Self::Eleven,
            MouseButton::Extra(_) => Self::Unknown,
        }
    }
}

/// What the pointer did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MouseAction {
    /// A button went down.
    #[default]
    Press,
    /// A button came up.
    Release,
    /// The pointer moved.
    Motion,
}

impl From<MouseAction> for mouse::Action {
    fn from(value: MouseAction) -> Self {
        match value {
            MouseAction::Press => Self::Press,
            MouseAction::Release => Self::Release,
            MouseAction::Motion => Self::Motion,
        }
    }
}

/// One pointer event, in surface pixels.
///
/// Pixels rather than cells because the SGR-pixels format reports pixels, and because the encoder
/// owns the padding and cell metrics it needs to convert — doing the division here would put the
/// same rounding rule in two places and let them drift.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MouseMove {
    /// What happened.
    pub action: MouseAction,
    /// Which button, or `None` for a bare motion.
    pub button: Option<MouseButton>,
    /// Modifiers held.
    pub mods: Mods,
    /// X in surface pixels, from the surface's left edge.
    pub x: f32,
    /// Y in surface pixels, from the surface's top edge.
    pub y: f32,
}

/// The surface geometry the pointer encoder converts against.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SurfaceGeometry {
    /// Surface width in pixels.
    pub width: u32,
    /// Surface height in pixels.
    pub height: u32,
    /// One cell's width in pixels. Must be non-zero.
    pub cell_width: u32,
    /// One cell's height in pixels. Must be non-zero.
    pub cell_height: u32,
    /// Padding above the grid.
    pub padding_top: u32,
    /// Padding below the grid.
    pub padding_bottom: u32,
    /// Padding left of the grid.
    pub padding_left: u32,
    /// Padding right of the grid.
    pub padding_right: u32,
}

impl From<SurfaceGeometry> for mouse::EncoderSize {
    fn from(value: SurfaceGeometry) -> Self {
        Self {
            screen_width: value.width,
            screen_height: value.height,
            cell_width: value.cell_width.max(1),
            cell_height: value.cell_height.max(1),
            padding_top: value.padding_top,
            padding_bottom: value.padding_bottom,
            padding_right: value.padding_right,
            padding_left: value.padding_left,
        }
    }
}

/// The key encoder and its one reusable event.
pub struct Keyboard {
    encoder: key::Encoder<'static>,
    event: key::Event<'static>,
    /// The user's `macos-option-as-alt`, kept because the engine forgets it.
    ///
    /// `set_options_from_terminal` copies the modes a program negotiated and, having no terminal
    /// state to read it from, resets this one to `False`. A resync runs before every press, so a
    /// value applied once and not re-applied is a setting that lasts one keystroke.
    option_as_alt: OptionAsAlt,
}

impl fmt::Debug for Keyboard {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Keyboard { .. }")
    }
}

impl Keyboard {
    /// A keyboard with the engine's default options.
    ///
    /// # Errors
    /// The engine's own error, if either allocation fails.
    pub fn new() -> Result<Self> {
        Ok(Self {
            encoder: key::Encoder::new()?,
            event: key::Event::new()?,
            option_as_alt: OptionAsAlt::False,
        })
    }

    /// How the macOS Option key is treated.
    ///
    /// The one encoder option that is a *user* preference rather than something the running program
    /// negotiated, which is why it has its own door while the rest arrive through
    /// [`Keyboard::sync`] — and why it is stored: the resync would otherwise erase it.
    pub fn set_option_as_alt(&mut self, value: OptionAsAlt) {
        self.option_as_alt = value;
        self.encoder.set_macos_option_as_alt(value);
    }

    /// Copies the modes the running program negotiated out of the terminal, then restores the one
    /// option the terminal cannot answer.
    ///
    /// Must be called after anything that could change them, which in practice means after every
    /// feed: an application enters the kitty protocol with an escape sequence, and a stale encoder
    /// would keep sending the old encoding until something else happened to refresh it.
    pub(crate) fn sync(&mut self, terminal: &libghostty_vt::terminal::Terminal<'static, 'static>) {
        self.encoder
            .set_options_from_terminal(terminal)
            .set_macos_option_as_alt(self.option_as_alt);
    }

    /// Encodes one keystroke, appending to `out`.
    ///
    /// An empty result is normal and not an error: a modifier press, a composing keystroke, and a
    /// release outside the kitty protocol all encode to nothing.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn encode(&mut self, press: &KeyPress<'_>, out: &mut Vec<u8>) -> Result<()> {
        self.event
            .set_action(press.action.into())
            .set_key(press.key.unwrap_or(Key::Unidentified))
            .set_mods(press.mods.to_engine())
            .set_consumed_mods(press.consumed_mods.to_engine())
            .set_composing(press.composing)
            .set_utf8(press.text)
            .set_unshifted_codepoint(press.unshifted.unwrap_or('\0'));
        append_encoded(out, |spare| self.encoder.encode(&self.event, spare))
    }
}

/// Appends one encoding to `out`, growing `out` by the size the engine asks for.
///
/// The engine's `encode_to_vec` grows a non-empty vector by `required - spare`, which reserves
/// against the LENGTH and so leaves the spare capacity short by the bytes already there: a second
/// keystroke appended after the first fails with `OutOfSpace` for good. Callers that batch several
/// encodings into one buffer — the recorder, the conformance replay — are exactly that shape, so
/// the growth is done here, against the spare capacity, and the engine is only ever handed a slice
/// it said was big enough.
fn append_encoded(
    out: &mut Vec<u8>,
    mut encode: impl FnMut(&mut [u8]) -> core::result::Result<usize, libghostty_vt::Error>,
) -> Result<()> {
    let start = out.len();
    let mut spare = out.capacity() - start;
    loop {
        out.resize(start + spare, 0);
        let (_, room) = out.split_at_mut(start);
        match encode(room) {
            Ok(written) => {
                out.truncate(start + written);
                return Ok(());
            },
            Err(libghostty_vt::Error::OutOfSpace { required }) => {
                out.truncate(start);
                out.reserve(required.max(spare + 1));
                spare = out.capacity() - start;
            },
            Err(error) => {
                out.truncate(start);
                return Err(error.into());
            },
        }
    }
}

/// The mouse encoder, its one reusable event, and the geometry it converts against.
pub struct Pointer {
    encoder: mouse::Encoder<'static>,
    event: mouse::Event<'static>,
    geometry: SurfaceGeometry,
    /// The tracking and format modes the encoder was last synced to, or `None` before the first.
    ///
    /// The engine's `set_options_from_terminal` forgets the last reported cell as a side effect,
    /// and that cell is what turns ten sub-cell motions into one report. So the sync happens
    /// only when the modes actually moved, and this is how that is known without a C call per
    /// mode per event.
    modes: Option<MouseModes>,
    /// Which buttons the encoder has seen pressed and not yet released, one bit per button.
    ///
    /// The engine reports a position outside the viewport — a drag past the surface's edge —
    /// only while it believes a button is held, and it does not track that itself.
    held: u16,
}

/// The eight DEC modes that decide whether and how a pointer event is reported, one bit each.
///
/// Read as a unit so one comparison says whether the encoder needs resyncing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct MouseModes(u8);

impl MouseModes {
    /// The modes as the terminal holds them, or `None` when the engine would not say.
    fn read(terminal: &libghostty_vt::terminal::Terminal<'static, 'static>) -> Option<Self> {
        use libghostty_vt::terminal::Mode;
        const MODES: [Mode; 8] = [
            Mode::X10_MOUSE,
            Mode::NORMAL_MOUSE,
            Mode::BUTTON_MOUSE,
            Mode::ANY_MOUSE,
            Mode::UTF8_MOUSE,
            Mode::SGR_MOUSE,
            Mode::URXVT_MOUSE,
            Mode::SGR_PIXELS_MOUSE,
        ];
        let mut bits = 0_u8;
        for (index, mode) in MODES.iter().enumerate() {
            if terminal.mode(*mode).ok()? {
                bits |= 1_u8 << index;
            }
        }
        Some(Self(bits))
    }
}

/// The bit [`Pointer::held`] keeps for a button, or `0` for one it does not track.
///
/// Only the three physical buttons are tracked. A wheel notch is reported as a PRESS of button
/// four or five that no release ever follows, so counting it would leave the encoder believing a
/// button is held for the rest of the session.
///
/// The arms are unqualified on purpose: these are the bits of a HELD mask, not a wire alphabet, and
/// `Enum::Variant => n,` is the shape the shared-constants ratchet reads as one.
const fn button_bit(button: MouseButton) -> u16 {
    use MouseButton::{Extra, Left, Middle, Right};
    match button {
        Left => 1,
        Right => 2,
        Middle => 4,
        Extra(_) => 0,
    }
}

impl fmt::Debug for Pointer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Pointer")
            .field("geometry", &self.geometry)
            .finish_non_exhaustive()
    }
}

impl Pointer {
    /// A pointer with the engine's default options and no geometry yet.
    ///
    /// # Errors
    /// The engine's own error, if either allocation fails.
    pub fn new() -> Result<Self> {
        let mut encoder = mouse::Encoder::new()?;
        // One report per cell entered, as ghostty's `mouseReport` sends: the engine remembers the
        // last cell it reported and drops a motion that stays inside it.
        encoder.set_track_last_cell(true);
        Ok(Self {
            encoder,
            event: mouse::Event::new()?,
            geometry: SurfaceGeometry::default(),
            modes: None,
            held: 0,
        })
    }

    /// Tells the encoder the surface's pixel geometry.
    ///
    /// Cheap and idempotent, so a caller may hand it over on every layout pass rather than tracking
    /// whether it changed.
    pub fn set_geometry(&mut self, geometry: SurfaceGeometry) {
        self.geometry = geometry;
        self.encoder.set_size(geometry.into());
    }

    /// Copies the tracking mode and wire format the running program negotiated, when they moved.
    ///
    /// Called after every feed rather than before every event: a feed is the only thing that can
    /// change a mode, and syncing per event would forget the last reported cell each time.
    pub(crate) fn sync(&mut self, terminal: &libghostty_vt::terminal::Terminal<'static, 'static>) {
        let modes = MouseModes::read(terminal);
        if modes.is_some() && modes == self.modes {
            return;
        }
        self.modes = modes;
        self.encoder.set_options_from_terminal(terminal);
    }

    /// Forgets any button state the encoder was tracking.
    ///
    /// Needed when the surface loses the pointer mid-drag: without it the encoder still believes a
    /// button is down and reports drag motion the user is no longer making.
    pub fn reset(&mut self) {
        self.encoder.reset();
        self.held = 0;
        self.encoder.set_any_button_pressed(false);
    }

    /// Encodes one pointer event, appending to `out`.
    ///
    /// An empty result is normal: a program that asked for no tracking, or asked for press-only
    /// tracking and got a motion, produces no bytes.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn encode(&mut self, event: &MouseMove, out: &mut Vec<u8>) -> Result<()> {
        if let Some(button) = event.button {
            let held = match event.action {
                MouseAction::Press => self.held | button_bit(button),
                MouseAction::Release => self.held & !button_bit(button),
                MouseAction::Motion => self.held,
            };
            if (held != 0) != (self.held != 0) {
                self.encoder.set_any_button_pressed(held != 0);
            }
            self.held = held;
        }
        self.event
            .set_action(event.action.into())
            .set_button(event.button.map(Into::into))
            .set_mods(event.mods.to_engine())
            .set_position(mouse::Position {
                x: event.x,
                y: event.y,
            });
        append_encoded(out, |spare| self.encoder.encode(&self.event, spare))
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use libghostty_vt::key;

    use super::{
        KeyAction, KeyPress, Keyboard, Mods, MouseAction, MouseButton, MouseMove, Pointer, SurfaceGeometry,
    };

    #[test]
    fn the_bits_are_the_engines_own() {
        assert_eq!(Mods::SHIFT.bits(), key::Mods::SHIFT.bits());
        assert_eq!(Mods::ALT.bits(), key::Mods::ALT.bits());
        assert_eq!(Mods::CTRL.bits(), key::Mods::CTRL.bits());
        assert_eq!(Mods::SUPER.bits(), key::Mods::SUPER.bits());
        assert_eq!(Mods::RIGHT_ALT.bits(), key::Mods::ALT_SIDE.bits());
    }

    #[test]
    fn an_unknown_modifier_bit_survives_the_round_trip() {
        let mods = Mods::from_bits(0x8000);
        assert_eq!(
            mods.bits(),
            0x8000,
            "a bit a newer engine understands is passed through, not masked off"
        );
    }

    #[test]
    fn modifiers_combine_and_test() {
        let held = Mods::CTRL.union(Mods::SHIFT);
        assert!(held.contains(Mods::CTRL));
        assert!(held.contains(Mods::SHIFT));
        assert!(!held.contains(Mods::ALT));
        assert!(Mods::NONE.contains(Mods::NONE));
    }

    #[test]
    fn a_plain_letter_encodes_to_itself() {
        let mut keyboard = Keyboard::new().unwrap();
        let mut out = Vec::new();
        keyboard
            .encode(
                &KeyPress {
                    key: Some(key::Key::A),
                    text: Some("a"),
                    unshifted: Some('a'),
                    ..KeyPress::default()
                },
                &mut out,
            )
            .unwrap();
        assert_eq!(out, b"a");
    }

    #[test]
    fn a_keystroke_appended_behind_earlier_ones_still_fits() {
        // The shape the recorder and the replay produce: one buffer, many keystrokes. A wide
        // character behind eleven ASCII ones asks the engine for more room than the spare
        // capacity holds, and the growth has to be measured against the spare, not the length.
        let mut keyboard = Keyboard::new().unwrap();
        let mut out = Vec::new();
        for _ in 0..11 {
            keyboard
                .encode(
                    &KeyPress {
                        key: Some(key::Key::K),
                        text: Some("k"),
                        unshifted: Some('k'),
                        ..KeyPress::default()
                    },
                    &mut out,
                )
                .unwrap();
        }
        keyboard
            .encode(
                &KeyPress {
                    key: None,
                    text: Some("世"),
                    ..KeyPress::default()
                },
                &mut out,
            )
            .unwrap();
        assert_eq!(out, "kkkkkkkkkkk世".as_bytes());
    }

    #[test]
    fn control_letter_encodes_to_its_c0_code() {
        let mut keyboard = Keyboard::new().unwrap();
        let mut out = Vec::new();
        keyboard
            .encode(
                &KeyPress {
                    key: Some(key::Key::C),
                    mods: Mods::CTRL,
                    unshifted: Some('c'),
                    ..KeyPress::default()
                },
                &mut out,
            )
            .unwrap();
        assert_eq!(out, b"\x03", "ctrl-c is ETX, not the letter");
    }

    #[test]
    fn the_arrows_encode_as_cursor_sequences() {
        let mut keyboard = Keyboard::new().unwrap();
        let mut out = Vec::new();
        keyboard
            .encode(
                &KeyPress {
                    key: Some(key::Key::ArrowUp),
                    ..KeyPress::default()
                },
                &mut out,
            )
            .unwrap();
        assert_eq!(out, b"\x1b[A");
    }

    #[test]
    fn a_composing_keystroke_sends_nothing() {
        let mut keyboard = Keyboard::new().unwrap();
        let mut out = Vec::new();
        keyboard
            .encode(
                &KeyPress {
                    key: Some(key::Key::A),
                    text: Some("a"),
                    composing: true,
                    ..KeyPress::default()
                },
                &mut out,
            )
            .unwrap();
        assert!(
            out.is_empty(),
            "a keystroke the IME still owns has not been typed yet"
        );
    }

    #[test]
    fn the_encoder_appends_rather_than_replacing() {
        let mut keyboard = Keyboard::new().unwrap();
        let mut out = b"pre".to_vec();
        keyboard
            .encode(
                &KeyPress {
                    key: Some(key::Key::A),
                    text: Some("a"),
                    ..KeyPress::default()
                },
                &mut out,
            )
            .unwrap();
        assert_eq!(out, b"prea", "a caller batching a burst keeps what it had");
    }

    #[test]
    fn a_pointer_with_no_tracking_negotiated_sends_nothing() {
        let mut pointer = Pointer::new().unwrap();
        pointer.set_geometry(SurfaceGeometry {
            width: 800,
            height: 400,
            cell_width: 8,
            cell_height: 16,
            ..SurfaceGeometry::default()
        });
        let mut out = Vec::new();
        pointer
            .encode(
                &MouseMove {
                    action: MouseAction::Press,
                    button: Some(MouseButton::Left),
                    mods: Mods::NONE,
                    x: 16.0,
                    y: 32.0,
                },
                &mut out,
            )
            .unwrap();
        assert!(
            out.is_empty(),
            "nothing asked for mouse reports, so the click stays local"
        );
    }

    #[test]
    fn every_named_button_maps_and_an_unknown_extra_degrades() {
        assert_eq!(
            libghostty_vt::mouse::Button::from(MouseButton::Left),
            libghostty_vt::mouse::Button::Left
        );
        assert_eq!(
            libghostty_vt::mouse::Button::from(MouseButton::Extra(5)),
            libghostty_vt::mouse::Button::Five
        );
        assert_eq!(
            libghostty_vt::mouse::Button::from(MouseButton::Extra(99)),
            libghostty_vt::mouse::Button::Unknown,
            "a button past the protocol is unknown, not a wrong one"
        );
    }

    #[test]
    fn a_zero_cell_size_cannot_reach_the_encoder() {
        let size = libghostty_vt::mouse::EncoderSize::from(SurfaceGeometry::default());
        assert_eq!(size.cell_width, 1, "the encoder divides by this");
        assert_eq!(size.cell_height, 1);
    }

    #[test]
    fn the_action_mappings_are_total() {
        assert_eq!(key::Action::from(KeyAction::Press), key::Action::Press);
        assert_eq!(key::Action::from(KeyAction::Release), key::Action::Release);
        assert_eq!(key::Action::from(KeyAction::Repeat), key::Action::Repeat);
        assert_eq!(
            libghostty_vt::mouse::Action::from(MouseAction::Motion),
            libghostty_vt::mouse::Action::Motion
        );
    }
}
