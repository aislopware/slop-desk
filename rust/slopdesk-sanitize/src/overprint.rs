//! Replay hygiene: superseded line revisions contribute nothing.
//!
//! Drops the SUPERSEDED revisions of a line that a progress reporter overprints in place with `CR`
//! (or `CSI 1 G`), from a scrollback REPLAY stream.
//!
//! ## Why
//! `git push`, `swift build`/`swift test`, `npm`, `pip`, `cargo`, `docker pull` — every tool that
//! draws a percentage — repaints ONE line hundreds or thousands of times: `…: 1%\r…: 2%\r…`, or
//! `CSI 2K CR` then the new text. The final display is two or three lines; the recorded byte stream
//! is megabytes. On a COLD reattach every superseded revision is re-sent and re-parsed by the
//! client's terminal, which is seconds of wire + VT work whose entire visible result is the LAST
//! revision. The alt-screen and synchronized-output passes cannot see this churn: it never enters
//! the alt screen and is never wrapped in a synchronized-output frame, and the distiller passes the
//! command-OUTPUT span (`133;C`→`D`) verbatim by contract.
//!
//! ## What survives
//! A line is split at each cursor-to-column-0 motion (`CR`, `CSI G`/`CSI 1 G`) into REVISIONS, each
//! painting from column 0. A revision is dropped only when LATER revisions of the same line TOUCH
//! every column it touched — are at least as wide, or erase across it (`CSI K`) — because then the
//! last writer of each of those columns is a later revision either way. Anything else is kept:
//! - the LAST revision of the line, always (that is the visible state);
//! - a revision WIDER than everything after it — its tail survives on screen, exactly as a real
//!   terminal leaves progress residue behind a shorter successor;
//! - a revision that ERASES more than its successors touch: its blanking is what put those columns
//!   in their final state (so the final `CSI 2 K` of a repaint loop survives, at one revision's
//!   cost, while the thousands before it do not);
//! - every revision of a line the pass cannot model exactly — any cursor motion other than the
//!   column-0 reset, `BS`/`HT`, an OSC/DCS/`ESC`-pair, or malformed UTF-8 marks the whole line
//!   UNSAFE and it is emitted byte-for-byte (the "never cleaner than raw" fallback the sibling
//!   passes take).
//!
//! Zero-width state a dropped revision established still applies to the survivor: `SGR` and the
//! position-neutral `?25`/`?7` (cursor visibility, autowrap) toggles are CARRIED FORWARD and
//! re-emitted ahead of the next kept revision, so a coloured bar keeps its colour. A revision that
//! OPENS with a zero-width scalar (combining mark, ZWJ, variation selector) marks the line UNSAFE:
//! the mark attaches to the last printed cell, which belongs to a predecessor a drop would take
//! away with it.
//!
//! Known accepted gaps (the first mirrors the sync-frame pass's autowrap gap):
//! - A revision WIDER than the recording-time grid wrapped onto extra rows, and its `CR` then
//!   returned to the start of the LAST visual row only — so its earlier rows survived on screen and
//!   dropping the revision loses them. The pass has no grid width (the ring spans resizes, and the
//!   client re-wraps at its own width anyway, so that layout was never faithfully replayable).
//!   Width-aware progress reporters — which is what emits this churn — never exceed the grid.
//! - A LINE whose first scalar is a zero-width mark attaches it across the line boundary into the
//!   PREVIOUS line, whose keep decisions are already emitted. The mark's target only moves if that
//!   line's final revision painted nothing while earlier revisions were dropped — an erase-only
//!   tail under a mark-led successor, which no real reporter produces.
//!
//! ## Where it runs
//! ONLY on the replay-side transform, after the sync-frame collapser and before the distiller
//! (megabytes less for the distiller to scan; lines carrying an OSC `133` mark are UNSAFE here, so
//! every mark reaches it verbatim). The live byte stream and the un-acked resume tail are
//! untouched.
//!
//! It lives in screend rather than in the Swift chain around it for one reason: it needs
//! [`scalar_width`](crate::width::scalar_width), and a display-width table that exists in two
//! languages is the cross-language mirror this tree forbids.

// Every index here is into a vector this module owns and just measured — `revisions[last]` where
// `last` came from its own `len`, `keep[index]` where the two were built in one pass and are the
// same length by construction. The bound is the construction, not a check anyone can skip.
#![expect(
    clippy::indexing_slicing,
    reason = "indexes vectors this module built and measured"
)]

