//! A recorded terminal session: what a real program wrote, and what was typed at it.
//!
//! ## What a recording is for
//!
//! A fuzz corpus proves the engine survives hostile bytes. It says nothing about the shape a modern
//! TUI actually produces — a full-screen redraw every frame, a scrolling region redrawn in place,
//! an alternate screen entered and left, colours that change per frame, a cursor parked somewhere
//! specific between frames. The cheapest honest source of that shape is a real program, run once,
//! with everything it wrote written down.
//!
//! A recording is therefore an INPUT, not a golden file. Nothing in it is an expected answer: the
//! frames are recomputed on every run and checked against the engine, so there is nothing to
//! re-bless when the engine pin moves. That is why it is not covered by the golden-vector rule.
//!
//! ## Why the pty read boundaries are kept
//!
//! Each [`Event::Output`] is one `read(2)` from the pty master, exactly as it arrived. That is the
//! whole reason a recording tests more than the bytes concatenated: a terminal that only ever sees
//! whole escape sequences is not the terminal that ships. Replaying the reads in order is a chunk
//! schedule the real world chose, for free.
//!
//! ## Why the input is a script and not just bytes
//!
//! [`Event::Input`] carries both the script that was pressed and the bytes
//! [`crate::VtSession::encode_key`] produced for it AT THAT POINT IN THE STREAM. A replay
//! re-encodes the script against the terminal the preceding output built and compares. What that
//! tests is not the engine's encoder — that is upstream's — but the integration: an application
//! turns on the kitty protocol with an escape sequence, and the next keystroke has to be encoded
//! the new way. The recording is the only place that ordering is captured.
//!
//! [`Event::Mouse`], [`Event::Paste`] and [`Event::Focus`] are the same argument for the other
//! three things a surface sends up a pty, and each has a mode the program turns on mid-stream that
//! decides what the bytes are — mouse tracking and its report format, bracketed paste, focus
//! reporting. An event whose bytes are EMPTY is not a gap: it is the recorded refusal of a surface
//! asked to report something no program had asked to hear about, and a replay that started
//! producing bytes there would be sending a running program input it never consented to.

use crate::input::SurfaceGeometry;
use crate::keyscript::{self, KeyEvent, ScriptError};
use crate::mousescript::{self, MouseScriptError};

/// The magic and version at the head of every recording.
const MAGIC: &[u8] = b"SDREC2\n";

/// The surface geometry a recording's grid implies, with no padding.
///
/// The ONE place the conversion lives. The recorder sets this before encoding a pointer event and
/// the replay sets the same thing before re-encoding it; a second spelling of `width = cols ×
/// cell_width` in either would make a pointer report that disagreed with itself look like an
/// encoder bug.
#[must_use]
pub const fn geometry_of(cols: u16, rows: u16, cell_width: u32, cell_height: u32) -> SurfaceGeometry {
    SurfaceGeometry {
        width: (cols as u32).saturating_mul(cell_width),
        height: (rows as u32).saturating_mul(cell_height),
        cell_width,
        cell_height,
        padding_top: 0,
        padding_bottom: 0,
        padding_left: 0,
        padding_right: 0,
    }
}

/// One keystroke run: the presses it spells, and the bytes it encoded to when it was pressed.
pub type TypedRun<'a> = (Vec<KeyEvent>, &'a [u8]);

/// One thing that happened during a recorded session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// One `read(2)` from the pty master, byte for byte.
    Output(Vec<u8>),
    /// A keystroke run and the bytes it encoded to when it was pressed.
    Input {
        /// The [`crate::keyscript`] spelling of what was pressed.
        script: String,
        /// What [`crate::VtSession::encode_key`] produced for it, in order.
        bytes: Vec<u8>,
    },
    /// What the terminal answered the program with — a DA, a DSR, a XTGETTCAP reply.
    ///
    /// Kept separately from [`Self::Input`] because it is not something a user did: a modern TUI
    /// blocks on these at startup, so a replay that never produces them is replaying a session the
    /// program would never have got past.
    Reply(Vec<u8>),
    /// A pointer run and the bytes it encoded to when it was made.
    ///
    /// Empty `bytes` is the recorded REFUSAL: [`crate::VtSession::encode_mouse`] writes nothing and
    /// answers `false` when no program has asked for mouse reporting, which is the surface's signal
    /// that the gesture is its own to handle as a selection or a scroll. A replay checks the
    /// refusal exactly as it checks a report.
    Mouse {
        /// The [`crate::mousescript`] spelling of what the pointer did.
        script: String,
        /// What [`crate::VtSession::encode_mouse`] produced for it, in order.
        bytes: Vec<u8>,
    },
    /// A paste and the bytes it encoded to when it was made.
    ///
    /// The text is kept rather than only the bytes because the bracketing is the thing under test:
    /// the same text is `text` alone or `ESC [ 200 ~ text ESC [ 201 ~` depending on a mode the
    /// program turned on, and only re-encoding the text can tell which.
    Paste {
        /// What was pasted.
        text: String,
        /// What [`crate::VtSession::encode_paste`] produced for it.
        bytes: Vec<u8>,
    },
    /// The surface gaining or losing focus, and the bytes that went up the pty for it.
    ///
    /// Empty `bytes` is again the recorded refusal — a program that never enabled mode 1004 hears
    /// nothing about focus, and a replay that reported anyway would be writing into a program's
    /// input on a window event it never subscribed to.
    Focus {
        /// Whether the surface took focus.
        focused: bool,
        /// The `CSI I`/`CSI O` this produced, or nothing.
        bytes: Vec<u8>,
    },
}

