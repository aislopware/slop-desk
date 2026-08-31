//! A face that marshals, a length that is parsed once, and four projections that stay asked.
//!
//! Ported from the deleted `check-supervisor.sh`. Every rule here pins a defect NO test can see: a
//! projection that is correct at every size and only wrong in the clock, a guard that compiles and
//! reads correctly and does nothing, a pair that cannot be caught disagreeing because both answers
//! are plausible. A green suite is exactly what a regression here looks like, so the pin is
//! textual.
//!
//! The measurements are `swiftc -O` against the shipped staticlib, two runs agreeing inside 4%
//! each.

use crate::claim::{Claim, RUST, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// Where the document's canonical order is asked for.
const WS_STATE: &str = "Sources/SlopDeskWorkspaceModel/State/HostWorkspaceState.swift";

/// The audio row is Rust's, from the capture tap to the speakers
///
/// This started as ONE rule about ONE loop: `AudioStreamDecoder.decodePCM` and
/// `slopdesk_video::audio_wire::decode_pcm_s16le` were the same s16le widen byte for byte, down to
/// the same validate-then-DROP rule for a ragged tail, and the Rust half had no caller outside its
/// own tests. What made that pair need a gate rather than a note is that it CANNOT be caught
/// disagreeing: a full-scale sample is `-1.0` either way, and a drifted normalisation is just audio
/// that is slightly quieter than it should be. Nobody files that.
///
/// The rest of the row turned out to be the same shape at a larger size. Four Swift files — an
/// `AudioConverter` encoder, an `AudioConverter` decoder, an `AUHAL`/`RemoteIO` output unit and a
/// lock-free ring with a pump around it — were about 1200 lines, of which the part that HAD to be
/// Swift was none. They are `rust/slopdesk-apple-audio` and `rust/slopdesk-audio-out` now, and what
/// is left in Swift is three faces that marshal.
///
/// So the gate is on the FACES: each must still ask its door, and none may import an audio
/// framework again, because an `import AudioToolbox` in one of these files is what a
/// re-implementation starts as. The ban list is the FRAMEWORKS rather than the code shapes, which
/// is both narrower to write and impossible to satisfy while re-growing the loop.
///
/// ## The capture end of the row is no longer a face
/// `docs/61` deleted `AudioStreamEncoder.swift` along with the rest of the Swift host, and the door
/// it asked went with it — `rust/slopdesk-videohostd` links `slopdesk-apple-audio` and
/// `slopdesk-video` as ordinary crates, so there is no `(ptr, len)` left to prove a call across.
/// The claim is re-aimed rather than dropped, because the thing it protected is not the door: the
/// tap end of this row still must not hold a fold, a widen or a converter of its own, and now it is
/// the one place in the tree that could grow one back in the same language the answer is written
/// in.
///
/// So the daemon carries this rule's two halves in the daemon's own terms. It must ASK
/// `slopdesk_apple_audio` and `audio_source` — the framework wrapper and the fold — and it may not
/// name a `CoreAudio` type directly, which is the `import AudioToolbox` of a crate: an
/// `AudioStreamBasicDescription` or an `AudioBufferList` spelled here is the converter coming back
/// outside the one `objc2` crate allowed to hold it (`docs/57` §5). `rust/slopdesk-apple-audio` and
/// `rust/slopdesk-video` are out of scope for the ban, because holding those is what they are for.
///
/// The ring, the pump and the Swift stage face went with the loop, and the PATHS are the
/// unambiguous fact — a re-added `AudioJitterBuffer.swift` would carry whatever names its author
/// picked. The "no Swift declares `AudioStreamEncoder`" half is stated tree-wide, once, in
/// [`crate::rules::deleted_video_swift`].
#[must_use]
pub fn the_audio_row_is_rusts(tree: &Tree) -> Report {
    /// The GUI video host, which holds the capture end of the row now.
    ///
    /// A DIRECTORY rather than a file, the way [`crate::rules::video_host`] argues: the daemon's
    /// audio module is still being split off the session, and this rule is about the tap asking,
    /// not about which file does the asking.
    const DAEMON: &str = "rust/slopdesk-videohostd";
    /// Each surviving Swift face and the door it must still ask.
    const FACES: &[(&str, &str)] = &[
        (
            "Sources/SlopDeskVideoClient/AudioStreamDecoder.swift",
            r"slopdesk_audio_decoder_decode\(",
        ),
        (
            "Sources/SlopDeskVideoClient/AudioPlaybackEngine.swift",
            r"slopdesk_audio_player_enqueue\(",
        ),
    ];
    /// The files that left with the loop.
    const GONE: &[&str] = &[
        "Sources/SlopDeskVideoClient/AudioJitterBuffer.swift",
        "Tests/SlopDeskVideoClientTests/AudioJitterBufferTests.swift",
        "Tests/SlopDeskVideoClientTests/AudioSampleRingTests.swift",
        "Tests/SlopDeskVideoClientTests/AudioPlaybackPumpTests.swift",
    ];

    let mut claims = vec![
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["slopdesk_apple_audio", "audio_source", "audio_wire"],
            message: "the daemon stopped asking {entry} — the converter, the stereo fold and the wire \
                      header are the crates', and a tap that stopped asking has started widening samples of \
                      its own (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\bAudioStreamBasicDescription\b|\bAudioBufferList\b|\bAudioConverterRef\b|\bkAudioFormat[A-Za-z0-9]*\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon names a CoreAudio type directly in {files} — that is this row's `import \
                      AudioToolbox`, and the framework's own contract may only be carried inside \
                      slopdesk-apple-audio (docs/57 §5, docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\bfn (fold_interleaved_to_stereo|fold_planar_to_stereo|pack_s16le|decode_pcm_s16le)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon declares a fold or a widen of its own in {files} — those are \
                      audio_source.rs's and audio_wire.rs's, and a drifted normalisation is audio that is \
                      slightly quieter than it should be, which nobody files (docs/61 §3)",
        },
    ];
    for (face, door) in FACES {
        claims.push(Claim::Matches {
            path: face,
            pattern: door,
            message: "an audio face stopped asking its door — the audio row's calls are \
                      slopdesk-apple-audio's and slopdesk-audio-out's",
        });
        claims.push(Claim::Lacks {
            path: face,
            pattern: r"^import (AudioToolbox|AudioUnit|CoreAudio|AVFAudio)$",
            view: View::Code,
            message: "an audio face imports an audio framework again — the AudioToolbox calls are \
                      slopdesk-apple-audio's",
        });
    }
    for gone in GONE {
        claims.push(Claim::Absent {
            path: gone,
            message: "the jitter stage, its ring and its pump are rust/slopdesk-audio-out",
        });
    }
    check_all(tree, &claims)
}

