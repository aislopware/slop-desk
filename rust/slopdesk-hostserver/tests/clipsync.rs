//! The four clipboard-sync rules, against a board that is a `Vec` rather than a pasteboard.
//!
//! Unlike the two PATH verbs, the Swift shim these replace WAS unit-tested — against a named
//! `NSPasteboard`, which the pasteboard server serves without a window session. That option exists
//! here too (`slopdesk_apple_pasteboard::Board::unique`, which is where the `AppKit` half is
//! asserted), and is deliberately not what this suite uses: the rules below are about preference,
//! caps and an echo guard, and a fake board is the only way to build the states that matter — an
//! over-cap clip, a board declaring a concealed marker, a counter that did not move.

#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a test asserts by panicking, and a fixture it built itself is not a runtime input"
)]

use std::sync::{Mutex, PoisonError};

use slopdesk_clipboard::Pasteboard;
/// The two UTIs the fold refuses on, taken from the fold rather than re-typed.
///
/// A third spelling here would defeat the point: a fixture that declares its OWN string is green
/// while the fold refuses a different one. `the_two_utis_are_the_ones_appkit_declares` pins THESE
/// against `AppKit` itself, so the chain is fold → fixture → framework with no copy in it.
use slopdesk_clipboard::{CONCEALED_TYPE as CONCEALED, FILE_URL_TYPE as FILE_URL};
use slopdesk_hostserver::clipsync::Clipboard;
use slopdesk_hostsession::{MetadataPerformer, MetadataRequest};
use slopdesk_muxsession::metadata_admission::Performer;
use slopdesk_wire::MetadataStatus;
use slopdesk_wire::metadata::MetadataVerb;
use slopdesk_wire::metadata::codec::{
    CLIPBOARD_BASELINE_PROBE, ClipboardClip, ClipboardKind, MAX_CLIPBOARD_CONTENT_BYTES,
    decode_clipboard_read_response, encode_clipboard_read_request, encode_clipboard_set,
};

/// A board made of three `Option`s and a counter.
#[derive(Debug, Default)]
struct Fake {
    count: Mutex<i64>,
    declared: Mutex<Vec<String>>,
    text: Mutex<Option<String>>,
    png: Mutex<Option<Vec<u8>>>,
    /// When set, every write is refused with the board untouched — the "will not decode" arm.
    refuses: bool,
}

impl Fake {
    /// A board holding text, declaring the plain-text UTI the way a real writer would.
    fn holding_text(text: &str) -> Self {
        let board = Self::default();
        board.set_text(text);
        board
    }

    /// A board holding an image.
    fn holding_png(png: &[u8]) -> Self {
        let board = Self::default();
        *board.png.lock().unwrap_or_else(PoisonError::into_inner) = Some(png.to_vec());
        *board.declared.lock().unwrap_or_else(PoisonError::into_inner) = vec!["public.png".to_owned()];
        *board.count.lock().unwrap_or_else(PoisonError::into_inner) = 1;
        board
    }

    /// A board that refuses every write — what a garbage clip meets on the real one.
    fn unwritable() -> Self {
        Self {
            refuses: true,
            ..Self::default()
        }
    }

    fn set_text(&self, text: &str) {
        *self.text.lock().unwrap_or_else(PoisonError::into_inner) = Some(text.to_owned());
        *self.declared.lock().unwrap_or_else(PoisonError::into_inner) =
            vec!["public.utf8-plain-text".to_owned()];
        *self.count.lock().unwrap_or_else(PoisonError::into_inner) += 1;
    }

    /// Adds a declared type without touching the content — how a password manager marks its clip.
    fn also_declares(&self, uti: &str) {
        self.declared
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(uti.to_owned());
    }
}