use crate::width::scalar_width;

const ESC: u8 = 0x1B;
const CR: u8 = 0x0D;
const LF: u8 = 0x0A;

/// Cap on the carried-forward `SGR` bytes. A line with a hundred thousand dropped revisions would
/// otherwise accumulate their every `SGR` byte; past the cap the OLDEST carried sequences are
/// dropped whole (a later `SGR` overrides an earlier one for the same attribute, so the tail is the
/// load-bearing end). The `?25`/`?7` toggles live OUTSIDE the cap as two-slot state — a one-shot
/// `?25l` must survive any amount of colour churn.
const CARRY_CAP: usize = 4096;

/// Revision count at which the line's buffered revisions are COMPACTED in place. The keep rule is a
/// suffix-maximum, so applying it to the buffered prefix drops exactly what the final pass would
/// drop — a pure memory backstop for a single line repainted millions of times. Never runs on an
/// UNSAFE line: coverage is garbage once modelling has failed, and the verbatim guarantee needs
/// every byte (an unsafe line stops splitting instead, so the per-revision memory the threshold
/// bounds cannot accumulate there either).
const COMPACTION_THRESHOLD: usize = 65536;

/// Coverage of a revision that erases through the line's end (`CSI K`) — covers any width.
const FULL_COVERAGE: usize = usize::MAX;

/// One column-0 repaint of the current line.
///
/// Droppability rests on ONE quantity, `covers`: the columns the revision TOUCHES — paints a glyph
/// into or blanks with an erase. A revision is redundant exactly when later revisions touch every
/// column it did, because then the last writer of each of those columns is a later revision either
/// way. (Counting only what a revision still SHOWS would be wrong: a revision that merely erases
/// shows nothing yet still decides those columns.)
#[derive(Debug, Default)]
struct Revision {
    /// The `CR` / `CSI G` that opened this revision (empty for the line's first revision).
    prefix: Vec<u8>,
    /// Everything painted since that reset, verbatim.
    bytes: Vec<u8>,
    /// Just the zero-width state changes within `bytes` (`SGR`, `?25`/`?7`), in order.
    carry: Vec<u8>,
    /// Columns from 0 this revision paints or erases.
    covers: usize,
    /// Current column, so an erase knows which side of the cursor it clears.
    cursor: usize,
    /// Whether `cursor` is the TRUE column. A revision opened by `CR`/`CHA` starts at column 0 and
    /// always knows; the FIRST revision of a line inherits the column the previous line left (bare
    /// `LF` moves down WITHOUT returning to column 0), which is unknown when the buffer starts
    /// mid-stream or the previous line was unmodelled. Unknown ⇒ `keep_mask` never drops the
    /// revision: its painted span may reach past anything a successor covers.
    start_known: bool,
    /// Whether a width>0 glyph has landed yet. A zero-width scalar arriving BEFORE one attaches to
    /// a cell OUTSIDE this revision.
    painted_glyph: bool,
}

/// Byte-level parser phase. `CSI`/string bodies are tracked so a `CR` inside one is never mistaken
/// for a revision boundary.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum State {
    Ground,
    AfterEsc,
    Csi,
    /// OSC/DCS/SOS/PM/APC — line is already UNSAFE; consume to the terminator.
    StringBody,
    StringBodyEsc,
}

/// What a completed `CSI` sequence does to this pass's model.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum CsiEffect {
    /// `CSI G` / `CSI 1 G` (CHA to column 1) — a revision boundary, like `CR`.
    ColumnZero,
    /// `CSI Ps K` (EL) — 0 = cursor→end, 1 = start→cursor, 2 = the whole line.
    EraseInLine(i64),
    /// Zero-width, position-neutral state: `SGR`, and the `?25` / `?7` toggles.
    StateOnly,
    /// Anything else — the pass cannot place the cursor afterwards.
    Unmodelled,
}

/// Returns `data` with fully-covered line revisions removed.
#[must_use]
pub fn collapse(data: &[u8]) -> Vec<u8> {
    if data.is_empty() {
        return Vec::new();
    }
    let mut pass = Pass::new(data.len());
    for &byte in data {
        pass.consume(byte);
    }
    pass.finish()
}

