//! The connect GATE: the four fields that name a host, and the batch that leaves for it.
//!
//! One module for six rules that all sit on the same seam — the app-global link. Two of them run on
//! the KEYSTROKE path (the OUT batch plan), one runs once per successful connect (the recent-hosts
//! menu), and three run when something goes wrong (the failure reason, the form's refusal, the
//! reconnect fold). They were six Swift statics across two files, two of them spelled twice.
//!
//! ## Why the keystroke bytes never cross
//!
//! [`plan`] is the hot one: it runs on every drained OUT batch, which during a window drag is
//! ~100 events and during a paste is one very large one. The obvious boundary hands the door the
//! bytes and takes frames back, and it would be the wrong one — the rule does not READ a single
//! input byte. It reads LENGTHS. Merging two adjacent inputs is `a.len() + b.len()`; splitting an
//! oversized one is division; the barrier is the event's KIND. So what crosses is a side-table of
//! `(kind, length, cols, rows)` records, and what comes back is `(kind, offset, length, cols,
//! rows)` frames that NAME slices of a blob the near side already holds and never hands over.
//!
//! `docs/55` §4 states the convention this is an instance of — "the answer that is an OFFSET, not a
//! copy" — and the `decode_admission` worked pair states the test it passes: *the test is not how
//! big the value is, it is whether the far side READS the part that is big. Where it does not, the
//! boundary lands where the law's own inputs end.* A batch of 100 events crosses as 100 fixed-width
//! records whether the user dragged a window or pasted a megabyte.
//!
//! ### What the two halves are for
//!
//! [`coalesce`] is the resize-corruption fix. A fast, continuous window drag makes `libghostty`
//! emit a DISTINCT grid size per layout pass (59 → 60 → … → 145 columns), so the caller's
//! identical-size dedupe never fires and ~100 distinct resizes reach this path. Forwarding every
//! one sends ~100 `TIOCSWINSZ` to the host PTY spread over time, so the child's `SIGWINCH` handler
//! fires repeatedly at INTERMEDIATE sizes — and zsh's handler does an incremental prompt redraw
//! (cursor-up N lines, clear, redraw) with N computed for a size that keeps changing under it. The
//! redraw math desyncs, and an orphaned cursor survives until the next fresh prompt. A LOCAL
//! terminal never hits this, because the kernel COALESCES `SIGWINCH`: the app reads the LATEST size
//! once and jumps straight to final. This restores that on the wire.
//!
//! Two properties carry the whole fix. Input is a HARD BARRIER — a resize buffered before a
//! keystroke is emitted before it, never after — and the TRAILING-EDGE GUARANTEE: the last resize
//! of every batch is always emitted, by construction rather than by a timer that could be dropped.
//!
//! [`pack`] then normalises the input side of the same batch: adjacent payloads MERGE (a key repeat
//! or a mouse-report storm would otherwise pay an actor hop and a send round trip each) and an
//! oversized one SPLITS into frames the data sub-channel will accept. Concatenation byte-identity
//! holds by construction, because the frames partition the blob: every offset is the previous
//! frame's end, and the run always ends where its bytes do.
//!
//! ## The MRU answers a VIRTUAL index
//!
//! [`push_recent`] would be a natural fit for "positions of the entries that survive", except that
//! no such answer can say "and the new one goes here" — or express a limit of zero, where the
//! candidate itself is dropped. So the positions are into a list that does not exist yet: `0` is
//! the candidate and `i + 1` is existing entry `i`. Dedupe, the push-front and the cap all fall out
//! of one truncation, and the caller rebuilds its array without a branch.
//!
//! ## A reason with no words is not a reason
//!
//! [`failure_reason`] deliberately collapses empty and absent, which `docs/55` §4b otherwise bars
//! ("a zero LENGTH is not an absent VALUE"). The rule IS "pick the first non-empty of two strings":
//! a `LocalizedError` whose `errorDescription` is present but blank has told the user nothing, and
//! showing them a blank alert instead of the Swift payload behind it is a worse answer than the
//! `??` this replaced would have given. The presence flag would have to be ignored to get the right
//! behaviour, so it is not taken.
//!
//! ## One rule, two readings
//!
//! [`parse_target`] answers a target or a [`Hint`], and that single verdict is what makes
//! "`validationHint == nil` ⟺ the Connect button is live" STRUCTURAL rather than a comment. The two
//! Swift halves were separate — a `parsedTarget()` and a `validationHint` walking the same four
//! fields in the same order with two different sets of `if`s — which is the shape where a new field
//! gets added to one and not the other.
//!
//! ## The fold takes the discriminant alone
//!
//! [`reconnect_fold`] never sees the attempt count or the next-retry instant. They are the caller's
//! own payload for the status it adopts, and [`StatusKind`]'s own header already says why that is
//! the boundary: *the classifiers below read none of them, so what crosses is the discriminant
//! alone.*
//!
//! ## Two deliberate widenings over the Swift this replaced
//!
//! - **Trimming.** Rust's [`str::trim`] cuts Unicode `White_Space`; Swift's
//!   `CharacterSet.whitespaces` does not include a newline. A host or port pasted with a trailing
//!   newline used to be refused with a hint and is now accepted. That is the answer a person
//!   pasting from a terminal meant.
//! - **Host equality.** Swift's `String ==` is canonical equivalence; comparing UTF-8 bytes here is
//!   stricter. Two hostnames that differ only by Unicode normalisation would now be two MRU entries
//!   rather than one. Hostnames are ASCII in every case that reaches this, and a stricter identity
//!   errs towards keeping an entry the user typed rather than folding it into one they did not.

