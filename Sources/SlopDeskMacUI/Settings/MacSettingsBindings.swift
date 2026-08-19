// MacSettingsBindings — a setting KEY to the value behind it, for the Mac's renderer.
//
// docs/56 increment 19 named this as one of exactly two things that stay in each half: "a row
// carries a KEY but not a BINDING — `@Default(.onLaunch)` is a Swift property wrapper over
// `UserDefaults` — so key → binding is a `switch` in each half". This is the Mac's switch. It is
// the whole of what this renderer knows that the table does not, and it knows nothing about widgets:
// a key resolves to a FLAG, a TOKEN, a NUMBER or TEXT, and which control draws it is
// `settings_layout`'s answer, arriving separately.
//
// WHY IT IS NOT SHARED, since one table for both halves is this port's whole thesis elsewhere. A
// shared accessor would have to be closures over `Defaults[...]`, and a closure read is invisible to
// SwiftUI's dependency tracking — the phone's page would stop redrawing when a value changed under
// it. `@Default` is a property wrapper precisely because that observation is the point, and a
// property wrapper cannot be handed to AppKit. The DUPLICATION here is therefore of the storage
// mapping only; every word, every option list, every group and every platform gate is still read
// from the one table, which is where drift actually hurt.
//
// THE TERMINAL REFRESH is a property of the KEY, not of the page. The SwiftUI half spells it as a
// per-page `store.refreshing(_:)` seam wrapping "every toggle on the Controls page"; here it is
// `refreshesTerminal`, listed against the keys that are libghostty config. Same set, said once.

import AppKit
import Defaults
import SlopDeskClientCore
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore

/// What is behind a key, in the four shapes a control can drive.
///
/// A token is the value the store PERSISTS — the same string the option catalog carries — so a menu
/// or a card row never learns what Swift type it is choosing between.
enum MacSettingAccess {
    case flag(get: () -> Bool, set: (Bool) -> Void)
    case token(get: () -> String, set: (String) -> Void)
    case number(get: () -> Double, set: (Double) -> Void)
    case text(get: () -> String, set: (String) -> Void)
}

/// Resolves keys to values for one Settings window.
@MainActor
struct MacSettingsBindings {
    let store: PreferencesStore
    let workspace: WorkspaceStore?

    /// The keys that are libghostty CONFIG rather than client chrome: writing one must also re-apply
    /// the live terminal config, which is what `PreferencesStore.refreshing(_:)` does for the phone.
    private static let refreshesTerminal: Set<String> = [
        SettingsKey.shiftArrowSelect, SettingsKey.clearSelectionOnTyping,
        SettingsKey.clearSelectionOnCopy, SettingsKey.copyOnSelect,
        SettingsKey.trimTrailingSpacesOnCopy, SettingsKey.pasteProtection,
        SettingsKey.pasteBracketedSafe, SettingsKey.focusFollowsMouse,
        SettingsKey.mouseHideWhileTyping, SettingsKey.clickToMove, SettingsKey.allowMouseCapture,
        SettingsKey.undoAtPrompt, SettingsKey.autoSecureInput, SettingsKey.secureInputIndicator,
        SettingsKey.allowShiftClickKey, SettingsKey.rightClickActionKey, SettingsKey.optionAsAltKey,
        SettingsKey.scrollMultiplier, SettingsKey.clipboardShellControlled,
        SettingsKey.clipboardReadKey, SettingsKey.clipboardWriteKey,
    ]

    /// What is behind `key`, or `nil` for one this renderer has no storage for — which is a row that
    /// draws nothing rather than a row that draws a dead control.
    func access(_ key: String) -> MacSettingAccess? {
        if let flag = flagAccess(key) { return flag }
        if let token = tokenAccess(key) { return token }
        if let number = numberAccess(key) { return number }
        if key == SettingsKey.customLinkSchemes {
            return .text(
                get: { Defaults[.customLinkSchemes].joined(separator: ", ") },
                set: { raw in
                    Defaults[.customLinkSchemes] = raw
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                },
            )
        }
        return nil
    }

    /// Whether this row's value can be edited at all. Only the device-local shared-focus row can be
    /// unbacked — with no `WorkspaceStore` there is no `device-prefs.json` to write.
    func isEditable(_ key: String) -> Bool {
        key == AllSettingsCatalog.followSessionFocusKey ? workspace != nil : true
    }

