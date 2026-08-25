//! The simulator dialect's UPSTREAM half: one JSON object per gesture, key or button press, sent as
//! a websocket TEXT frame on the same socket the frames arrive on.
//!
//! ## Coordinates are not pixels
//!
//! Every positional envelope carries the [`Surface`] its x/y were measured in, and the host
//! rescales to the device's real framebuffer. That is what lets the panel send view-space points
//! directly — no DPI maths on this side, no assumption about the device's native resolution, and a
//! window resize mid-drag stays correct because the size travels with each event rather than being
//! negotiated once.
//!
//! ## A function per verb, not one struct with everything optional
//!
//! The envelope is a flat heterogeneous bag whose key set changes per type: `tap` carries x/y,
//! `touch2-move` carries x1/y1/x2/y2, `key` carries neither. One type covering all of them models
//! that only by making every field optional and hoping the right subset is populated; a function
//! per verb makes the wrong combination unrepresentable instead.
//!
//! Keys serialize SORTED — not for the wire, which does not care, but so each answer is a pure
//! function of its inputs and a test can pin the whole string.

use serde_json::{Map, Value, json};

/// The default seconds of contact a tap reports, matching the server's own.
pub const DEFAULT_TAP_DURATION: f64 = 0.05;
/// The default seconds a one-finger drag is interpolated over, matching the server's own.
pub const DEFAULT_SWIPE_DURATION: f64 = 0.25;

/// The surface the coordinates were measured in.
///
/// Zero is legal and means "unknown" — the server treats it as a no-scale hint rather than dividing
/// by it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Surface {
    /// The measured surface's width, in the caller's own units.
    pub width: f64,
    /// The measured surface's height, in the same units.
    pub height: f64,
}

/// Where a continuous contact is in its life.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum TouchPhase {
    /// The contact lands.
    Down = 0,
    /// The contact moves while still down.
    Move = 1,
    /// The contact lifts.
    Up = 2,
}

impl TouchPhase {
    /// The suffix the wire spells this phase with.
    const fn name(self) -> &'static str {
        match self {
            Self::Down => "down",
            Self::Move => "move",
            Self::Up => "up",
        }
    }
}

/// The chord held with a key, as the bits the door carries and the names the server reads.
///
/// A set rather than a list because the server reads a SET: sending `shift` twice, or in a
/// different order, is the same chord, and a bitmask is the shape that cannot express the
/// difference.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub struct Modifiers(u8);

impl Modifiers {
    /// No modifier held.
    pub const NONE: Self = Self(0);
    /// The shift bit.
    pub const SHIFT: Self = Self(1 << 0);
    /// The control bit.
    pub const CONTROL: Self = Self(1 << 1);
    /// The option bit.
    pub const OPTION: Self = Self(1 << 2);
    /// The command bit.
    pub const COMMAND: Self = Self(1 << 3);

    /// The chord these bits describe.
    #[must_use]
    pub const fn from_bits(bits: u8) -> Self {
        Self(bits)
    }

    /// Whether every bit of `other` is held here.
    #[must_use]
    const fn holds(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// The names the server reads, in a fixed order so one chord has one spelling.
    fn names(self) -> Vec<&'static str> {
        [
            (Self::SHIFT, "shift"),
            (Self::CONTROL, "control"),
            (Self::OPTION, "option"),
            (Self::COMMAND, "command"),
        ]
        .into_iter()
        .filter(|&(bit, _)| self.holds(bit))
        .map(|(_, name)| name)
        .collect()
    }
}

/// A tap. `duration` is seconds of contact — a longer one is how a long-press is expressed, since
/// the wire has no separate verb for it.
#[must_use]
pub fn tap(x: f64, y: f64, duration: f64, surface: Surface) -> String {
    positional("tap", surface, [
        ("x", json!(x)),
        ("y", json!(y)),
        ("duration", json!(duration)),
    ])
}

/// A one-finger drag from start to end over `duration` seconds, interpolated host-side.
///
/// Distinct from a touch down/move/up sequence: this is fire-and-forget, so it suits a caller that
/// has a delta but no continuous contact to track.
#[must_use]
pub fn swipe(from: (f64, f64), to: (f64, f64), duration: f64, surface: Surface) -> String {
    positional("swipe", surface, [
        ("startX", json!(from.0)),
        ("startY", json!(from.1)),
        ("endX", json!(to.0)),
        ("endY", json!(to.1)),
        ("duration", json!(duration)),
    ])
}

