// SettingsOption — one choice in a settings group, as data.
//
// Split out of `SettingsControls` when the client's presentation logic left the view target
// (docs/56). What a section OFFERS — the values, their labels, their honest captions and their order
// — is answered the same way on a phone as on a Mac; only the control that draws them differs (cards
// on a Mac, a native list row on a phone). Keeping the descriptor here is what lets both halves read
// the one catalog, and what lets `SettingsOptionCatalogTests` pin a section without rendering it.

import Foundation

/// One choice in a ``SettingsOptionCards`` group or a ``SettingsOptionMenuRow``: the value it writes, its
/// label, and an optional one-line caption. Pure data: declaring the options as a LIST (rather than inline
/// `Text(…).tag(…)` children) is what lets a test pin the labels, captions, and order of a section's choices
/// without rendering it (`SettingsOptionCatalogTests`).
///
/// `Sendable` (over a `Sendable` value) because the catalog holds these as top-level `static let` lists: pure,
/// immutable option data, reachable from any isolation without a `@MainActor` hop.
package struct SettingsOption<Value: Hashable & Sendable>: Identifiable, Sendable {
    package let value: Value
    package let label: String
    /// A short qualifier on the label — where a choice needs to be honest about a caveat ("same as End
    /// today", "only if busy"). `nil` for the common case.
    package let caption: String?

    package var id: Value { value }

    package init(_ value: Value, _ label: String, caption: String? = nil) {
        self.value = value
        self.label = label
        self.caption = caption
    }

    /// The one-line form a `.menu` `Picker` shows: the label, with the caveat folded in after an en dash
    /// (a menu item has no second line to hang a caption on, and dropping the caption would drop the
    /// honesty it carries).
    package var menuLabel: String {
        guard let caption, !caption.isEmpty else { return label }
        return "\(label) — \(caption)"
    }
}