/// The collapse pass's whole mutable state, so the byte loop reads as one machine rather than a
/// closure soup over a dozen captured locals.
#[derive(Debug)]
struct Pass {
    out: Vec<u8>,
    state: State,
    /// The in-progress escape sequence, decided at its final byte.
    seq: Vec<u8>,
    /// The column the current line starts in. `None` = unknown: the buffer opens mid-stream, so
    /// where the previous (unseen) line left the cursor is anybody's guess.
    start_column: Option<usize>,
    revisions: Vec<Revision>,
    line_unsafe: bool,
    /// Bytes of a partially-read multi-byte scalar.
    utf8_pending: Vec<u8>,
    utf8_needed: usize,
}

impl Pass {
    fn new(capacity: usize) -> Self {
        let mut pass = Self {
            out: Vec::with_capacity(capacity),
            state: State::Ground,
            seq: Vec::new(),
            start_column: None,
            revisions: Vec::new(),
            line_unsafe: false,
            utf8_pending: Vec::new(),
            utf8_needed: 0,
        };
        let opening = pass.opening_revision();
        pass.revisions.push(opening);
        pass
    }

    /// The line's opening revision, seeded with whatever the previous line left behind.
    fn opening_revision(&self) -> Revision {
        let Some(column) = self.start_column else {
            // `keep_mask` never drops it — its true span is unknowable.
            return Revision {
                start_known: false,
                ..Revision::default()
            };
        };
        // It paints from HERE, not from column 0.
        Revision {
            cursor: column,
            start_known: true,
            ..Revision::default()
        }
    }

    fn current(&mut self) -> &mut Revision {
        // The pass never empties `revisions` without pushing an opening one back, so the fallback
        // is unreachable; it exists so this returns a reference rather than an index every
        // caller re-checks.
        if self.revisions.is_empty() {
            self.revisions.push(Revision {
                start_known: false,
                ..Revision::default()
            });
        }
        let last = self.revisions.len() - 1;
        &mut self.revisions[last]
    }

    fn consume(&mut self, byte: u8) {
        match self.state {
            State::Ground => self.consume_ground(byte),
            State::AfterEsc => self.consume_after_esc(byte),
            State::Csi => self.consume_csi(byte),
            State::StringBody => {
                self.current().bytes.push(byte);
                match byte {
                    0x07 => self.state = State::Ground, // BEL terminates
                    ESC => self.state = State::StringBodyEsc,
                    _ => {},
                }
            },
            State::StringBodyEsc => {
                self.current().bytes.push(byte);
                self.state = if byte == b'\\' {
                    State::Ground
                } else {
                    State::StringBody
                };
            },
        }
    }

    fn consume_ground(&mut self, byte: u8) {
        match byte {
            ESC => {
                self.abandon_partial_scalar();
                self.seq.clear();
                self.seq.push(ESC);
                self.state = State::AfterEsc;
            },
            CR => {
                self.abandon_partial_scalar();
                self.start_revision(vec![CR]);
            },
            LF => self.flush_line(Some(LF)),
            0x0B | 0x0C => {
                // VT / FF — a vertical motion this pass does not model.
                self.line_unsafe = true;
                self.flush_line(Some(byte));
            },
            _ => self.consume_ground_byte(byte),
        }
    }

    fn abandon_partial_scalar(&mut self) {
        if !self.utf8_pending.is_empty() {
            self.line_unsafe = true;
        }
        self.utf8_pending.clear();
        self.utf8_needed = 0;
    }

    fn consume_after_esc(&mut self, byte: u8) {
        self.seq.push(byte);
        match byte {
            b'[' => self.state = State::Csi,
            b']' | b'P' | b'X' | b'^' | b'_' => {
                self.line_unsafe = true;
                self.append_sequence(false, None);
                self.state = State::StringBody;
            },
            ESC => {
                // Consecutive ESC — the first was a lone one; keep this as the introducer.
                self.line_unsafe = true;
                self.seq.pop();
                self.append_sequence(false, None);
                self.seq.push(ESC);
            },
            _ => {
                // A two-byte escape (IND/RI/NEL/DECSC/…) — not modelled.
                self.line_unsafe = true;
                self.append_sequence(false, None);
                self.state = State::Ground;
            },
        }
    }

