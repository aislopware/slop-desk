//! Replay hygiene: static synchronized repaints contribute nothing.
//!
//! Drops synchronized-output frames (`?2026h … ?2026l`) that repaint the viewport WITHOUT moving
//! any content into history, from a scrollback REPLAY stream.
//!
//! ## Why
//! An inline (non-alt-screen) TUI — Claude Code is the canonical tenant — redraws its live widget
//! region tens of times per second, each repaint wrapped in a synchronized-output frame and
//! anchored with absolute cursor positioning. Recorded over hours that is megabytes of spinner
//! ticks and widget churn whose every intermediate state is invisible in the final display;
//! replaying it renders seconds of stale frames at the RECORDING-time geometry (a different pane
//! size shreds the absolute positioning — the "reconnect while Claude Code runs → broken pane"
//! field report). [`crate::altscreen`] cannot help: these TUIs never enter the alt screen, and the
//! churn lives inside an OPEN command span the distiller passes verbatim.
//!
//! ## What survives
//! A frame is KEPT when it does anything besides repaint in place:
//! - scrolls content into history: `LF`/`VT`/`FF`, `ESC D` (IND), `ESC E` (NEL), `CSI S`/`CSI T`;
//! - `ESC M` (RI), `CSI 2J`/`3J`, `CSI r` (DECSTBM), `ESC c` — viewport-global effects a later
//!   frame may depend on;
//! - enters/leaves the alt screen (47/1047/1049) — [`crate::altscreen`] segmentation and the live
//!   TUI's screen switch must survive;
//! - carries an `OSC 133;` mark — the distiller's block structure must not lose marks;
//! - is the LAST frame of the stream (terminated or not) — the newest recorded widget state, the
//!   closest thing to "current" until the post-reattach `SIGWINCH` repaint lands;
//! - has non-`2026` params on its own opener/closer (never drop a piggybacked mode change).
//!
//! Known accepted gap: a frame that scrolls ONLY via autowrap at the last column (no explicit `LF`)
//! is indistinguishable without a grid emulator and would be dropped; sync-frame TUIs disable
//! autowrap inside frames (Claude Code emits `?7l` per frame), so this stays theoretical.
//!
//! ## Where it runs
//! In [`crate::sanitize`] after [`crate::altscreen`] (closed alt-screen segments are already gone —
//! this pass then only chews inline churn and the live open segment) and before the overprint pass.
//! Final terminal STATE is unaffected: dropped frames are strictly interior repaints, every kept
//! frame re-anchors itself (sync-frame TUIs draw each frame self-contained), and the stream-final
//! input modes are re-asserted by [`crate::inputmode`]'s net-state pass.

// A VT scanner is a byte cursor, and `bytes[i]` is bounded by the `while` head that let control
// reach it — `i < n` is the check, tested once per step rather than re-asked at every read. The
// `get(i)` rewrite would replace one panic that cannot fire with a silent `None` arm that swallows
// a real off-by-one, so the opt-out is per scanner file and stops at its edge.
#![expect(clippy::indexing_slicing, reason = "the loop head bounds every cursor read")]

use std::ops::Range;

use crate::altscreen::is_alt_mode;
use crate::vtscan::{
    Csi, ESC, PrivateMarker, Terminators, param_fields, parse_csi, string_introducer, string_sequence_end,
};

/// The synchronized-output DEC private mode.
pub const SYNC_MODE: i64 = 2026;

/// Which way a synchronized-output `DECSET`/`DECRST` goes.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum SyncTransition {
    Begin,
    End,
}

/// One synchronized-output frame: its byte range (markers inclusive) and drop verdict.
#[derive(Clone, PartialEq, Eq, Debug)]
struct Frame {
    range: Range<usize>,
    droppable: bool,
}

/// Returns `bytes` with static (non-scrolling) synchronized-output frames removed.
///
/// A truncated trailing sequence passes through unchanged.
#[must_use]
pub fn collapse(bytes: &[u8]) -> Vec<u8> {
    let n = bytes.len();
    // Segment pass: record each frame's range + verdict, emit everything else verbatim. Two-phase
    // (ranges first, bytes second) so the LAST frame can be kept regardless of its own verdict
    // without pre-scanning for it.
    let mut frames: Vec<Frame> = Vec::new();
    let mut i = 0;
    while i < n {
        if bytes[i] != ESC || i + 1 >= n {
            i += 1;
            continue;
        }
        let introducer = bytes[i + 1];
        if introducer == b'[' {
            let Some(csi) = parse_csi(bytes, i) else {
                break; // truncated trailing CSI — passthrough
            };
            if sync_transition(&csi) == Some(SyncTransition::Begin) {
                let scanned = scan_frame(bytes, &csi);
                frames.push(Frame {
                    range: i..scanned.end,
                    droppable: scanned.droppable,
                });
                i = scanned.end;
            } else {
                i = csi.end;
            }
        } else if let Some(bel_terminates) = string_introducer(introducer) {
            // Skip string bodies opaquely — an embedded `?2026h` must not open a frame.
            let Some(seq) = string_sequence_end(bytes, i + 2, Terminators::replay(bel_terminates)) else {
                break;
            };
            i = seq.seq_end;
        } else {
            i += 2;
        }
    }
    if !frames.iter().any(|frame| frame.droppable) {
        return bytes.to_vec();
    }

    let mut out = Vec::with_capacity(n);
    let mut cursor = 0;
    let last = frames.len() - 1;
    for (index, frame) in frames.iter().enumerate() {
        out.extend_from_slice(&bytes[cursor..frame.range.start]);
        // The last frame is always kept: it is the newest recorded widget state.
        if !frame.droppable || index == last {
            out.extend_from_slice(&bytes[frame.range.clone()]);
        }
        cursor = frame.range.end;
    }
    out.extend_from_slice(&bytes[cursor..]);
    out
}

