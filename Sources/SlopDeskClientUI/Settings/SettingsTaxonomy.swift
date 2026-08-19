// SettingsTaxonomy — which sections exist.
//
// ``SettingsSection`` is a DISPATCH key and nothing else: a routed id the sheet holds and
// ``SettingsSectionContent`` resolves to a body. That resolution lives in `SettingsPages.swift`
// rather than here, because it is the ONLY door to eight `private` page structs — moving it out of
// their file would mean widening all eight to `internal` to keep one caller working.
//
// Nothing a section IS lives here. Its title, its glyph and its place in the order come from
// `slopdesk_workspace::settings_catalog` through ``SettingsCatalog/sections``, so the Mac's navigator
// and the phone's list read one table rather than two. The cases carry no data of their own.
//
// THE MAC DOES NOT USE THIS FILE. `SlopDeskMacUI/Settings` builds every section generically from
// `settings_layout` and names no section at all (`MacSettingsPage`), which is why there is no
// `MacSettingsSection` enum beside it. The dispatch exists on this half because SwiftUI's page
// bodies are types, and a type has to be named somewhere.

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SwiftUI

/// The settings taxonomy as a DISPATCH key: which section's body to build. It is an enum because that
/// is what ``SettingsSectionContent``'s exhaustive `switch` needs — a section maps to a `some View`,
/// which is the one part of a section that cannot leave Swift.
///
/// Everything a section IS — its title, its glyph, its place in the order, whether the compact list
/// drops it — comes from `slopdesk_workspace::settings_catalog` through ``SettingsCatalog/sections``,
/// so the Mac's navigator and the phone's list read one table rather than two. The cases here carry
/// no data of their own; ``ordered`` is the list to render, and `SettingsSectionTaxonomyTests` pins
/// that it covers every case, which is what stops a case added here from being unreachable in both
/// lists (the same exhaustiveness contract every option group holds).
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case shell
    case controls
    case editor
    case agents
    case appearance
    case keybindings
    case advanced

    var id: String { rawValue }

    /// The catalog row behind this case, or `nil` for a case the boundary does not name — which the
    /// taxonomy test is what rules out.
    private var row: SettingsCatalog.Section? { SettingsCatalog.section(rawValue) }

    /// The list row's title.
    var title: String { row?.title ?? "" }

    /// The list row's glyph (SF Symbol name).
    var systemImage: String { row?.systemImage ?? "" }

    /// The whole taxonomy IN THE CATALOG'S ORDER. Declaration order here is not the contract; the
    /// boundary's is, and `SettingsSectionTaxonomyTests` is what pins that every case is reachable.
    /// Every page reaches BOTH halves. There is no per-section platform flag any more: Key Bindings
    /// was the only section the phone dropped, and it dropped it over a recorder the phone has had
    /// since docs/56 increment 30. What still differs by half is the GROUPS inside a page, which the
    /// layout table gates as data.
    static let ordered: [Self] = SettingsCatalog.sections.compactMap { Self(rawValue: $0.id) }
}
#endif