    fn consume_csi(&mut self, byte: u8) {
        self.seq.push(byte);
        if !(0x40..=0x7E).contains(&byte) {
            // Parameter (0x30–0x3F) or intermediate (0x20–0x2F) byte — keep accumulating.
            if !(0x20..=0x3F).contains(&byte) {
                self.line_unsafe = true; // malformed CSI
                self.append_sequence(false, None);
                self.state = State::Ground;
            }
            return;
        }
        match classify_csi(&self.seq) {
            CsiEffect::ColumnZero => {
                let prefix = std::mem::take(&mut self.seq);
                self.start_revision(prefix);
            },
            CsiEffect::EraseInLine(mode) => self.append_sequence(false, Some(mode)),
            CsiEffect::StateOnly => self.append_sequence(true, None),
            CsiEffect::Unmodelled => {
                self.line_unsafe = true;
                self.append_sequence(false, None);
            },
        }
        self.seq.clear();
        self.state = State::Ground;
    }

    /// Appends the completed escape sequence to the current revision, classifying its effect.
    fn append_sequence(&mut self, carries_state: bool, erase: Option<i64>) {
        let seq = std::mem::take(&mut self.seq);
        let revision = self.current();
        revision.bytes.extend_from_slice(&seq);
        if carries_state {
            revision.carry.extend_from_slice(&seq);
        }
        match erase {
            // cursor → end of line, on top of what it already painted: the whole line.
            Some(0 | 2) => revision.covers = FULL_COVERAGE,
            // start of line → cursor INCLUSIVE.
            Some(1) => revision.covers = revision.covers.max(revision.cursor + 1),
            _ => {},
        }
        self.seq = seq;
        self.seq.clear();
    }

    /// Opens a new revision at column 0 (the `CR` / `CSI G` in `prefix`).
    fn start_revision(&mut self, prefix: Vec<u8>) {
        if self.line_unsafe {
            // The line is already verbatim; splitting buys nothing and each revision costs memory
            // that the (safe-only) compaction backstop could no longer reclaim.
            self.current().bytes.extend_from_slice(&prefix);
            return;
        }
        self.revisions.push(Revision {
            prefix,
            start_known: true,
            ..Revision::default()
        });
        if self.revisions.len() >= COMPACTION_THRESHOLD {
            self.compact_revisions();
        }
    }

    /// Folds one non-control ground byte into the current revision, tracking display width across
    /// UTF-8 scalars. A malformed sequence marks the line UNSAFE (its width — and so its coverage —
    /// would be a guess).
    fn consume_ground_byte(&mut self, byte: u8) {
        let mut unsafe_line = false;
        let mut width: Option<usize> = None;
        if self.utf8_needed > 0 {
            if (0x80..=0xBF).contains(&byte) {
                self.utf8_pending.push(byte);
                self.utf8_needed -= 1;
                if self.utf8_needed == 0 {
                    match decode_scalar(&self.utf8_pending) {
                        Some(scalar) => width = Some(scalar_width(scalar)),
                        None => unsafe_line = true,
                    }
                    self.utf8_pending.clear();
                }
            } else {
                unsafe_line = true;
                self.utf8_pending.clear();
                self.utf8_needed = 0;
            }
            self.current().bytes.push(byte);
            // The push above must land before the early return: an abandoned scalar is still bytes
            // the revision emitted.
            self.finish_ground_byte(width, unsafe_line);
            return;
        }
        match byte {
            0x20..=0x7E => width = Some(1),
            0x7F => {}, // DEL — ignored by a terminal, zero width.
            // BS/HT/BEL/… — a motion or effect this pass does not model. 0x80–0xC1 and 0xF5–0xFF
            // are never a valid UTF-8 lead, and are equally unmodellable.
            0x00..=0x1F | 0x80..=0xC1 | 0xF5..=0xFF => unsafe_line = true,
            0xC2..=0xDF => {
                self.utf8_pending.clear();
                self.utf8_pending.push(byte);
                self.utf8_needed = 1;
            },
            0xE0..=0xEF => {
                self.utf8_pending.clear();
                self.utf8_pending.push(byte);
                self.utf8_needed = 2;
            },
            0xF0..=0xF4 => {
                self.utf8_pending.clear();
                self.utf8_pending.push(byte);
                self.utf8_needed = 3;
            },
        }
        self.current().bytes.push(byte);
        self.finish_ground_byte(width, unsafe_line);
    }