    /// The multiplier a `custom` line-height pick starts from: whatever is already set, so switching
    /// away from Custom and back restores what was chosen rather than snapping to a constant.
    var lineHeightSeed: Double {
        if case let .custom(value) = store.terminal.lineHeight { return value }
        return 1.2
    }

    /// The custom multiplier itself, which is not a row of its own — it is what picking `custom`
    /// opens, so it is conditioned on another setting's VALUE and belongs to the renderer.
    func lineHeightMultiplier() -> MacSettingAccess {
        .number(
            get: { lineHeightSeed },
            set: { store.terminal.lineHeight = .custom($0) },
        )
    }

    // MARK: Flags

    private func flagAccess(_ key: String) -> MacSettingAccess? {
        switch key {
        case SettingsKey.redactSecrets: defaultsFlag(key, .redactSecrets)
        case SettingsKey.oscNotifications: defaultsFlag(key, .oscNotifications)
        case SettingsKey.notifyOnFinish: defaultsFlag(key, .notifyOnFinish)
        case SettingsKey.notifyOnError: defaultsFlag(key, .notifyOnError)
        case SettingsKey.notifyOnWatchFinish: defaultsFlag(key, .notifyOnWatchFinish)
        case SettingsKey.longCommandNotifications: defaultsFlag(key, .longCommandNotifications)
        case SettingsKey.bounceDockIcon: defaultsFlag(key, .bounceDockIcon)
        case SettingsKey.tabBadgeOnCommandFinish: defaultsFlag(key, .tabBadgeOnCommandFinish)
        case SettingsKey.tabBadgeOnCommandFail: defaultsFlag(key, .tabBadgeOnCommandFail)
        case SettingsKey.tabBadgeOnCommandAwaitInput: defaultsFlag(key, .tabBadgeOnCommandAwaitInput)
        case SettingsKey.soundShellControlled: defaultsFlag(key, .soundShellControlled)
        case SettingsKey.soundOnErrorExit: defaultsFlag(key, .soundOnErrorExit)
        case SettingsKey.agentNotifyTaskComplete: defaultsFlag(key, .agentNotifyTaskComplete)
        case SettingsKey.agentNotifyAwaitInput: defaultsFlag(key, .agentNotifyAwaitInput)
        case SettingsKey.agentSoundTaskComplete: defaultsFlag(key, .agentSoundTaskComplete)
        case SettingsKey.agentSoundAwaitInput: defaultsFlag(key, .agentSoundAwaitInput)
        case SettingsKey.agentBadgeWhileProcessing: defaultsFlag(key, .agentBadgeWhileProcessing)
        case SettingsKey.agentBadgeWhenComplete: defaultsFlag(key, .agentBadgeWhenComplete)
        case SettingsKey.agentBadgeWhenAwaitingInput: defaultsFlag(key, .agentBadgeWhenAwaitingInput)
        case SettingsKey.recordClipboardHistory: defaultsFlag(key, .recordClipboardHistory)
        case SettingsKey.shiftArrowSelect: defaultsFlag(key, .shiftArrowSelect)
        case SettingsKey.clearSelectionOnTyping: defaultsFlag(key, .clearSelectionOnTyping)
        case SettingsKey.clearSelectionOnCopy: defaultsFlag(key, .clearSelectionOnCopy)
        case SettingsKey.copyOnSelect: defaultsFlag(key, .copyOnSelect)
        case SettingsKey.trimTrailingSpacesOnCopy: defaultsFlag(key, .trimTrailingSpacesOnCopy)
        case SettingsKey.pasteProtection: defaultsFlag(key, .pasteProtection)
        case SettingsKey.pasteBracketedSafe: defaultsFlag(key, .pasteBracketedSafe)
        case SettingsKey.focusFollowsMouse: defaultsFlag(key, .focusFollowsMouse)
        case SettingsKey.mouseHideWhileTyping: defaultsFlag(key, .mouseHideWhileTyping)
        case SettingsKey.clickToMove: defaultsFlag(key, .clickToMove)
        case SettingsKey.allowMouseCapture: defaultsFlag(key, .allowMouseCapture)
        case SettingsKey.undoAtPrompt: defaultsFlag(key, .undoAtPrompt)
        case SettingsKey.autoSecureInput: defaultsFlag(key, .autoSecureInput)
        case SettingsKey.secureInputIndicator: defaultsFlag(key, .secureInputIndicator)
        case SettingsKey.linkDetection: defaultsFlag(key, .linkDetection)
        case SettingsKey.paneSwitcherPreview: defaultsFlag(key, .paneSwitcherPreview)
        case SettingsKey.satelliteBackgroundPointerKey: defaultsFlag(key, .satelliteBackgroundPointer)
        case SettingsKey.dockIconAnimateProgress: defaultsFlag(key, .dockIconAnimateProgress)
        case SettingsKey.dockIconErrorBadge: defaultsFlag(key, .dockIconErrorBadge)
        case SettingsKey.titleShellControlled: defaultsFlag(key, .titleShellControlled)
        case SettingsKey.clipboardShellControlled: defaultsFlag(key, .clipboardShellControlled)
        // A four-way leaf enum surfaced as the ON/OFF switch the spec asks for: ON ⇒ ⇧ extends the
        // selection, OFF ⇒ ⇧ is forwarded. Read through `extendsSelection` so a value left by the
        // removed four-way picker still reads sanely.
        case SettingsKey.allowShiftClickKey:
            flag(
                key,
                get: { Defaults[.allowShiftClick].extendsSelection },
                set: { Defaults[.allowShiftClick] = $0 ? .enabled : .disabled },
            )
        // The two HOST flags ride the `video-prefs.json` sidecar, where absent means "the daemon
        // decides" — and it decides differently per flag, which is why the fallback is named on
        // `AgentPreferences` rather than spelled as `?? false` at the control.
        case AllSettingsCatalog.RenderKey.agentPreventSleep:
            flag(
                key,
                get: { store.agent.preventSleep ?? AgentPreferences.preventSleepDefault },
                set: { store.agent.preventSleep = $0 },
            )
        case AllSettingsCatalog.RenderKey.agentResumeOnRecovery:
            flag(
                key,
                get: { store.agent.resumeOnRecovery ?? AgentPreferences.resumeOnRecoveryDefault },
                set: { store.agent.resumeOnRecovery = $0 },
            )
        case AllSettingsCatalog.RenderKey.fontLigaturesAlphabet:
            flag(
                key,
                get: { store.terminal.fontLigaturesAlphabet },
                set: { store.terminal.fontLigaturesAlphabet = $0 },
            )
        // Device-local (`device-prefs.json`, docs/45 §7.3), and writes go through the store's one
        // edit path so the "resuming follow drops the device-local overlay" rule cannot be routed
        // around. With no store the write is inert and the row is drawn disabled.
        case AllSettingsCatalog.followSessionFocusKey:
            flag(
                key,
                get: {
                    workspace?.devicePreferences.followSessionFocus
                        ?? DevicePreferences.platformDefaultFollowSessionFocus
                },
                set: { [workspace] in workspace?.setFollowSessionFocus($0) },
            )
        default: nil
        }
    }

