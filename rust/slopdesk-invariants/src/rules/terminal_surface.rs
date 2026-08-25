//! The input surface, the grid geometry twin, the link scan and the command blocks.
//!
//! Ported from the deleted `check-supervisor.sh`, the stretch after the terminal-mode tracker.

use crate::claim::{Claim, Extract, SWIFT, View, check_all};
use crate::report::Report;
use crate::text;
use crate::tree::Tree;

const SWIFT_LINKS: &str = "Sources/SlopDeskWorkspaceCore/Terminal/TerminalLinkDetector.swift";
const RUST_LINK: &str = "rust/slopdesk-terminal/src/link.rs";
const SWIFT_BLOCKS: &str = "Sources/SlopDeskWorkspaceCore/Terminal/TerminalBlockModel.swift";
const RUST_BLOCKS: &str = "rust/slopdesk-terminal/src/blocks.rs";
const SWIFT_SEARCH: &str = "Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift";
const SWIFT_SEARCH_ACTION: &str = "Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchSurfaceAction.swift";

/// The input surface: which box to offer, and which bytes coming back are the PTY echoing what the
/// compose box just typed.
///
/// `rust/slopdesk-terminal`'s `inputbox` (which owns the dedup ring), reached through ONE handle —
/// because the alt-screen flip that switches A→B1 is the same flip that clears a half-matched echo,
/// and splitting them would put that coupling back in Swift.
///
/// The ring itself was `public` and separately tested but built by nothing except the model above.
/// It crosses as that model's INTERIOR; a Swift one growing back is a second entrance to one state
/// machine, with the record-then-echo ordering rule restated outside the door.
#[must_use]
pub fn input_surface(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: "Sources/SlopDeskClaudeCode/InputBoxModel.swift",
            entries: &[
                "slopdesk_input_box_new",
                "slopdesk_input_box_free",
                "slopdesk_input_box_reset",
                "slopdesk_input_box_state",
                "slopdesk_input_box_ingest",
                "slopdesk_input_box_take_rendered",
                "slopdesk_input_box_event",
                "slopdesk_input_box_record_compose_sent",
            ],
            message: "Sources/SlopDeskClaudeCode/InputBoxModel.swift no longer calls {entry} — the input \
                      surface is rust/slopdesk-terminal's",
        },
        Claim::Absent {
            path: "Sources/SlopDeskClaudeCode/InputDedupRing.swift",
            message: "rust/slopdesk-terminal's dedup crosses inside the input box",
        },
        Claim::NoneUnder {
            roots: &["Sources", "Tests"],
            extensions: SWIFT,
            pattern: r"(struct|enum|final class) InputDedupRing\b|func expectedEchoBytes\(|func stepFilter\(",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift hold-and-confirm echo ring is back in {files} — one implementation, and it is \
                      Rust's",
        },
    ];
    check_all(tree, &claims)
}