use crate::connection::StatusKind;

// ---------------------------------------------------------------------------------------------
// The OUT batch: what leaves for the host, and in how many frames
// ---------------------------------------------------------------------------------------------

/// One event the near side buffered on its way OUT, reduced to what the plan reads.
///
/// The input payload is a LENGTH, not bytes: see the module header. The near side keeps the bytes
/// concatenated in its own blob, in this same order, and the answer names slices of it.
#[expect(
    variant_size_differences,
    reason = "a length is a pointer-wide word and a grid size is two shorts; padding the resize out to \
              match would make an invalid state representable"
)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutEvent {
    /// Keystrokes — how many bytes this event contributes to the batch's input blob.
    Input(usize),
    /// A grid size the terminal asked the host PTY for.
    Resize {
        /// Columns.
        cols: u16,
        /// Rows.
        rows: u16,
    },
}

/// One frame the near side should actually send, in send order.
#[expect(
    variant_size_differences,
    reason = "a blob slice is two pointer-wide words and a grid size is two shorts; the gap is the price of \
              the two arms not being able to stand in for one another"
)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Frame {
    /// Send `[offset, offset + len)` of the batch's concatenated input blob.
    Input {
        /// Where the frame starts in the blob.
        offset: usize,
        /// How many bytes it runs for. Never zero — an empty frame is not a send.
        len: usize,
    },
    /// Send this grid size.
    Resize {
        /// Columns.
        cols: u16,
        /// Rows.
        rows: u16,
    },
}

/// LATEST-WINS resize coalescing, with input as a hard barrier.
///
/// Walk the arrival-ordered batch buffering the latest resize in a single slot; consecutive resizes
/// collapse to the last. An input FLUSHES that slot before it is appended, so input byte order is
/// never disturbed and a resize that physically preceded a keystroke is never emitted after it. At
/// end of batch the buffered resize is appended — the trailing-edge guarantee.
///
/// Exposed beside [`plan`] because it is the half [`teardown`-style residual flushes] want on their
/// own: a flush that sends only the surviving resize wants the resize rule and not the framing one.
/// The composition is what crosses; both halves are here so the properties can be pinned apart.
///
/// [`teardown`-style residual flushes]: plan
#[must_use]
pub fn coalesce(batch: &[OutEvent]) -> Vec<OutEvent> {
    if batch.len() < 2 {
        return batch.to_vec();
    }
    let mut out = Vec::with_capacity(batch.len());
    let mut pending: Option<OutEvent> = None;
    for event in batch {
        match *event {
            // Same run: keep only the latest.
            resize @ OutEvent::Resize { .. } => pending = Some(resize),
            input @ OutEvent::Input(_) => {
                // The barrier: the buffered resize goes out FIRST, then the bytes.
                if let Some(resize) = pending.take() {
                    out.push(resize);
                }
                out.push(input);
            },
        }
    }
    // The trailing resize run, which is the final drag size.
    if let Some(resize) = pending {
        out.push(resize);
    }
    out
}