/// A session, recorded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Recording {
    /// The grid the session ran at.
    pub cols: u16,
    /// The grid the session ran at.
    pub rows: u16,
    /// The cell width in device pixels the session ran at.
    pub cell_width: u32,
    /// The cell height in device pixels the session ran at.
    pub cell_height: u32,
    /// What was recorded, in a form a human reading a failure can recognise.
    pub title: String,
    /// Everything that happened, in order.
    pub events: Vec<Event>,
}

/// Why a recording could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    /// The head of the file is not a recording of a version this understands.
    BadMagic,
    /// The file ends inside a field.
    Truncated {
        /// The byte offset the read ran off the end at.
        at: usize,
    },
    /// An event tag this version does not have.
    UnknownEvent {
        /// The tag byte.
        tag: u8,
        /// Where it sat.
        at: usize,
    },
    /// A string field is not UTF-8.
    NotUtf8 {
        /// Where the field started.
        at: usize,
    },
    /// A keystroke script field does not parse.
    BadScript(ScriptError),
    /// A pointer script field does not parse.
    BadMouseScript(MouseScriptError),
}

impl core::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::BadMagic => f.write_str("not a SDREC2 recording"),
            Self::Truncated { at } => write!(f, "recording ends inside a field at byte {at}"),
            Self::UnknownEvent { tag, at } => write!(f, "unknown event tag {tag} at byte {at}"),
            Self::NotUtf8 { at } => write!(f, "field at byte {at} is not UTF-8"),
            Self::BadScript(error) => write!(f, "recorded key script does not parse: {error}"),
            Self::BadMouseScript(error) => {
                write!(f, "recorded pointer script does not parse: {error}")
            },
        }
    }
}

impl core::error::Error for DecodeError {}

impl From<ScriptError> for DecodeError {
    fn from(value: ScriptError) -> Self {
        Self::BadScript(value)
    }
}

impl From<MouseScriptError> for DecodeError {
    fn from(value: MouseScriptError) -> Self {
        Self::BadMouseScript(value)
    }
}

