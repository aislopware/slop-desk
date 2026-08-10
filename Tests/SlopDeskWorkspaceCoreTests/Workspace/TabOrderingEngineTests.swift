import Foundation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for ``TabOrderingEngine`` — sectioning is always By-Project with the sections A→Z, no
/// grouping/sort hamburger, so the engine is the key rules (``TabOrderingEngine/normalizedProjectKey(_:)``
/// for the bucket, ``TabOrderingEngine/projectSectionHeader(for:)`` for the title) plus the ONE bucketing
/// primitive over them, ``TabOrderingEngine/bucketedByProject(_:projectKey:)``, which the sidebar runs per
/// PANE and the tab-close rule runs per TAB. Headless: no SwiftUI, no I/O — plain statics over plain
/// values. The rail's use of the primitive is pinned in `RailRowBuilderTests` (`sectionedByProject`),
/// including the cross-layer pin that the close rule walks the order the rail drew.
final class TabOrderingEngineTests: XCTestCase {
    // MARK: - normalizedProjectKey (the bucketing key rule)

    func testNormalizedProjectKeyTrimsAndStripsTrailingSlashes() {
        XCTAssertEqual(TabOrderingEngine.normalizedProjectKey("/work/alpha"), "/work/alpha")
        XCTAssertEqual(
            TabOrderingEngine.normalizedProjectKey("/work/alpha/"), "/work/alpha",
            "a trailing slash names the SAME project — stripped so one dir can't split into two sections",
        )
        XCTAssertEqual(TabOrderingEngine.normalizedProjectKey("  /work/alpha  "), "/work/alpha")
        XCTAssertEqual(TabOrderingEngine.normalizedProjectKey("/work/alpha///"), "/work/alpha")
    }

    func testNormalizedProjectKeyKeepsRootSlash() {
        XCTAssertEqual(TabOrderingEngine.normalizedProjectKey("/"), "/", "root stays `/`, never stripped empty")
    }

    func testNormalizedProjectKeyTreatsBlankAsAbsent() {
        XCTAssertNil(TabOrderingEngine.normalizedProjectKey(nil))
        XCTAssertNil(TabOrderingEngine.normalizedProjectKey(""))
        XCTAssertNil(TabOrderingEngine.normalizedProjectKey("   "), "whitespace-only ⇒ absent ⇒ the Other bucket")
    }

    // MARK: - projectSectionHeader (the section title rule)

    func testProjectSectionHeaderIsLastPathComponent() {
        XCTAssertEqual(TabOrderingEngine.projectSectionHeader(for: "/Users/me/proj/foo"), "foo")
        XCTAssertEqual(
            TabOrderingEngine.projectSectionHeader(for: "/Users/me/proj/foo/"), "foo",
            "trailing-slash tolerant (omittingEmptySubsequences)",
        )
    }

    func testProjectSectionHeaderFallsBackToWholeKeyWithoutSlash() {
        XCTAssertEqual(TabOrderingEngine.projectSectionHeader(for: "~"), "~")
    }

    func testProjectSectionHeaderNilOrBlankIsOther() {
        XCTAssertEqual(TabOrderingEngine.projectSectionHeader(for: nil), "Other")
        XCTAssertEqual(TabOrderingEngine.projectSectionHeader(for: "  "), "Other")
    }

    // MARK: - bucketedByProject (the ONE sectioning rule, shared with the rail)

    /// Sections sort A→Z and elements keep their incoming order inside one — a second tab for an
    /// already-open project joins that project's section rather than opening a new one after the section
    /// that happened to be created in between. Seeded in a NON-alphabetical creation order so a bucketer
    /// that kept first-appearance slots fails loudly.
    func testBucketedByProjectSectionsSortAlphabeticallyAndKeepElementOrder() {
        let keys = ["/w/gamma", "/w/beta", "/w/gamma", "/w/alpha", "/w/beta"]
        let sections = TabOrderingEngine.bucketedByProject(keys.enumerated().map { ($0.offset, $0.element) }) {
            $0.1
        }
        XCTAssertEqual(sections.map(\.key), ["/w/alpha", "/w/beta", "/w/gamma"])
        XCTAssertEqual(sections.map { $0.elements.map(\.0) }, [[3], [1, 4], [0, 2]])
    }