impl Pasteboard for &Fake {
    fn change_count(&self) -> i64 {
        *self.count.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn declared(&self) -> Vec<String> {
        self.declared
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    fn text(&self) -> Option<String> {
        self.text.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn png(&self) -> Option<Vec<u8>> {
        self.png.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn write_text(&self, text: &str) -> bool {
        if self.refuses {
            return false;
        }
        self.set_text(text);
        true
    }

    fn write_png(&self, png: &[u8]) -> bool {
        if self.refuses {
            return false;
        }
        *self.png.lock().unwrap_or_else(PoisonError::into_inner) = Some(png.to_vec());
        *self.text.lock().unwrap_or_else(PoisonError::into_inner) = None;
        *self.declared.lock().unwrap_or_else(PoisonError::into_inner) =
            vec!["public.png".to_owned(), "public.tiff".to_owned()];
        *self.count.lock().unwrap_or_else(PoisonError::into_inner) += 1;
        true
    }
}

/// A request at `verb` carrying `payload`.
fn ask<B: Pasteboard + Send + Sync>(
    performer: &Clipboard<B>,
    verb: MetadataVerb,
    payload: &[u8],
) -> (u8, Vec<u8>) {
    let answer = performer.perform(&MetadataRequest {
        request_id: 3,
        verb: verb.as_byte(),
        payload,
        performer: Performer::Clipboard,
        master_fd: -1,
        shell_pid: 0,
    });
    (answer.status, answer.payload)
}

/// A verb-16 request for `last_seen`, decoded into `(change_count, clip)`.
fn read<B: Pasteboard + Send + Sync>(
    performer: &Clipboard<B>,
    last_seen: i64,
) -> (i64, Option<ClipboardClip>) {
    let (status, body) = ask(
        performer,
        MetadataVerb::ReadClipboard,
        &encode_clipboard_read_request(last_seen),
    );
    assert_eq!(
        status,
        MetadataStatus::Ok.as_byte(),
        "a well-formed read always answers ok"
    );
    decode_clipboard_read_response(&body).expect("the host's own encoder must round-trip")
}

/// A text clip, as the client would encode one.
fn text_clip(text: &str) -> ClipboardClip {
    ClipboardClip {
        kind_byte: ClipboardKind::Text.as_byte(),
        bytes: text.as_bytes().to_vec(),
    }
}

// ---------------------------------------------------------------------------- verb 15, the set

#[test]
fn a_pushed_text_clip_lands_on_the_board() {
    let board = Fake::default();
    let performer = Clipboard::new(&board);
    let (status, payload) = ask(
        &performer,
        MetadataVerb::SetClipboard,
        &encode_clipboard_set(&text_clip("from the client")),
    );
    assert_eq!(status, MetadataStatus::Ok.as_byte());
    assert!(payload.is_empty(), "a set answers a status and nothing else");
    assert_eq!(board.text.lock().unwrap().as_deref(), Some("from the client"));
}

#[test]
fn a_pushed_clip_of_an_unknown_future_kind_is_refused_rather_than_guessed_at() {
    let board = Fake::holding_text("keep me");
    let performer = Clipboard::new(&board);
    let (status, _) = ask(
        &performer,
        MetadataVerb::SetClipboard,
        &encode_clipboard_set(&ClipboardClip {
            kind_byte: 0x7F,
            bytes: b"whatever this is".to_vec(),
        }),
    );
    assert_eq!(status, MetadataStatus::Error.as_byte());
    assert_eq!(
        board.text.lock().unwrap().as_deref(),
        Some("keep me"),
        "a refused clip must leave the board exactly as it was",
    );
}

#[test]
fn a_pushed_text_clip_that_is_not_utf8_is_refused_without_a_trap() {
    let board = Fake::holding_text("keep me");
    let performer = Clipboard::new(&board);
    let (status, _) = ask(
        &performer,
        MetadataVerb::SetClipboard,
        &encode_clipboard_set(&ClipboardClip {
            kind_byte: ClipboardKind::Text.as_byte(),
            bytes: vec![0xFF, 0xFE, 0xFD],
        }),
    );
    assert_eq!(status, MetadataStatus::Error.as_byte());
    assert_eq!(board.text.lock().unwrap().as_deref(), Some("keep me"));
}

#[test]
fn a_malformed_set_payload_is_an_error_and_never_reaches_the_board() {
    let board = Fake::holding_text("keep me");
    let performer = Clipboard::new(&board);
    let (status, _) = ask(&performer, MetadataVerb::SetClipboard, &[]);
    assert_eq!(status, MetadataStatus::Error.as_byte());
    assert_eq!(board.text.lock().unwrap().as_deref(), Some("keep me"));
}

#[test]
fn a_clip_the_board_will_not_take_is_an_error_rather_than_a_silent_ok() {
    let board = Fake::unwritable();
    let performer = Clipboard::new(&board);
    let (status, _) = ask(
        &performer,
        MetadataVerb::SetClipboard,
        &encode_clipboard_set(&text_clip("undecodable in practice")),
    );
    assert_eq!(
        status,
        MetadataStatus::Error.as_byte(),
        "the board refuses BEFORE it clears, and the wire says so",
    );
}

// ---------------------------------------------------------------------------- verb 16, the read

#[test]
fn a_read_of_a_changed_board_ships_its_text() {
    let board = Fake::holding_text("on the host");
    let performer = Clipboard::new(&board);
    let (count, clip) = read(&performer, 0);
    assert_eq!(count, 1);
    assert_eq!(clip, Some(text_clip("on the host")));
}

#[test]
fn a_read_at_the_count_it_already_saw_answers_the_count_and_no_content() {
    let board = Fake::holding_text("on the host");
    let performer = Clipboard::new(&board);
    let (count, clip) = read(&performer, 1);
    assert_eq!(count, 1);
    assert_eq!(clip, None, "unchanged means the client already has it");
}

#[test]
fn a_baseline_probe_learns_where_the_host_stands_without_pulling_a_stale_clip() {
    let board = Fake::holding_text("predates the connection");
    let performer = Clipboard::new(&board);
    let (count, clip) = read(&performer, CLIPBOARD_BASELINE_PROBE);
    assert_eq!(count, 1, "the count is the whole point of the probe");
    assert_eq!(
        clip, None,
        "a freshly connected client must not have the host's pre-connection clip applied to it",
    );
}

#[test]
fn a_clients_own_push_is_never_shipped_straight_back_to_it() {
    let board = Fake::default();
    let performer = Clipboard::new(&board);
    let (status, _) = ask(
        &performer,
        MetadataVerb::SetClipboard,
        &encode_clipboard_set(&text_clip("the client's own")),
    );
    assert_eq!(status, MetadataStatus::Ok.as_byte());

    // The client asks with the count it last SAW, which is the one before its own push.
    let (count, clip) = read(&performer, 0);
    assert_eq!(
        count, 1,
        "the count still moves — the client needs to learn the new one"
    );
    assert_eq!(
        clip, None,
        "the echo guard: the board is at the count this client's push produced, so there is nothing new to \
         send it",
    );
}

#[test]
fn a_third_partys_write_after_a_client_push_does_ship() {
    let board = Fake::default();
    let performer = Clipboard::new(&board);
    let (status, _) = ask(
        &performer,
        MetadataVerb::SetClipboard,
        &encode_clipboard_set(&text_clip("the client's own")),
    );
    assert_eq!(status, MetadataStatus::Ok.as_byte());
    board.set_text("somebody else copied this");

    let (count, clip) = read(&performer, 1);
    assert_eq!(count, 2);
    assert_eq!(
        clip,
        Some(text_clip("somebody else copied this")),
        "the guard is a single remembered count, not a mute button",
    );
}

#[test]
fn an_image_wins_over_the_text_flavour_beside_it() {
    let board = Fake::holding_png(b"pretend png");
    board.set_text("the picture's caption");
    let performer = Clipboard::new(&board);
    let (_, clip) = read(&performer, 0);
    assert_eq!(
        clip,
        Some(ClipboardClip {
            kind_byte: ClipboardKind::ImagePng.as_byte(),
            bytes: b"pretend png".to_vec(),
        }),
        "taking the text would silently downgrade the paste — the image is the fidelity ceiling",
    );
}

#[test]
fn a_file_copy_ships_nothing_at_all() {
    let board = Fake::holding_text("/Users/someone/Documents/report.pdf");
    board.also_declares(FILE_URL);
    let performer = Clipboard::new(&board);
    let (count, clip) = read(&performer, 0);
    assert_eq!(
        count, 1,
        "the count is still reported — the client must not re-ask for ever"
    );
    assert_eq!(clip, None, "a host path means nothing on the other machine");
}

#[test]
fn an_over_cap_clip_is_dropped_rather_than_truncated() {
    let board = Fake::default();
    *board.png.lock().unwrap() = Some(vec![0u8; MAX_CLIPBOARD_CONTENT_BYTES + 1]);
    *board.declared.lock().unwrap() = vec!["public.png".to_owned()];
    *board.count.lock().unwrap() = 1;
    let performer = Clipboard::new(&board);
    let (_, clip) = read(&performer, 0);
    assert_eq!(clip, None, "half an image is not a smaller image");
}

#[test]
fn a_clip_exactly_at_the_cap_still_ships() {
    let board = Fake::default();
    *board.png.lock().unwrap() = Some(vec![7u8; MAX_CLIPBOARD_CONTENT_BYTES]);
    *board.declared.lock().unwrap() = vec!["public.png".to_owned()];
    *board.count.lock().unwrap() = 1;
    let performer = Clipboard::new(&board);
    let (_, clip) = read(&performer, 0);
    assert_eq!(
        clip.map(|clip| clip.bytes.len()),
        Some(MAX_CLIPBOARD_CONTENT_BYTES),
        "the cap is inclusive, and the codec that carries it agrees",
    );
}

#[test]
fn an_empty_board_answers_its_count_and_nothing_else() {
    let board = Fake::default();
    let performer = Clipboard::new(&board);
    let (count, clip) = read(&performer, -2);
    assert_eq!(count, 0);
    assert_eq!(clip, None);
}

#[test]
fn empty_text_on_the_board_is_not_a_clip() {
    let board = Fake::holding_text("");
    let performer = Clipboard::new(&board);
    let (_, clip) = read(&performer, 0);
    assert_eq!(clip, None, "an empty string is nothing to paste");
}

#[test]
fn a_truncated_read_request_is_an_error_and_the_host_still_replies() {
    let board = Fake::holding_text("on the host");
    let performer = Clipboard::new(&board);
    let (status, payload) = ask(&performer, MetadataVerb::ReadClipboard, &[0x00, 0x01]);
    assert_eq!(status, MetadataStatus::Error.as_byte());
    assert!(
        payload.is_empty(),
        "the reply is what keeps the client's pending-request registry from waiting out a timeout",
    );
}

// ------------------------------------------------------------------- the preserved asymmetry

#[test]
fn the_host_ships_a_concealed_clip_where_the_client_refuses_to_push_one() {
    let board = Fake::holding_text("hunter2");
    board.also_declares(CONCEALED);
    let performer = Clipboard::new(&board);
    let (_, clip) = read(&performer, 0);
    assert_eq!(
        clip,
        Some(text_clip("hunter2")),
        "the verb-16 path passes `skipping_concealed: false` — a product decision `PasteboardClip`'s header \
         records and this port preserves rather than quietly closing",
    );
}

#[test]
fn the_same_board_read_with_the_refusal_asked_for_ships_nothing() {
    let board = Fake::holding_text("hunter2");
    board.also_declares(CONCEALED);
    let performer = Clipboard::new(&board);
    assert_eq!(
        performer.read_clip(true),
        None,
        "the asymmetry is ONE word at the call site, not two function bodies",
    );
}

// ------------------------------------------------------------------------------- the routing

#[test]
fn a_verb_this_performer_does_not_own_is_answered_unsupported() {
    let board = Fake::holding_text("on the host");
    let performer = Clipboard::new(&board);
    for verb in [MetadataVerb::Cwd, MetadataVerb::OpenPath, MetadataVerb::HostInfo] {
        let (status, _) = ask(&performer, verb, &[]);
        assert_eq!(
            status,
            MetadataStatus::UnsupportedVerb.as_byte(),
            "{verb:?} belongs to another performer",
        );
    }
    assert_eq!(
        *board.count.lock().unwrap(),
        1,
        "and none of them touched the board"
    );
}

// ------------------------------------------------------- the two UTIs, against the framework

/// `slopdesk-clipboard` types both UTI strings so it can build with no `AppKit`; this is where they
/// are checked against the framework that actually declares them. The drift this closes is
/// `docs/55` §6's: two spellings of one contract, in two places that cannot see each other. The
/// pin lives in THIS suite because this is the crate that links both the fold and the framework.
#[cfg(target_os = "macos")]
#[test]
fn the_two_utis_are_the_ones_appkit_declares() {
    use slopdesk_apple_pasteboard::Flavour;

    assert_eq!(CONCEALED, Flavour::Concealed.uti());
    assert_eq!(FILE_URL, Flavour::File.uti());
}