/// A single continuous contact.
///
/// The `edge` hint — set when the gesture began off-screen — is what lets the host distinguish a
/// swipe that starts at the bezel (home, app switcher, notification centre) from one that starts on
/// the content.
#[must_use]
pub fn touch(phase: TouchPhase, x: f64, y: f64, edge: Option<&str>, surface: Surface) -> String {
    let mut fields = base(surface);
    fields.insert("type".to_owned(), json!(format!("touch1-{}", phase.name())));
    fields.insert("x".to_owned(), json!(x));
    fields.insert("y".to_owned(), json!(y));
    if let Some(edge) = edge {
        fields.insert("edge".to_owned(), json!(edge));
    }
    render(fields)
}

/// Two simultaneous contacts — pinch, spread, two-finger pan. The host derives the gesture from how
/// the pair moves; there is no separate pinch verb on this wire.
#[must_use]
pub fn touch2(phase: TouchPhase, first: (f64, f64), second: (f64, f64), surface: Surface) -> String {
    positional(&format!("touch2-{}", phase.name()), surface, [
        ("x1", json!(first.0)),
        ("y1", json!(first.1)),
        ("x2", json!(second.0)),
        ("y2", json!(second.1)),
    ])
}

/// A hardware button by its server-side name (`home`, `lock`, `volume-up`, …).
///
/// `hold` above zero becomes the `duration` field — the difference between a tap on the side button
/// and the press-and-hold that summons the power slider.
#[must_use]
pub fn button(name: &str, hold: f64) -> String {
    let mut fields = Map::new();
    fields.insert("type".to_owned(), json!("button"));
    fields.insert("button".to_owned(), json!(name));
    if hold > 0.0 {
        fields.insert("duration".to_owned(), json!(hold));
    }
    render(fields)
}

/// One key by its `KeyboardEvent.code` name (`KeyA`, `Enter`, `ArrowLeft`).
///
/// The server owns the HID page/usage table, so this side stays a dumb sender.
#[must_use]
pub fn key(code: &str, modifiers: Modifiers) -> String {
    let mut fields = Map::new();
    fields.insert("type".to_owned(), json!("key"));
    fields.insert("code".to_owned(), json!(code));
    let names = modifiers.names();
    if !names.is_empty() {
        fields.insert("modifiers".to_owned(), json!(names));
    }
    render(fields)
}

/// A run of text as synthesized keystrokes. US-ASCII only — anything outside it must go through
/// [`paste`], which routes via the simulator's pasteboard instead.
#[must_use]
pub fn type_text(text: &str) -> String {
    render(text_verb("type", text))
}

/// Text into the focused field via the simulator's pasteboard. The path around [`type_text`]'s
/// ASCII limit, and the only one that carries emoji or CJK.
#[must_use]
pub fn paste(text: &str) -> String {
    render(text_verb("paste", text))
}

/// Pull the simulator's current selection onto the host's clipboard.
#[must_use]
pub fn copy() -> String {
    render(text_only("copy"))
}

fn text_verb(verb: &str, text: &str) -> Map<String, Value> {
    let mut fields = text_only(verb);
    fields.insert("text".to_owned(), json!(text));
    fields
}

fn text_only(verb: &str) -> Map<String, Value> {
    let mut fields = Map::new();
    fields.insert("type".to_owned(), json!(verb));
    fields
}

/// The three keys every positional envelope shares.
fn base(surface: Surface) -> Map<String, Value> {
    let mut fields = Map::new();
    fields.insert("width".to_owned(), json!(surface.width));
    fields.insert("height".to_owned(), json!(surface.height));
    fields
}

fn positional<const N: usize>(verb: &str, surface: Surface, extra: [(&str, Value); N]) -> String {
    let mut fields = base(surface);
    fields.insert("type".to_owned(), json!(verb));
    for (key, value) in extra {
        fields.insert(key.to_owned(), value);
    }
    render(fields)
}

/// The wire form. `serde_json`'s map is ordered, so the keys come out sorted and the answer is a
/// pure function of its inputs.
fn render(fields: Map<String, Value>) -> String {
    Value::Object(fields).to_string()
}

#[cfg(test)]
mod tests {
    use super::{
        DEFAULT_SWIPE_DURATION, DEFAULT_TAP_DURATION, Modifiers, Surface, TouchPhase, button, copy, key,
        paste, swipe, tap, touch, touch2, type_text,
    };

