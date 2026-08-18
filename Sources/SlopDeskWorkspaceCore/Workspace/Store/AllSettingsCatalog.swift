import CSlopDeskFFI
import Foundation

// MARK: - AllSettingsCatalog (the near side of every setting, as a ROW)

/// Every client-side configuration key slopdesk understands, together with what each row RENDERS: a
/// monospace `key`, a human `label`, a one-line `description`, the `defaultText`, the `bucket` that
/// says whether it is edited inline or on a dedicated section, and the `keywords` blob the search
/// field also matches.
///
/// None of it is decided here. `slopdesk_workspace::settings_rows` holds the table; this reads it.
///
/// WHY IT LEFT SWIFT, given it was already headless. This file existed for the right reason — a
/// searchable list cannot be built out of view bodies — but the lift only moved half of what was
/// duplicated. The words came in two copies: this catalog held `"Copy on Select"` and its sentence
/// for the searchable list, and the Controls page's own toggle row held the same two strings again,
/// byte for byte, in a different target. Thirty-one labels and fifteen descriptions were like that.
/// A row's label is the same sentence wherever the row appears, so it is one string now.
///
/// THE KEYS STAY SWIFT. They are ``SettingsKey`` constants because they are `Defaults.Key` names,
/// and a `UserDefaults` binding cannot leave Swift; the boundary quotes them the way it quotes any
/// value already on disk. `AllSettingsCatalogTests` is the pin that keeps the two spellings one —
/// every advertised key must be a surfaced ``SettingsKey`` and every surfaced key must have a row —
/// and it stays a Swift test because it needs the Swift namespace to say so.
///
/// GOLDEN-SAFE: metadata only. Nothing here reads or writes a value, touches a wire codec, or looks
/// at the env overlay.
public enum AllSettingsCatalog {
    /// One row in the All Settings list.
    public struct SettingEntry: Equatable, Identifiable, Sendable {
        /// How the row is edited — an expert key with an inline control, or a key whose real control
        /// lives on a dedicated section.
        public enum Bucket: UInt8, Equatable, Sendable {
            /// No richer section control (or a simple flag) — render an INLINE control (toggle /
            /// stepper / picker) bound to the key. Edits apply live, identical to hand-editing the
            /// config.
            ///
            /// NOTE: this is a RENDERING hint ("inline editor vs jump-to-section button"), NOT a
            /// reset scope. Many rows rendered inline ALSO have a dedicated section control and are
            /// therefore preserved by ``PreferencesStore/resetAdvancedOnly()``. Do not conflate the
            /// two — the reset scope lives in ``PreferencesStore``, not in this bucket.
            case advancedOnly = 0
            /// A richer control lives on a dedicated section — render the current value plus a ✎
            /// button that jumps to ``SettingEntry/targetSection``.
            case hasDedicatedTab = 1
        }

        /// The monospace config key shown in the row (a ``SettingsKey`` constant, or a config-style
        /// render-pref name like `font-family` for a typed-model field).
        public let key: String
        /// The human-readable label as the flat INDEX shows it — standalone, and qualified where it
        /// needs to be, because the list has no section header above it to supply the context.
        /// Search-matched.
        public let label: String
        /// The label a settings PAGE shows, where a header already supplies what ``label`` has to
        /// spell out. Equal to ``label`` for most rows; the boundary folds the fallback, so this is
        /// never empty and a renderer never has to know which rows carry an override.
        public let pageLabel: String
        /// A one-line description (search-matched; rendered gray beneath the key).
        public let description: String
        /// The default value rendered as `· Default: …` after the description.
        public let defaultText: String
        /// Whether the row is inline-editable or jumps to a dedicated section.
        public let bucket: Bucket
        /// For ``Bucket/hasDedicatedTab``: the section id to jump to (e.g. `"editor"`). `nil` for
        /// ``Bucket/advancedOnly`` — kept as a String so this headless catalog never imports the
        /// UI's own dispatch enum.
        public let targetSection: String?
        /// Extra free-text the search field matches against (synonyms not in the label/description).
        public let keywords: String