    fn finish_ground_byte(&mut self, width: Option<usize>, mut unsafe_line: bool) {
        if let Some(width) = width {
            let revision = self.current();
            // A zero-width scalar attaches to the LAST printed cell; before this revision has
            // painted one, that cell belongs to a PREDECESSOR a drop would take with it.
            if width == 0 && !revision.painted_glyph {
                unsafe_line = true;
            }
            if width > 0 {
                revision.painted_glyph = true;
            }
            revision.cursor += width;
            revision.covers = revision.covers.max(revision.cursor);
        }
        if unsafe_line {
            self.line_unsafe = true;
        }
    }

    /// Emits the buffered line plus `terminator`, dropping every fully-covered revision. An UNSAFE
    /// line is emitted byte-for-byte — also after a compaction, whose own drops happened while the
    /// line was still modelled and are therefore screen-neutral.
    fn flush_line(&mut self, terminator: Option<u8>) {
        if !self.utf8_pending.is_empty() {
            self.line_unsafe = true; // truncated scalar — width unknowable
        }
        if self.line_unsafe {
            for revision in &self.revisions {
                self.out.extend_from_slice(&revision.prefix);
                self.out.extend_from_slice(&revision.bytes);
            }
        } else {
            let keep = keep_mask(&self.revisions);
            let mut carried = Carry::default();
            for (index, revision) in self.revisions.iter().enumerate() {
                if !keep[index] {
                    carried.absorb(&revision.carry);
                    continue;
                }
                self.out.extend_from_slice(&revision.prefix);
                carried.take(&mut self.out);
                self.out.extend_from_slice(&revision.bytes);
            }
        }
        if let Some(terminator) = terminator {
            self.out.push(terminator);
        }
        // `LF`/`VT`/`FF` move DOWN without returning to column 0, so the next line opens where this
        // one left the cursor — known only when the surviving last revision tracked it (an
        // unmodelled line's cursor is a guess, and a guess would drop visible content).
        let last_known = self.revisions.last().is_some_and(|last| last.start_known);
        let last_cursor = self.revisions.last().map_or(0, |last| last.cursor);
        self.start_column = if self.line_unsafe || !last_known {
            None
        } else {
            Some(last_cursor)
        };
        self.revisions.clear();
        let opening = self.opening_revision();
        self.revisions.push(opening);
        self.line_unsafe = false;
        self.utf8_pending.clear();
        self.utf8_needed = 0;
    }

    /// Rewrites the buffered revisions to the survivors of the keep rule (memory backstop).
    fn compact_revisions(&mut self) {
        let keep = keep_mask(&self.revisions);
        // Half the buffered count is a guess at the survivor count, not a bound — the vector grows
        // if the keep rule spares more.
        #[expect(clippy::integer_division, reason = "a capacity hint, deliberately halved")]
        let mut survivors: Vec<Revision> = Vec::with_capacity(self.revisions.len() / 2 + 1);
        let mut carried = Carry::default();
        for (index, revision) in std::mem::take(&mut self.revisions).into_iter().enumerate() {
            if !keep[index] {
                carried.absorb(&revision.carry);
                continue;
            }
            let mut survivor = revision;
            if !carried.is_empty() {
                // Fold the carry INTO the survivor: it is zero-width, so coverage is unchanged and
                // both the emitted bytes and a later carry stay in the original order.
                let mut folded = Vec::new();
                carried.take(&mut folded);
                let mut bytes = folded.clone();
                bytes.append(&mut survivor.bytes);
                survivor.bytes = bytes;
                let mut carry = folded;
                carry.append(&mut survivor.carry);
                survivor.carry = carry;
            }
            survivors.push(survivor);
        }
        self.revisions = survivors;
    }

    /// End of stream: a dangling escape and the unterminated final line are emitted as-is.
    fn finish(mut self) -> Vec<u8> {
        if !self.seq.is_empty() {
            self.line_unsafe = true;
            let seq = std::mem::take(&mut self.seq);
            self.current().bytes.extend_from_slice(&seq);
        }
        if matches!(self.state, State::StringBody | State::StringBodyEsc) {
            self.line_unsafe = true;
        }
        self.flush_line(None);
        self.out
    }
}