/// Where a scanned frame ends, and whether it may be dropped.
struct Scanned {
    end: usize,
    droppable: bool,
}

/// Scans one frame from its opener to the matching `?2026l` (or end-of-stream), deciding whether it
/// may be dropped.
///
/// An UNTERMINATED frame (a live repaint in progress at the cut point) is never droppable.
fn scan_frame(bytes: &[u8], opener: &Csi<'_>) -> Scanned {
    let n = bytes.len();
    // A piggybacked param on the opener (`?2026;…h`) must survive — keep the whole frame.
    let mut keep = param_fields(opener, PrivateMarker::DropWhenPresent) != vec![SYNC_MODE];
    let mut j = opener.end;
    while j < n {
        let byte = bytes[j];
        if byte == 0x0A || byte == 0x0B || byte == 0x0C {
            keep = true;
            j += 1;
            continue;
        }
        if byte != ESC || j + 1 >= n {
            j += 1;
            continue;
        }
        let introducer = bytes[j + 1];
        if introducer == b'[' {
            let Some(csi) = parse_csi(bytes, j) else {
                // Truncated trailing CSI inside the frame — passthrough.
                return Scanned {
                    end: n,
                    droppable: false,
                };
            };
            if sync_transition(&csi) == Some(SyncTransition::End) {
                if param_fields(&csi, PrivateMarker::DropWhenPresent) != vec![SYNC_MODE] {
                    keep = true;
                }
                return Scanned {
                    end: csi.end,
                    droppable: !keep,
                };
            }
            if must_keep(&csi) {
                keep = true;
            }
            j = csi.end;
        } else if let Some(bel_terminates) = string_introducer(introducer) {
            // A semantic prompt mark inside the frame anchors the distiller — keep.
            if bel_terminates && matches_osc_133(bytes, j + 2) {
                keep = true;
            }
            let Some(seq) = string_sequence_end(bytes, j + 2, Terminators::replay(bel_terminates)) else {
                // Unterminated string body — the frame is still being drawn.
                return Scanned {
                    end: n,
                    droppable: false,
                };
            };
            j = seq.seq_end;
        } else if matches!(introducer, b'D' | b'E' | b'M' | b'c') {
            // IND/NEL scroll at the bottom margin, RI at the top, RIS resets everything.
            keep = true;
            j += 2;
        } else {
            j += 2;
        }
    }
    // No closer — the live TUI's in-flight frame, keep verbatim.
    Scanned {
        end: n,
        droppable: false,
    }
}

/// `CSI`s inside a frame that force the frame to survive — effects a later frame or the final
/// display may depend on.
fn must_keep(csi: &Csi<'_>) -> bool {
    if !csi.intermediates.is_empty() {
        return false;
    }
    match csi.final_byte {
        // Scroll up/down (`S`/`T`) — content crosses the history boundary — and DECSTBM (`r`),
        // whose scroll-region geometry later frames rely on.
        b'S' | b'T' | b'r' => true,
        // ED 2 (full viewport) / 3 (scrollback erase); plain/0/1 are the churn itself.
        b'J' => {
            param_fields(csi, PrivateMarker::DropWhenPresent)
                .iter()
                .any(|&field| field == 2 || field == 3)
        },
        b'h' | b'l' => {
            csi.params.first() == Some(&b'?')
                && param_fields(csi, PrivateMarker::DropWhenPresent)
                    .into_iter()
                    .any(is_alt_mode)
        },
        _ => false,
    }
}

/// `Begin`/`End` when the `CSI` is a `DECSET`/`DECRST` whose params include mode 2026.
fn sync_transition(csi: &Csi<'_>) -> Option<SyncTransition> {
    if !csi.intermediates.is_empty()
        || (csi.final_byte != b'h' && csi.final_byte != b'l')
        || csi.params.first() != Some(&b'?')
    {
        return None;
    }
    if !param_fields(csi, PrivateMarker::DropWhenPresent).contains(&SYNC_MODE) {
        return None;
    }
    Some(if csi.final_byte == b'h' {
        SyncTransition::Begin
    } else {
        SyncTransition::End
    })
}

/// Whether an `OSC` body starting at `body_start` is a semantic prompt mark (`133;…`).
fn matches_osc_133(bytes: &[u8], body_start: usize) -> bool {
    bytes.get(body_start..body_start + 4) == Some(b"133;".as_slice())
}