        public var id: String { key }
    }

    /// The config-style name the shared-focus row (``DevicePreferences/followSessionFocus``,
    /// docs/45 §8.2) is filed under. NOT a ``SettingsKey``: the value lives in `device-prefs.json`,
    /// not `UserDefaults`.
    public static let followSessionFocusKey = string { slopdesk_settings_row_key(sharedFocusIndex, $0, $1) } ?? ""

    /// The advertised rows that persist OUTSIDE `UserDefaults` — the DEVICE-LOCAL facts in
    /// `device-prefs.json` (docs/45 §7.3), owned by ``WorkspaceStore``.
    ///
    /// `Defaults.reset(_:)` cannot reach them and no typed model in ``PreferencesStore`` holds them
    /// either, so a Reset All restores them through ``WorkspaceStore/resetDeviceLocalSettings()``.
    /// `AllSettingsCatalogTests` binds the three reset surfaces to the advertised keys through this:
    /// a row belonging to none of them fails there rather than quietly outliving the reset the panel
    /// just promised.
    public static let deviceLocalKeys: Set<String> = [followSessionFocusKey]

    /// The config-file names of the five typed RENDER FIELDS. Not ``SettingsKey`` constants — those
    /// are `Defaults.Key` names, and these five live on ``TerminalPreferences`` instead — but they
    /// are still the name a row is filed under, so a view that wants one of these rows' words asks
    /// for it by constant rather than retyping the name and the label both.
    public enum RenderKey {
        public static let fontFamily = "font-family"
        public static let fontFamilyBold = "font-family-bold"
        public static let fontFamilyItalic = "font-family-italic"
        public static let fontFamilyBoldItalic = "font-family-bold-italic"
        public static let fontFamilyFallback = "font-family-fallback"
        public static let fontAutoMatchWeightStyle = "font-auto-match-weight-style"
        public static let fontSize = "font-size"
        public static let fontLineHeight = "font-line-height"
        public static let fontLigatures = "font-ligatures"
        public static let fontLigaturesAlphabet = "font-ligatures-alphabet"
        public static let fontBold = "font-bold"
        public static let fontItalic = "font-italic"
        public static let fontBlending = "font-blending"
        public static let scrollbackLimit = "scrollback-limit"
        public static let cursorStyle = "cursor-style"
        public static let cursorStyleBlink = "cursor-style-blink"
        public static let agentPreventSleep = "agent-prevent-sleep"
        public static let agentResumeOnRecovery = "agent-resume-on-recovery"
    }

    /// The advertised rows ``PreferencesStore/resetAll()`` restores WITHOUT a global `Defaults.Key`:
    /// the typed RENDER FIELDS, which come back with the model they name a field of, and
    /// `appearance.density`, which is cleared by name from the store's own injected suite. Neither
    /// can appear in a reset key set, so this is what tells "restored another way" apart from
    /// "restored by nobody".
    public static let modelBackedKeys: Set<String> = [
        RenderKey.fontFamily, RenderKey.fontSize, RenderKey.scrollbackLimit,
        RenderKey.cursorStyle, RenderKey.cursorStyleBlink,
        RenderKey.fontFamilyBold, RenderKey.fontFamilyItalic, RenderKey.fontFamilyBoldItalic,
        RenderKey.fontFamilyFallback, RenderKey.fontAutoMatchWeightStyle, RenderKey.fontLineHeight,
        RenderKey.fontLigatures, RenderKey.fontLigaturesAlphabet,
        RenderKey.fontBold, RenderKey.fontItalic, RenderKey.fontBlending,
        RenderKey.agentPreventSleep, RenderKey.agentResumeOnRecovery,
        SettingsKey.density,
    ]

    /// Every client-side configuration key, in the reading order the list renders.
    public static let entries: [SettingEntry] = (0..<slopdesk_settings_row_count()).map(entry(at:))