/// ONE GRID GEOMETRY, spelled on both sides because one side cannot reach the other.
///
/// `TerminalCellMetrics.rect` turns a detector span into the rect the underline and the hint labels
/// are DRAWN in; `slopdesk_terminal::link_hit::span_rect` turns the same span into the rect a point
/// is measured against. They must agree exactly or a link underlines in one place and answers a
/// click in another — a mismatch nobody reports as a bug, because both halves look right on their
/// own.
///
/// This is a genuine cross-language pair (docs/55 §8) and it is NOT closed by a door. `rect` lives
/// in the `SlopDeskTerminal` target, whose whole dependency list is `SlopDeskProtocol`; making it a
/// face would put `CSlopDeskFFI` into a target that links nothing today, and widen the graph for
/// two multiplies and two adds on the per-drawn-span path. So the pair stays, and this is what
/// holds it: each side must spell all four expressions, and anyone editing one has to come here and
/// edit the other. Whitespace-insensitive, because the two languages punctuate differently and
/// neither formatter is ours to argue with.
///
/// Neither may reach for `fma`/`addingProduct`: CLAUDE.md keeps `a * b + c` separate so the two
/// sides round identically, and a fused multiply-add on ONE of them is a half-cell disagreement on
/// a wide grid that no test with small numbers in it can see.
#[must_use]
pub fn grid_geometry(tree: &Tree) -> Report {
    /// Each row is one expression, spelled the way each language punctuates it.
    const SHAPES: [(&str, &str); 3] = [
        ("originX+cellWidth*", "origin_x+metrics.cell_width*"),
        ("originY+cellHeight*", "origin_y+metrics.cell_height*"),
        (
            "cellWidth*CGFloat(colEnd-colStart)",
            "metrics.cell_width*(col_end-col_start)",
        ),
    ];

    let mut report = Report::new();
    let (Some(swift), Some(rust)) = (
        report.source(
            tree,
            "Sources/SlopDeskTerminal/TerminalSurface.swift",
            "TerminalCellMetrics.rect lives there",
        ),
        report.source(
            tree,
            "rust/slopdesk-terminal/src/link_hit.rs",
            "link_hit::span_rect lives there",
        ),
    ) else {
        return report;
    };

    let squeeze = |text: &str| text.chars().filter(|c| !c.is_whitespace()).collect::<String>();
    let swift_rect = squeeze(&text::range(&swift.text, r"func rect\(row:", r"^    \}"));
    let rust_rect = squeeze(&text::range(&rust.text, r"fn span_rect\(", r"^\}"));

    report.fail_if(
        swift_rect.is_empty(),
        "TerminalCellMetrics.rect is gone — its Rust twin still measures a hit",
    );
    report.fail_if(
        rust_rect.is_empty(),
        "link_hit::span_rect is gone — the drawn rect has nothing left to agree with",
    );
    for (swift_shape, rust_shape) in SHAPES {
        report.fail_if(
            !swift_rect.contains(swift_shape),
            format!(
                "TerminalCellMetrics.rect no longer spells '{swift_shape}' — link_hit::span_rect still does",
            ),
        );
        report.fail_if(
            !rust_rect.contains(rust_shape),
            format!(
                "link_hit::span_rect no longer spells '{rust_shape}' — TerminalCellMetrics.rect still does",
            ),
        );
    }
    report.fail_if(
        text::matches(&swift_rect, "addingProduct|mul_add")
            || text::matches(&rust_rect, "addingProduct|mul_add"),
        "the grid geometry fused a multiply-add — the two sides must round the same way",
    );
    report
}