impl Recording {
    /// The bytes this recording is stored as.
    ///
    /// Little-endian lengths in front of every variable field, so a reader never has to scan for a
    /// terminator and a byte stream containing anything at all round-trips.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&self.cols.to_le_bytes());
        out.extend_from_slice(&self.rows.to_le_bytes());
        out.extend_from_slice(&self.cell_width.to_le_bytes());
        out.extend_from_slice(&self.cell_height.to_le_bytes());
        put_bytes(&mut out, self.title.as_bytes());
        put_len(&mut out, self.events.len());
        for event in &self.events {
            match event {
                Event::Output(bytes) => {
                    out.push(0);
                    put_bytes(&mut out, bytes);
                },
                Event::Input { script, bytes } => {
                    out.push(1);
                    put_bytes(&mut out, script.as_bytes());
                    put_bytes(&mut out, bytes);
                },
                Event::Reply(bytes) => {
                    out.push(2);
                    put_bytes(&mut out, bytes);
                },
                Event::Mouse { script, bytes } => {
                    out.push(3);
                    put_bytes(&mut out, script.as_bytes());
                    put_bytes(&mut out, bytes);
                },
                Event::Paste { text, bytes } => {
                    out.push(4);
                    put_bytes(&mut out, text.as_bytes());
                    put_bytes(&mut out, bytes);
                },
                Event::Focus { focused, bytes } => {
                    out.push(5);
                    out.push(u8::from(*focused));
                    put_bytes(&mut out, bytes);
                },
            }
        }
        out
    }

    /// Reads a recording back.
    ///
    /// # Errors
    /// [`DecodeError`] naming the byte the read failed at. A recording that decodes has every
    /// script in it parseable, which is checked here so that a replay never has to.
    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut reader = Reader { bytes, at: 0 };
        if reader.take(MAGIC.len())? != MAGIC {
            return Err(DecodeError::BadMagic);
        }
        let cols = reader.u16()?;
        let rows = reader.u16()?;
        let cell_width = reader.u32()?;
        let cell_height = reader.u32()?;
        let title = reader.string()?;
        let count = reader.len()?;

        let mut events = Vec::with_capacity(count.min(1024));
        for _ in 0..count {
            let at = reader.at;
            let tag = reader.u8()?;
            events.push(match tag {
                0 => Event::Output(reader.bytes()?.to_vec()),
                1 => {
                    let script = reader.string()?;
                    // Parsed here and thrown away: a recording whose script cannot be read is
                    // broken, and finding that out at decode time names the file rather than
                    // failing somewhere inside a replay loop.
                    drop(keyscript::parse(&script)?);
                    Event::Input {
                        script,
                        bytes: reader.bytes()?.to_vec(),
                    }
                },
                2 => Event::Reply(reader.bytes()?.to_vec()),
                3 => {
                    let script = reader.string()?;
                    drop(mousescript::parse(&script)?);
                    Event::Mouse {
                        script,
                        bytes: reader.bytes()?.to_vec(),
                    }
                },
                4 => {
                    Event::Paste {
                        text: reader.string()?,
                        bytes: reader.bytes()?.to_vec(),
                    }
                },
                5 => {
                    Event::Focus {
                        focused: reader.u8()? != 0,
                        bytes: reader.bytes()?.to_vec(),
                    }
                },
                other => {
                    return Err(DecodeError::UnknownEvent { tag: other, at });
                },
            });
        }
        Ok(Self {
            cols,
            rows,
            cell_width,
            cell_height,
            title,
            events,
        })
    }

    /// Every keystroke in the recording, parsed, paired with the bytes it produced.
    ///
    /// # Errors
    /// [`ScriptError`] — which [`Self::decode`] has already ruled out for a recording read from
    /// bytes, and which can only appear for one built by hand.
    pub fn key_events(&self) -> Result<Vec<TypedRun<'_>>, ScriptError> {
        self.events
            .iter()
            .filter_map(|event| {
                match event {
                    Event::Input { script, bytes } => Some((script, bytes)),
                    Event::Output(_)
                    | Event::Reply(_)
                    | Event::Mouse { .. }
                    | Event::Paste { .. }
                    | Event::Focus { .. } => None,
                }
            })
            .map(|(script, bytes)| Ok((keyscript::parse(script)?, bytes.as_slice())))
            .collect()
    }

    /// The surface geometry this recording's grid implies.
    ///
    /// Both the recorder and the replay set this on the session before a pointer event, which is
    /// what makes a re-encoded mouse report land on the cell the script named.
    #[must_use]
    pub const fn geometry(&self) -> SurfaceGeometry {
        geometry_of(self.cols, self.rows, self.cell_width, self.cell_height)
    }
}

/// Appends a length-prefixed byte field.
fn put_bytes(out: &mut Vec<u8>, bytes: &[u8]) {
    put_len(out, bytes.len());
    out.extend_from_slice(bytes);
}

/// Appends a `u32` length, saturating rather than wrapping.
///
/// A recording longer than 4 GiB is not a thing this format carries, and saturating is the failure
/// that a decoder catches as a truncation rather than one that silently reads the wrong field.
fn put_len(out: &mut Vec<u8>, len: usize) {
    let value = u32::try_from(len).unwrap_or(u32::MAX);
    out.extend_from_slice(&value.to_le_bytes());
}

/// A cursor over the encoded bytes that can only move forward.
struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8], DecodeError> {
        let end = self
            .at
            .checked_add(count)
            .ok_or(DecodeError::Truncated { at: self.at })?;
        let slice = self
            .bytes
            .get(self.at..end)
            .ok_or(DecodeError::Truncated { at: self.at })?;
        self.at = end;
        Ok(slice)
    }

    fn u8(&mut self) -> Result<u8, DecodeError> {
        self.take(1)?
            .first()
            .copied()
            .ok_or(DecodeError::Truncated { at: self.at })
    }

    fn u16(&mut self) -> Result<u16, DecodeError> {
        let slice = self.take(2)?;
        let array: [u8; 2] = slice
            .try_into()
            .map_err(|_ignored| DecodeError::Truncated { at: self.at })?;
        Ok(u16::from_le_bytes(array))
    }

    fn u32(&mut self) -> Result<u32, DecodeError> {
        let slice = self.take(4)?;
        let array: [u8; 4] = slice
            .try_into()
            .map_err(|_ignored| DecodeError::Truncated { at: self.at })?;
        Ok(u32::from_le_bytes(array))
    }

    fn len(&mut self) -> Result<usize, DecodeError> {
        Ok(self.u32()? as usize)
    }

    fn bytes(&mut self) -> Result<&'a [u8], DecodeError> {
        let len = self.len()?;
        self.take(len)
    }

    fn string(&mut self) -> Result<String, DecodeError> {
        let at = self.at;
        let bytes = self.bytes()?;
        core::str::from_utf8(bytes)
            .map(str::to_owned)
            .map_err(|_ignored| DecodeError::NotUtf8 { at })
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a test that cannot decode what it just encoded has failed"
)]
mod tests {
    use super::{DecodeError, Event, Recording};

