import Foundation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for ``TabOrderingEngine`` — sectioning is always By-Project in creation order, with no
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

    /// Sections take their slot on FIRST APPEARANCE and elements keep their incoming order inside one — a
    /// second tab for an already-open project joins that project's section rather than opening a new one
    /// after the section that happened to be created in between.
    func testBucketedByProjectSectionsFollowFirstAppearance() {
        let keys = ["/w/alpha", "/w/beta", "/w/alpha", "/w/gamma", "/w/beta"]
        let sections = TabOrderingEngine.bucketedByProject(keys.enumerated().map { ($0.offset, $0.element) }) {
            $0.1
        }
        XCTAssertEqual(sections.map(\.key), ["/w/alpha", "/w/beta", "/w/gamma"])
        XCTAssertEqual(sections.map { $0.elements.map(\.0) }, [[0, 2], [1, 4], [3]])
    }

    /// The keyless bucket is `nil` — its own section, taking its first-appearance slot like any other
    /// rather than being forced to the end or hidden behind a sentinel string.
    func testBucketedByProjectGivesTheKeylessBucketItsOwnFirstAppearanceSlot() {
        let sections = TabOrderingEngine.bucketedByProject([
            "video", "alpha", "video2", "alpha2",
        ]) { $0.hasPrefix("video") ? nil : "/w/alpha" }
        XCTAssertEqual(
            sections.map(\.key),
            [nil, "/w/alpha"],
            "the video pane's section comes first — it appeared first",
        )
        XCTAssertEqual(sections.map(\.elements), [["video", "video2"], ["alpha", "alpha2"]])
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