    /// Ordering is on the DISPLAYED header (the key's basename), not the whole key — `/w/zeta/alpha`
    /// reads "alpha" in the sidebar and belongs under A, no matter what its parent folder is called.
    func testBucketedByProjectSortsOnTheHeaderNotTheWholeKey() {
        let sections = TabOrderingEngine.bucketedByProject(["z", "b"]) {
            $0 == "z" ? "/w/zeta/alpha" : "/w/apps/beta"
        }
        XCTAssertEqual(
            sections.map(\.key), ["/w/zeta/alpha", "/w/apps/beta"],
            "alpha before beta — the parent segment does not decide the slot",
        )
    }

    /// The Finder's comparison: case-insensitive, and digit runs read as NUMBERS (`app2` before `app10`).
    func testBucketedByProjectSortsCaseInsensitivelyAndNumerically() {
        let sections = TabOrderingEngine.bucketedByProject(["a", "b", "c"]) {
            switch $0 {
            case "a": "/w/app10"
            case "b": "/w/App2"
            default: "/w/ant"
            }
        }
        XCTAssertEqual(sections.map(\.key), ["/w/ant", "/w/App2", "/w/app10"])
    }

    /// Two same-basename worktrees are two sections sharing one header — the KEY breaks the tie, which is
    /// both deterministic (`sorted(by:)` is not documented stable) and the order their parent-qualified
    /// headers will read in (`feature-a/myapp` before `feature-b/myapp`).
    func testBucketedByProjectBreaksAHeaderTieOnTheKey() {
        let sections = TabOrderingEngine.bucketedByProject(["b", "a"]) {
            $0 == "b" ? "/w/feature-b/myapp" : "/w/feature-a/myapp"
        }
        XCTAssertEqual(sections.map(\.key), ["/w/feature-a/myapp", "/w/feature-b/myapp"])
    }

    /// The keyless bucket is `nil` — its own section, sorted LAST rather than filed under "O" among the
    /// real projects or hidden behind a sentinel string.
    func testBucketedByProjectSortsTheKeylessBucketLast() {
        let sections = TabOrderingEngine.bucketedByProject([
            "video", "zulu", "video2", "zulu2",
        ]) { $0.hasPrefix("video") ? nil : "/w/zulu" }
        XCTAssertEqual(
            sections.map(\.key),
            ["/w/zulu", nil],
            "Other comes last even behind a Z project — it is not a name, it is the absence of one",
        )
        XCTAssertEqual(sections.map(\.elements), [["zulu", "zulu2"], ["video", "video2"]])
    }

    /// Bucketing folds through ``TabOrderingEngine/normalizedProjectKey(_:)``, so keys that differ only by a
    /// trailing slash or surrounding whitespace are ONE section — the whole reason normalization exists.
    func testBucketedByProjectFoldsKeysThroughNormalization() {
        let sections = TabOrderingEngine.bucketedByProject(["a", "b", "c"]) { element in
            switch element {
            case "a": "/w/alpha"
            case "b": "/w/alpha/"
            default: "  /w/alpha  "
            }
        }
        XCTAssertEqual(sections.count, 1, "one directory, one section")
        XCTAssertEqual(sections[0].key, "/w/alpha")
        XCTAssertEqual(sections[0].elements, ["a", "b", "c"])
    }

    /// ``TabOrderingEngine/projectGroupedTabOrder(_:projectKey:)`` is the flattening of exactly these
    /// sections — the property that lets the close rule claim it walks the order the sidebar DREW, since
    /// the sidebar sections with the same primitive (per pane) that this reads (per tab).
    func testProjectGroupedTabOrderIsTheFlattenedBucketing() {
        let tabs = (0..<5).map { _ in TabID() }
        let keys: [TabID: String] = [
            tabs[0]: "/w/alpha", tabs[1]: "/w/beta", tabs[2]: "/w/alpha",
            tabs[3]: "/w/gamma", tabs[4]: "/w/beta",
        ]
        let lookup: (TabID) -> String? = { keys[$0] }
        XCTAssertEqual(
            TabOrderingEngine.projectGroupedTabOrder(tabs, projectKey: lookup),
            TabOrderingEngine.bucketedByProject(tabs, projectKey: lookup).flatMap(\.elements),
        )
        XCTAssertEqual(
            TabOrderingEngine.projectGroupedTabOrder(tabs, projectKey: lookup),
            [tabs[0], tabs[2], tabs[1], tabs[4], tabs[3]],
        )
    }
}
