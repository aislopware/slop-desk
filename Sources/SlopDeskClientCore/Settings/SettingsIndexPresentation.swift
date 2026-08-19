// SettingsIndexPresentation — the All-Settings index's words, and which control a row gets.
//
// docs/56 stage D, increment 49. The searchable index of every client key is `Platform::Both`, so both
// halves draw it — an `NSTableView`-shaped column on the Mac, a `Form` of `Section`s on the phone. What is
// NOT per-half is anything the reader reads: the header, the two reset buttons and their confirmations,
// the "· Default: …" line, and — the expensive one — WHICH CONTROL each of the ~50 inline-editable keys
// gets and what its choices are called.
//
// ## The fold, and why it is this small
//
// A renderer already knows the SHAPE of a key's storage: it holds the binding. `MacSettingsBindings`
// resolves a key to a flag / token / number / text, and the SwiftUI half's `@Default` declarations say the
// same thing in the type system. So the shared answer is not "switch or menu or stepper" — each half
// derives that from the storage it owns — it is the three things storage cannot say: which OPTION GROUP a
// token picks from, which LADDER a number steps along, and which key the index shows read-only.
//
// That distinction matters because the alternative was measured, and it had already decayed.
// `AllSettingsListView` spelled thirteen option lists inline as `Text("…").tag(…)` children — and four of
// them had drifted from `slopdesk_workspace::settings_catalog`, which has held the same lists all along:
// "Context Menu" against the catalog's "Context menu", "Copy or Paste" against "Copy or paste", "Home"
// against "Home Directory", and an On-Launch pair spelled a THIRD way again in
// `FirstLaunchStepPresentation`. Naming the GROUP is what makes a fourth spelling impossible to type.
//
// ## What stays with each half
//
// The binding (`@Default` is a property wrapper and cannot cross), the widget, and the hue. Nothing here
// reads a framework or a design token — `SlopDeskSlate` depends on THIS target, so an ink cannot descend
// without becoming a cycle (docs/56 increment 47).

import Foundation
import SlopDeskVideoProtocol // VideoPreferences — the sidecar fields a jump row reads through their defaults
import SlopDeskWorkspaceCore