/// The keep rule, as ONE function for both the final flush and mid-line compaction (the two must
/// never drift — compaction's whole claim is that it drops exactly what the flush would).
///
/// A revision survives when it is the last (the visible state), when its coverage exceeds every
/// later revision's (suffix maximum — its tail is still on screen), or when its start column is
/// UNKNOWN (its true span is unknowable, so no successor can be proven to bury it — not even one
/// that erases the whole line, since the unknown paint may have wrapped rows).
fn keep_mask(revisions: &[Revision]) -> Vec<bool> {
    let mut keep = vec![false; revisions.len()];
    let Some(last) = revisions.len().checked_sub(1) else {
        return keep;
    };
    keep[last] = true;
    let mut max_coverage = revisions[last].covers;
    for index in (0..last).rev() {
        if revisions[index].covers > max_coverage || !revisions[index].start_known {
            keep[index] = true;
        }
        max_coverage = max_coverage.max(revisions[index].covers);
    }
    keep
}

/// Decodes one complete multi-byte UTF-8 scalar.
///
/// An OVERLONG encoding is structurally complete but a terminal rejects it and paints nothing —
/// crediting it width would let a successor bury visible residue. Surrogates and out-of-range
/// values are rejected too.
fn decode_scalar(bytes: &[u8]) -> Option<u32> {
    let (mut value, minimum) = match bytes.len() {
        2 => (u32::from(bytes[0] & 0x1F), 0x80),
        3 => (u32::from(bytes[0] & 0x0F), 0x800),
        4 => (u32::from(bytes[0] & 0x07), 0x10000),
        _ => return None,
    };
    for &byte in &bytes[1..] {
        value = (value << 6) | u32::from(byte & 0x3F);
    }
    if value < minimum {
        return None;
    }
    char::from_u32(value).map(|scalar| scalar as u32)
}

/// Position-neutral DEC private modes: cursor visibility (DECTCEM) and autowrap (DECAWM). Every
/// other private mode (alt screen, mouse, sync, bracketed paste) belongs to a sibling pass and is
/// deliberately NOT modelled here.
const NEUTRAL_PRIVATE_MODES: [i64; 2] = [7, 25];

fn classify_csi(seq: &[u8]) -> CsiEffect {
    if seq.len() < 3 {
        return CsiEffect::Unmodelled;
    }
    let Some(&final_byte) = seq.last() else {
        return CsiEffect::Unmodelled;
    };
    let params = &seq[2..seq.len() - 1];
    let is_private = params.first() == Some(&b'?');
    // An intermediate byte (0x20–0x2F) means a sequence outside the small set modelled here.
    if params.iter().any(|byte| (0x20..=0x2F).contains(byte)) {
        return CsiEffect::Unmodelled;
    }
    let digits = if is_private { &params[1..] } else { params };
    if !digits.iter().all(|byte| byte.is_ascii_digit() || *byte == b';') {
        return CsiEffect::Unmodelled;
    }
    if is_private {
        if final_byte != b'h' && final_byte != b'l' {
            return CsiEffect::Unmodelled;
        }
        let values = split_params(digits);
        if values.is_empty() || !values.iter().all(|value| NEUTRAL_PRIVATE_MODES.contains(value)) {
            return CsiEffect::Unmodelled;
        }
        return CsiEffect::StateOnly;
    }
    match final_byte {
        b'm' => CsiEffect::StateOnly,
        b'K' => {
            let values = split_params(digits);
            let mode = values.first().copied().unwrap_or(0);
            // EL takes ONE parameter and only modes 0–2 exist; anything else is a sequence this
            // pass has no model for.
            if values.len() <= 1 && (0..=2).contains(&mode) {
                CsiEffect::EraseInLine(mode)
            } else {
                CsiEffect::Unmodelled
            }
        },
        // CHA is 1-based: an omitted or explicit 1 lands on column 0.
        b'G' => {
            let values = split_params(digits);
            if values.is_empty() || values == [1] {
                CsiEffect::ColumnZero
            } else {
                CsiEffect::Unmodelled
            }
        },
        _ => CsiEffect::Unmodelled,
    }
}

