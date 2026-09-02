//! A text spelling for a run of pointer events, so that "what the user pointed at" can be written
//! down.
//!
//! The sibling of [`crate::keyscript`], and it exists for the same one reason: a recorded session
//! is only an honest test of the pointer path if the bytes in it came out of
//! [`crate::VtSession::encode_mouse`] rather than being typed by hand. The recorder writes the
//! spelling into the file; the replay parses the same spelling and must arrive at the same bytes.
//!
//! ## The grammar
//!
//! A script is a run of events separated by whitespace. One event is
//!
//! ```text
//! [MODS-][ACTION:]BUTTON@COL,ROW
//! ```
//!
//! * `MODS` — any of `C` (Control), `A`/`M` (Alt), `S` (Shift), `D` (Command), each followed by
//!   `-`.
//! * `ACTION` — `press` (the default), `release` or `motion`, followed by `:`.
//! * `BUTTON` — `left`, `right`, `middle`, or a number from 4 to 11 for a button past the first
//!   three; the wheel is `4`/`5` up/down and `6`/`7` left/right, which is how X10 numbered them and
//!   what every terminal has reported since. A `motion:` event may leave the button out entirely,
//!   which is a bare hover.
//! * `COL,ROW` — a cell of the grid, zero-based.
//!
//! So a click and a drag spell as `left@12,5 motion:left@16,5 release:left@16,5`.
//!
//! ## Why the position is a CELL and the encoder wants a pixel
//!
//! A script says what a human pointed at, and a human points at a character. The pixel is derived —
//! [`MouseScriptEvent::to_move`] puts the point at the middle of the cell, which is the one place
//! in the cell whose rounding cannot flip either way. Writing pixels into the script instead would
//! make every recording depend on the cell metrics of the machine that recorded it, and re-reading
//! it at another size would silently point somewhere else.

use crate::input::{Mods, MouseAction, MouseButton, MouseMove, SurfaceGeometry};

/// Why a pointer script could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MouseScriptError {
    /// An event has no `@COL,ROW`.
    NoPosition {
        /// The event as written.
        event: String,
    },
    /// The `COL,ROW` is not two numbers.
    BadPosition {
        /// The event as written.
        event: String,
    },
    /// The action before the `:` is not one this vocabulary has.
    UnknownAction {
        /// The word that was written.
        action: String,
    },
    /// The button is not one this vocabulary has.
    UnknownButton {
        /// The word that was written.
        button: String,
    },
    /// A press or a release with no button to press.
    ButtonlessPress {
        /// The event as written.
        event: String,
    },
}

impl core::fmt::Display for MouseScriptError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::NoPosition { event } => write!(f, "`{event}` has no `@COL,ROW`"),
            Self::BadPosition { event } => write!(f, "`{event}` does not end in two cell numbers"),
            Self::UnknownAction { action } => {
                write!(f, "unknown pointer action `{action}` (press, release, motion)")
            },
            Self::UnknownButton { button } => {
                write!(
                    f,
                    "unknown pointer button `{button}` (left, right, middle, 4..11)"
                )
            },
            Self::ButtonlessPress { event } => {
                write!(
                    f,
                    "`{event}` presses or releases nothing — only motion may omit the button"
                )
            },
        }
    }
}

impl core::error::Error for MouseScriptError {}

/// One pointer event, in the cells a human would name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MouseScriptEvent {
    /// What the pointer did.
    pub action: MouseAction,
    /// Which button, or `None` for a bare hover.
    pub button: Option<MouseButton>,
    /// Modifiers held.
    pub mods: Mods,
    /// The grid column pointed at, zero-based.
    pub col: u16,
    /// The grid row pointed at, zero-based.
    pub row: u16,
}