    // MARK: Tokens

    private func tokenAccess(_ key: String) -> MacSettingAccess? {
        switch key {
        case SettingsKey.onLaunchKey: defaultsToken(key, .onLaunch)
        case SettingsKey.closeConfirmTabKey: defaultsToken(key, .closeConfirmTab)
        case SettingsKey.closeConfirmWindowKey: defaultsToken(key, .closeConfirmWindow)
        case SettingsKey.notifyWhileForegroundKey: defaultsToken(key, .notifyWhileForeground)
        case SettingsKey.workingDirectoryNewWindowKey: defaultsRawToken(key, .workingDirectoryNewWindow)
        case SettingsKey.workingDirectoryNewTabKey: defaultsRawToken(key, .workingDirectoryNewTab)
        case SettingsKey.workingDirectoryNewSplitKey: defaultsRawToken(key, .workingDirectoryNewSplit)
        case SettingsKey.rightClickActionKey: defaultsToken(key, .rightClickAction)
        case SettingsKey.optionAsAltKey: defaultsToken(key, .optionAsAlt)
        case SettingsKey.linkCmdClickKey: defaultsToken(key, .linkCmdClick)
        case SettingsKey.linkCmdShiftClickKey: defaultsToken(key, .linkCmdShiftClick)
        case SettingsKey.autoDetectLinkSchemesKey: defaultsToken(key, .autoDetectLinkSchemes)
        case SettingsKey.newTabPositionKey: defaultsToken(key, .newTabPosition)
        case SettingsKey.autoHideTabsPanelKey: defaultsToken(key, .autoHideTabsPanel)
        case SettingsKey.windowSizeKey: defaultsToken(key, .windowSize)
        case SettingsKey.desktopWindowPresentationKey: defaultsToken(key, .desktopWindowPresentation)
        case SettingsKey.clipboardReadKey: defaultsToken(key, .clipboardRead)
        case SettingsKey.clipboardWriteKey: defaultsToken(key, .clipboardWrite)
        // The one group the store persists as a BARE string, cleared by name on a reset rather than
        // reset through a typed key — hence the catalog's own token for the absent case.
        case SettingsKey.density:
            token(
                key,
                get: { store.appearance.density ?? SettingsCatalog.densityComfortable },
                set: { store.appearance.density = $0 },
            )
        // Unset presents on arrival, so the menu offers the two REAL modes and reads the absent
        // state as the one it already behaves as — a third "Default" item would be a second way to
        // pick `arrival` with nothing on screen telling the two apart.
        case AllSettingsCatalog.RenderKey.videoPacer:
            token(
                key,
                get: { (store.video.pacer ?? VideoPreferences.pacerDefault).rawValue },
                set: { raw in
                    guard let pacer = VideoPreferences.Pacer(rawValue: raw) else { return }
                    store.video.pacer = pacer
                },
            )
        case AllSettingsCatalog.RenderKey.cursorStyle:
            token(
                key,
                get: { store.terminal.cursorStyle.rawValue },
                set: { raw in
                    guard let style = TerminalPreferences.CursorStyle(rawValue: raw) else { return }
                    store.terminal.cursorStyle = style
                },
            )
        case AllSettingsCatalog.RenderKey.cursorStyleBlink:
            token(
                key,
                get: { store.terminal.cursorBlink.rawValue },
                set: { raw in
                    guard let blink = TerminalPreferences.CursorBlink(rawValue: raw) else { return }
                    store.terminal.cursorBlink = blink
                },
            )
        case AllSettingsCatalog.RenderKey.fontLigatures:
            token(
                key,
                get: { store.terminal.fontLigatures.rawValue },
                set: { raw in
                    guard let value = FontLigatures(rawValue: raw) else { return }
                    store.terminal.fontLigatures = value
                },
            )
        case AllSettingsCatalog.RenderKey.fontBold:
            token(
                key,
                get: { store.terminal.fontBold.rawValue },
                set: { raw in
                    guard let value = FontStyleMode(rawValue: raw) else { return }
                    store.terminal.fontBold = value
                },
            )
        case AllSettingsCatalog.RenderKey.fontItalic:
            token(
                key,
                get: { store.terminal.fontItalic.rawValue },
                set: { raw in
                    guard let value = FontStyleMode(rawValue: raw) else { return }
                    store.terminal.fontItalic = value
                },
            )
        case AllSettingsCatalog.RenderKey.fontBlending:
            token(
                key,
                get: { store.terminal.fontBlending.rawValue },
                set: { raw in
                    guard let value = FontBlending(rawValue: raw) else { return }
                    store.terminal.fontBlending = value
                },
            )
        // `LineHeightMode` carries a `Double` on `.custom`, so the token is the CASE and the number
        // belongs to the multiplier control the choice opens.
        case AllSettingsCatalog.RenderKey.fontLineHeight:
            token(
                key,
                get: {
                    switch store.terminal.lineHeight {
                    case .default: "default"
                    case .compact: "compact"
                    case .loose: "loose"
                    case .custom: "custom"
                    }
                },
                set: { raw in
                    switch raw {
                    case "default": store.terminal.lineHeight = .default
                    case "compact": store.terminal.lineHeight = .compact
                    case "loose": store.terminal.lineHeight = .loose
                    case "custom": store.terminal.lineHeight = .custom(lineHeightSeed)
                    default: break
                    }
                },
            )
        default: nil
        }
    }

