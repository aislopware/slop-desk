// SettingsBespokePresentation — what the CROSS-PLATFORM bespoke settings surfaces say, and what state
// picks which control on them.
//
// docs/56 stage D, increment 49, and the same lift increment 47 did for the first-launch checklist.
// `Control.bespoke(id)` is the layout table's admission that a group is not a list of settings: an empty
// page that states its own emptiness, a card that writes someone's `~/.claude/settings.json`, a live
// caret preview, a font specimen field. Until the Mac drew those in AppKit there was exactly ONE
// renderer for each, so every word in them and every state→control answer had a single speller BY
// ACCIDENT. There are two renderers now, so the words and the answers moved down here and are
// single-spelled ON PURPOSE. Nothing below reads a framework; nothing above re-decides.
//
// ## What is NOT here, and why
//
// **No ink, no metric, no font.** `SlopDeskSlate` DEPENDS on this target (Package.swift), so a token read
// from here would be a cycle rather than a widening — the residue increment 47 recorded. What descends is
// the ROLE (``SettingsProseInk``) and the SILHOUETTE (an SF-Symbol name); each renderer spells the one
// solved value in its own colour type — `SettingsInk.ok` in SwiftUI, `Slate.Native.StatusInk.ok` in
// AppKit.
//
// **No MAC-ONLY surface.** `os-integration`, `cli-install`, `raw-overrides` and `config-file` are gated to
// `Platform::Mac` by the layout table, so there is no second half to keep in step with and nothing to
// spell once. Their words live with their single AppKit renderer, exactly as `MacOSIntegrationRows`' and
// `MacCLIInstallCard`'s already do.
//
// **No key → BINDING.** `@Default` is a property wrapper whose whole point is that SwiftUI observes the
// read, and a property wrapper cannot be handed to AppKit — docs/56 increment 19 named that as one of the
// two things that stay in each half, and it still is.

import CoreText
import Foundation
import SlopDeskVideoProtocol // TerminalPreferences — the cursor fields the preview reads
import SlopDeskWorkspaceCore // AgentHooksController, PermissionStatus

// MARK: - The one ink vocabulary these surfaces speak

/// What a run of prose on a bespoke settings surface MEANS, so the hue can stay with the drawing.
///
/// A settings surface has one small ladder of emphases and three status angles, and every one of them is
/// already a named token on both halves. Naming the role here and resolving it up there is what lets a
/// caption's weight be decided once without `SlopDeskSlate` having to descend below its own dependency.
package enum SettingsProseInk: Equatable, Sendable {
    /// The thing being read — a row title, a value.
    case primary
    /// The gray second line: a subtitle, an inline explanation.
    case secondary
    /// The faintest legible rung: a footnote, a dead placeholder.
    case tertiary
    /// Success / permitted / installed.
    case ok
    /// A caveat that is not yet a failure.
    case warn
    /// Blocked / denied / failed.
    case err
    /// Neutral information — the host half of a shell prompt, a note glyph.
    case info
}

// MARK: - Editor (reserved)

/// The Editor page's empty state. slopdesk has no file editor, so the page states that in the
/// empty-state voice (MERIDIAN C3: muted symbol, short title, one-line cause) rather than listing dead
/// rows — and the sentence names where the settings a reader came looking for actually live, because "not
/// available" without a forwarding address reads as a broken build.
package enum SettingsEditorEmpty {
    /// The muted glyph, as an SF-Symbol name both halves ask for.
    package static let systemImage = "text.document"

    package static let title = "No File Editor Yet"

    package static let blurb =
        "Soft Wrap, Line Numbers, and Tab Size configure a built-in file editor slopdesk "
            + "does not have. Terminal font and cursor live under Appearance; scrollback "
            + "under Controls."
}

// MARK: - Agents → Claude Code

