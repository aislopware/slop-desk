import Foundation

// MARK: - E8 / ES-E8-3: embedder-side paste pre-check (the reachability fix)

/// What the terminal embedder should do when ⌘V / right-click-Paste / the context-menu Paste is invoked,
/// decided BEFORE the clipboard text is handed to libghostty.
///
/// - ``pasteDirect``: hand the paste straight to libghostty (`paste_from_clipboard`) — protection is off,
///   the payload is plainly safe, or a full-screen TUI owns the screen. libghostty applies bracketed-paste
///   framing itself.
/// - ``confirm(_:)``: show ``PasteProtectionSheet`` first, carrying the flagged dangers; the embedder
///   completes the paste with `allow_unsafe` ONLY if the user approves.
public enum PastePrecheckDecision: Equatable, Sendable {
    case pasteDirect
    case confirm(PasteSafetyAnalyzer.PasteDangers)
}

/// The PURE, headless decision behind **Paste Protection** at the EMBEDDER's paste entry point.
///
/// ## Why this exists (the reachability bug — ES-E8-3)
/// libghostty only invokes its `confirm_read_clipboard_cb` (the site that ran ``PasteSafetyAnalyzer``)
/// when its OWN `input.paste.isSafe` returns false — and `isSafe` flags ONLY a payload containing `\n`
/// (or a literal bracketed-paste end marker `\x1b[201~`). That gate is **NARROWER** than the four paste
/// dangers this codebase flags (see ``PasteSafetyAnalyzer``): a single-line `sudo rm -rf /`, an ESC-laced
/// control-char paste, or a bare-`\r` paste are all `isSafe == true`, so they reached the terminal
/// SILENTLY — two of the four advertised dangers were effectively suppressed. The embedder could only
/// ever DROP a warning libghostty already tripped, never ADD one.
///
/// The fix is to run the danger analyzer at the embedder's paste path BEFORE handing the bytes to
/// libghostty, so all four danger classes are reachable regardless of newlines. This enum is the **testable heart** of
/// that pre-check; the GUI surface (`GhosttyTerminalView`, compile-only behind `#if canImport(CGhostty)`)
/// is the thin actuator that reads the pasteboard, calls ``decide(clipboard:protectionOn:isAlternateScreen:)``,
/// and either pastes directly or shows the sheet.
///
/// It supplies the two program-state booleans `PasteSafetyAnalyzer.shouldWarn` also takes from the LIVE
/// terminal/settings state: `bracketedSafe` is the "Paste Bracketed Safe" setting, and
/// `programAdvertisedBracketed` is the real DECSET `?2004h` state parsed by the client `TerminalModeTracker`.
/// When both hold, the foreground program frames the paste as an inert bracketed block, so the sheet is
/// skipped — matching libghostty's own `clipboard-paste-bracketed-safe` gate this pre-check preempts. They
/// default to `false` so a caller that cannot resolve the live state stays conservative (favouring an extra
/// warning over a missed danger).
public enum PastePrecheck {
    /// Decide what an embedder paste should do for `clipboard`.
    ///
    /// - Parameters:
    ///   - clipboard: the pasteboard text the user is about to paste.
    ///   - protectionOn: the live "Paste Protection" toggle
    ///     (``SettingsKey/pasteProtectionEnabled``, default ON).
    ///   - isAlternateScreen: whether a full-screen / foreground program owns the screen (the GUI derives
    ///     this from the OSC-133 shell-activity the host streams). A full-screen TUI receives the paste
    ///     inertly, so the sheet is skipped — matching ``PasteSafetyAnalyzer/shouldWarn(text:protectionOn:bracketedSafe:programAdvertisedBracketed:isAlternateScreen:)``.
    ///   - bracketedSafe: the live "Paste Bracketed Safe" setting
    ///     (``SettingsKey/pasteBracketedSafeEnabled``, default ON).
    ///   - programAdvertisedBracketed: whether the foreground program has bracketed-paste mode
    ///     (DECSET `?2004h`) enabled, from the client ``TerminalModeTracker``.
    /// - Returns: ``PastePrecheckDecision/pasteDirect`` to paste without a dialog, or
    ///   ``PastePrecheckDecision/confirm(_:)`` carrying the flagged dangers to render in the sheet.
    public static func decide(
        clipboard: String,
        protectionOn: Bool,
        isAlternateScreen: Bool,
        bracketedSafe: Bool = false,
        programAdvertisedBracketed: Bool = false,
    ) -> PastePrecheckDecision {
        let warn = PasteSafetyAnalyzer.shouldWarn(
            text: clipboard,
            protectionOn: protectionOn,
            bracketedSafe: bracketedSafe,
            programAdvertisedBracketed: programAdvertisedBracketed,
            isAlternateScreen: isAlternateScreen,
        )
        guard warn else { return .pasteDirect }
        return .confirm(PasteSafetyAnalyzer.analyze(clipboard))
    }
}