#[cfg(test)]
mod tests {
    use super::collapse;

    /// Two static repaints: the first is churn, the last is the current widget state.
    #[test]
    fn a_static_repaint_is_dropped_and_the_last_frame_is_kept() {
        let stream = b"\x1b[?2026h\x1b[Hspin 1\x1b[?2026l\x1b[?2026h\x1b[Hspin 2\x1b[?2026l";
        assert_eq!(collapse(stream), b"\x1b[?2026h\x1b[Hspin 2\x1b[?2026l");
    }

    #[test]
    fn a_lone_frame_survives_because_it_is_the_last_one() {
        let stream = b"\x1b[?2026h\x1b[Hwidget\x1b[?2026l";
        assert_eq!(collapse(stream), stream);
    }

    #[test]
    fn a_stream_with_no_frames_is_returned_untouched() {
        let stream = b"plain output\r\nwith \x1b[31mcolour\x1b[0m";
        assert_eq!(collapse(stream), stream);
    }

    /// A frame that scrolls moved content into history — it cannot be re-derived.
    #[test]
    fn a_frame_that_scrolls_survives() {
        for scroller in [
            &b"\n"[..],
            &b"\x0b"[..],
            &b"\x0c"[..],
            &b"\x1bD"[..],
            &b"\x1bE"[..],
        ] {
            let mut stream = b"\x1b[?2026h".to_vec();
            stream.extend_from_slice(scroller);
            stream.extend_from_slice(b"\x1b[?2026l");
            stream.extend_from_slice(b"\x1b[?2026htail\x1b[?2026l");
            assert_eq!(collapse(&stream), stream, "{scroller:?} must keep its frame");
        }
    }

    #[test]
    fn scroll_and_region_csis_keep_their_frame() {
        for keeper in [
            &b"\x1b[2S"[..],
            &b"\x1b[3T"[..],
            &b"\x1b[2J"[..],
            &b"\x1b[1;24r"[..],
        ] {
            let mut stream = b"\x1b[?2026h".to_vec();
            stream.extend_from_slice(keeper);
            stream.extend_from_slice(b"\x1b[?2026l\x1b[?2026htail\x1b[?2026l");
            assert_eq!(collapse(&stream), stream, "{keeper:?} must keep its frame");
        }
    }

    /// `ED 0`/`1` (and a bare `ED`) are the in-place churn this pass exists to drop.
    #[test]
    fn a_plain_erase_display_is_churn_not_a_keeper() {
        let stream = b"\x1b[?2026h\x1b[0J\x1b[?2026l\x1b[?2026htail\x1b[?2026l";
        assert_eq!(collapse(stream), b"\x1b[?2026htail\x1b[?2026l");
    }

    #[test]
    fn an_alt_screen_switch_inside_a_frame_keeps_it() {
        let stream = b"\x1b[?2026h\x1b[?1049h\x1b[?2026l\x1b[?2026htail\x1b[?2026l";
        assert_eq!(collapse(stream), stream);
    }

    /// The distiller anchors on `133` marks; a dropped frame must never take one with it.
    #[test]
    fn a_prompt_mark_inside_a_frame_keeps_it() {
        let stream = b"\x1b[?2026h\x1b]133;A\x07\x1b[?2026l\x1b[?2026htail\x1b[?2026l";
        assert_eq!(collapse(stream), stream);
    }

    /// An ordinary OSC is not a mark and must not rescue the frame.
    #[test]
    fn an_ordinary_osc_inside_a_frame_does_not_keep_it() {
        let stream = b"\x1b[?2026h\x1b]0;title\x07\x1b[?2026l\x1b[?2026htail\x1b[?2026l";
        assert_eq!(collapse(stream), b"\x1b[?2026htail\x1b[?2026l");
    }

    #[test]
    fn a_piggybacked_param_on_the_opener_or_closer_keeps_the_frame() {
        let opener = b"\x1b[?2026;25h\x1b[Hx\x1b[?2026l\x1b[?2026htail\x1b[?2026l";
        assert_eq!(collapse(opener), opener);
        let closer = b"\x1b[?2026h\x1b[Hx\x1b[?2026;25l\x1b[?2026htail\x1b[?2026l";
        assert_eq!(collapse(closer), closer);
    }

    /// A frame still open at the cut point is a repaint in progress — never droppable, while its
    /// CLOSED predecessor collapses as usual.
    #[test]
    fn an_unterminated_frame_survives() {
        let stream = b"\x1b[?2026h\x1b[Hone\x1b[?2026l\x1b[?2026h\x1b[Hin flight";
        assert_eq!(collapse(stream), b"\x1b[?2026h\x1b[Hin flight");
        let alone = b"text\x1b[?2026h\x1b[Hin flight";
        assert_eq!(collapse(alone), alone);
    }

    #[test]
    fn an_embedded_sync_marker_inside_a_string_body_opens_nothing() {
        let stream = b"\x1bP\x1b[?2026h\x1b\\plain";
        assert_eq!(collapse(stream), stream);
    }

    #[test]
    fn an_empty_stream_stays_empty() {
        assert_eq!(collapse(b""), b"");
    }
}