/// What the Install-Hooks row's trailing slot offers, by the controller's install state.
///
/// One value for the whole slot rather than a title plus an enabled flag plus a spinner flag — the
/// sibling of ``FirstLaunchHooksControl``, which the checklist reads. They are two enums rather than one
/// because the two surfaces genuinely differ: the checklist's finished state is a BADGE with nothing to
/// press, while Settings keeps Uninstall actionable so the integration can be taken back off.
package enum SettingsHooksButtons: Equatable, Sendable {
    /// The entries are on disk either way — a dead "Installed" pill beside a live Uninstall.
    case offerUninstall
    /// The Install button. `enabled` is FALSE while no connected pane backs the card: shown DISABLED
    /// rather than hidden, so the row still says what it is for (docs/DECISIONS, "no dead UI").
    case offerInstall(enabled: Bool)
    /// A write is in flight — a spinner owns the slot.
    case working
}

/// What the Status row reads, by the controller's install state.
///
/// ``inactive`` is kept apart from ``installed`` for the reason ``FirstLaunchHooksBadge`` states: a green
/// check over a dead integration is the one thing this row must never draw.
package enum SettingsHooksStatus: Equatable, Sendable {
    /// Installed AND the host's listener is bound.
    case installed
    /// Written to `settings.json` with the listener unbound: installed, and dead.
    case inactive
    case notInstalled
    case working
    /// Nothing backs the card, or the probe has not answered yet.
    case unbacked

    /// The word, reusing the checklist badge's for the two states both surfaces name.
    package var label: String {
        switch self {
        case .installed: FirstLaunchHooksBadge.installed.label
        case .inactive: FirstLaunchHooksBadge.inactive.label
        case .notInstalled: "Not Installed"
        case .working: "Working…"
        case .unbacked: "—"
        }
    }

    /// The leading silhouette, as an SF-Symbol name — `nil` for the states a word alone says.
    package var systemImage: String? {
        switch self {
        case .installed: FirstLaunchHooksBadge.installed.systemImage
        case .inactive: FirstLaunchHooksBadge.inactive.systemImage
        case .notInstalled,
             .unbacked,
             .working: nil
        }
    }

    /// How the word is set. The hue is the renderer's; which of the seven it is, is not.
    package var ink: SettingsProseInk {
        switch self {
        case .installed: .ok
        case .inactive: .warn
        case .notInstalled,
             .working: .secondary
        case .unbacked: .tertiary
        }
    }
}

