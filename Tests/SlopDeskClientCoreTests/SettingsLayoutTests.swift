import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

/// The near side of `slopdesk_workspace::settings_layout`.
///
/// What the Rust tests already pin — the order, the platform filter, the flattening of a control —
/// is NOT restated here; that would be the cross-language mirror fixture `CLAUDE.md` bans. What is
/// left is what only this side can see: that the crossing arrives intact, that the join onto the row
/// table finds a label for every row, and that the ONE property the whole port exists for holds —
/// asking as the phone and asking as the Mac from the same process gives two different pages.
final class SettingsLayoutTests: XCTestCase {
    // MARK: The crossing arrives

    /// Nothing comes back blank. Every string door here answers `0` for "nothing", so a marshalling
    /// slip does not throw — it renders an unlabelled row under a headerless group, which looks like
    /// a layout bug rather than a boundary bug.
    func testEveryGroupAndRowCrossesWithItsWords() {
        for half in [SettingsLayout.Half.mac, .phone] {
            for section in SettingsCatalog.sections {
                for group in SettingsLayout.groups(section.id, for: half) {
                    XCTAssertFalse(group.title.isEmpty, "a group on \(section.id) crossed with no header")
                    XCTAssertFalse(
                        group.rows.isEmpty,
                        "\(group.title) crossed empty for \(half) — a header with nothing under it",
                    )
                    // A bespoke group draws itself and names no setting, so it has no label to
                    // cross — see `testABespokeGroupNamesItselfAndEditsNoKey` for that half.
                    for row in group.rows where !row.key.isEmpty {
                        XCTAssertFalse(row.label.isEmpty, "a row in \(group.title) crossed with no label")
                    }
                }
            }
        }
    }

    /// Every row that names a key resolves to a row in the settings table, which is where its label
    /// comes from. An unresolved key falls back to the key ITSELF, so this is the assertion that no
    /// page is quietly showing `features.redactSecrets` where a name should be.
    func testEveryRowsLabelComesFromTheRowTableRatherThanItsKey() {
        let advertised = Dictionary(
            AllSettingsCatalog.entries.map { ($0.key, $0.pageLabel) },
            uniquingKeysWith: { first, _ in first },
        )
        for half in [SettingsLayout.Half.mac, .phone] {
            for section in SettingsCatalog.sections {
                for group in SettingsLayout.groups(section.id, for: half) {
                    for row in group.rows where !row.key.isEmpty {
                        XCTAssertEqual(
                            row.label,
                            advertised[row.key],
                            "\(row.key) is rendering its own key as a name — the join missed it",
                        )
                    }
                }
            }
        }
    }

    /// A row that EDITS names a key; a row that merely DRAWS does not. That split is what a renderer
    /// switches on to decide whether to go looking for a binding at all, so both directions matter: a
    /// keyless toggle would silently render nothing, and a note with a key would send a renderer
    /// hunting for a binding that does not exist.
    func testOnlyARowThatEditsSomethingNamesAKey() {
        for half in [SettingsLayout.Half.mac, .phone] {
            for section in SettingsCatalog.sections {
                for row in SettingsLayout.groups(section.id, for: half).flatMap(\.rows) {
                    switch row.control {
                    case let .bespoke(id):
                        XCTAssertFalse(id.isEmpty, "a bespoke row names nothing to draw")
                        XCTAssertTrue(row.key.isEmpty, "\(id) draws itself, so it edits no single key")
                    case .note:
                        XCTAssertTrue(row.key.isEmpty, "a note edits nothing, so it names no key")
                        XCTAssertFalse(row.subtitle.isEmpty, "a note with no words is an empty paragraph")
                    default:
                        XCTAssertFalse(row.key.isEmpty, "a row with a real control edits nothing")
                    }
                }
            }
        }
    }

    // MARK: The reason the table exists

    /// ONE PROCESS, TWO ANSWERS. This is the property that makes a platform gate data rather than a
    /// directive: a Mac can ask what the phone draws. Under `#if os(macOS)` the question had no
    /// runtime form at all, which is why the thirty-seven gates were never counted or tested.
    func testAskingAsEachHalfFromOneProcessGivesTwoPages() {
        let onMac = SettingsLayout.groups("general", for: .mac).map(\.title)
        let onPhone = SettingsLayout.groups("general", for: .phone).map(\.title)

        XCTAssertTrue(onMac.contains("OS Integration"), "the Mac draws the LaunchServices group")
        XCTAssertFalse(onPhone.contains("OS Integration"), "iOS has no LaunchServices deep-links to offer")
        XCTAssertEqual(
            onPhone, onMac.filter { $0 != "OS Integration" },
            "the two pages differ by exactly the group iOS cannot back, in the same order",
        )
    }

    /// The device-local row whose DEFAULT differs by platform is on BOTH pages — the one place where
    /// "this is platform-specific" must NOT become "this is macOS-only". Without a control on each,
    /// a device keeps its platform default forever and the escape hatch is unreachable in whichever
    /// direction it did not start in (docs/45 §8.2).
    func testTheSharedFocusRowIsOnBothPages() {
        for half in [SettingsLayout.Half.mac, .phone] {
            let keys = SettingsLayout.groups("general", for: half).flatMap(\.rows).map(\.key)
            XCTAssertTrue(
                keys.contains(AllSettingsCatalog.followSessionFocusKey),
                "\(half) cannot reach the one knob whose default it disagrees with the other half about",
            )
        }
    }

    /// A section id no section has is not a page. The lookup is by string, so this is the arm that
    /// stops a typo from silently rendering the first page.
    func testAnUnknownSectionIsNotAPage() {
        XCTAssertTrue(SettingsLayout.groups("not-a-section", for: .mac).isEmpty)
        XCTAssertTrue(SettingsLayout.groups("", for: .phone).isEmpty)
    }
}
