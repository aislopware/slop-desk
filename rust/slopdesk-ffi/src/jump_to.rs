//! The ⌘J Jump-To panel's rows — one door over `slopdesk_workspace::jump_to`.
//!
//! ONE crossing rather than one per detection, and it carries ORDER rather than text. The caller
//! already holds its detections and its blocks; what it does not know is which of them earn a row —
//! the collapse of four path forms into one badge, the dedup of a path a build log printed forty
//! times, the ceiling on a pathological scrollback, and the skip of a block still being captured.
//! So the answer is indices INTO the caller's own arrays, plus the kind each surviving detection is
//! called by, and no scrollback text makes a second trip through the boundary to be handed back
//! unchanged.
//!
//! The link kinds and the link texts are two arrays that must line up, so a length disagreement
//! answers NOTHING: a detection classified by its neighbour's kind would badge and open as the
//! wrong thing, confidently.

use core::ffi::c_uchar;

use slopdesk_workspace::jump_to;

use crate::link_detect::kind_of as detected_kind;
use crate::workspace::{Span, borrow_array, text_of};
use crate::{borrow, deliver};

/// How many bytes [`slopdesk_ws_jump_to_rows`] leads with: the count of LINK rows, which is where
/// the block indices start.
pub const JUMP_TO_HEAD_BYTES: usize = 4;

/// The ceiling on link rows, so the near side can pin the same bound it is held to.
pub const JUMP_TO_MAX_LINK_ITEMS: usize = jump_to::MAX_LINK_ITEMS;