/// The Settings → Agents → Claude Code card: its words, and the two folds from one install state.
///
/// ⚠️ THE WORDS ARE NOT ISOLATED; the answers are. Every constant is a `String` a renderer reads wherever
/// it happens to be, so hoisting `@MainActor` to the type would force an actor hop on a label lookup. Only
/// the functions that read ``AgentHooksController`` — which IS `@MainActor` — carry it.
package enum SettingsHooksCard {
    /// The row's bold title. Longer than the checklist's ``FirstLaunchStepPresentation/hooksAgentName``
    /// on purpose: the checklist card is already headed "Install Claude Code hooks", and this row sits in
    /// a group whose header is just "Claude Code".
    package static let rowTitle = "Install Hooks"

    /// What installing does, in the file it does it to.
    package static let rowBlurb =
        "Add slopdesk hooks to ~/.claude/settings.json for real-time state updates"

    /// The Status row's own label.
    package static let statusRowTitle = "Status"

    /// The dead pill beside Uninstall — a state, not an offer.
    package static let installedTitle = "Installed"

    package static let uninstallTitle = "Uninstall"

    /// One word, shared with the checklist, so the two halves cannot end up offering "Install" and
    /// "Install Hooks" for the same press.
    package static let installTitle = FirstLaunchStepPresentation.hooksInstallTitle

    /// Shown while nothing backs the card. Shorter than the checklist's note because Settings is already
    /// the "later" the checklist points at.
    package static let connectNote = "Connect a session to manage hooks"

    /// installed-but-INACTIVE. The entries are in `settings.json` but the host daemon's hook listener is
    /// not bound, so every hook exits silently and no live agent state arrives. There is no toggle to
    /// blame any more (the listener binds unconditionally), so this means the bind FAILED or the host
    /// predates it — show the fix, not a green check over a dead integration.
    package static let inactiveNote =
        "Hooks are installed but the host isn't listening — its socket failed to bind, or "
            + "the host daemon is an older build. Restart it, then open new panes."

    /// Install/uninstall write the host file LIVE, but Claude re-reads `settings.json` only on next
    /// launch. An agent-restart caveat, not a host-reconnect sidecar flag — hence a plain caption rather
    /// than the `.reconnect` chip, which would mislead.
    package static let restartCaption = "Hooks take effect after the agent restarts."

    /// The trailing buttons for the Install-Hooks row.
    ///
    /// `.unknown` folds in with `.disconnected` for ``FirstLaunchStepPresentation/hooksControl(_:)``'s
    /// reason: it is the pre-probe state, it resolves within one round trip, and a live Install button
    /// for that beat is a button whose backing is unknown.
    @preconcurrency
    @MainActor
    package static func buttons(_ controller: AgentHooksController?) -> SettingsHooksButtons {
        switch FirstLaunchStepPresentation.hooksState(controller) {
        case .installed,
             .installedInactive: .offerUninstall
        case .notInstalled: .offerInstall(enabled: true)
        case .working: .working
        case .disconnected,
             .unknown: .offerInstall(enabled: false)
        }
    }

    /// What the Status row reads.
    @preconcurrency
    @MainActor
    package static func status(_ controller: AgentHooksController?) -> SettingsHooksStatus {
        switch FirstLaunchStepPresentation.hooksState(controller) {
        case .installed: .installed
        case .installedInactive: .inactive
        case .notInstalled: .notInstalled
        case .working: .working
        case .disconnected,
             .unknown: .unbacked
        }
    }

    /// Whether ``connectNote`` is shown — exactly when the Install button is dead for want of a pane.
    @preconcurrency
    @MainActor
    package static func showsConnectNote(_ controller: AgentHooksController?) -> Bool {
        buttons(controller) == .offerInstall(enabled: false)
    }

    /// Whether ``inactiveNote`` is shown — exactly the one state that earns the warning silhouette.
    @preconcurrency
    @MainActor
    package static func showsInactiveNote(_ controller: AgentHooksController?) -> Bool {
        status(controller) == .inactive
    }
}

// MARK: - Shell → Notification → System Permission

/// The system-permission status row at the top of the Notification group — a settings row that edits no
/// setting, because what it shows is the state of an OS grant no key in the table can carry.
///
/// The DOT itself is decided one floor further down, in ``PermissionStatus/dot(forAuthorization:)``, which
/// is pure and headlessly pinned (`PermissionStatusTests`). What is here is what the row SAYS about it.
package enum SettingsPermissionRow {
    package static let title = "System Permission"

    package static let buttonTitle = "Open System Settings"

    /// The line under the title, per dot. Named here rather than at either picker because the sentence is
    /// the same fact on both platforms even though the button behind it cannot be.
    package static func subtitle(_ dot: PermissionStatus.Dot) -> String {
        switch dot {
        case .green: "Notifications are allowed for slopdesk."
        case .amber: "Notification permission has not been granted yet."
        case .red: "Notifications are blocked — enable them in System Settings."
        }
    }

    /// How the dot is set. The three angles are already `SettingsProseInk`'s; the hue is the renderer's.
    package static func ink(_ dot: PermissionStatus.Dot) -> SettingsProseInk {
        switch dot {
        case .green: .ok
        case .amber: .warn
        case .red: .err
        }
    }

    /// The macOS deep link into the Notifications pane. An AUTHORED string — which pane to open is a
    /// choice — so it is spelled once here.
    ///
    /// There is no iOS twin to name: iOS cannot deep-link to the per-app OS pane at all, so that half
    /// opens the app's own settings through `UIApplication.openSettingsURLString`, which is the system's
    /// constant rather than a decision of ours. See docs/DECISIONS.md.
    package static let macPreferencesURL = "x-apple.systempreferences:com.apple.preference.notifications"
}