/// The LINK SCAN: paths, `path:line:col` diagnostics and URLs in the rows of the grid.
///
/// The one scan behind the ⌘-hold underline, Jump-To and Hint Mode. `rust/slopdesk-terminal`'s
/// `link`, reached through an arena door because the answer is a list of records each carrying up
/// to two strings.
///
/// The two WIDTH doors used to be pinned here beside the scan, and they are gone rather than
/// unpinned. Every Swift caller that walked a line cell by cell moved into the crate — vi-style
/// line motion, the hint assigner's column mapping, the scrollback wrap map — so each reads
/// `slopdesk_terminal::link::{scalar_cells, text_cells}` in-crate with no crossing at all, and the
/// doors outlived their last caller. What replaces the pin is the ban below: the TABLE may not grow
/// back in Swift, which is the fact the pin was standing in for.
#[must_use]
pub fn link_scan(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: SWIFT_LINKS,
            entries: &[
                "slopdesk_link_scan",
                "slopdesk_link_scan_free",
                "slopdesk_link_scan_counts",
                "slopdesk_link_scan_link",
                "slopdesk_link_scan_take_arena",
            ],
            message: "Sources/SlopDeskWorkspaceCore/Terminal/TerminalLinkDetector.swift no longer calls \
                      {entry} — the link scan is rust/slopdesk-terminal's",
        },
        Claim::Lacks {
            path: "rust/slopdesk-ffi/include/slopdesk_ffi.h",
            pattern: "slopdesk_link_scalar_cells|slopdesk_link_text_cells",
            view: View::Code,
            message: "a link width door is back in the header — its last Swift caller moved into the crate",
        },
        // The scan itself, in the shapes it had in Swift. The last two alternatives are the
        // East-Asian width TABLE the columns come from — matched on the scalar/character parameter,
        // because a second copy of it would put every overlay one cell out on a CJK row without
        // failing a test that has no CJK in it. (`ViLineMotion.cellWidth(_ line: String, at:)` is a
        // CALLER of the door, not a table, and stays.)
        Claim::NoneUnder {
            roots: &["Sources", "Tests"],
            extensions: SWIFT,
            pattern: r"func (trimWrapping|classifyURL|classifyMailto|classifyPath|pathShape|splitLineCol|lexicallyNormalize|fileURLPath)\(|func (isWide|isZeroWidth)\(_? ?[a-z]*: ?Unicode\.Scalar|func cellWidth(Of)?\(_? ?[a-z]*: ?(Character|String)\)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift link/path scan or cell-width table is back in {files} — one scan, and it is \
                      Rust's",
        },
        // Both bounds are spelled on both sides — one as a `public static let` the call sites read,
        // one as a `pub const` the scan enforces. A drift here is a hang bound or an overlay flood
        // that no test sees.
        Claim::SameValue {
            label: "link scan matches per row",
            swift: Extract::code(SWIFT_LINKS, r"static let maxMatchesPerRow = ([0-9]+)"),
            rust: Extract::code(RUST_LINK, r"pub const MAX_MATCHES_PER_ROW: usize = ([0-9]+)"),
        },
        Claim::SameValue {
            label: "link scan column bound",
            swift: Extract::code(SWIFT_LINKS, r"static let maxScanColumnsDefault = ([0-9]+)"),
            rust: Extract::code(RUST_LINK, r"pub const MAX_SCAN_COLUMNS: usize = ([0-9]+)"),
        },
    ];
    check_all(tree, &claims)
}

/// The COMMAND BLOCKS: the per-pane ring, the bookmark set and the output-request registry that
/// resets with it.
///
/// `rust/slopdesk-terminal`'s `blocks`, through ONE handle, because a reset drops the blocks and
/// has to answer every in-flight request in the same breath.
///
/// The rules that used to live in Swift are matched on the shapes they had. The eviction and the
/// FIFO bookmark cap are the two a re-implementation would get subtly wrong in a way no existing
/// test sees; the generation counter is the one that decides whether a stale timeout kills a live
/// request.
#[must_use]
pub fn command_blocks(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: SWIFT_BLOCKS,
            entries: &[
                "slopdesk_block_status",
                "slopdesk_block_duration_label",
                "slopdesk_block_adjacent_failed",
                "slopdesk_block_store_new",
                "slopdesk_block_store_free",
                "slopdesk_block_store_upsert",
                "slopdesk_block_store_project",
                "slopdesk_block_store_first_seen",
                "slopdesk_block_store_filtered",
                "slopdesk_block_store_is_bookmarked",
                "slopdesk_block_store_toggle_bookmark",
                "slopdesk_block_store_set_bookmarks",
                "slopdesk_block_store_bookmarks",
                "slopdesk_block_store_request",
                "slopdesk_block_store_is_pending",
                "slopdesk_block_store_current_generation",
                "slopdesk_block_store_resolve",
                "slopdesk_block_store_time_out",
                "slopdesk_block_store_reset",
                "slopdesk_block_store_take_stranded",
            ],
            message: "Sources/SlopDeskWorkspaceCore/Terminal/TerminalBlockModel.swift no longer calls \
                      {entry} — the command blocks are rust/slopdesk-terminal's",
        },
        Claim::NoneUnder {
            roots: &["Sources", "Tests"],
            extensions: SWIFT,
            pattern: r"func evictIfNeeded\(|var requestGeneration\b|var bookmarkOrder\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift block ring / bookmark order / generation counter is back in {files} — one \
                      ring, and it is Rust's",
        },
        // Both caps are spelled on both sides: a Swift `static let` the UI and the persistence read,
        // a Rust `pub const` the ring enforces. A drift makes the client hold a block superd already
        // evicted.
        Claim::SameValue {
            label: "block ring cap",
            swift: Extract::code(SWIFT_BLOCKS, r"static let maxBlocks = ([0-9]+)"),
            rust: Extract::code(RUST_BLOCKS, r"pub const MAX_BLOCKS: usize = ([0-9]+)"),
        },
        Claim::SameValue {
            label: "bookmark cap",
            swift: Extract::code(SWIFT_BLOCKS, r"static let maxBookmarks = ([0-9]+)"),
            rust: Extract::code(RUST_BLOCKS, r"pub const MAX_BOOKMARKS: usize = ([0-9]+)"),
        },
    ];
    check_all(tree, &claims)
}

