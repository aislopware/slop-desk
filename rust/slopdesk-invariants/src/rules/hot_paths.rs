//! Four per-keystroke, per-row or per-chunk paths, each of which had a second implementation that
//! was correct and slow.
//!
//! Ported from the deleted `check-supervisor.sh`. What is enforced is not the measurement — a
//! number in a gate rots — but the call site that earned it: the engine that does not backtrack,
//! the ranking that happens once per query, the splitter that skips the walk it does not need.

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The Swift face of the pane outbox — a marshaller, and the rule below says how much of one.
const OUTBOX_FACE: &str = "Sources/SlopDeskHost/PaneOutbox.swift";

/// One regex engine meets the untrusted rows, and it does not backtrack
///
/// Hint Mode ran ten compiled `NSRegularExpressions` over rows a remote program wrote, bridged
/// through `NSString`, mapping columns with a third cell walk. Two things were wrong with that and
/// this pins both: the columns now come from the link scan's clustering, and the user's
/// `hint-pattern` — a regex a human pasted in, run against text an attacker influences — now runs
/// on a finite automaton whose match time is linear in the row. A backtracking engine here is a
/// hang the user cannot escape, so the Swift face must stay a marshaller.
#[must_use]
pub fn one_regex_engine_over_untrusted(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneOf {
            paths: &["Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift"],
            pattern: r"NSRegularExpression|NSString|force_try|displayCellWidth|boundedPrefix|overlapsAccepted",
            view: View::Code,
            message: "{files} scans for hint targets in Swift again — slopdesk-rowscan owns the scan",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift",
            names: &[
                "slopdesk_hint_scan",
                "slopdesk_hint_scan_target",
                "slopdesk_hint_scan_take_arena",
            ],
            message: "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift no longer asks {entry} \
                      — the hint scan is one implementation",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift",
            names: &["static", "func", "labels", "static", "func", "filter"],
            message: "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift lost ${kept} — the \
                      label arithmetic stays here on purpose (docs/55)",
        },
        Claim::Matches {
            path: "rust/slopdesk-rowscan/Cargo.toml",
            pattern: r"^regex = ",
            view: View::Code,
            message: "rust/slopdesk-rowscan dropped the regex crate — a hand-written or backtracking \
                      matcher is the hang",
        },
        Claim::NoneOf {
            paths: &["rust/slopdesk-terminal/Cargo.toml"],
            pattern: r"^regex = ",
            view: View::Code,
            message: "rust/slopdesk-terminal took an external dependency — that crate is on the PTY hot path",
        },
    ];
    check_all(tree, &claims)
}

/// 3. THE PALETTE'S THREE RESULT PROPERTIES ARE ONE PASS. `paletteResults`, `rankedResults` and
///
/// `selectableResults` each used to re-run the whole mixer: ~8 category sources, and per source a
/// fresh tuple array, a fresh `[String?]` of three fields per row, and one
/// `slopdesk_ws_search_rank` crossing whose blob is every title, subtitle and synonym concatenated.
/// Measured over a 90-row catalog in 8 sources: ~150 µs PER READ (139–167) for a typed query, ~30
/// µs for the empty-query path. `moveSelection` reads `selectableResults` only for `.count`, so
/// every ↑/↓ paid one pass before the body paid another, and the phone's `PaletteView` reads
/// `rankedResults` twice per body — three passes per arrow key on the phone, two on the Mac. They
/// now share one memo keyed on `(generation, query, filter, recents)`, and `mixerGeneration` is
/// what makes a rebuilt mixer invalidate it. BREAK-TESTED twice: pointing `rankedResults` back at
/// `mixer?.ranked(` fires its reader arm, and deleting the `&+= 1` line from `rebuildMixer` fires
/// the generation arm.
#[must_use]
pub fn palette_ranks_once_per_query(tree: &Tree) -> Report {
    let claims = [
        Claim::Matches {
            path: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift",
            pattern: r"var paletteResults: \[[A-Za-z]+\] \{ memoizedResults\.",
            view: View::Raw,
            message: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift: paletteResults no \
                      longer reads the memo — each read is a whole ~150 µs fzf pass, and three of them ride \
                      one arrow key",
        },
        Claim::Matches {
            path: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift",
            pattern: r"var rankedResults: \[[A-Za-z]+\] \{ memoizedResults\.",
            view: View::Raw,
            message: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift: rankedResults no longer \
                      reads the memo — each read is a whole ~150 µs fzf pass, and three of them ride one \
                      arrow key",
        },
        Claim::Matches {
            path: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift",
            pattern: r"var selectableResults: \[[A-Za-z]+\] \{ memoizedResults\.",
            view: View::Raw,
            message: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift: selectableResults no \
                      longer reads the memo — each read is a whole ~150 µs fzf pass, and three of them ride \
                      one arrow key",
        },
        Claim::Names {
            path: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift",
            needle: "mixerGeneration &+= 1",
            message: "Sources/SlopDeskClientCore/Overlays/OverlayCoordinator.swift: rebuildMixer no longer \
                      bumps mixerGeneration — the memo would serve results from the PREVIOUS catalog",
        },
    ];
    check_all(tree, &claims)
}