// MARK: - Appearance → Cursor

/// One run of the cursor preview's mock prompt: the text, and what it means.
package struct SettingsCursorPromptRun: Equatable, Sendable {
    package let text: String
    package let ink: SettingsProseInk

    package init(_ text: String, _ ink: SettingsProseInk) {
        self.text = text
        self.ink = ink
    }
}

/// The Appearance → Cursor surface: its words, its mock prompt, and the cell the preview caret fills.
package enum SettingsCursorSurface {
    package static let blurb = "Live preview of your cursor color, style, opacity and blink behavior."

    package static let colorLabel = "Cursor color"

    package static let textColorLabel = "Text color under cursor"

    package static let opacityLabel = "Cursor opacity"

    /// The `john@doe-pc$ git commit -m "` mock, up to the caret (`cursor-style.png`'s visual spec):
    /// `john` in green, `@doe-pc` in the muted blue-gray that separates the HOST run from the user, and
    /// the command in the default foreground.
    package static let promptBeforeCaret: [SettingsCursorPromptRun] = [
        SettingsCursorPromptRun("john", .ok),
        SettingsCursorPromptRun("@doe-pc", .info),
        SettingsCursorPromptRun("$ git commit -m \"", .primary),
    ]

    /// What closes the quote after the caret.
    package static let promptAfterCaret: [SettingsCursorPromptRun] = [
        SettingsCursorPromptRun("\"", .primary),
    ]

    /// The approximate monospace cell for the preview font, from the resolved body point size (advance
    /// ≈ 0.62 em, line height ≈ 1.3 em). A PREVIEW-ONLY estimate — the real surface metrics come from
    /// libghostty — but an estimate both halves have to share, or the same caret reads as two silhouettes.
    package static func previewCell(em: Double) -> (width: Double, height: Double) {
        (width: em * 0.62, height: em * 1.3)
    }

    /// Whether the cosmetic preview caret blinks. `.on` and `.default` animate — `.default` defers to DEC
    /// mode 12, whose usual state is blink-on; `.off` holds steady. Preview-only: the real surface honours
    /// mode 12 for `.default` rather than guessing at it.
    package static func previewBlinks(_ blink: TerminalPreferences.CursorBlink) -> Bool { blink != .off }
}

// MARK: - Appearance → Font Family

/// The Font-Family scope tabs (`font-setting.png`): a control whose choice picks which OTHER controls
/// exist, which is why the group is bespoke and no row in the table describes it.
package enum SettingsFontScope: String, CaseIterable, Sendable, Identifiable {
    /// The primary family, and the three faces derived from it.
    case global
    /// The ordered list consulted when the primary lacks a glyph.
    case fallback

    package var id: String { rawValue }

    package var label: String {
        switch self {
        case .global: "Global"
        case .fallback: "Fallback"
        }
    }

    /// The contextual note under the tab row — what this scope actually sets.
    package var note: String {
        switch self {
        case .global: "The terminal's primary family, and the faces derived from it."
        case .fallback:
            "Fonts used, in order, when the primary font lacks a glyph (e.g. CJK or Nerd-Font icons)."
        }
    }
}