    const SURFACE: Surface = Surface {
        width: 200.0,
        height: 400.0,
    };

    /// Every positional envelope carries the surface its coordinates were measured in — the field
    /// the host scales by, and the one thing that lets this side send view-space points at all.
    #[test]
    fn every_positional_envelope_carries_its_surface() {
        for envelope in [
            tap(1.0, 2.0, DEFAULT_TAP_DURATION, SURFACE),
            swipe((1.0, 2.0), (3.0, 4.0), DEFAULT_SWIPE_DURATION, SURFACE),
            touch(TouchPhase::Down, 1.0, 2.0, None, SURFACE),
            touch2(TouchPhase::Move, (1.0, 2.0), (3.0, 4.0), SURFACE),
        ] {
            assert!(envelope.contains(r#""width":200.0"#), "{envelope}");
            assert!(envelope.contains(r#""height":400.0"#), "{envelope}");
        }
    }

    /// The keys are sorted, which is what lets a test pin a whole string at all.
    #[test]
    fn a_tap_is_one_sorted_object() {
        assert_eq!(
            tap(10.0, 20.0, 0.05, SURFACE),
            r#"{"duration":0.05,"height":400.0,"type":"tap","width":200.0,"x":10.0,"y":20.0}"#
        );
    }

    /// The phase is in the VERB, not a field — `touch1-down` and `touch1-move` are different
    /// messages to the server, not one message with a mode.
    #[test]
    fn the_phase_spells_the_verb() {
        for (phase, verb) in [
            (TouchPhase::Down, "touch1-down"),
            (TouchPhase::Move, "touch1-move"),
            (TouchPhase::Up, "touch1-up"),
        ] {
            let envelope = touch(phase, 1.0, 2.0, None, SURFACE);
            assert!(envelope.contains(&format!(r#""type":"{verb}""#)), "{envelope}");
        }
        assert!(touch2(TouchPhase::Up, (1.0, 2.0), (3.0, 4.0), SURFACE).contains(r#""type":"touch2-up""#));
    }

    /// The edge hint is ABSENT rather than empty when the gesture began on the content: an `edge`
    /// key the server reads is a swipe it drives the home indicator with.
    #[test]
    fn the_edge_hint_appears_only_when_there_is_one() {
        assert!(!touch(TouchPhase::Down, 1.0, 2.0, None, SURFACE).contains("edge"));
        assert!(touch(TouchPhase::Down, 1.0, 2.0, Some("bottom"), SURFACE).contains(r#""edge":"bottom""#));
    }

    /// A hold of zero is a PRESS, and a press must not carry a duration: the server reads one as
    /// the press-and-hold that summons the power slider.
    #[test]
    fn a_button_carries_a_duration_only_when_it_is_held() {
        assert_eq!(button("home", 0.0), r#"{"button":"home","type":"button"}"#);
        assert_eq!(
            button("lock", 2.0),
            r#"{"button":"lock","duration":2.0,"type":"button"}"#
        );
    }

    /// One chord has one spelling, whichever order the bits arrived in.
    #[test]
    fn a_chord_spells_its_modifiers_in_one_fixed_order() {
        let both = Modifiers::from_bits(Modifiers::COMMAND.0 | Modifiers::SHIFT.0);
        assert_eq!(
            key("KeyA", both),
            r#"{"code":"KeyA","modifiers":["shift","command"],"type":"key"}"#
        );
        assert_eq!(key("Enter", Modifiers::NONE), r#"{"code":"Enter","type":"key"}"#);
    }

    /// The two text verbs are different ROUTES on the server — keystrokes versus the pasteboard —
    /// and the panel picks between them by what the text contains.
    #[test]
    fn the_two_text_verbs_stay_distinct() {
        assert_eq!(type_text("hi"), r#"{"text":"hi","type":"type"}"#);
        assert_eq!(paste("🙂"), r#"{"text":"🙂","type":"paste"}"#);
        assert_eq!(copy(), r#"{"type":"copy"}"#);
    }

    /// Text is JSON-escaped, which is the whole reason this is not string concatenation: a quote or
    /// a newline in what the user typed would otherwise end the object early.
    #[test]
    fn hostile_text_is_escaped_rather_than_ending_the_object() {
        assert_eq!(type_text("a\"b\nc\\d"), r#"{"text":"a\"b\nc\\d","type":"type"}"#);
    }
}