/// The All-Settings index: its wording, its option-group table, and the readout a ✎ row shows.
package enum SettingsIndexPresentation {
    // MARK: The words

    /// The section header, set in caps by whichever half draws it.
    package static let header = "ALL SETTINGS"

    package static let searchPlaceholder = "Search"

    package static let resetAllTitle = "Reset All Settings"

    package static let resetAdvancedTitle = "Reset Advanced Only"

    /// The full reset's confirmation. It promises EVERY setting, which is why the action behind it must be
    /// `resetEverySetting(deviceLocal:)` and not `resetAll()` — the latter cannot reach `device-prefs.json`
    /// (`AllSettingsCatalog.deviceLocalKeys`), and a promise the button cannot keep is the bug this wording
    /// exists to pin.
    package static let resetAllPrompt = "Reset All Settings?"

    package static let resetAllMessage =
        "This restores every setting to its default — font, keybindings, and all expert "
            + "keys. This cannot be undone."

    /// The destructive button's own verb — shorter than the row's title, because the sheet has already
    /// said which reset this is.
    package static let resetAllConfirm = "Reset All"

    package static let resetAdvancedPrompt = "Reset Advanced Settings?"

    package static let resetAdvancedMessage =
        "This restores the advanced keys (video, agent, and raw overrides) to their defaults, "
            + "leaving your font and keybinding choices intact. This cannot be undone."

    package static let resetAdvancedConfirm = "Reset Advanced"

    package static let cancelTitle = "Cancel"

    /// What an empty result set says. The query is quoted with typographic marks because it is being shown
    /// back to the reader, not echoed as a token.
    package static func noMatches(_ query: String) -> String { "No settings match “\(query)”." }

    /// The gray line under a row's key: what the setting does, then what it is when untouched.
    package static func detail(_ entry: AllSettingsCatalog.SettingEntry) -> String {
        "\(entry.description) · Default: \(entry.defaultText)"
    }

    // MARK: Which choices a row offers

    /// The option group a TOKEN-backed index row picks from, or `nil` for a key whose storage is not a
    /// token — which is every flag, every number and the one read-only row.
    ///
    /// Every group here is `slopdesk_workspace::settings_catalog`'s. A key that wants a list this table
    /// does not hold wants a list in the catalog, not a `Text(…).tag(…)` typed at the control.
    package static func optionGroup(_ key: String) -> SettingsCatalog.Group? {
        switch key {
        case SettingsKey.onLaunchKey: .onLaunch
        case SettingsKey.newTabPositionKey: .newTabPosition
        case SettingsKey.closeConfirmTabKey: .closeConfirmationTab
        case SettingsKey.closeConfirmWindowKey: .closeConfirmation
        case SettingsKey.notifyWhileForegroundKey: .notifyWhileForeground
        case SettingsKey.rightClickActionKey: .rightClickAction
        case SettingsKey.optionAsAltKey: .optionAsAlt
        case SettingsKey.clipboardReadKey,
             SettingsKey.clipboardWriteKey: .clipboardAccess
        case SettingsKey.linkCmdClickKey: .linkCmdClick
        case SettingsKey.linkCmdShiftClickKey: .linkCmdShiftClick
        case SettingsKey.autoDetectLinkSchemesKey: .autoDetectLinkSchemes
        case SettingsKey.workingDirectoryNewWindowKey,
             SettingsKey.workingDirectoryNewTabKey,
             SettingsKey.workingDirectoryNewSplitKey: .workingDirectory
        default: nil
        }
    }

    /// The token a stored value SELECTS, for the keys whose storage admits values their option group does
    /// not offer.
    ///
    /// Three keys, and they are all the same one: the working-directory settings persist a
    /// `WorkingDirectoryPolicy.rawConfig`, which may be a literal PATH set from the config file or from the
    /// raw editor, while the catalog offers two policies. `WORKING_DIRECTORY`'s own doc comment in
    /// `settings_catalog.rs` decides what to do about it — "a custom path … reads as `home` here" — and this
    /// is that sentence in Swift, so neither renderer has to draw a blank pop-up over a path.
    ///
    /// Everything else is already a token its group lists and comes back unchanged.
    package static func selectedToken(_ key: String, _ raw: String) -> String {
        switch key {
        case SettingsKey.workingDirectoryNewWindowKey,
             SettingsKey.workingDirectoryNewTabKey,
             SettingsKey.workingDirectoryNewSplitKey:
            (WorkingDirectoryPolicy(rawConfig: raw) == .inherit ? .inherit : WorkingDirectoryPolicy.home)
                .rawConfig
        default: raw
        }
    }

    /// The ladder a NUMBER-backed index row steps along, or `nil` for a key with no scalar behind it.
    ///
    /// One entry today, and it is the whole reason this is a lookup rather than a literal: the multiplier's
    /// range, granularity and `%.2f×` readout are all `Ladder::ScrollMultiplier`'s, and both halves used to
    /// re-type the three of them at the control.
    package static func ladder(_ key: String) -> SettingsCatalog.Ladder? {
        key == SettingsKey.scrollMultiplier ? .scrollMultiplier : nil
    }

    /// Whether the index shows a key as a live READ-ONLY summary rather than an editor.
    ///
    /// One key: the custom link schemes. The full editor is a free-text field on Controls → Link Schemes,
    /// drawn only while the detection mode is Custom, and a second editor here would be a second way to
    /// write a list whose separator rules live at the first one.
    package static func isReadOnly(_ key: String) -> Bool { key == SettingsKey.customLinkSchemes }

    /// The read-only summary itself, so "None" is not spelled at two controls.
    package static func readOnlySummary(_ raw: String) -> String { raw.isEmpty ? "None" : raw }

    // MARK: What a ✎ row reads

    /// The current value of a `.hasDedicatedTab` row, shown beside the ✎ that jumps to the page owning it.
    ///
    /// Read LIVE from the stores rather than printed from `entry.defaultText`, because a jump row that
    /// prints the default is a row that lies the moment anything is set. The `default:` arm is the honest
    /// exception: a key with a dedicated page but no readout here has nothing better to show than what a
    /// fresh install would.
    ///
    /// ⚠️ THE VIDEO FIELDS GO THROUGH THEIR NAMED DEFAULTS, never `default:`. They are OPTIONAL on
    /// `VideoPreferences`, where absent means "whatever the daemon would have picked" — which reads
    /// correctly as the row's default text while nothing is set, and lies the moment something is.
    @preconcurrency
    @MainActor
    package static func dedicatedValue(
        _ entry: AllSettingsCatalog.SettingEntry,
        store: PreferencesStore,
        device: WorkspaceStore?,
    ) -> String {
        switch entry.key {
        case AllSettingsCatalog.RenderKey.fontFamily: store.terminal.fontFamily
        case AllSettingsCatalog.RenderKey.fontSize: "\(Int(store.terminal.fontSize))"
        case AllSettingsCatalog.RenderKey.scrollbackLimit: "\(store.terminal.scrollbackLines)"
        case AllSettingsCatalog.RenderKey.cursorStyle: store.terminal.cursorStyle.displayName
        case AllSettingsCatalog.RenderKey.cursorStyleBlink: store.terminal.cursorBlink.rawValue.capitalized
        case SettingsKey.density:
            (store.appearance.density ?? SettingsCatalog.densityComfortable).capitalized
        // Device-local (docs/45 §7.3), so it is read from the `WorkspaceStore` rather than a typed model.
        case AllSettingsCatalog.followSessionFocusKey: followSessionFocusText(device)
        case AllSettingsCatalog.RenderKey.videoQpSharp:
            "\(store.video.qpSharp ?? VideoPreferences.qpSharpDefault)"
        case AllSettingsCatalog.RenderKey.videoQpCoarse:
            "\(store.video.qpCoarse ?? VideoPreferences.qpCoarseDefault)"
        case AllSettingsCatalog.RenderKey.videoFecM:
            "\(store.video.fecM ?? VideoPreferences.fecMDefault)"
        case AllSettingsCatalog.RenderKey.videoFecK:
            "\(store.video.fecK ?? VideoPreferences.fecKDefault)"
        case AllSettingsCatalog.RenderKey.videoPacer:
            SettingsCatalog.label(.videoPacer, for: (store.video.pacer ?? VideoPreferences.pacerDefault).rawValue)
        case AllSettingsCatalog.RenderKey.videoSharpen:
            SettingsCatalog.Ladder.videoSharpen.readout(store.video.sharpen ?? VideoPreferences.sharpenDefault)
        default: entry.defaultText
        }
    }

    /// Whether this device follows the shared focus, as the index prints it.
    ///
    /// ⚠️ A `nil` store reads as the PLATFORM DEFAULT, never as off: that IS what a fresh device would use,
    /// and it is the only honest answer when nothing is backing the row. `SharedFocusSetting.valueText(_:)`
    /// forwards here so the phone's row and this index cannot disagree about one word.
    @preconcurrency
    @MainActor
    package static func followSessionFocusText(_ device: WorkspaceStore?) -> String {
        let following = device?.devicePreferences.followSessionFocus
            ?? DevicePreferences.platformDefaultFollowSessionFocus
        return following ? "On" : "Off"
    }
}