/// The two length prefixes, and the sentinel a signed `Int` swallowed
///
/// `ScreenClient.exchange` shifted four untrusted bytes together by hand, checked them against a
/// 64 MiB ceiling re-spelled one file over, and then allocated that much. It is the highest-risk
/// hand-written parse either lane had: the one field on this wire a peer fully controls, deciding
/// how much memory this process commits. `rust/slopdesk-screenwire` owned the ENCODER for it the
/// whole time. It asks now.
///
/// ## The trap that made the first half worth doing properly
/// `SupervisorFrame.read` already asked its door — `slopdesk_supervisor_body_length` — and then
/// guarded the refusal with `count != .max`, which NEVER FIRED. Swift's `ClangImporter` maps
/// `size_t` onto the SIGNED `Int`, so the door's all-ones refusal arrives as `-1` while `.max`
/// infers `Int.max`; the two never met, and an over-cap header fell through to
/// `readExactly(count: -1)`. Measured with a scratch C target rather than reasoned about: a
/// function returning `(size_t)-1` types as `Int`, prints `-1`, and `== .max` is `false`. The guard
/// is `>= 0` now.
///
/// So the screen door refuses with `0` instead, deliberately, and that asymmetry IS the design: a
/// reply of zero bytes is not a thing on this wire, `0` is unrepresentable as a real length, and
/// `> 0` is a check that needs no knowledge of how `size_t` crosses. The supervisor lane cannot
/// take the same refusal — an empty body IS legal there — which is why it keeps the sentinel and
/// gets a ratchet on the guard instead.
///
/// Every arm reads CODE rather than prose, and here that is load-bearing twice over: the paragraph
/// above the Swift guard spells out the WRONG version and why it was wrong, and the doc comment on
/// the Rust door explains, in those words, why it does not use `usize::MAX`. A gate that could not
/// tell the explanation from the thing explained would have to be deleted the first time anyone
/// read it.
#[must_use]
pub fn a_length_prefix_is_parsed_once(tree: &Tree) -> Report {
    /// The screen lane's transport — where the reply prefix is read off the socket.
    const SCREEN_TRANSPORT: &str = "rust/slopdesk-screenclient/src/transport.rs";
    /// The supervisor lane's frame reader.
    const SUPERVISOR_FRAME: &str = "rust/slopdesk-superclient/src/frame.rs";

    check_all(tree, &[
        Claim::Matches {
            path: SCREEN_TRANSPORT,
            pattern: r"reply_body_length\(prefix\)",
            message: "the screen client stopped asking screenwire for the reply length — that prefix is \
                      untrusted and screenwire owns its layout",
        },
        Claim::Matches {
            path: SUPERVISOR_FRAME,
            pattern: r"slopdesk_superwire::body_length\(header\)",
            message: "the supervisor frame stopped asking superwire for the body length — that prefix is \
                      untrusted and superwire owns its layout",
        },
        // The hand-rolled decode: a byte-shift ladder, or a `from_be_bytes` off the raw header.
        Claim::NoneOf {
            paths: &[SCREEN_TRANSPORT, SUPERVISOR_FRAME],
            // Bound to an ASSIGNMENT on purpose. `frame.rs` reassembles the header once more inside
            // `FrameError::BodyTooLarge(...)` — to say in the error how long the refused body claimed
            // to be — and that read decides nothing. What the ban is for is a length that goes on to
            // size an allocation, which has to be bound first.
            pattern: r"(let|=) *\w* *=? *(u32|u64)::from_be_bytes|<< *24|<< *16",
            view: View::Code,
            message: "{files} shifts a length prefix together by hand again — an untrusted length decides \
                      an allocation, and the wire crate owns that layout",
        },
        // Both lanes take the refusal as an `Option`, which is the whole reason the Swift-era
        // `size_t`/`.max` trap cannot come back: there is no sentinel to compare wrongly. What CAN
        // come back is unwrapping it.
        Claim::NoneOf {
            paths: &[SCREEN_TRANSPORT, SUPERVISOR_FRAME],
            pattern: r"body_length\([^)]*\)\s*\.\s*(unwrap|expect)",
            view: View::Code,
            message: "{files} unwraps the wire crate's length refusal — a header the peer controls would \
                      panic the reader instead of being refused",
        },
    ])
}