/// Splits a numeric CSI parameter run into its values. An omitted value reads as 0 (the VT
/// default), and an over-long run yields the `[-1]` sentinel — never a modelled mode or parameter,
/// so every caller's range check rejects it.
fn split_params(digits: &[u8]) -> Vec<i64> {
    if digits.is_empty() {
        return Vec::new();
    }
    let mut values = Vec::new();
    let mut accumulator: i64 = 0;
    let mut saw_digit = false;
    for &byte in digits {
        if byte == b';' {
            values.push(if saw_digit { accumulator } else { 0 });
            accumulator = 0;
            saw_digit = false;
        } else {
            accumulator = accumulator * 10 + i64::from(byte - 0x30);
            if accumulator > 65535 {
                return vec![-1]; // absurd parameter — never a modelled mode
            }
            saw_digit = true;
        }
    }
    values.push(if saw_digit { accumulator } else { 0 });
    values
}

/// The zero-width state of DROPPED revisions, replayed ahead of the next kept one.
///
/// Held as STATE rather than a byte stream so the cap cannot eat a one-shot toggle:
/// - the `?25`/`?7` modes keep only the LAST sequence that set each (exactly the state that
///   replaying every toggle would end in);
/// - `SGR` sequences accumulate in order, cleared whole by a full reset (`CSI m`, or a leading `0`
///   parameter), with the OLDEST discarded past [`CARRY_CAP`] — a later `SGR` overrides an earlier
///   one for the same attribute, so the tail is the load-bearing end. Only original sequences are
///   re-emitted, whole, so the carry can never exceed the bytes it absorbed.
#[derive(Debug, Default)]
struct Carry {
    /// Complete `SGR` sequences, oldest first, and their total byte count.
    sgr: Vec<Vec<u8>>,
    sgr_bytes: usize,
    /// Last sequence that set mode 7 / mode 25, stamped with an arrival clock so emission preserves
    /// their relative order (one sequence may set both).
    toggle7: Option<(u64, Vec<u8>)>,
    toggle25: Option<(u64, Vec<u8>)>,
    toggle_clock: u64,
}

impl Carry {
    const fn is_empty(&self) -> bool {
        self.sgr.is_empty() && self.toggle7.is_none() && self.toggle25.is_none()
    }

    /// Splits a dropped revision's carry into its sequences and folds each into the state.
    fn absorb(&mut self, carry: &[u8]) {
        if carry.is_empty() {
            return;
        }
        let mut start = 0;
        for index in 1..carry.len() {
            if carry[index] == ESC {
                self.fold(&carry[start..index]);
                start = index;
            }
        }
        self.fold(&carry[start..]);
    }

    fn fold(&mut self, seq: &[u8]) {
        let Some(&final_byte) = seq.last() else {
            return;
        };
        if final_byte == b'm' {
            // `CSI params m` — a reset as the FIRST parameter (0, or none at all) kills every
            // attribute before it. A 0 deeper in the list may be a colour component (`38;5;0`), so
            // only the leading position is trusted to reset.
            let values = split_params(seq.get(2..seq.len() - 1).unwrap_or_default());
            if values.first().copied().unwrap_or(0) == 0 {
                self.sgr.clear();
                self.sgr_bytes = 0;
            }
            self.sgr_bytes += seq.len();
            self.sgr.push(seq.to_vec());
            while self.sgr_bytes > CARRY_CAP && self.sgr.len() > 1 {
                self.sgr_bytes -= self.sgr.remove(0).len();
            }
        } else {
            // `CSI ? modes h/l` — only the final setting of each toggle is the truth.
            self.toggle_clock += 1;
            for mode in split_params(seq.get(3..seq.len() - 1).unwrap_or_default()) {
                if mode == 7 {
                    self.toggle7 = Some((self.toggle_clock, seq.to_vec()));
                }
                if mode == 25 {
                    self.toggle25 = Some((self.toggle_clock, seq.to_vec()));
                }
            }
        }
    }

    /// Appends the carried state (`SGR` oldest-first, then the toggles) and resets.
    fn take(&mut self, out: &mut Vec<u8>) {
        for seq in &self.sgr {
            out.extend_from_slice(seq);
        }
        match (self.toggle7.as_ref(), self.toggle25.as_ref()) {
            (None, None) => {},
            (Some(only), None) | (None, Some(only)) => out.extend_from_slice(&only.1),
            (Some(a), Some(b)) if a.0 == b.0 => out.extend_from_slice(&a.1), // one sequence set both
            (Some(a), Some(b)) => {
                let (first, second) = if a.0 < b.0 { (a, b) } else { (b, a) };
                out.extend_from_slice(&first.1);
                out.extend_from_slice(&second.1);
            },
        }
        *self = Self::default();
    }
}