    fn sample() -> Recording {
        Recording {
            cols: 81,
            rows: 25,
            cell_width: 8,
            cell_height: 16,
            title: "sample".to_owned(),
            events: vec![
                Event::Output(b"\x1b[2J\x1b[Hhello".to_vec()),
                Event::Reply(b"\x1b[?62;22c".to_vec()),
                Event::Input {
                    script: "<C-c>".to_owned(),
                    bytes: vec![0x03],
                },
                Event::Mouse {
                    script: "left@12,5 release:left@12,5".to_owned(),
                    bytes: b"\x1b[<0;13;6M\x1b[<0;13;6m".to_vec(),
                },
                Event::Paste {
                    text: "two words".to_owned(),
                    bytes: b"\x1b[200~two words\x1b[201~".to_vec(),
                },
                Event::Focus {
                    focused: true,
                    bytes: b"\x1b[I".to_vec(),
                },
                // A read that ends mid-escape is the shape the format exists to keep.
                Event::Output(b"\x1b[3".to_vec()),
                Event::Output(b"1mred".to_vec()),
            ],
        }
    }

    #[test]
    fn a_recording_round_trips() {
        let original = sample();
        let decoded = Recording::decode(&original.encode()).expect("decode");
        assert_eq!(decoded, original);
    }

    #[test]
    fn an_empty_output_read_survives() {
        // Zero-length reads happen and must not be confused with the end of the file.
        let original = Recording {
            events: vec![Event::Output(Vec::new()), Event::Reply(Vec::new())],
            ..sample()
        };
        assert_eq!(Recording::decode(&original.encode()).expect("decode"), original);
    }

    #[test]
    fn a_truncated_file_names_the_byte() {
        let bytes = sample().encode();
        let cut = bytes
            .get(..bytes.len().saturating_sub(3))
            .expect("prefix")
            .to_vec();
        assert!(matches!(
            Recording::decode(&cut),
            Err(DecodeError::Truncated { .. })
        ));
    }

    #[test]
    fn a_foreign_file_is_refused_before_anything_is_read() {
        assert_eq!(Recording::decode(b"asciicast v2"), Err(DecodeError::BadMagic));
    }

    #[test]
    fn a_script_that_does_not_parse_fails_at_decode_time() {
        let original = Recording {
            events: vec![Event::Input {
                script: "<Nope>".to_owned(),
                bytes: Vec::new(),
            }],
            ..sample()
        };
        assert!(matches!(
            Recording::decode(&original.encode()),
            Err(DecodeError::BadScript(_))
        ));
    }

    #[test]
    fn a_pointer_script_that_does_not_parse_fails_at_decode_time() {
        let original = Recording {
            events: vec![Event::Mouse {
                script: "sideways@1".to_owned(),
                bytes: Vec::new(),
            }],
            ..sample()
        };
        assert!(matches!(
            Recording::decode(&original.encode()),
            Err(DecodeError::BadMouseScript(_))
        ));
    }

    #[test]
    fn a_refusal_round_trips_as_a_refusal() {
        // Empty bytes on a pointer or focus event mean the surface was asked to report something no
        // program had subscribed to. That is a recorded fact, not a missing field, so it has to
        // survive the file rather than being confused with a truncation.
        let original = Recording {
            events: vec![
                Event::Mouse {
                    script: "left@0,0".to_owned(),
                    bytes: Vec::new(),
                },
                Event::Focus {
                    focused: false,
                    bytes: Vec::new(),
                },
            ],
            ..sample()
        };
        assert_eq!(Recording::decode(&original.encode()).expect("decode"), original);
    }

    #[test]
    fn the_geometry_is_the_grid_times_the_cell() {
        let recording = sample();
        let geometry = recording.geometry();
        assert_eq!(geometry.width, 81 * 8);
        assert_eq!(geometry.height, 25 * 16);
        assert_eq!(geometry.padding_left, 0);
    }

    #[test]
    fn key_events_pair_each_script_with_its_bytes() {
        let recording = sample();
        let pairs = recording.key_events().expect("scripts parse");
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs.first().map(|(events, _)| events.len()), Some(1));
        assert_eq!(pairs.first().map(|(_, bytes)| *bytes), Some(&[0x03][..]));
    }
}