/// The document has ONE emission order, and Swift asks for it
///
/// The order lives in `slopdesk_wire::document::state`, where a `BTreeMap`'s key order IS the
/// wire's emission order. Swift's mirror is a `Dictionary` with no order at all, so it used to
/// DERIVE the same order: a hand-written `Comparable` over `(kind, objectID bytes, field)` whose
/// comparator materialised a fresh 16-byte `[UInt8]` per SIDE per comparison. One `sortedEntries`
/// on a 24-pane / 480-cell document therefore ran ~8,600 heap allocations for a question about
/// eighteen bytes at a time: the sort alone 1,018 µs, now 23 µs through the door; `sortedEntries`
/// end to end 1,075 µs → 77 µs; at 64 panes 2,334 → 219 µs.
///
/// The FAILURE MODE is the reason this is pinned rather than merely fixed: two orders never
/// disagree loudly, they RE-EMIT. A snapshot stops being byte-deterministic, a diff churns on
/// dictionary iteration order, and every frame of that reads downstream exactly like a real change.
///
/// FOUR call sites — `sortedEntries`, `keys(ofKind:objectID:)`, and `diff`'s two lists. Counted
/// with comments stripped: the doc comments above these functions name the door too, and a count
/// that includes prose passes while the last real call site is being deleted. That was found by
/// break-test — deleting `diff`'s `deletes` call site did NOT fire until the strip was added.
///
/// ## And `persisting` MUST NOT ORDER
/// It reduces the document to what belongs on disk and returns a `HostWorkspaceState` — an
/// unordered map — so it used to spend a whole canonical ordering of every cell (~1 ms at 24 panes
/// before the port, 77 µs after) and drop the result into a `Dictionary` on the very next line.
/// `WorkspaceCacheStore` calls it inside `encodeSnapshot`, which orders again, so the discarded
/// pass was paid on every save. `encode` below it reads `sortedEntries` legitimately, which is why
/// this bans it in the FUNCTION and not the file — and why an EMPTY extraction fails rather than
/// passing, since a renamed function would otherwise satisfy a ban over nothing.
#[must_use]
pub fn the_document_has_one_emission_order(tree: &Tree) -> Report {
    /// The bridge that calls the door.
    const WS_BRIDGE: &str = "Sources/SlopDeskWorkspaceModel/WorkspaceSolverBridge.swift";
    /// The codec whose `persisting` must filter rather than sort.
    const WS_FILE: &str = "Sources/SlopDeskWorkspaceModel/Codec/WorkspaceStateFile.swift";

    check_all(tree, &[
        Claim::Doors {
            path: WS_BRIDGE,
            entries: &["slopdesk_ws_key_order"],
            message: "the solver bridge no longer calls {entry} — the emission order is slopdesk-wire's",
        },
        Claim::AtLeast {
            path: WS_STATE,
            pattern: r"wsKeyOrder\(",
            minimum: 4,
            message: "the workspace state asks wsKeyOrder {found} times, not 4 — an ordered answer went \
                      back to deriving its own",
        },
        // What a re-implementation grows back: the conformance, the byte array the comparator
        // allocated, the hand-written `<`, and the `.sorted()` that only compiles once one of
        // them is back.
        Claim::Lacks {
            path: WS_STATE,
            pattern: r"struct WorkspaceKey[^{]*Comparable|objectIDBytes|static func < *\(|entries\.keys\.sorted\(\)|keys\.sorted\(\)",
            view: View::Code,
            message: "the workspace state derives the emission order again — that order is \
                      slopdesk_wire::document::state's, asked through wsKeyOrder",
        },
        Claim::LacksWithin {
            path: WS_FILE,
            start: r"static func persisting\(",
            end: r"^    \}$",
            pattern: "sortedEntries",
            view: View::Code,
            message: "persisting() orders the document again — its answer is an unordered map, so the order \
                      is thrown away on the next line",
        },
        Claim::Within {
            path: WS_FILE,
            start: r"static func persisting\(",
            end: r"^    \}$",
            pattern: r"in state\.entries where isPersisted",
            message: "persisting() no longer walks state.entries directly — the filter reads neither the \
                      object id nor the value",
        },
    ])
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The three faces that marshal, each asking its door and importing no framework.
    fn faces(fixture: &Fixture) {
        fixture
            .write(
                "rust/slopdesk-videohostd/src/audio.rs",
                "use slopdesk_apple_audio::{CMSampleBuffer, Encoder, read_stereo};\nuse \
                 slopdesk_video::audio_source::{CHANNEL_COUNT, SAMPLE_RATE};\nuse \
                 slopdesk_video::audio_wire::AudioStreamConfig;\n",
            )
            .write(
                "Sources/SlopDeskVideoClient/AudioStreamDecoder.swift",
                "import Foundation\nslopdesk_audio_decoder_decode(handle, bytes, count)\n",
            )
            .write(
                "Sources/SlopDeskVideoClient/AudioPlaybackEngine.swift",
                "import Foundation\nslopdesk_audio_player_enqueue(handle, frames)\n",
            );
    }

    #[test]
    fn an_audio_face_that_grows_a_loop_is_red() {
        let fixture = Fixture::new("held-audio");
        faces(&fixture);
        assert!(super::the_audio_row_is_rusts(&fixture.tree()).is_clean());

        // What a re-implementation starts as.
        fixture.write(
            "Sources/SlopDeskVideoClient/AudioStreamDecoder.swift",
            "import AudioToolbox\nslopdesk_audio_decoder_decode(handle, bytes, count)\n",
        );
        assert!(!super::the_audio_row_is_rusts(&fixture.tree()).is_clean());

        // And the jitter stage back under whatever name its author picked — pinned by PATH.
        faces(&fixture);
        fixture.write(
            "Sources/SlopDeskVideoClient/AudioJitterBuffer.swift",
            "final class AudioJitterBuffer {}\n",
        );
        assert!(!super::the_audio_row_is_rusts(&fixture.tree()).is_clean());

        // The same drift at the capture end, in the language it can be written in now: a CoreAudio
        // type named where the tap runs is this row's `import AudioToolbox`, and the obligation it
        // carries belongs inside slopdesk-apple-audio rather than beside the caller.
        faces(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/audio.rs",
            "let mut asbd = AudioStreamBasicDescription::default();\n",
        );
        assert!(!super::the_audio_row_is_rusts(&fixture.tree()).is_clean());

        // The fold itself regrown beside the module that answers it — the pair that cannot be
        // caught disagreeing, because a drifted normalisation is only slightly quieter.
        faces(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/audio.rs",
            "fn fold_planar_to_stereo(planes: &[&[f32]]) -> Vec<f32> { Vec::new() }\n",
        );
        assert!(!super::the_audio_row_is_rusts(&fixture.tree()).is_clean());

        // And the tap that stopped asking at all — nothing is respelled, so only the ask can fail.
        faces(&fixture);
        fixture.write(
            "rust/slopdesk-videohostd/src/audio.rs",
            "let samples = self.staged;\n",
        );
        assert!(!super::the_audio_row_is_rusts(&fixture.tree()).is_clean());
    }

    /// Both lanes asking their wire crate for the length, each taking the refusal as an `Option`.
    const SCREEN_TRANSPORT: &str = "rust/slopdesk-screenclient/src/transport.rs";
    const SUPERVISOR_FRAME: &str = "rust/slopdesk-superclient/src/frame.rs";

    fn prefixes(fixture: &Fixture) {
        fixture
            .write(
                SCREEN_TRANSPORT,
                "let Some(count) = reply_body_length(prefix) else { return Ok(None) };\n",
            )
            .write(
                SUPERVISOR_FRAME,
                "let Some(count) = slopdesk_superwire::body_length(header) else { return Ok(None) };\n",
            );
    }

    /// The Swift-era half of this rule was a `size_t` sentinel a signed `Int` swallowed, and it
    /// died with its language: an `Option` has no value to compare wrongly. What replaced it is the
    /// one way the refusal can still be thrown away — and the hand-shift, which never depended on
    /// the language at all.
    #[test]
    fn a_sentinel_a_signed_int_swallows_is_red() {
        let fixture = Fixture::new("held-prefixes");
        prefixes(&fixture);
        assert!(super::a_length_prefix_is_parsed_once(&fixture.tree()).is_clean());

        // The refusal taken and dropped — a header the peer controls panics the reader.
        fixture.write(
            SUPERVISOR_FRAME,
            "let count = slopdesk_superwire::body_length(header).unwrap();\n",
        );
        assert!(!super::a_length_prefix_is_parsed_once(&fixture.tree()).is_clean());

        // The hand-shifted prefix, deciding an allocation off four untrusted bytes.
        prefixes(&fixture);
        fixture.write(
            SCREEN_TRANSPORT,
            "let Some(count) = reply_body_length(prefix) else { return Ok(None) };\nlet n = \
             u32::from_be_bytes(prefix);\n",
        );
        assert!(!super::a_length_prefix_is_parsed_once(&fixture.tree()).is_clean());

        // And the door stopped being asked at all.
        prefixes(&fixture);
        fixture.write(SCREEN_TRANSPORT, "let count = prefix.len();\n");
        assert!(!super::a_length_prefix_is_parsed_once(&fixture.tree()).is_clean());
    }

    /// The order asked four times, and a `persisting` that filters.
    fn order(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskWorkspaceModel/WorkspaceSolverBridge.swift",
                "slopdesk_ws_key_order(keys, count, out)\n",
            )
            .write(
                super::WS_STATE,
                "let a = wsKeyOrder(entries)\nlet b = wsKeyOrder(entries)\n\
                 let c = wsKeyOrder(adds)\nlet d = wsKeyOrder(deletes)\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceModel/Codec/WorkspaceStateFile.swift",
                "    static func persisting(_ state: HostWorkspaceState) -> HostWorkspaceState {\n\
                 \x20       for entry in state.entries where isPersisted(entry.key) { kept[entry.key] = entry.value }\n\
                 \x20       return HostWorkspaceState(entries: kept)\n    }\n\
                 \x20   static func encode(_ state: HostWorkspaceState) -> Data {\n\
                 \x20       for entry in state.sortedEntries { out.append(entry) }\n    }\n",
            );
    }

    #[test]
    fn a_second_emission_order_is_red() {
        let fixture = Fixture::new("held-order");
        order(&fixture);
        assert!(super::the_document_has_one_emission_order(&fixture.tree()).is_clean());

        // A call site deleted: three is not four, and two orders RE-EMIT rather than disagree.
        fixture.write(
            super::WS_STATE,
            "let a = wsKeyOrder(entries)\nlet b = wsKeyOrder(entries)\nlet c = wsKeyOrder(adds)\n",
        );
        assert!(!super::the_document_has_one_emission_order(&fixture.tree()).is_clean());

        // The comparator back, with its 16-byte allocation per side per comparison.
        order(&fixture);
        fixture.write(
            super::WS_STATE,
            "let a = wsKeyOrder(entries)\nlet b = wsKeyOrder(entries)\nlet c = wsKeyOrder(adds)\nlet d = \
             wsKeyOrder(deletes)\nstruct WorkspaceKey: Hashable, Comparable {}\n",
        );
        assert!(!super::the_document_has_one_emission_order(&fixture.tree()).is_clean());

        // And `persisting` ordering an answer it throws away on the next line. The ban is scoped to
        // the FUNCTION — `encode` below it reads `sortedEntries` legitimately.
        order(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceModel/Codec/WorkspaceStateFile.swift",
            "    static func persisting(_ state: HostWorkspaceState) -> HostWorkspaceState {\n\x20       \
             for entry in state.sortedEntries where isPersisted(entry.key) { kept[entry.key] = entry.value \
             }\n\x20       return HostWorkspaceState(entries: kept)\n    }\n",
        );
        assert!(!super::the_document_has_one_emission_order(&fixture.tree()).is_clean());
    }
}