/// Which detections and which blocks earn a Jump-To row.
///
/// `link_kinds` are `SLOPDESK_LINK_KIND_*` codes, one per detection, and `link_spans` name the same
/// detections' raw texts in `blob`; `block_spans` name the blocks' command texts in the same blob.
/// The answer is `[u32 link_count]`, then `link_count` pairs of `[u32 index][u32 kind]` — the kind
/// being a `SLOPDESK_WS_OPEN_QUICKLY_KIND_*` code — then one `[u32 index]` per surviving block.
///
/// Answers `0` when `link_kinds` and `link_spans` disagree on how many detections there are: the
/// two are positional, and a detection read under its neighbour's kind would open as the wrong
/// thing. A span naming no text reads as an empty string, which is what a block still being
/// captured is.
///
/// # Safety
/// `(blob, blob_len)` must be null, or name `blob_len` initialised bytes live for the call;
/// `(link_kinds, link_kind_count)`, `(link_spans, link_span_count)` and
/// `(block_spans, block_span_count)` likewise for their own element counts; `(out, cap)` must be
/// null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_ws_jump_to_rows(
    link_kinds: *const u32,
    link_kind_count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    link_spans: *const Span,
    link_span_count: usize,
    block_spans: *const Span,
    block_span_count: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    if link_kind_count != link_span_count {
        return 0;
    }
    // SAFETY: the caller's obligation, restated above.
    let bytes = unsafe { borrow(blob, blob_len) };
    // SAFETY: ditto, for the three arrays.
    let (kinds, links, blocks) = unsafe {
        (
            borrow_array(link_kinds, link_kind_count),
            borrow_array(link_spans, link_span_count),
            borrow_array(block_spans, block_span_count),
        )
    };

    let detections: Vec<_> = kinds
        .iter()
        .zip(links)
        .filter_map(|(code, span)| {
            detected_kind(*code).map(|kind| (kind, text_of(*span, bytes).unwrap_or_default()))
        })
        .collect();
    // A code no kind answers to would silently drop its detection and shift every later index, so
    // the whole reading is lost instead.
    if detections.len() != link_span_count {
        return 0;
    }
    let texts: Vec<_> = blocks
        .iter()
        .map(|span| text_of(*span, bytes).unwrap_or_default())
        .collect();

    // Every field is one word, so the answer is built as words and framed once. A word that will
    // not fit the prefix loses the WHOLE reading rather than being truncated into an index that
    // names a different row — the same choice `push_text` makes for a length it cannot state.
    let answer = jump_to::rows(&detections, &texts);
    let mut words = Vec::with_capacity(1 + answer.links.len() * 2 + answer.blocks.len());
    words.push(answer.links.len());
    for row in &answer.links {
        words.push(row.index);
        words.push(usize::from(row.kind.code()));
    }
    words.extend_from_slice(&answer.blocks);

    let mut packed = Vec::with_capacity(words.len() * JUMP_TO_HEAD_BYTES);
    for word in words {
        let Ok(word) = u32::try_from(word) else {
            return 0;
        };
        packed.extend_from_slice(&word.to_be_bytes());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&packed, out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use slopdesk_workspace::open_quickly::Kind;

    use super::{JUMP_TO_HEAD_BYTES, JUMP_TO_MAX_LINK_ITEMS, slopdesk_ws_jump_to_rows};
    use crate::link_detect::{
        SLOPDESK_LINK_KIND_ABSOLUTE_PATH, SLOPDESK_LINK_KIND_FILE_URL, SLOPDESK_LINK_KIND_NONE,
        SLOPDESK_LINK_KIND_URL,
    };
    use crate::testing::delivered;
    use crate::workspace::Span;

    /// Packs the detections and the blocks into one arena and reads the two index lists back.
    fn ask(links: &[(u32, &str)], blocks: &[&str]) -> (Vec<(u32, u32)>, Vec<u32>) {
        let mut blob = Vec::new();
        let mut pack = |text: &str| {
            let offset = blob.len();
            blob.extend_from_slice(text.as_bytes());
            Span {
                offset,
                len: text.len(),
                present: true,
            }
        };
        let link_spans: Vec<_> = links.iter().map(|(_, raw)| pack(raw)).collect();
        let block_spans: Vec<_> = blocks.iter().map(|text| pack(text)).collect();
        let kinds: Vec<u32> = links.iter().map(|(code, _)| *code).collect();

        // SAFETY: every pointer names a live local for the duration of the call.
        let answer = delivered(|out, cap| unsafe {
            slopdesk_ws_jump_to_rows(
                kinds.as_ptr(),
                kinds.len(),
                blob.as_ptr(),
                blob.len(),
                link_spans.as_ptr(),
                link_spans.len(),
                block_spans.as_ptr(),
                block_spans.len(),
                out,
                cap,
            )
        });
        split(&answer)
    }

    /// The head, the `[index][kind]` pairs and the trailing block indices.
    fn split(answer: &[u8]) -> (Vec<(u32, u32)>, Vec<u32>) {
        let words: Vec<u32> = answer
            .as_chunks::<4>()
            .0
            .iter()
            .copied()
            .map(u32::from_be_bytes)
            .collect();
        let Some((count, rest)) = words.split_first() else {
            return (Vec::new(), Vec::new());
        };
        let pairs = usize::try_from(*count).unwrap_or(0) * 2;
        let (link_words, block_words) = rest.split_at(pairs.min(rest.len()));
        (
            link_words
                .as_chunks::<2>()
                .0
                .iter()
                .map(|&pair| <(u32, u32)>::from(pair))
                .collect(),
            block_words.to_vec(),
        )
    }

    #[test]
    fn the_links_and_the_blocks_cross_as_two_index_lists_in_one_answer() {
        let (links, blocks) = ask(
            &[
                (SLOPDESK_LINK_KIND_ABSOLUTE_PATH, "/usr/local/bin/foo"),
                (SLOPDESK_LINK_KIND_URL, "https://example.test/x"),
                (SLOPDESK_LINK_KIND_FILE_URL, "file:///a/b.txt"),
            ],
            &["git status", "", "ls -la"],
        );
        assert_eq!(links, [
            (0, u32::from(Kind::Path.code())),
            (1, u32::from(Kind::Url.code())),
            (2, u32::from(Kind::FileUrl.code())),
        ]);
        assert_eq!(
            blocks,
            [0, 2],
            "the still-forming block leaves a GAP, not a shift"
        );
    }

    /// The two link arrays are positional, so a disagreement loses the whole reading rather than
    /// badging a detection with its neighbour's kind.
    #[test]
    fn a_kind_array_of_the_wrong_length_answers_nothing() {
        let blob = b"/etc/hosts";
        let spans = [Span {
            offset: 0,
            len: blob.len(),
            present: true,
        }];
        let kinds = [SLOPDESK_LINK_KIND_ABSOLUTE_PATH, SLOPDESK_LINK_KIND_URL];
        // SAFETY: every pointer names a live local for the duration of the call.
        let answer = delivered(|out, cap| unsafe {
            slopdesk_ws_jump_to_rows(
                kinds.as_ptr(),
                kinds.len(),
                blob.as_ptr(),
                blob.len(),
                spans.as_ptr(),
                spans.len(),
                std::ptr::null(),
                0,
                out,
                cap,
            )
        });
        assert!(answer.is_empty());
    }

    /// A code no kind answers to would drop its detection and shift every later index by one, so it
    /// loses the reading too.
    #[test]
    fn an_unknown_link_kind_loses_the_reading_rather_than_shifting_it() {
        let (links, blocks) = ask(
            &[
                (SLOPDESK_LINK_KIND_ABSOLUTE_PATH, "/etc/hosts"),
                (SLOPDESK_LINK_KIND_NONE, "?"),
            ],
            &["ls"],
        );
        assert!(links.is_empty());
        assert!(blocks.is_empty());
    }

    #[test]
    fn a_repeated_detection_crosses_once_and_the_cap_holds() {
        let (deduped, _) = ask(&[(SLOPDESK_LINK_KIND_ABSOLUTE_PATH, "/etc/hosts"); 3], &[]);
        assert_eq!(deduped.len(), 1);

        let raws: Vec<String> = (0..JUMP_TO_MAX_LINK_ITEMS + 50)
            .map(|n| format!("/p/{n}"))
            .collect();
        let many: Vec<_> = raws
            .iter()
            .map(|raw| (SLOPDESK_LINK_KIND_ABSOLUTE_PATH, raw.as_str()))
            .collect();
        let (capped, _) = ask(&many, &[]);
        assert_eq!(capped.len(), JUMP_TO_MAX_LINK_ITEMS);
    }

    #[test]
    fn nothing_detected_and_nothing_captured_still_answers_its_head() {
        // SAFETY: the two null arrays are declared empty, which is what `borrow` requires of them.
        let answer = delivered(|out, cap| unsafe {
            slopdesk_ws_jump_to_rows(
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                out,
                cap,
            )
        });
        assert_eq!(answer.len(), JUMP_TO_HEAD_BYTES);
        assert_eq!(answer, [0, 0, 0, 0]);
    }
}