/// Frames the input side of an (already coalesced) batch: merge adjacent payloads, split an
/// oversized one, and let a resize pass through as a hard barrier.
///
/// `max_input_frame_bytes` is the data sub-channel's payload ceiling, which the caller asks its own
/// flow-control constant for. A ceiling of zero is clamped to one rather than refused: this rule is
/// reached from a C boundary, and the alternative to clamping is a loop that never ends.
///
/// Concatenation byte-identity is by construction — the emitted input frames partition the blob's
/// `[0, total)` in order, so their bytes concatenate to exactly the input bytes.
#[must_use]
pub fn pack(events: &[OutEvent], max_input_frame_bytes: usize) -> Vec<Frame> {
    let ceiling = max_input_frame_bytes.max(1);
    let mut frames = Vec::with_capacity(events.len());
    // Where the buffered run starts in the blob, and how much of it is still unframed.
    let mut start = 0_usize;
    let mut buffered = 0_usize;
    for event in events {
        match *event {
            OutEvent::Input(len) => buffered = buffered.saturating_add(len),
            OutEvent::Resize { cols, rows } => {
                flush(&mut frames, &mut start, &mut buffered, ceiling);
                frames.push(Frame::Resize { cols, rows });
            },
        }
    }
    flush(&mut frames, &mut start, &mut buffered, ceiling);
    frames
}

/// Cuts the buffered run into frames of at most `ceiling` bytes and advances the blob cursor past
/// it. Saturating, because a batch whose lengths were summed from a hostile side must still end.
fn flush(frames: &mut Vec<Frame>, start: &mut usize, buffered: &mut usize, ceiling: usize) {
    while *buffered > 0 {
        let len = (*buffered).min(ceiling);
        frames.push(Frame::Input { offset: *start, len });
        *start = start.saturating_add(len);
        *buffered = buffered.saturating_sub(len);
    }
}

/// The whole OUT plan: [`coalesce`], then [`pack`].
///
/// The one door the near side calls. Resizes pass through `pack` unchanged and in order, so a
/// caller that wants the coalesce alone — a teardown flushing a residual backlog, where keystrokes
/// typed against a dying session are deliberately dropped — reads this answer and skips the input
/// frames rather than asking a second time.
#[must_use]
pub fn plan(batch: &[OutEvent], max_input_frame_bytes: usize) -> Vec<Frame> {
    pack(&coalesce(batch), max_input_frame_bytes)
}

// ---------------------------------------------------------------------------------------------
// The recent-hosts menu
// ---------------------------------------------------------------------------------------------

/// One entry in the gate's recent-hosts menu, reduced to what IDENTIFIES it.
///
/// Host and mux port are the identity; the two video ports are settings. A re-connect that changed
/// only the media port therefore REPLACES its entry rather than adding a second one for the same
/// machine — which is why the door answers positions in a list that includes the candidate, so the
/// replacement is the caller's own new value rather than the stale one it matched.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Endpoint<'a> {
    /// The machine, as the user typed it.
    pub host: &'a str,
    /// Its terminal-mux port.
    pub port: u16,
}

/// The recent-hosts menu after one successful connect, as positions into a VIRTUAL list where `0`
/// is `candidate` and `i + 1` is `existing[i]`.
///
/// Dedupe by host:port, push the candidate to the front, cap at `limit`. Every existing entry that
/// matches is dropped, not just the first: a list that already carried a duplicate — a hand-edited
/// `defaults` blob, an older build's write — comes back clean rather than carrying it forever.
///
/// A `limit` of zero answers nothing at all, which is the same answer the Swift this replaced gave.
#[must_use]
pub fn push_recent(candidate: Endpoint<'_>, existing: &[Endpoint<'_>], limit: usize) -> Vec<u32> {
    let mut order = Vec::with_capacity(existing.len().saturating_add(1));
    order.push(0_u32);
    for (index, entry) in existing.iter().enumerate() {
        if *entry == candidate {
            continue;
        }
        order.push(u32::try_from(index.saturating_add(1)).unwrap_or(u32::MAX));
    }
    order.truncate(limit);
    order
}

// ---------------------------------------------------------------------------------------------
// The failure reason
// ---------------------------------------------------------------------------------------------

/// The user-facing reason for a thrown connect error: the localized description when it has words,
/// else the readable payload behind it.
///
/// The two arguments are what the near side can get out of an `Error`, which cannot itself cross a
/// C ABI: a `LocalizedError`'s `errorDescription`, and `String(describing:)`. The second is what
/// keeps `invalidState("resume before first connect")` readable instead of collapsing to
/// Foundation's bridged "The operation couldn't be completed. (… error N.)", which is what a bare
/// `localizedDescription` prints for a plain Swift error enum.
///
/// See the module header for why an EMPTY localized description is treated as an absent one.
#[must_use]
pub const fn failure_reason<'a>(localized: &'a str, fallback: &'a str) -> &'a str {
    if localized.is_empty() { fallback } else { localized }
}

