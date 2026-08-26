//! The input surface, the grid geometry twin, the link scan and the command blocks.
//!
//! Ported from the deleted `check-supervisor.sh`, the stretch after the terminal-mode tracker.

use crate::claim::{Claim, Extract, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const SWIFT_LINKS: &str = "Sources/SlopDeskWorkspaceCore/Terminal/TerminalLinkDetector.swift";
const RUST_LINK: &str = "rust/slopdesk-terminal/src/link.rs";
const SWIFT_BLOCKS: &str = "Sources/SlopDeskWorkspaceCore/Terminal/TerminalBlockModel.swift";
const RUST_BLOCKS: &str = "rust/slopdesk-terminal/src/blocks.rs";
const SWIFT_SEARCH: &str = "Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift";
const SWIFT_SEARCH_ACTION: &str = "Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchSurfaceAction.swift";
const SWIFT_METRICS: &str = "Sources/SlopDeskTerminal/TerminalSurface.swift";
const SWIFT_FIT: &str = "Sources/SlopDeskTerminal/TerminalGridFit.swift";
const RUST_GEOMETRY: &str = "rust/slopdesk-terminal/src/geometry.rs";
const RUST_LINK_HIT: &str = "rust/slopdesk-terminal/src/link_hit.rs";

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

/// ONE GRID GEOMETRY, and it is `slopdesk_terminal::geometry`.
///
/// Two questions, one arithmetic. Where a detector span is DRAWN (the ⌘-hold underline, the hint
/// labels) and where a point is MEASURED against it (`link_hit`) must agree exactly, or a link
/// underlines in one place and answers a click in another — a mismatch nobody reports, because both
/// halves look right on their own. Where a grid the client did not choose is LETTERBOXED is the
/// same target's other geometry, held to the same rounding.
///
/// This rule used to hold the pair OPEN. `rect` lived in a target whose whole dependency list was
/// `SlopDeskProtocol`, so docs/55 §8 recorded it as drift and pinned both spellings instead — each
/// side had to spell all four expressions, and editing one meant coming here to edit the other. The
/// letterbox beside it is what changed the arithmetic on that trade: one archive now buys a cluster
/// rather than two multiplies, so the duplicate is gone and this pins what replaced it.
///
/// The FLOAT ban outlives the duplicate. `slopdesk_grid_*` is the only place the multiplies happen,
/// but a face that re-derived a width to save a crossing would round its own way on a wide grid,
/// and no test with small numbers in it would see the half-cell.
#[must_use]
pub fn grid_geometry(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: RUST_GEOMETRY,
            message: "the one grid geometry both the drawn rect and the measured hit fold through",
        },
        Claim::Doors {
            path: SWIFT_METRICS,
            entries: &["slopdesk_grid_rect", "slopdesk_grid_clamped_rect"],
            message: "TerminalCellMetrics no longer calls {entry} — the span rect is \
                      slopdesk_terminal::geometry's",
        },
        Claim::Doors {
            path: SWIFT_FIT,
            entries: &[
                "slopdesk_grid_fit",
                "slopdesk_grid_placement",
                "slopdesk_grid_is_letterboxed",
            ],
            message: "TerminalLetterbox no longer calls {entry} — the placement is \
                      slopdesk_terminal::geometry's",
        },
        Claim::NoneOf {
            paths: &[SWIFT_METRICS, SWIFT_FIT],
            pattern: r"cellWidth \*|cellHeight \*|addingProduct",
            view: View::Code,
            message: "{files} multiplies a cell metric again instead of asking the door — a face that \
                      re-derives a width rounds its own way, and a half-cell on a wide grid is what no test \
                      with small numbers in it can see",
        },
        Claim::NoneOf {
            paths: &[RUST_LINK_HIT],
            pattern: r"mul_add|metrics\.cell_width \*|metrics\.origin_x \+",
            view: View::Code,
            message: "{files} spells the span arithmetic again instead of folding through `geometry` — the \
                      cross-language pair this rule used to hold OPEN is closed, and a second spelling \
                      anywhere reopens it",
        },
    ];
    check_all(tree, &claims)
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
    /// another, because both halves look right on their own. It is a door now, so what this seeds
    /// is the RETURN of the arithmetic — on either side of it.
    #[test]
    fn neither_half_of_the_grid_geometry_may_spell_it_again() {
        let metrics = "\
extension TerminalCellMetrics {
    func rect(row: Int, colStart: Int, colEnd: Int) -> CGRect {
        Self.cgRect(slopdesk_grid_rect(cellWidth, cellHeight, originX, originY,
                                       Int64(row), Int64(colStart), Int64(colEnd)))
    }

    func clampedRect(row: Int, colStart: Int, colEnd: Int) -> CGRect? {
        let span = slopdesk_grid_clamped_rect(cellWidth, cellHeight, originX, originY,
                                              Int64(cols), Int64(row), Int64(colStart), Int64(colEnd))
        return span.present ? Self.cgRect(span) : nil
    }
}
";
        let fit = "\
extension TerminalLetterbox {
    var isLetterboxed: Bool { slopdesk_grid_is_letterboxed(contentRect.origin.x, contentRect.origin.y) }
    static func fit(cols: Int, rows: Int) -> Self? { unwrap(slopdesk_grid_fit(Int64(cols), Int64(rows))) }
    static func placement(cols: Int, rows: Int) -> Placement? {
        unwrap(slopdesk_grid_placement(Int64(cols), Int64(rows)))
    }
}
";
        let hit = "\
fn span_rect(metrics: CellMetrics, span: LinkSpan) -> Rect {
    geometry::rect(metrics, widen(span.row), widen(span.col_start), widen(span.col_end))
}
";
        let fixture = Fixture::new("grid-geometry");
        fixture
            .write("rust/slopdesk-terminal/src/geometry.rs", "pub fn rect() {}\n")
            .write("Sources/SlopDeskTerminal/TerminalSurface.swift", metrics)
            .write("Sources/SlopDeskTerminal/TerminalGridFit.swift", fit)
            .write("rust/slopdesk-terminal/src/link_hit.rs", hit);
        assert!(super::grid_geometry(&fixture.tree()).is_clean());

        // The Swift half drifts first: a face that "saves a crossing" by deriving the width itself.
        fixture.write(
            "Sources/SlopDeskTerminal/TerminalSurface.swift",
            &metrics.replace(
                "Self.cgRect(slopdesk_grid_rect(cellWidth",
                "CGRect(x: originX, y: originY, width: cellWidth * CGFloat(colEnd - colStart), height: \
                 cellHeight); _ = (slopdesk_grid_rect(cellWidth",
            ),
        );
        let report = super::grid_geometry(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("multiplies a cell metric again")),
            "{report:?}"
        );

        // Then the Rust half, with the fused multiply-add the whole ban exists for. The token is
        // ASSEMBLED rather than spelled: `no-fused-multiply-add` bans one anywhere in the tree, so a
        // break-test that seeds one has to seed it without being one.
        fixture
            .write("Sources/SlopDeskTerminal/TerminalSurface.swift", metrics)
            .write(
                "rust/slopdesk-terminal/src/link_hit.rs",
                &hit.replace(
                    "geometry::rect(metrics,",
                    &format!(
                        "metrics.cell_width.{}(1.0, metrics.origin_x); geometry::rect(metrics,",
                        concat!("mul", "_add")
                    ),
                ),
            );
        let report = super::grid_geometry(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("spells the span arithmetic again")),
            "{report:?}"
        );

        // And the crate the whole rule folds through, gone.
        fixture.remove("rust/slopdesk-terminal/src/geometry.rs");
        assert!(
            super::grid_geometry(&fixture.tree())
                .violations()
                .iter()
                .any(|v| v.contains("both the drawn rect and the measured hit fold through")),
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