impl MouseScriptEvent {
    /// The pixel event this stands for on a surface of `geometry`.
    ///
    /// The point is the MIDDLE of the cell. Any other choice would sit on a boundary the encoder
    /// has to round, and a rounding rule is exactly the kind of thing a test must not have an
    /// opinion about.
    #[must_use]
    pub fn to_move(&self, geometry: SurfaceGeometry) -> MouseMove {
        let cell_width = f64::from(geometry.cell_width.max(1));
        let cell_height = f64::from(geometry.cell_height.max(1));
        let x = f64::from(geometry.padding_left) + f64::from(self.col) * cell_width + cell_width / 2.0;
        let y = f64::from(geometry.padding_top) + f64::from(self.row) * cell_height + cell_height / 2.0;
        MouseMove {
            action: self.action,
            button: self.button,
            mods: self.mods,
            #[expect(
                clippy::cast_possible_truncation,
                reason = "a surface coordinate is f32 at the door; the arithmetic is exact in f64 for the \
                          cell counts a grid can hold"
            )]
            x: x as f32,
            #[expect(
                clippy::cast_possible_truncation,
                reason = "a surface coordinate is f32 at the door; see above"
            )]
            y: y as f32,
        }
    }
}

/// Reads a pointer script into the events it spells.
///
/// # Errors
/// [`MouseScriptError`] naming the event that could not be read. An empty script is not an error
/// and yields no events.
pub fn parse(script: &str) -> Result<Vec<MouseScriptEvent>, MouseScriptError> {
    script.split_whitespace().map(parse_one).collect()
}

/// Reads one whitespace-free event.
fn parse_one(event: &str) -> Result<MouseScriptEvent, MouseScriptError> {
    let (spec, position) = event.rsplit_once('@').ok_or_else(|| {
        MouseScriptError::NoPosition {
            event: event.to_owned(),
        }
    })?;
    let (col, row) = position
        .split_once(',')
        .and_then(|(col, row)| Some((col.parse().ok()?, row.parse().ok()?)))
        .ok_or_else(|| {
            MouseScriptError::BadPosition {
                event: event.to_owned(),
            }
        })?;

    let mut mods = Mods::NONE;
    let mut rest = spec;
    while let Some((prefix, tail)) = rest.split_once('-') {
        let held = match prefix {
            "C" => Mods::CTRL,
            "A" | "M" => Mods::ALT,
            "S" => Mods::SHIFT,
            "D" => Mods::SUPER,
            _ => break,
        };
        if tail.is_empty() {
            break;
        }
        mods = mods.union(held);
        rest = tail;
    }

    let (action, button_word) = match rest.split_once(':') {
        Some((word, tail)) => (action_for(word)?, tail),
        None => (MouseAction::Press, rest),
    };
    let button = if button_word.is_empty() {
        None
    } else {
        Some(button_for(button_word)?)
    };
    // A press with nothing to press would encode as a motion and quietly test the wrong path, so
    // the spelling refuses it rather than the encoder guessing.
    if button.is_none() && !matches!(action, MouseAction::Motion) {
        return Err(MouseScriptError::ButtonlessPress {
            event: event.to_owned(),
        });
    }

    Ok(MouseScriptEvent {
        action,
        button,
        mods,
        col,
        row,
    })
}

/// The action a word stands for.
fn action_for(word: &str) -> Result<MouseAction, MouseScriptError> {
    Ok(match word {
        "press" | "down" => MouseAction::Press,
        "release" | "up" => MouseAction::Release,
        "motion" | "move" | "drag" => MouseAction::Motion,
        other => {
            return Err(MouseScriptError::UnknownAction {
                action: other.to_owned(),
            });
        },
    })
}