// ---------------------------------------------------------------------------------------------
// The form: four text fields to a target, or a refusal
// ---------------------------------------------------------------------------------------------

/// Why the gate's Connect button is disabled.
///
/// One hint per FIELD GROUP rather than per field: the two video ports live behind one disclosure
/// and are edited together, so naming which of the two is wrong would point at a row the user
/// cannot see.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hint {
    /// The host field is blank.
    Host,
    /// The terminal-mux port is not a number in 1–65535.
    Port,
    /// One of the two video ports is not a number in 1–65535.
    VideoPorts,
    /// The two video ports name the same port.
    PortsDiffer,
}

impl Hint {
    /// Every hint, in the order the codes number them.
    pub const ALL: [Self; 4] = [Self::Host, Self::Port, Self::VideoPorts, Self::PortsDiffer];

    /// What it says.
    #[must_use]
    pub const fn text(self) -> &'static str {
        match self {
            Self::Host => "Enter a host",
            Self::Port => "Port must be a number from 1–65535",
            Self::VideoPorts => "Video ports must be numbers from 1–65535",
            Self::PortsDiffer => "Media and cursor ports must differ",
        }
    }

    /// The code this hint crosses as. `0` means "no hint", so the codes start at one — an absent
    /// refusal is the common case and giving it the zero byte keeps a caller from having to carry a
    /// second flag beside the verdict.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Host => 1,
            Self::Port => 2,
            Self::VideoPorts => 3,
            Self::PortsDiffer => 4,
        }
    }

    /// The hint a code names — [`None`] for `0`, and for a code this build cannot name.
    #[must_use]
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            1 => Some(Self::Host),
            2 => Some(Self::Port),
            3 => Some(Self::VideoPorts),
            4 => Some(Self::PortsDiffer),
            _ => None,
        }
    }
}

/// The target the four fields parse to.
///
/// The host comes back as an OFFSET into the caller's own `host` argument rather than as text: the
/// only thing the parse did to it was trim it, so copying it out would be copying a string the
/// caller is already holding. `docs/55` §4's "the answer that is an OFFSET, not a copy".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Target {
    /// Where the TRIMMED host starts in the `host` argument's own bytes.
    pub host_offset: usize,
    /// How many bytes the trimmed host runs for. Never zero — a blank host is [`Hint::Host`].
    pub host_len: usize,
    /// The terminal-mux port.
    pub port: u16,
    /// The video media port.
    pub media_port: u16,
    /// The cursor-overlay port.
    pub cursor_port: u16,
}

/// Parses the gate's four text fields into a target, or names the first thing wrong with them.
///
/// The order of the checks is the order the fields are read down the card, which is the order a
/// person fixes them in: a blank host is reported before a bad port even when both are wrong, so
/// the hint always points at the topmost problem rather than at whichever check happened to be
/// written first.
///
/// A port of zero is refused with the same hint as a port that is not a number at all. Port 0 is
/// the kernel's "pick one for me", which a client dialling OUT cannot use, and reporting it as a
/// range error is the reading a person can act on.
///
/// # Errors
/// The first [`Hint`] the four fields earn, reading down the card. The refusal IS the form's
/// validation message — there is no second walk of the fields to produce one.
pub fn parse_target(host: &str, port: &str, media_port: &str, cursor_port: &str) -> Result<Target, Hint> {
    let trimmed = host.trim();
    if trimmed.is_empty() {
        return Err(Hint::Host);
    }
    let Some(mux) = field_port(port) else {
        return Err(Hint::Port);
    };
    let (Some(media), Some(cursor)) = (field_port(media_port), field_port(cursor_port)) else {
        return Err(Hint::VideoPorts);
    };
    if media == cursor {
        return Err(Hint::PortsDiffer);
    }
    Ok(Target {
        host_offset: host.len().saturating_sub(host.trim_start().len()),
        host_len: trimmed.len(),
        port: mux,
        media_port: media,
        cursor_port: cursor,
    })
}

/// One port field: trimmed, parsed, and refused at zero.
fn field_port(text: &str) -> Option<u16> {
    match text.trim().parse::<u16>() {
        Ok(0) | Err(_) => None,
        Ok(port) => Some(port),
    }
}

// ---------------------------------------------------------------------------------------------
// The reconnect fold
// ---------------------------------------------------------------------------------------------

