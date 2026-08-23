//! A face that marshals, a length that is parsed once, and four projections that stay asked.
//!
//! Ported from `scripts/check-supervisor.sh`. Every rule here pins a defect NO test can see: a
//! projection that is correct at every size and only wrong in the clock, a guard that compiles and
//! reads correctly and does nothing, a pair that cannot be caught disagreeing because both answers
//! are plausible. A green suite is exactly what a regression here looks like, so the pin is textual.
//!
//! The measurements are `swiftc -O` against the shipped staticlib, two runs agreeing inside 4% each.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// Where the document's canonical order is asked for.
const WS_STATE: &str = "Sources/SlopDeskWorkspaceModel/State/HostWorkspaceState.swift";
/// The catalog whose search crossed the boundary.
const SETTINGS_CATALOG: &str = "Sources/SlopDeskClientCore/Settings/SettingsCatalog.swift";

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
/// So the gate is on the FACES: each must still ask its door, and none may import an audio framework
/// again, because an `import AudioToolbox` in one of these files is what a re-implementation starts
/// as. The ban list is the FRAMEWORKS rather than the code shapes, which is both narrower to write
/// and impossible to satisfy while re-growing the loop.
///
/// The ring, the pump and the Swift stage face went with them, and the PATHS are the unambiguous
/// fact — a re-added `AudioJitterBuffer.swift` would carry whatever names its author picked.
#[must_use]
pub fn the_audio_row_is_rusts(tree: &Tree) -> Report {
    /// Each surviving face and the door it must still ask.
    const FACES: &[(&str, &str)] = &[
        (
            "Sources/SlopDeskVideoHost/AudioStreamEncoder.swift",
            r"slopdesk_audio_encoder_push_sample_buffer\(",
        ),
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

    let mut claims = Vec::new();
    for (face, door) in FACES {
        claims.push(Claim::Matches {
            path: face,
            pattern: door,
            view: View::Code,
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
/// `readExactly(count: -1)`. Measured with a scratch C target rather than reasoned about: a function
/// returning `(size_t)-1` types as `Int`, prints `-1`, and `== .max` is `false`. The guard is
/// `>= 0` now.
///
/// So the screen door refuses with `0` instead, deliberately, and that asymmetry IS the design: a
/// reply of zero bytes is not a thing on this wire, `0` is unrepresentable as a real length, and
/// `> 0` is a check that needs no knowledge of how `size_t` crosses. The supervisor lane cannot take
/// the same refusal — an empty body IS legal there — which is why it keeps the sentinel and gets a
/// ratchet on the guard instead.
///
/// Every arm reads CODE rather than prose, and here that is load-bearing twice over: the paragraph
/// above the Swift guard spells out the WRONG version and why it was wrong, and the doc comment on
/// the Rust door explains, in those words, why it does not use `usize::MAX`. A gate that could not
/// tell the explanation from the thing explained would have to be deleted the first time anyone read
/// it.
#[must_use]
pub fn a_length_prefix_is_parsed_once(tree: &Tree) -> Report {
    /// The screen lane's client.
    const SCREEN_CLIENT: &str = "Sources/SlopDeskScreen/ScreenClient.swift";
    /// The supervisor lane's frame reader.
    const SUPERVISOR_FRAME: &str = "Sources/SlopDeskSupervisor/SupervisorFrame.swift";
    /// The screen door itself.
    const SCREEN_FFI: &str = "rust/slopdesk-ffi/src/screen.rs";

    check_all(
        tree,
        &[
            Claim::Matches {
                path: SCREEN_CLIENT,
                pattern: r"slopdesk_screen_body_length\(",
                view: View::Code,
                message: "the screen client stopped asking the door for the reply length — that \
                          prefix is untrusted and screenwire owns its layout",
            },
            // The hand-rolled decode: a byte-shift ladder, or `bigEndian`/`UInt32` reassembly off
            // the header.
            Claim::Lacks {
                path: SCREEN_CLIENT,
                pattern: r"<< *24|<< *16|bigEndian|UInt32\(header",
                view: View::Code,
                message: "the screen client shifts a length prefix together by hand again — an \
                          untrusted length decides an allocation, and screenwire owns that layout",
            },
            // `>= 0` is the spelling that works; `!= .max` is the spelling that compiles, reads
            // correctly, and does nothing.
            Claim::NoneOf {
                paths: &[SUPERVISOR_FRAME, SCREEN_CLIENT],
                pattern: r"(!=|==) *\.max",
                view: View::Code,
                message: "a door's size_t answer is compared against .max again — size_t reaches \
                          Swift as the SIGNED Int, so an all-ones refusal arrives as -1 and that \
                          guard never fires",
            },
            Claim::Matches {
                path: SUPERVISOR_FRAME,
                pattern: "count >= 0",
                view: View::Code,
                message: "the supervisor frame stopped guarding its body length with >= 0 — the \
                          door's refusal arrives as a negative Int, not as .max",
            },
            Claim::Lacks {
                path: SCREEN_FFI,
                pattern: "usize::MAX",
                view: View::Code,
                message: "the screen door refuses with usize::MAX again — that sentinel reaches \
                          Swift as -1; this door refuses with 0",
            },
        ],
    )
}

/// The document has ONE emission order, and Swift asks for it
///
/// The order lives in `slopdesk_wire::document::state`, where a `BTreeMap`'s key order IS the wire's
/// emission order. Swift's mirror is a `Dictionary` with no order at all, so it used to DERIVE the
/// same order: a hand-written `Comparable` over `(kind, objectID bytes, field)` whose comparator
/// materialised a fresh 16-byte `[UInt8]` per SIDE per comparison. One `sortedEntries` on a 24-pane
/// / 480-cell document therefore ran ~8,600 heap allocations for a question about eighteen bytes at
/// a time: the sort alone 1,018 µs, now 23 µs through the door; `sortedEntries` end to end 1,075 µs
/// → 77 µs; at 64 panes 2,334 → 219 µs.
///
/// The FAILURE MODE is the reason this is pinned rather than merely fixed: two orders never disagree
/// loudly, they RE-EMIT. A snapshot stops being byte-deterministic, a diff churns on dictionary
/// iteration order, and every frame of that reads downstream exactly like a real change.
///
/// FOUR call sites — `sortedEntries`, `keys(ofKind:objectID:)`, and `diff`'s two lists. Counted with
/// comments stripped: the doc comments above these functions name the door too, and a count that
/// includes prose passes while the last real call site is being deleted. That was found by
/// break-test — deleting `diff`'s `deletes` call site did NOT fire until the strip was added.
///
/// ## And `persisting` MUST NOT ORDER
/// It reduces the document to what belongs on disk and returns a `HostWorkspaceState` — an unordered
/// map — so it used to spend a whole canonical ordering of every cell (~1 ms at 24 panes before the
/// port, 77 µs after) and drop the result into a `Dictionary` on the very next line.
/// `WorkspaceCacheStore` calls it inside `encodeSnapshot`, which orders again, so the discarded pass
/// was paid on every save. `encode` below it reads `sortedEntries` legitimately, which is why this
/// bans it in the FUNCTION and not the file — and why an EMPTY extraction fails rather than passing,
/// since a renamed function would otherwise satisfy a ban over nothing.
#[must_use]
pub fn the_document_has_one_emission_order(tree: &Tree) -> Report {
    /// The bridge that calls the door.
    const WS_BRIDGE: &str = "Sources/SlopDeskWorkspaceModel/WorkspaceSolverBridge.swift";
    /// The codec whose `persisting` must filter rather than sort.
    const WS_FILE: &str = "Sources/SlopDeskWorkspaceModel/Codec/WorkspaceStateFile.swift";

    check_all(
        tree,
        &[
            Claim::Doors {
                path: WS_BRIDGE,
                entries: &["slopdesk_ws_key_order"],
                message: "the solver bridge no longer calls {entry} — the emission order is \
                          slopdesk-wire's",
            },
            Claim::AtLeast {
                path: WS_STATE,
                pattern: r"wsKeyOrder\(",
                minimum: 4,
                message: "the workspace state asks wsKeyOrder {found} times, not 4 — an ordered \
                          answer went back to deriving its own",
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
                message: "persisting() orders the document again — its answer is an unordered map, \
                          so the order is thrown away on the next line",
            },
            Claim::Within {
                path: WS_FILE,
                start: r"static func persisting\(",
                end: r"^    \}$",
                pattern: r"in state\.entries where isPersisted",
                view: View::Code,
                message: "persisting() no longer walks state.entries directly — the filter reads \
                          neither the object id nor the value",
            },
        ],
    )
}

/// The palette catalog is indexed once, and the settings taxonomy owns its own search
///
/// ## The catalog
/// `items(in:)` was `allRows.filter { $0.category == category }`, so one zero-state build ran eight
/// full passes over ~90 rows and minted eight arrays; `recentPaletteItems()` linear-scanned
/// `allRows` once per remembered id. Both are `static let` dictionaries built once. Measured on the
/// whole zero-state build: 8.06–8.22 µs → 2.53–2.86 µs.
///
/// ## The taxonomy
/// `SettingsCatalog.sections` has crossed the boundary since it was written; the SEARCH over it had
/// not, so each face wrote its own `lowercased().contains(…)` over the answer. That is `docs/55`
/// §8's drift class, and §8's point is that this class is NOT ranked by cost — eight sections
/// filtered per keystroke is ~750 ns and would never on its own justify a door. What justifies it is
/// that the question stops having two answers. The needle crosses RAW, which is the load-bearing
/// half: a caller that lowercases or trims first has re-spelled the fold it was supposed to stop
/// spelling.
///
/// The corpus arm stays armed over the whole of `Sources/` rather than scoped to `ClientCore`
/// BECAUSE the fourth spelling is the finding: `MacSettingsNavigator` held it, lives outside the
/// target this rule came from, and the arm was RED on the shipped tree until that call site landed
/// centrally. A rule that only watched `ClientCore` would have passed on the day the drift started.
///
/// ## And no production API exists for a test's sake
/// `SearchMixer.availableFilters` was a `public var` whose only reader anywhere in the tree — after
/// the Mac and phone sweeps both finished without adding one — was a single assertion in
/// `OverlayCoordinatorMountTests`. Under the one-implementation rule that is a hook held open, so it
/// is deleted and the test reads the same fact off what the mixer PRODUCES, where a user could also
/// see it. Banned tree-wide, so it fires wherever it comes back rather than only in the file it left.
#[must_use]
pub fn a_catalog_is_indexed_not_rescanned(tree: &Tree) -> Report {
    /// The palette's catalog.
    const PALETTE: &str = "Sources/SlopDeskClientCore/Palette/PaletteDataSource.swift";
    /// The coordinator that used to scan it per remembered id.
    const OVERLAYS: &str = "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift";

    check_all(
        tree,
        &[
            Claim::Matches {
                path: PALETTE,
                pattern: "static let rowsByCategory",
                view: View::Code,
                message: "the palette catalog lost its category index — items(in:) would be a \
                          fresh scan of allRows per read",
            },
            Claim::Matches {
                path: PALETTE,
                pattern: "static let rowsByID",
                view: View::Code,
                message: "the palette catalog lost its id index — the recents lookup would be a \
                          fresh scan of allRows per remembered id",
            },
            Claim::Lacks {
                path: PALETTE,
                pattern: r"allRows\.filter|allRows\.first\(where:",
                view: View::Code,
                message: "the palette catalog scans allRows again — the categories and the ids are \
                          both indexed once at load",
            },
            Claim::Lacks {
                path: OVERLAYS,
                pattern: r"ActionsPaletteSource\.allRows\.first\(where:",
                view: View::Code,
                message: "the coordinator scans the palette catalog per remembered id — \
                          ActionsPaletteSource.rowsByID answers in one lookup",
            },
            Claim::Matches {
                path: SETTINGS_CATALOG,
                pattern: r"slopdesk_settings_sections_matching\(",
                view: View::Code,
                message: "the settings catalog no longer calls slopdesk_settings_sections_matching \
                          — the search over the taxonomy is slopdesk-workspace's",
            },
            Claim::LacksWithin {
                path: SETTINGS_CATALOG,
                start: r"static func sections\(matching",
                end: r"^    \}$",
                pattern: r"lowercased\(\)|trimmingCharacters",
                view: View::Code,
                message: "sections(matching:) folds the needle before sending it — the fold is the \
                          far side's, and folding twice is the rule spelled twice",
            },
            // Read RAW, the way the shell's `grep -rl` did: this is a corpus ban whose subject is a
            // call shape, and the four files that ever held it do not discuss it in prose.
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: r"SettingsCatalog\.sections[^)]*\.filter",
                all: &[],
                unless: &[],
                view: View::Raw,
                exempt: &[],
                message: "{files} filters SettingsCatalog.sections itself — ask \
                          SettingsCatalog.sections(matching:), which is the taxonomy's own search",
            },
            Claim::NoneUnder {
                roots: &["Sources"],
                extensions: SWIFT,
                pattern: "var availableFilters",
                all: &[],
                unless: &[],
                view: View::Raw,
                exempt: &[],
                message: "availableFilters is back in {files} — it had exactly one reader, a test; \
                          assert on the zero state the mixer renders instead",
            },
        ],
    )
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The three faces that marshal, each asking its door and importing no framework.
    fn faces(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskVideoHost/AudioStreamEncoder.swift",
                "import Foundation\nslopdesk_audio_encoder_push_sample_buffer(handle, buffer)\n",
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
    }

    /// Both lanes reading their length through a door, each with the guard that works.
    fn prefixes(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskScreen/ScreenClient.swift",
                "let count = slopdesk_screen_body_length(header)\nguard count > 0 else { return nil }\n",
            )
            .write(
                "Sources/SlopDeskSupervisor/SupervisorFrame.swift",
                "let count = slopdesk_supervisor_body_length(header)\nguard count >= 0 else { return nil }\n",
            )
            .write(
                "rust/slopdesk-ffi/src/screen.rs",
                "pub extern fn slopdesk_screen_body_length(header: *const u8) -> usize { 0 }\n",
            );
    }

    #[test]
    fn a_sentinel_a_signed_int_swallows_is_red() {
        let fixture = Fixture::new("held-prefixes");
        prefixes(&fixture);
        assert!(super::a_length_prefix_is_parsed_once(&fixture.tree()).is_clean());

        // The guard that compiles, reads correctly, and never fires.
        fixture.write(
            "Sources/SlopDeskSupervisor/SupervisorFrame.swift",
            "let count = slopdesk_supervisor_body_length(header)\nguard count != .max else { return nil }\n",
        );
        assert!(!super::a_length_prefix_is_parsed_once(&fixture.tree()).is_clean());

        // The hand-shifted prefix, deciding an allocation off four untrusted bytes.
        prefixes(&fixture);
        fixture.write(
            "Sources/SlopDeskScreen/ScreenClient.swift",
            "let count = slopdesk_screen_body_length(header)\n\
             let n = Int(header[0]) << 24 | Int(header[1])\nguard count > 0 else { return nil }\n",
        );
        assert!(!super::a_length_prefix_is_parsed_once(&fixture.tree()).is_clean());

        // And the sentinel that reaches Swift as -1.
        prefixes(&fixture);
        fixture.write(
            "rust/slopdesk-ffi/src/screen.rs",
            "pub extern fn slopdesk_screen_body_length(h: *const u8) -> usize { usize::MAX }\n",
        );
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
            "let a = wsKeyOrder(entries)\nlet b = wsKeyOrder(entries)\n\
             let c = wsKeyOrder(adds)\nlet d = wsKeyOrder(deletes)\n\
             struct WorkspaceKey: Hashable, Comparable {}\n",
        );
        assert!(!super::the_document_has_one_emission_order(&fixture.tree()).is_clean());

        // And `persisting` ordering an answer it throws away on the next line. The ban is scoped to
        // the FUNCTION — `encode` below it reads `sortedEntries` legitimately.
        order(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceModel/Codec/WorkspaceStateFile.swift",
            "    static func persisting(_ state: HostWorkspaceState) -> HostWorkspaceState {\n\
             \x20       for entry in state.sortedEntries where isPersisted(entry.key) { kept[entry.key] = entry.value }\n\
             \x20       return HostWorkspaceState(entries: kept)\n    }\n",
        );
        assert!(!super::the_document_has_one_emission_order(&fixture.tree()).is_clean());
    }

    /// Both indexes, the door, and a needle that crosses raw.
    fn indexed(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskClientCore/Palette/PaletteDataSource.swift",
                "static let rowsByCategory: [Category: [Row]] = index(allRows)\n\
                 static let rowsByID: [String: Row] = index(allRows)\n",
            )
            .write(
                "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift",
                "let row = ActionsPaletteSource.rowsByID[id]\n",
            )
            .write(
                super::SETTINGS_CATALOG,
                "    static func sections(matching needle: String) -> [Section] {\n\
                 \x20       slopdesk_settings_sections_matching(needle)\n    }\n",
            );
    }

    #[test]
    fn a_rescanned_catalog_is_red() {
        let fixture = Fixture::new("held-indexed");
        indexed(&fixture);
        assert!(super::a_catalog_is_indexed_not_rescanned(&fixture.tree()).is_clean());

        // Eight full passes over ~90 rows for one zero-state build.
        fixture.write(
            "Sources/SlopDeskClientCore/Palette/PaletteDataSource.swift",
            "static let rowsByCategory: [Category: [Row]] = index(allRows)\n\
             static let rowsByID: [String: Row] = index(allRows)\n\
             static func items(in c: Category) -> [Row] { allRows.filter { $0.category == c } }\n",
        );
        assert!(!super::a_catalog_is_indexed_not_rescanned(&fixture.tree()).is_clean());

        // The needle folded before it crosses — the rule spelled twice.
        indexed(&fixture);
        fixture.write(
            super::SETTINGS_CATALOG,
            "    static func sections(matching needle: String) -> [Section] {\n\
             \x20       slopdesk_settings_sections_matching(needle.lowercased())\n    }\n",
        );
        assert!(!super::a_catalog_is_indexed_not_rescanned(&fixture.tree()).is_clean());

        // And the fourth spelling, in a target the rule would have missed if it were scoped.
        indexed(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Settings/MacSettingsNavigator.swift",
            "let hits = SettingsCatalog.sections.filter { $0.title.lowercased().contains(q) }\n",
        );
        assert!(!super::a_catalog_is_indexed_not_rescanned(&fixture.tree()).is_clean());
    }
}