    // MARK: Numbers

    private func numberAccess(_ key: String) -> MacSettingAccess? {
        switch key {
        case SettingsKey.tabBadgeBusyDelaySeconds: defaultsNumber(key, .tabBadgeBusyDelaySeconds)
        case SettingsKey.scrollMultiplier: defaultsNumber(key, .scrollMultiplier)
        case SettingsKey.windowColsKey: defaultsCount(key, .windowCols)
        case SettingsKey.windowRowsKey: defaultsCount(key, .windowRows)
        case SettingsKey.windowWidthPxKey: defaultsCount(key, .windowWidthPx)
        case SettingsKey.windowHeightPxKey: defaultsCount(key, .windowHeightPx)
        case AllSettingsCatalog.RenderKey.scrollbackLimit:
            number(
                key,
                get: { Double(store.terminal.scrollbackLines) },
                set: { store.terminal.scrollbackLines = Int($0) },
            )
        case AllSettingsCatalog.RenderKey.fontSize:
            number(key, get: { store.terminal.fontSize }, set: { store.terminal.fontSize = $0 })
        // The video fields ride the `video-prefs.json` sidecar, where absent means "whatever the
        // daemon (or, for sharpen, the renderer) would have picked" — read through the named
        // default for the same reason the two agent flags are, and written as a value, so an
        // untouched field stays absent and a set one is explicit.
        case AllSettingsCatalog.RenderKey.videoQpSharp:
            optionalCount(key, \.qpSharp, default: VideoPreferences.qpSharpDefault)
        case AllSettingsCatalog.RenderKey.videoQpCoarse:
            optionalCount(key, \.qpCoarse, default: VideoPreferences.qpCoarseDefault)
        case AllSettingsCatalog.RenderKey.videoFecM:
            optionalCount(key, \.fecM, default: VideoPreferences.fecMDefault)
        case AllSettingsCatalog.RenderKey.videoFecK:
            optionalCount(key, \.fecK, default: VideoPreferences.fecKDefault)
        case AllSettingsCatalog.RenderKey.videoSharpen:
            number(
                key,
                get: { store.video.sharpen ?? VideoPreferences.sharpenDefault },
                set: { store.video.sharpen = $0 },
            )
        default: nil
        }
    }