/// What a reconnect callback does to the status it lands on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reconnect {
    /// Nothing — the callback is stale, or the link moved on without it.
    Leave,
    /// Adopt reconnecting, carrying the caller's own attempt count and next-retry instant.
    Reconnecting,
    /// Adopt unreachable: the campaign is over.
    Unreachable,
}

/// Folds one reconnect-campaign callback into the status it found.
///
/// Two races make this a rule rather than an assignment.
///
/// - **A late progress callback.** The supervisor's callback for the attempt that SUCCEEDED can
///   arrive after the reconnected event already flipped the link back up. Adopting it would drag a
///   live link back to an orange "Reconnecting…" it would never leave, so only a link that is
///   already reconnecting-ish accepts one.
/// - **A callback that outlived a deliberate close.** Cancelling the supervisor does not cancel an
///   already-fired callback's hop, and `Disconnected` is BOTH the transient-drop state and the
///   deliberate-close terminal state. Without `deliberately_closed` a late callback whitewashes a
///   closed link into a campaign that no longer has a supervisor to end it.
///
/// `gave_up` picks which of the two callbacks this is: the campaign's per-attempt progress, or its
/// exhaustion. Both read the same two states, which is why they are one rule.
#[must_use]
pub const fn reconnect_fold(status: StatusKind, deliberately_closed: bool, gave_up: bool) -> Reconnect {
    if deliberately_closed {
        return Reconnect::Leave;
    }
    match status {
        StatusKind::Reconnecting | StatusKind::Disconnected => {
            if gave_up {
                Reconnect::Unreachable
            } else {
                Reconnect::Reconnecting
            }
        },
        // Already connected, connecting, failed or unreachable — do not regress.
        _ => Reconnect::Leave,
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::*;

    // ---- the OUT batch ----------------------------------------------------------------------

    /// A resize, sized square so one number names it in an assertion.
    const fn resize(size: u16) -> OutEvent {
        OutEvent::Resize {
            cols: size,
            rows: size,
        }
    }

    /// The frame a resize becomes.
    const fn resized(size: u16) -> Frame {
        Frame::Resize {
            cols: size,
            rows: size,
        }
    }

    /// An input frame.
    const fn framed(offset: usize, len: usize) -> Frame {
        Frame::Input { offset, len }
    }

    /// The bytes a plan sends, as `(offset, len)` runs — the concatenation-identity witness.
    fn sent(frames: &[Frame]) -> Vec<(usize, usize)> {
        frames
            .iter()
            .filter_map(|frame| {
                match *frame {
                    Frame::Input { offset, len } => Some((offset, len)),
                    Frame::Resize { .. } => None,
                }
            })
            .collect()
    }

    /// How many bytes a batch of events carries.
    fn total(events: &[OutEvent]) -> usize {
        events
            .iter()
            .map(|event| {
                match *event {
                    OutEvent::Input(len) => len,
                    OutEvent::Resize { .. } => 0,
                }
            })
            .sum()
    }

    #[test]
    fn a_drag_burst_collapses_to_the_final_size() {
        let burst: Vec<OutEvent> = (59..=145).map(resize).collect();
        assert_eq!(coalesce(&burst), vec![resize(145)]);
        assert_eq!(plan(&burst, 1024), vec![resized(145)]);
    }

    #[test]
    fn input_is_a_hard_barrier_and_a_resize_survives_on_each_side() {
        let batch = [resize(80), OutEvent::Input(1), resize(90)];
        assert_eq!(coalesce(&batch), batch.to_vec());
        assert_eq!(plan(&batch, 1024), vec![resized(80), framed(0, 1), resized(90)]);
    }

    #[test]
    fn both_inputs_survive_and_only_the_latest_resize_of_a_run_does() {
        let batch = [OutEvent::Input(1), resize(80), resize(90), OutEvent::Input(1)];
        assert_eq!(coalesce(&batch), vec![
            OutEvent::Input(1),
            resize(90),
            OutEvent::Input(1)
        ]);
        assert_eq!(
            plan(&batch, 1024),
            vec![framed(0, 1), resized(90), framed(1, 1)],
            "the barrier keeps the two bytes in two frames, and the offsets stay contiguous"
        );
    }

    #[test]
    fn a_trailing_resize_run_is_always_flushed() {
        let batch = [OutEvent::Input(1), resize(80), resize(90), resize(100)];
        assert_eq!(
            plan(&batch, 1024),
            vec![framed(0, 1), resized(100)],
            "the final drag size reaches the PTY by construction"
        );
    }

    #[test]
    fn an_empty_or_single_batch_passes_through() {
        assert!(coalesce(&[]).is_empty());
        assert!(plan(&[], 1024).is_empty());
        assert_eq!(coalesce(&[resize(120)]), vec![resize(120)]);
        assert_eq!(plan(&[resize(120)], 1024), vec![resized(120)]);
        assert_eq!(plan(&[OutEvent::Input(7)], 1024), vec![framed(0, 7)]);
    }

    #[test]
    fn adjacent_inputs_merge_into_one_frame() {
        let batch = [OutEvent::Input(1), OutEvent::Input(1), OutEvent::Input(1)];
        assert_eq!(
            plan(&batch, 1024),
            vec![framed(0, 3)],
            "a key-repeat run pays one send, not three"
        );
    }

    #[test]
    fn an_oversized_input_splits_at_the_ceiling() {
        let frames = plan(&[OutEvent::Input(10_000)], 4096);
        assert_eq!(frames, vec![
            framed(0, 4096),
            framed(4096, 4096),
            framed(8192, 1808)
        ]);
        assert_eq!(
            sent(&frames).iter().map(|run| run.1).sum::<usize>(),
            10_000,
            "the split frames reassemble byte-identically"
        );
    }

    #[test]
    fn a_zero_ceiling_is_clamped_rather_than_looping_forever() {
        assert_eq!(
            plan(&[OutEvent::Input(3)], 0),
            vec![framed(0, 1), framed(1, 1), framed(2, 1)],
            "a ceiling of zero is one byte per frame, not an unterminated loop"
        );
    }

    #[test]
    fn a_zero_length_input_frames_nothing() {
        assert!(
            plan(&[OutEvent::Input(0)], 1024).is_empty(),
            "an empty frame is not a send"
        );
        assert_eq!(
            plan(&[OutEvent::Input(0), resize(80), OutEvent::Input(0)], 1024),
            vec![resized(80)]
        );
    }

    #[test]
    fn the_offsets_partition_the_blob_in_order() {
        let mut batch = Vec::new();
        for index in 0..50_usize {
            batch.push(OutEvent::Input((index % 7) * 700 + 1));
            if index.is_multiple_of(11) {
                batch.push(resize(u16::try_from(80 + index).unwrap_or(80)));
            }
        }
        let frames = plan(&batch, 2048);
        let mut cursor = 0_usize;
        for (offset, len) in sent(&frames) {
            assert_eq!(offset, cursor, "every frame starts where the last one ended");
            assert!(len > 0 && len <= 2048, "and respects the ceiling");
            cursor += len;
        }
        assert_eq!(cursor, total(&batch), "byte-identity over an arbitrary mix");
    }

    #[test]
    fn planning_is_idempotent_over_its_own_answer() {
        let batches: [Vec<OutEvent>; 3] = [
            (10..=30).map(resize).collect(),
            vec![
                resize(80),
                OutEvent::Input(1),
                resize(90),
                resize(91),
                OutEvent::Input(1),
                resize(100),
            ],
            vec![OutEvent::Input(1), OutEvent::Input(2), OutEvent::Input(3)],
        ];
        for batch in batches {
            let once = coalesce(&batch);
            assert_eq!(coalesce(&once), once, "coalesce(coalesce(x)) == coalesce(x)");
            let framed_once = plan(&batch, 4096);
            let replayed: Vec<OutEvent> = framed_once
                .iter()
                .map(|frame| {
                    match *frame {
                        Frame::Input { len, .. } => OutEvent::Input(len),
                        Frame::Resize { cols, rows } => OutEvent::Resize { cols, rows },
                    }
                })
                .collect();
            assert_eq!(
                plan(&replayed, 4096),
                framed_once,
                "re-planning a plan changes nothing"
            );
        }
    }

    /// The two load-bearing invariants over many seeded-random batches: the input bytes come back
    /// in order and in full, and no two resizes survive adjacent. Hand-rolled `SplitMix64`, the
    /// same generator and the same seed the Swift tests this replaces used, because the crate's
    /// dependency list is not the place to reach for four lines of arithmetic.
    #[test]
    fn the_two_invariants_hold_over_many_batches() {
        struct SplitMix64(u64);
        impl SplitMix64 {
            fn next(&mut self) -> u64 {
                self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
                let mut z = self.0;
                z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
                z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
                z ^ (z >> 31)
            }
            fn below(&mut self, bound: usize) -> usize {
                if bound == 0 {
                    0
                } else {
                    usize::try_from(self.next() % bound as u64).unwrap_or(0)
                }
            }
        }

        let mut rng = SplitMix64(0x00D1_5123);
        for _ in 0..400 {
            let len = rng.below(21);
            let batch: Vec<OutEvent> = (0..len)
                .map(|_| {
                    if rng.below(2) == 0 {
                        resize(u16::try_from(rng.below(250) + 1).unwrap_or(1))
                    } else {
                        OutEvent::Input(rng.below(9) + 1)
                    }
                })
                .collect();

            let frames = plan(&batch, 4);
            let mut cursor = 0_usize;
            for (offset, run) in sent(&frames) {
                assert_eq!(offset, cursor, "input bytes come back in order");
                assert!(run > 0 && run <= 4, "and inside the ceiling");
                cursor += run;
            }
            assert_eq!(cursor, total(&batch), "and in full");

            let mut previous_was_resize = false;
            for frame in &frames {
                let is_resize = matches!(*frame, Frame::Resize { .. });
                assert!(
                    !(is_resize && previous_was_resize),
                    "no two adjacent resizes survive — every run collapsed"
                );
                previous_was_resize = is_resize;
            }
        }
    }

    // ---- the recent-hosts menu --------------------------------------------------------------

    /// An endpoint, so the MRU fixtures read as one line each.
    const fn at(host: &str, port: u16) -> Endpoint<'_> {
        Endpoint { host, port }
    }

    #[test]
    fn a_fresh_candidate_goes_to_the_front() {
        let existing = [at("a", 1), at("b", 2)];
        assert_eq!(push_recent(at("c", 3), &existing, 5), vec![0, 1, 2]);
    }

    #[test]
    fn a_matching_entry_is_replaced_rather_than_repeated() {
        let existing = [at("a", 1), at("b", 2), at("c", 3)];
        assert_eq!(
            push_recent(at("b", 2), &existing, 5),
            vec![0, 1, 3],
            "the candidate takes the front and the entry it matched is gone"
        );
    }

    #[test]
    fn identity_is_host_and_mux_port_only() {
        let existing = [at("a", 1)];
        assert_eq!(
            push_recent(at("a", 1), &existing, 5),
            vec![0],
            "changed video ports replace the entry — they are settings, not identity"
        );
        assert_eq!(
            push_recent(at("a", 2), &existing, 5),
            vec![0, 1],
            "a different mux port on the same host is a different entry"
        );
    }

    #[test]
    fn every_duplicate_is_dropped_not_just_the_first() {
        let existing = [at("a", 1), at("a", 1), at("b", 2), at("a", 1)];
        assert_eq!(push_recent(at("a", 1), &existing, 9), vec![0, 3]);
    }

    #[test]
    fn the_cap_takes_the_tail_off() {
        let existing = [at("a", 1), at("b", 2), at("c", 3), at("d", 4), at("e", 5)];
        assert_eq!(
            push_recent(at("f", 6), &existing, 5),
            vec![0, 1, 2, 3, 4],
            "the oldest entry falls off the end"
        );
    }

    #[test]
    fn a_limit_of_zero_keeps_nothing_at_all() {
        assert!(push_recent(at("a", 1), &[at("b", 2)], 0).is_empty());
    }

    #[test]
    fn an_empty_menu_answers_the_candidate_alone() {
        assert_eq!(push_recent(at("a", 1), &[], 5), vec![0]);
    }

    // ---- the failure reason -----------------------------------------------------------------

    #[test]
    fn a_localized_description_wins_when_it_has_words() {
        assert_eq!(
            failure_reason("Connection timed out — host unreachable?", "timedOut"),
            "Connection timed out — host unreachable?"
        );
    }

    #[test]
    fn a_wordless_localized_description_falls_back() {
        assert_eq!(
            failure_reason("", "invalidState(\"resume before first connect\")"),
            "invalidState(\"resume before first connect\")",
            "a reason with no words is not a reason"
        );
        assert_eq!(failure_reason("", ""), "", "and two blanks stay blank");
    }

    // ---- the form ---------------------------------------------------------------------------

    #[test]
    fn four_good_fields_parse_to_a_target() {
        let target = parse_target("mac-studio", "7420", "9000", "9001").expect("valid");
        assert_eq!(target, Target {
            host_offset: 0,
            host_len: 10,
            port: 7420,
            media_port: 9000,
            cursor_port: 9001,
        });
    }

    #[test]
    fn the_host_comes_back_as_an_offset_into_what_was_handed_in() {
        let typed = "  mac-studio\t";
        let target = parse_target(typed, "1", "2", "3").expect("valid");
        assert_eq!(
            typed.get(target.host_offset..target.host_offset + target.host_len),
            Some("mac-studio"),
            "the span names the trimmed host without copying it"
        );
    }

    #[test]
    fn a_blank_host_is_reported_before_anything_else_is() {
        for host in ["", "   ", "\t\n "] {
            assert_eq!(
                parse_target(host, "not-a-port", "0", "0"),
                Err(Hint::Host),
                "the hint points at the topmost problem, not the first check written"
            );
        }
    }

    #[test]
    fn a_port_that_is_not_a_number_or_is_zero_is_refused() {
        for port in ["", "  ", "abc", "0", "65536", "-1", "80.5"] {
            assert_eq!(
                parse_target("h", port, "9000", "9001"),
                Err(Hint::Port),
                "{port:?}"
            );
        }
    }

    #[test]
    fn either_bad_video_port_names_the_pair() {
        for (media, cursor) in [("", "9001"), ("9000", ""), ("0", "9001"), ("9000", "0")] {
            assert_eq!(
                parse_target("h", "7420", media, cursor),
                Err(Hint::VideoPorts),
                "{media:?}/{cursor:?}"
            );
        }
    }

    #[test]
    fn two_video_ports_that_name_the_same_port_are_refused() {
        assert_eq!(parse_target("h", "7420", "9000", "9000"), Err(Hint::PortsDiffer));
    }

    #[test]
    fn every_field_is_trimmed_including_a_pasted_newline() {
        let target = parse_target(" h ", " 7420\n", "\t9000", "9001 ").expect("valid");
        assert_eq!(
            (target.port, target.media_port, target.cursor_port),
            (7420, 9000, 9001)
        );
    }

    #[test]
    fn a_refusal_is_exactly_the_negation_of_a_target() {
        let cases = [
            ("h", "7420", "9000", "9001"),
            ("", "7420", "9000", "9001"),
            ("h", "x", "9000", "9001"),
            ("h", "7420", "x", "9001"),
            ("h", "7420", "9000", "9000"),
        ];
        for (host, port, media, cursor) in cases {
            let parsed = parse_target(host, port, media, cursor);
            assert_eq!(
                parsed.is_ok(),
                parsed.err().is_none(),
                "one verdict — the button being live and the hint being absent are one fact"
            );
        }
    }

    #[test]
    fn every_hint_round_trips_through_its_code_and_has_words() {
        assert_eq!(Hint::from_code(0), None);
        for hint in Hint::ALL {
            assert_eq!(Hint::from_code(hint.code()), Some(hint), "{hint:?}");
            assert!(!hint.text().is_empty(), "{hint:?}");
        }
        assert_eq!(Hint::from_code(200), None, "an unnamed code is not a hint");
    }

    #[test]
    fn the_codes_are_dense_and_start_at_one() {
        for (index, hint) in Hint::ALL.into_iter().enumerate() {
            assert_eq!(usize::from(hint.code()), index + 1, "{hint:?}");
        }
    }

    // ---- the reconnect fold -----------------------------------------------------------------

    #[test]
    fn only_a_reconnecting_ish_link_adopts_a_campaign_callback() {
        for status in StatusKind::ALL {
            let reconnecting_ish = matches!(status, StatusKind::Reconnecting | StatusKind::Disconnected);
            assert_eq!(
                reconnect_fold(status, false, false) == Reconnect::Reconnecting,
                reconnecting_ish,
                "{status:?}"
            );
            assert_eq!(
                reconnect_fold(status, false, true) == Reconnect::Unreachable,
                reconnecting_ish,
                "{status:?}"
            );
        }
    }

    #[test]
    fn a_deliberate_close_refuses_both_callbacks() {
        for status in StatusKind::ALL {
            for gave_up in [false, true] {
                assert_eq!(
                    reconnect_fold(status, true, gave_up),
                    Reconnect::Leave,
                    "{status:?}"
                );
            }
        }
    }

    #[test]
    fn a_live_link_is_never_dragged_backwards() {
        for status in [
            StatusKind::Connected,
            StatusKind::Connecting,
            StatusKind::Failed,
            StatusKind::Unreachable,
        ] {
            assert_eq!(reconnect_fold(status, false, false), Reconnect::Leave);
            assert_eq!(reconnect_fold(status, false, true), Reconnect::Leave);
        }
    }
}
