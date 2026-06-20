import Foundation
import XCTest
@testable import AislopdeskClientUI

/// P3 (W14 #6 — the missing decode test): ``TreeWorkspace``'s ADDITIVE-tolerant decode of the new
/// `launchPresets` key + the re-seed-when-empty logic. A v10 file written BEFORE W14 has no
/// `launchPresets` key — the decode must NOT trap and must yield an empty list, which
/// `seedingBuiltInLaunchPresetsIfEmpty()` then re-seeds with the shipped built-ins. A file that DOES
/// carry the field must round-trip it verbatim (no spurious re-seed / no loss). A user who curated the
/// list (kept ≥ 1 preset, even after deleting some) is left untouched — the re-seed never resurrects a
/// built-in they removed.
final class TreeWorkspaceLaunchPresetDecodeTests: XCTestCase {
    /// A minimal valid v10 workspace JSON, optionally including a `launchPresets` array. Built by hand so
    /// the test exercises the REAL `init(from:)`, not an encode-of-our-own-model derivation.
    private func workspaceJSON(launchPresets: String?) -> Data {
        // One session / one tab / one terminal leaf — enough for the required keys to decode.
        let session = try? JSONEncoder().encode(
            Session.singlePane(name: "Local", spec: PaneSpec(kind: .terminal, title: "Local")),
        )
        let sessionJSON = session.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var fields = """
        "schemaVersion": \(TreeWorkspace.currentSchemaVersion),
        "sessions": [\(sessionJSON)]
        """
        if let launchPresets {
            fields += ",\n\"launchPresets\": \(launchPresets)"
        }
        return Data("{\(fields)}".utf8)
    }

    // MARK: Additive decode — the field is absent (a pre-W14 v10 file)

    /// A v10 file with NO `launchPresets` key decodes WITHOUT trapping, to an empty list (no loss, no
    /// crash) — the forward-compatible additive-field contract.
    func testDecodeWithoutLaunchPresetsKeyYieldsEmptyAndDoesNotTrap() throws {
        let data = workspaceJSON(launchPresets: nil)
        let ws = try JSONDecoder().decode(TreeWorkspace.self, from: data)
        XCTAssertTrue(ws.launchPresets.isEmpty, "absent key ⇒ empty list (decodeIfPresent), never a trap")
    }

    /// The re-seed restores the built-ins for that empty (pre-W14) case — the workspace the store loads
    /// ends up with Claude Code / htop / Git log.
    func testEmptyLaunchPresetsReseedsBuiltIns() throws {
        let ws = try JSONDecoder().decode(TreeWorkspace.self, from: workspaceJSON(launchPresets: nil))
        let seeded = ws.seedingBuiltInLaunchPresetsIfEmpty()
        XCTAssertEqual(seeded.launchPresets.map(\.name), ["Claude Code", "htop", "Git log"])
        XCTAssertEqual(seeded.launchPresets, LaunchPreset.builtIns)
    }

    // MARK: Present field — round-trips verbatim, no spurious re-seed

    /// A file that carries a (custom) `launchPresets` list decodes it verbatim AND is left untouched by
    /// the re-seed — a curated list is never clobbered with the built-ins.
    func testDecodeWithCustomLaunchPresetsRoundTripsAndIsNotReseeded() throws {
        let mine = LaunchPreset(name: "Mine", command: "ls -la")
        let listJSON = try XCTUnwrap(String(data: JSONEncoder().encode([mine]), encoding: .utf8))
        let ws = try JSONDecoder().decode(TreeWorkspace.self, from: workspaceJSON(launchPresets: listJSON))
        XCTAssertEqual(ws.launchPresets, [mine], "present field decodes verbatim")
        let seeded = ws.seedingBuiltInLaunchPresetsIfEmpty()
        XCTAssertEqual(seeded.launchPresets, [mine], "a non-empty list is left untouched (no re-seed)")
    }

    /// A user who DELETED some built-ins (keeping ≥ 1) is NOT re-seeded — the removed built-ins stay gone.
    func testCuratedListAfterDeletionIsNotResurrected() throws {
        // Keep only htop (the user deleted Claude Code + Git log).
        let htop = try XCTUnwrap(LaunchPreset.builtIns.first { $0.name == "htop" })
        let listJSON = try XCTUnwrap(String(data: JSONEncoder().encode([htop]), encoding: .utf8))
        let ws = try JSONDecoder().decode(TreeWorkspace.self, from: workspaceJSON(launchPresets: listJSON))
        let seeded = ws.seedingBuiltInLaunchPresetsIfEmpty()
        XCTAssertEqual(seeded.launchPresets.map(\.name), ["htop"], "deleted built-ins are not resurrected")
    }

    /// An EMPTY explicit array (the field present but `[]`) also re-seeds — same as the absent case (the
    /// re-seed keys off emptiness, not presence).
    func testExplicitlyEmptyArrayAlsoReseeds() throws {
        let ws = try JSONDecoder().decode(TreeWorkspace.self, from: workspaceJSON(launchPresets: "[]"))
        XCTAssertTrue(ws.launchPresets.isEmpty)
        XCTAssertEqual(ws.seedingBuiltInLaunchPresetsIfEmpty().launchPresets, LaunchPreset.builtIns)
    }
}