    /// One optional whole-number `VideoPreferences` field, read through its named unset default.
    private func optionalCount(
        _ key: String, _ field: WritableKeyPath<VideoPreferences, Int?>, default unset: Int,
    ) -> MacSettingAccess {
        number(
            key,
            get: { Double(store.video[keyPath: field] ?? unset) },
            set: { store.video[keyPath: field] = Int($0) },
        )
    }

    // MARK: The four shapes, and the refresh that rides a write

    private func flag(_ key: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> MacSettingAccess {
        .flag(get: get, set: { value in set(value)
            refreshIfNeeded(key)
        })
    }

    private func token(
        _ key: String, get: @escaping () -> String, set: @escaping (String) -> Void,
    ) -> MacSettingAccess {
        .token(get: get, set: { value in set(value)
            refreshIfNeeded(key)
        })
    }

    private func number(
        _ key: String, get: @escaping () -> Double, set: @escaping (Double) -> Void,
    ) -> MacSettingAccess {
        .number(get: get, set: { value in set(value)
            refreshIfNeeded(key)
        })
    }

    private func defaultsFlag(_ key: String, _ defaultsKey: Defaults.Key<Bool>) -> MacSettingAccess {
        flag(key, get: { Defaults[defaultsKey] }, set: { Defaults[defaultsKey] = $0 })
    }

    private func defaultsNumber(_ key: String, _ defaultsKey: Defaults.Key<Double>) -> MacSettingAccess {
        number(key, get: { Defaults[defaultsKey] }, set: { Defaults[defaultsKey] = $0 })
    }

    private func defaultsCount(_ key: String, _ defaultsKey: Defaults.Key<Int>) -> MacSettingAccess {
        number(key, get: { Double(Defaults[defaultsKey]) }, set: { Defaults[defaultsKey] = Int($0) })
    }

    /// A key whose stored type is an enum with a `String` raw value — the common case, and the one the
    /// option catalog's tokens are.
    private func defaultsToken<Value: RawRepresentable & Defaults.Serializable>(
        _ key: String, _ defaultsKey: Defaults.Key<Value>,
    ) -> MacSettingAccess where Value.RawValue == String {
        token(
            key,
            get: { Defaults[defaultsKey].rawValue },
            set: { raw in
                guard let value = Value(rawValue: raw) else { return }
                Defaults[defaultsKey] = value
            },
        )
    }

    /// A key whose stored type IS the token — the three working-directory rows, which persist a bare
    /// string rather than an enum.
    private func defaultsRawToken(_ key: String, _ defaultsKey: Defaults.Key<String>) -> MacSettingAccess {
        token(key, get: { Defaults[defaultsKey] }, set: { Defaults[defaultsKey] = $0 })
    }

    private func refreshIfNeeded(_ key: String) {
        guard Self.refreshesTerminal.contains(key) else { return }
        store.refreshTerminalControls()
    }
}