/// The nerd-font run splitter is LINEAR, and skips the walk entirely when nothing is a symbol.
///
/// `runs(of:)` had the obvious accumulator — read the last run back out of the array, append one
/// character, write it back — and that is QUADRATIC without looking it: `out.last` hands back a
/// COPY of the tuple, so the run's `String` is two-referenced for an instant and `append` copies
/// the whole run before adding a character. Every `.slateNerdAware` string in three overlays walks
/// this once per keystroke. Measured, `swiftc -O`, two runs agreeing: a plain 48-character title
/// 3,563 → 104 ns, a 240-character one 21,588 → 371 ns (58×). The scalar pre-scan is the other
/// half, and is what makes the ordinary case — no nerd glyph anywhere, which is almost every string
/// — one scalar walk and one `String`, without entering the per-`Character` loop at all. It is also
/// what stops the two splice sites' `registered` guard ORDER from mattering.
#[must_use]
pub fn nerd_font_run_splitter_linear(tree: &Tree) -> Report {
    let claims = [
        Claim::Matches {
            path: "Sources/SlopDeskFontFaces/NerdSymbolFont.swift",
            pattern: r"guard text.unicodeScalars.contains\(where: isPrivateUse\)",
            view: View::Raw,
            message: "Sources/SlopDeskFontFaces/NerdSymbolFont.swift: runs(of:) lost its scalar pre-scan — \
                      every ordinary title pays a per-Character walk and a String per run again",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskFontFaces/NerdSymbolFont.swift"],
            pattern: r"if var last = out\.last|out\[out\.count - 1\] = ",
            view: View::Raw,
            message: "Sources/SlopDeskFontFaces/NerdSymbolFont.swift: runs(of:) accumulates through \
                      out.last again — that shape is QUADRATIC in the run length (3,563 ns for a 48-char \
                      title against 104)",
        },
    ];
    check_all(tree, &claims)
}