/// The Appearance → Font Family surface's words and its two placeholder rules.
package enum SettingsFontSurface {
    /// The label over the pill row of scope tabs.
    package static let scopeHeading = "Settings for"

    /// The primary family field's placeholder — an empty family means "whatever libghostty picks".
    package static let primaryPlaceholder = "Default"

    /// A derived face's placeholder while auto-match is ON: the field is locked and the face is derived,
    /// so "Auto" is the honest reading of an empty value there.
    package static let derivedAutoPlaceholder = "Auto"

    /// The same field with auto-match OFF: nothing is derived, and nothing is set either.
    package static let derivedUnsetPlaceholder = "Unset"

    package static let specimenSearchPlaceholder = "Search fonts"

    package static let specimenEmpty = "No matching fonts on this device."

    package static let fallbackEmpty = "No fallback fonts."

    package static let fallbackAddPlaceholder = "Add a fallback font"

    package static let fallbackAddTitle = "Add"

    package static let fallbackRemoveHint = "Remove fallback font"

    /// The host-installation boundary. The terminal renders on the HOST, so font installation is a host
    /// concern and there is no client "font folder" to open — the specimen list is this device's faces as
    /// a typing convenience, never an authoritative set.
    package static let hostNote =
        "Fonts are installed and rendered on the host. Type any family the host has; the picker lists "
            + "this device's monospaced faces for convenience."

    /// Which placeholder a derived-face field shows, by whether auto-match owns it.
    package static func derivedPlaceholder(locked: Bool) -> String {
        locked ? derivedAutoPlaceholder : derivedUnsetPlaceholder
    }
}

/// The comma-separated `fontFamilyFallback` list, as the editor sees it.
///
/// The field is ONE string because that is what `TerminalPreferences` persists and what the config builder
/// emits as a repeated-`font-family` chain (ghostty has no `font-family-fallback` key). Parsing and
/// re-joining it is a rule — where the separator goes, what an empty entry means, whether a duplicate is
/// added — so it lives here rather than twice in two list editors.
package enum SettingsFontFallbackList {
    /// The families in order, trimmed, with empties dropped.
    package static func entries(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `raw` with `family` appended, or `nil` when there is nothing to add — an empty name, or one the
    /// list already has. A `nil` is what tells a caller to leave the stored string ALONE rather than
    /// rewrite it to an identical value and churn the store's `didSet`.
    package static func adding(_ family: String, to raw: String) -> String? {
        let name = family.trimmingCharacters(in: .whitespaces)
        let list = entries(raw)
        guard !name.isEmpty, !list.contains(name) else { return nil }
        return joined(list + [name])
    }

    /// `raw` with the entry at `index` removed, or `nil` for an index the list does not have.
    package static func removing(at index: Int, from raw: String) -> String? {
        var list = entries(raw)
        guard list.indices.contains(index) else { return nil }
        list.remove(at: index)
        return joined(list)
    }

    /// The stored spelling: comma-space separated, which is what a reader who opens the config file sees.
    package static func joined(_ list: [String]) -> String { list.joined(separator: ", ") }
}

/// This device's monospaced font families — the specimen list both halves offer.
///
/// Here rather than in a view because it is an ANSWER, not a drawing: which faces exist is the same
/// question on either half, and CoreText answers it without AppKit, UIKit or a `@MainActor` hop. Computed
/// ONCE (a `static let` is lazy and thread-safe); the monospace filter falls back to the FULL family list
/// when it resolves nothing, so an unusual font setup gets a populated picker rather than an empty one.
///
/// ⚠️ These are the CLIENT's fonts. The terminal renders on the host, which may have a different set — the
/// list is a convenience for typing and is never enforced (``SettingsFontSurface/hostNote`` says so).
package enum InstalledFontFamilies {
    package static let all: [String] = compute()

    /// The families whose name contains `needle`, case-insensitively. An empty needle is everything, in
    /// order — a search field that has not been typed into is not a filter.
    package static func matching(_ needle: String) -> [String] {
        let query = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { $0.lowercased().contains(query) }
    }

    private static func compute() -> [String] {
        let families = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        let mono = families.filter(isMonospace)
        return (mono.isEmpty ? families : mono).sorted()
    }

    /// Whether a family resolves to a fixed-pitch face — a CoreText symbolic-trait probe.
    private static func isMonospace(_ family: String) -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: family] as CFDictionary,
        )
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        return CTFontGetSymbolicTraits(font).contains(.traitMonoSpace)
    }
}