    /// The `.advancedOnly` keys the list renders with a real INLINE editor — the contract
    /// `AllSettingsListView`'s `inlineControl(for:)` switch must cover. A key here with no case falls
    /// to that switch's default arm, which is a dead value label with no control;
    /// `AllSettingsCatalogTests.testEveryAdvancedOnlyRowHasInlineControl` pins the coverage.
    public static let inlineEditableKeys: Set<String> = Set(
        (0..<slopdesk_settings_row_count())
            .filter { slopdesk_settings_row_is_inline_editable($0) }
            .compactMap { index in string { slopdesk_settings_row_key(index, $0, $1) } },
    )

    /// Filter the catalog by a search query — a case-insensitive SUBSTRING match against the key,
    /// label, description and keywords, not the fuzzy ranking every other search field uses. This
    /// list is read by someone who already knows the name of the knob they want, so `cursor` must
    /// narrow to the cursor rows rather than order all of them by how cursor-ish they are. An empty
    /// query returns everything in order; a no-match query returns `[]`.
    public static func filter(_ query: String) -> [SettingEntry] {
        matchedPositions(query).map(entry(at:))
    }

    // MARK: The crossing

    /// One row, read field by field.
    private static func entry(at index: Int) -> SettingEntry {
        SettingEntry(
            key: string { slopdesk_settings_row_key(index, $0, $1) } ?? "",
            label: string { slopdesk_settings_row_label(index, $0, $1) } ?? "",
            pageLabel: string { slopdesk_settings_row_page_label(index, $0, $1) } ?? "",
            description: string { slopdesk_settings_row_description(index, $0, $1) } ?? "",
            defaultText: string { slopdesk_settings_row_default_text(index, $0, $1) } ?? "",
            bucket: SettingEntry.Bucket(rawValue: slopdesk_settings_row_bucket(index)) ?? .advancedOnly,
            targetSection: string { slopdesk_settings_row_target_section(index, $0, $1) },
            keywords: string { slopdesk_settings_row_keywords(index, $0, $1) } ?? "",
        )
    }

    /// The positions a query matched, retrying at the size the door named.
    private static func matchedPositions(_ query: String) -> [Int] {
        var query = query
        return query.withUTF8 { needle -> [Int] in
            var out = [Int](repeating: 0, count: slopdesk_settings_row_count())
            let found = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_settings_row_matches(needle.baseAddress, needle.count, buffer.baseAddress, buffer.count)
            }
            guard found > 0 else { return [] }
            guard found <= out.count else {
                // The whole catalog is the widest possible answer, so this cannot happen — but the
                // protocol says ask again rather than read a buffer the door refused to fill.
                out = [Int](repeating: 0, count: found)
                let retried = out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_settings_row_matches(needle.baseAddress, needle.count, buffer.baseAddress, buffer.count)
                }
                return retried <= out.count ? Array(out.prefix(retried)) : []
            }
            return Array(out.prefix(found))
        }
    }

    /// Where the shared-focus row sits, resolved once by the key the boundary itself spells.
    private static let sharedFocusIndex: Int = {
        var key = "follow-session-focus"
        let index = key.withUTF8 { slopdesk_settings_row_index($0.baseAddress, $0.count) }
        return index == SLOPDESK_SETTINGS_ROW_NONE ? 0 : index
    }()

    /// Reads one delivered string, retrying at the size the door named. `nil` for a zero length,
    /// which every door uses for "there is nothing here" — which for `targetSection` is the honest
    /// answer for a row edited in place.
    private static func string(_ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String? {
        var out = [UInt8](repeating: 0, count: inlineCapacity)
        var written = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
        guard written > 0 else { return nil }
        if written > out.count {
            out = [UInt8](repeating: 0, count: written)
            written = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
            guard written > 0, written <= out.count else { return nil }
        }
        return String(bytes: out.prefix(written), encoding: .utf8)
    }

    /// Long enough for every label, key and default; a description or a keyword blob overflows it and
    /// makes the door report its size so the reader asks again.
    private static let inlineCapacity = 96
}