/// The SEARCH surfaces: libghostty's binding grammar, and the two decisions both of them make.
///
/// `rust/slopdesk-workspace`'s `find_bar`, through `TerminalSearchSurfaceAction` — the one Swift
/// type allowed to hold the vocabulary, and the reason it sits in `SlopDeskWorkspaceCore` rather
/// than beside either bar: THREE callers speak it, in two targets.
///
/// The five spellings are the rare table where a second copy is not a style question. They are a
/// FOREIGN protocol — libghostty parses them, and the parser is vendored under `ThirdParty/`, so
/// nothing on this side regenerates them — and a typo produces a control that silently does nothing
/// rather than a build error. All three callers had written them out; two of those copies had
/// already drifted from the third on which modes may arm the literal matcher.
///
/// `Tests` is deliberately NOT scanned: the suites assert the strings AS STRINGS on purpose,
/// because a test comparing `.end` to `.end` would pass on the day the spelling drifted from what
/// the surface parses.
#[must_use]
pub fn search_surface(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: SWIFT_SEARCH_ACTION,
            entries: &[
                "slopdesk_ws_find_bar_wire",
                "slopdesk_ws_find_bar_row_driven",
                "slopdesk_ws_find_bar_arming",
                "slopdesk_ws_find_bar_nav_forward",
            ],
            message: "Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchSurfaceAction.swift no longer \
                      calls {entry} — libghostty's binding grammar and the modes it may be armed in are \
                      rust/slopdesk-workspace's find_bar",
        },
        Claim::Doors {
            path: SWIFT_SEARCH,
            entries: &["slopdesk_ws_find_reanchor", "slopdesk_ws_find_step"],
            message: "Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift no longer calls \
                      {entry} — where the selection lands after a rescan or a step is find_bar's",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r#""(search:|navigate_search|end_search|scroll_to_row:)"#,
            all: &[],
            unless: &[],
            view: View::Statements,
            exempt: &[],
            message: "a libghostty search binding-action string is spelled in {files} — the grammar is \
                      foreign and lives in ONE place, `TerminalSearchSurfaceAction.wire`, which crosses for \
                      the whole string rather than assembling it from a prefix",
        },
        // The three-flag verdict, matched on the shape it had at each of the two call sites it was
        // written out at. Either one growing back is the drift that let the case-sensitive arm land on
        // one search surface and not the other.
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(isRegex|controller\.isRegex) *\|\| *(controller\.)?wholeWord|!isRegex, *!caseSensitive",
            all: &[],
            unless: &[],
            view: View::Statements,
            exempt: &[],
            message: "the row-driven-nav partition is spelled again in {files} — both search surfaces read \
                      `TerminalSearchSurfaceAction.needsRowDrivenNav`, so neither can decide alone which \
                      modes libghostty may be trusted with",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The mismatch nobody reports as a bug: a link underlines in one place and answers a click in
    /// another, because both halves look right on their own.
    #[test]
    fn the_two_halves_of_the_grid_geometry_must_both_spell_it() {
        let swift = "\
extension TerminalCellMetrics {
    func rect(row: Int, colStart: Int, colEnd: Int) -> CGRect {
        let x = originX + cellWidth * CGFloat(colStart)
        let y = originY + cellHeight * CGFloat(row)
        let w = cellWidth * CGFloat(colEnd - colStart)
        return CGRect(x: x, y: y, width: w, height: cellHeight)
    }
}
";
        let rust = "\
fn span_rect(metrics: &Metrics, row: usize, col_start: usize, col_end: usize) -> Rect {
    let x = metrics.origin_x + metrics.cell_width * col_start as f64;
    let y = metrics.origin_y + metrics.cell_height * row as f64;
    let w = metrics.cell_width * (col_end - col_start) as f64;
    Rect { x, y, w, h: metrics.cell_height }
}
";
        let fixture = Fixture::new("grid-geometry");
        fixture
            .write("Sources/SlopDeskTerminal/TerminalSurface.swift", swift)
            .write("rust/slopdesk-terminal/src/link_hit.rs", rust);
        assert!(super::grid_geometry(&fixture.tree()).is_clean());

        // The banned token is assembled rather than spelled: `no-fused-multiply-add` bans a fused
        // multiply-add ANYWHERE in the tree, and a break-test that seeds one has to seed it without
        // being one. Same reason the shell's own break-tests could only be prose.
        let fused = format!(
            "metrics.cell_width.{}(col_start as f64, metrics.origin_x)",
            concat!("mul", "_add")
        );
        fixture.write(
            "rust/slopdesk-terminal/src/link_hit.rs",
            &rust.replace("metrics.origin_x + metrics.cell_width * col_start as f64", &fused),
        );
        let report = super::grid_geometry(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("fused a multiply-add")),
            "{report:?}"
        );
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("origin_x+metrics.cell_width*")),
            "{report:?}"
        );
    }

    /// A drift in either cap makes the client hold a block superd already evicted.
    #[test]
    fn a_cap_bumped_on_one_side_only_is_caught() {
        let fixture = Fixture::new("block-caps");
        let swift_body = "\
static let maxBlocks = 200
static let maxBookmarks = 32
";
        fixture
            .write(
                "Sources/SlopDeskWorkspaceCore/Terminal/TerminalBlockModel.swift",
                &format!("{swift_body}{DOORS}"),
            )
            .write(
                "rust/slopdesk-terminal/src/blocks.rs",
                "pub const MAX_BLOCKS: usize = 200;\npub const MAX_BOOKMARKS: usize = 32;\n",
            );
        assert!(super::command_blocks(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-terminal/src/blocks.rs",
            "pub const MAX_BLOCKS: usize = 400;\npub const MAX_BOOKMARKS: usize = 32;\n",
        );
        let report = super::command_blocks(&fixture.tree());
        assert!(
            report.violations().iter().any(|v| v.contains("block ring cap")),
            "{report:?}"
        );
    }

    /// A width door back in the header means its last Swift caller came back out of the crate.
    #[test]
    fn a_retired_width_door_returning_to_the_header_is_caught() {
        let fixture = Fixture::new("width-door");
        fixture
            .write(
                "Sources/SlopDeskWorkspaceCore/Terminal/TerminalLinkDetector.swift",
                "slopdesk_link_scan(x)\nslopdesk_link_scan_free(x)\nslopdesk_link_scan_counts(x)\\
                 nslopdesk_link_scan_link(x)\nslopdesk_link_scan_take_arena(x)\nstatic let maxMatchesPerRow \
                 = 64\nstatic let maxScanColumnsDefault = 1000\n",
            )
            .write(
                "rust/slopdesk-terminal/src/link.rs",
                "pub const MAX_MATCHES_PER_ROW: usize = 64;\npub const MAX_SCAN_COLUMNS: usize = 1000;\n",
            )
            .write(
                "rust/slopdesk-ffi/include/slopdesk_ffi.h",
                "size_t slopdesk_link_scan(void);\n",
            );
        assert!(super::link_scan(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-ffi/include/slopdesk_ffi.h",
            "size_t slopdesk_link_scan(void);\nsize_t slopdesk_link_text_cells(const char *);\n",
        );
        let report = super::link_scan(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("width door is back")),
            "{report:?}"
        );
    }

    /// The two ways one search surface starts disagreeing with the other: it retypes libghostty's
    /// grammar, or it retypes the partition that decides when the grammar may be used. Both had
    /// already happened once, and neither failed a test — the strings still parsed, and each
    /// surface's own suite passed against its own reading.
    #[test]
    fn a_second_copy_of_the_binding_grammar_or_its_partition_is_caught() {
        let fixture = Fixture::new("search-surface");
        let vocabulary = "\
slopdesk_ws_find_bar_wire(kind, forward, row, text.baseAddress, text.count, out, cap)
slopdesk_ws_find_bar_row_driven(isRegex, wholeWord, caseSensitive)
slopdesk_ws_find_bar_arming(queryEmpty, isRegex, wholeWord, caseSensitive)
slopdesk_ws_find_bar_nav_forward(repeatingSameWay, searchBackward)
";
        let controller = "\
slopdesk_ws_find_reanchor(previous != nil, previous ?? 0, matches.count)
slopdesk_ws_find_step(current != nil, current ?? 0, forward, count)
";
        fixture
            .write(super::SWIFT_SEARCH_ACTION, vocabulary)
            .write(super::SWIFT_SEARCH, controller);
        assert!(super::search_surface(&fixture.tree()).is_clean());

        // A door dropped: the vocabulary went back to building the strings itself.
        fixture.write(
            super::SWIFT_SEARCH_ACTION,
            &vocabulary.replace(
                "slopdesk_ws_find_bar_wire(kind",
                "\"navigate_search:next\" // (kind",
            ),
        );
        let report = super::search_surface(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("slopdesk_ws_find_bar_wire")),
            "{report:?}"
        );

        // The grammar retyped at a third call site, in code rather than in the prose that explains it.
        fixture.write(super::SWIFT_SEARCH_ACTION, vocabulary).write(
            "Sources/SlopDeskWorkspaceCore/Terminal/GlobalSearchController.swift",
            "// clears the stale highlight with end_search, then scrolls\nreturn [\"end_search\"]\n",
        );
        let report = super::search_surface(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("binding-action string is spelled")),
            "{report:?}"
        );

        // …and the partition, spelled out beside a surface that then owns its own reading of it.
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Terminal/GlobalSearchController.swift",
            "if !isRegex, !caseSensitive { return arm(query) }\n",
        );
        let report = super::search_surface(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("row-driven-nav partition")),
            "{report:?}"
        );
    }

    /// Every block-store door, so the fixture above satisfies the `Doors` claim.
    const DOORS: &str = "\
slopdesk_block_status(x)
slopdesk_block_duration_label(x)
slopdesk_block_adjacent_failed(x)
slopdesk_block_store_new(x)
slopdesk_block_store_free(x)
slopdesk_block_store_upsert(x)
slopdesk_block_store_project(x)
slopdesk_block_store_first_seen(x)
slopdesk_block_store_filtered(x)
slopdesk_block_store_is_bookmarked(x)
slopdesk_block_store_toggle_bookmark(x)
slopdesk_block_store_set_bookmarks(x)
slopdesk_block_store_bookmarks(x)
slopdesk_block_store_request(x)
slopdesk_block_store_is_pending(x)
slopdesk_block_store_current_generation(x)
slopdesk_block_store_resolve(x)
slopdesk_block_store_time_out(x)
slopdesk_block_store_reset(x)
slopdesk_block_store_take_stranded(x)
";
}
