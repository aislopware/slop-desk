import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for ``TabOrderingEngine`` — after the 2026-07-10 re-scope (always By-Project, creation order;
/// the grouping/sort hamburger and its `groups(...)` derivation are deleted) the engine is two PURE key
/// helpers shared by every sectioning caller: ``TabOrderingEngine/normalizedProjectKey(_:)`` (the bucketing
/// key) and ``TabOrderingEngine/projectSectionHeader(for:)`` (the section title). Headless: no SwiftUI, no
/// I/O — plain statics over plain values. The full per-pane bucketing over these helpers is pinned in
/// `RailRowBuilderTests` (`sectionedByProject`).
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
}