/// The button a word stands for.
fn button_for(word: &str) -> Result<MouseButton, MouseScriptError> {
    Ok(match word {
        "left" | "l" => MouseButton::Left,
        "right" | "r" => MouseButton::Right,
        "middle" | "m" => MouseButton::Middle,
        // The wheel is buttons 4 to 7, and 8 upward are the side buttons. Spelled as numbers
        // because that is what the reports carry and what every terminal's documentation calls
        // them; a name here would be a fifth vocabulary for the same four integers.
        other => {
            let index: u8 = other
                .parse()
                .map_err(|_ignored| {
                    MouseScriptError::UnknownButton {
                        button: other.to_owned(),
                    }
                })
                .and_then(|index| {
                    if (4..=11).contains(&index) {
                        Ok(index)
                    } else {
                        Err(MouseScriptError::UnknownButton {
                            button: other.to_owned(),
                        })
                    }
                })?;
            MouseButton::Extra(index)
        },
    })
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::{MouseScriptError, parse};
    use crate::input::{Mods, MouseAction, MouseButton, SurfaceGeometry};

    fn geometry() -> SurfaceGeometry {
        SurfaceGeometry {
            width: 800,
            height: 480,
            cell_width: 8,
            cell_height: 16,
            ..SurfaceGeometry::default()
        }
    }

    #[test]
    fn a_bare_button_is_a_press() {
        let events = parse("left@12,5").expect("parse");
        let event = events.first().expect("one event");
        assert_eq!(event.action, MouseAction::Press);
        assert_eq!(event.button, Some(MouseButton::Left));
        assert_eq!(event.mods, Mods::NONE);
        assert_eq!((event.col, event.row), (12, 5));
    }

    #[test]
    fn a_drag_is_three_events_in_one_script() {
        let events = parse("left@2,1 motion:left@6,1 release:left@6,1").expect("parse");
        assert_eq!(events.len(), 3);
        assert_eq!(events.get(1).map(|e| e.action), Some(MouseAction::Motion));
        assert_eq!(events.get(2).map(|e| e.action), Some(MouseAction::Release));
    }

    #[test]
    fn a_hover_may_have_no_button() {
        let events = parse("motion:@3,4").expect("parse");
        assert_eq!(events.first().and_then(|e| e.button), None);
    }

    #[test]
    fn modifiers_stack_the_way_a_keyscript_stacks_them() {
        let events = parse("C-S-right@0,0").expect("parse");
        assert_eq!(
            events.first().map(|e| e.mods),
            Some(Mods::CTRL.union(Mods::SHIFT))
        );
        assert_eq!(events.first().and_then(|e| e.button), Some(MouseButton::Right));
    }

    #[test]
    fn the_wheel_is_a_numbered_button() {
        let events = parse("4@10,10 5@10,10").expect("parse");
        assert_eq!(events.first().and_then(|e| e.button), Some(MouseButton::Extra(4)));
        assert_eq!(events.get(1).and_then(|e| e.button), Some(MouseButton::Extra(5)));
    }

    #[test]
    fn a_press_with_no_button_is_refused() {
        assert!(matches!(
            parse("press:@1,1"),
            Err(MouseScriptError::ButtonlessPress { .. })
        ));
    }

    #[test]
    fn a_button_outside_the_reported_range_is_refused() {
        assert!(matches!(
            parse("99@1,1"),
            Err(MouseScriptError::UnknownButton { .. })
        ));
    }

    #[test]
    fn an_event_without_a_position_names_itself() {
        let Err(MouseScriptError::NoPosition { event }) = parse("left") else {
            panic!("expected a missing-position error");
        };
        assert_eq!(event, "left");
    }

    #[test]
    fn the_point_lands_in_the_middle_of_the_cell() {
        let events = parse("left@12,5").expect("parse");
        let moved = events.first().expect("one event").to_move(geometry());
        // Column 12 spans 96..104 and row 5 spans 80..96; the middle of each is what the encoder
        // must round to the same cell from either side.
        assert!((moved.x - 100.0).abs() < f32::EPSILON, "x was {}", moved.x);
        assert!((moved.y - 88.0).abs() < f32::EPSILON, "y was {}", moved.y);
    }

    #[test]
    fn padding_moves_the_point_with_the_grid() {
        let padded = SurfaceGeometry {
            padding_left: 10,
            padding_top: 4,
            ..geometry()
        };
        let events = parse("left@0,0").expect("parse");
        let moved = events.first().expect("one event").to_move(padded);
        assert!((moved.x - 14.0).abs() < f32::EPSILON, "x was {}", moved.x);
        assert!((moved.y - 12.0).abs() < f32::EPSILON, "y was {}", moved.y);
    }
}