/// One outbound merge, and the face over it holds no bytes of its own
///
/// hostd's PTY read loop appends a chunk per supervised read and ONE drain pops, but what it pops
/// is not what was appended: adjacent chunks coalesce up to the credit-safe payload cap, an
/// over-cap head splits so the 13-byte `.output` header cannot push a frame past the receiver's
/// grant threshold, and `.exit` is a barrier neither may cross. That is
/// `rust/slopdesk-muxsession`'s `outbox` (docs/59 step 2), and `deleted_host_swift`'s
/// `pane_outbound_queue` bans the machinery it replaced.
///
/// What is pinned HERE is the shape docs/55 §4c makes non-negotiable on this path: the door reads
/// LENGTHS and the face keeps the bytes. This runs once per 32 KiB chunk, forever — a door that
/// materialized a `Data` per chunk would cost 227.5 ns against a crossing's 1.0, which is the same
/// trade the recorded +30 ms cold reattach paid for a `sanitize` callback. So the face must still
/// call every entry point (a dropped door is a shadow queue beside the one the verdict is computed
/// from) and must NOT hold a second ordering of its own: no array of queued items, no head cursor.
/// Its one collection is a map from the slot the door minted to the payload that slot names.
#[must_use]
pub fn the_outbound_frame_merges_once(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: OUTBOX_FACE,
            message: "Sources/SlopDeskHost/PaneOutbox.swift is gone — the pane's outbound queue is not \
                      MuxChannelSession's to hold again (docs/59 §4)",
        },
        Claim::Doors {
            path: OUTBOX_FACE,
            entries: &[
                "slopdesk_pane_outbox_new",
                "slopdesk_pane_outbox_free",
                "slopdesk_pane_outbox_append_chunk",
                "slopdesk_pane_outbox_append_exit",
                "slopdesk_pane_outbox_is_empty",
                "slopdesk_pane_outbox_take",
            ],
            message: "Sources/SlopDeskHost/PaneOutbox.swift no longer calls {entry} — a face that drops a \
                      door is an implementation coming back, and here it would be a second queue beside the \
                      one the frame verdict is computed from",
        },
        Claim::NoneOf {
            paths: &[OUTBOX_FACE],
            pattern: r"\[(OutputItem|Payload|Frame)\]|var (head|cursor|nextSlot)\b|removeFirst",
            view: View::Code,
            message: "{files} keeps an ORDER of its own — the face holds a slot→payload map and nothing \
                      else, because the order, the merge and the split are the door's (docs/59 §4)",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The face whose doors [`super::the_outbound_frame_merges_once`] pins.
    const OUTBOX_FACE: &str = super::OUTBOX_FACE;

    fn write_one_regex_engine_over_untrusted(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift",
                "slopdesk_hint_scan\nslopdesk_hint_scan_target\nslopdesk_hint_scan_take_arena\nstatic\nfunc\\
                 \
                 nlabels\nstatic\nfunc\nfilter\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-rowscan/Cargo.toml",
                "regex = \nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-terminal/Cargo.toml",
                "kept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_regex_engine_over_untrusted_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-regex-engine-over-untrusted");
        write_one_regex_engine_over_untrusted(&fixture);
        assert!(super::one_regex_engine_over_untrusted(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift",
            "",
        );
        assert!(!super::one_regex_engine_over_untrusted(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_regex_engine_over_untrusted(&fixture);
        fixture.append(
            "Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift",
            "NSRegularExpression\n",
        );
        assert!(!super::one_regex_engine_over_untrusted(&fixture.tree()).is_clean());
    }

    /// Every door the face must keep asking, in one string a fixture can hold.
    const OUTBOX_DOORS: &str = "slopdesk_pane_outbox_new()\nslopdesk_pane_outbox_free()\\
                                nslopdesk_pane_outbox_append_chunk()\nslopdesk_pane_outbox_append_exit()\\
                                nslopdesk_pane_outbox_is_empty()\nslopdesk_pane_outbox_take()\n";

    #[test]
    fn the_outbound_frame_merges_once_holds_the_face_to_its_doors() {
        let fixture = Fixture::new("outbound-frame-merges-once");
        fixture.write(OUTBOX_FACE, OUTBOX_DOORS);
        assert!(super::the_outbound_frame_merges_once(&fixture.tree()).is_clean());

        // The face stopped asking — the merge grew back where the call used to be.
        fixture.write(OUTBOX_FACE, "slopdesk_pane_outbox_new()\n");
        assert!(!super::the_outbound_frame_merges_once(&fixture.tree()).is_clean());

        // The face kept every door AND a second ordering beside it.
        fixture.write(OUTBOX_FACE, OUTBOX_DOORS);
        fixture.append(OUTBOX_FACE, "    private var queued: [Payload] = []\n");
        assert!(!super::the_outbound_frame_merges_once(&fixture.tree()).is_clean());

        // And the file itself, gone: a tree with no face at all fails on `Exists` rather than
        // passing the way an empty corpus passes a ban.
        let bare = Fixture::new("outbound-frame-merges-once-bare");
        bare.write("Sources/SlopDeskHost/A.swift", "let ordinary = 1\n");
        assert!(!super::the_outbound_frame_merges_once(&bare.tree()).is_clean());
    }
}
