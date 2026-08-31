// MARK: - Embedder-side paste pre-check (the reachability fix)

/// What the terminal renderer should do when ⌘V / right-click-Paste / the context-menu Paste is invoked,
/// decided BEFORE the clipboard text is handed to the engine.
///
/// - ``pasteDirect``: hand the paste straight through (`slopdesk_term_surface_encode_paste`) — protection
///   is off, the payload is plainly safe, or a full-screen TUI owns the screen. The engine door applies
///   bracketed-paste framing itself.
/// - ``confirm(_:)``: show ``PasteProtectionSheet`` first, carrying the flagged dangers; the embedder
///   completes the paste with `allow_unsafe` ONLY if the user approves.
public enum PastePrecheckDecision: Equatable, Sendable {
    case pasteDirect
    case confirm(PasteSafetyAnalyzer.PasteDangers)
}

/// The PURE, headless decision behind **Paste Protection** at the RENDERER's paste entry point.
///
/// ## Why this exists (the reachability bug, and why it is now history)
/// The deleted fork's libghostty only invoked its `confirm_read_clipboard_cb` (the site that ran
/// ``PasteSafetyAnalyzer``) when its OWN `input.paste.isSafe` returned false — and `isSafe` flagged
/// ONLY a payload containing `\n` (or a literal bracketed-paste end marker `\x1b[201~`). That gate was
/// **NARROWER** than the four paste dangers this codebase flags (see ``PasteSafetyAnalyzer``): a
/// single-line `sudo rm -rf /`, an ESC-laced control-char paste, or a bare-`\r` paste were all
/// `isSafe == true`, so they reached the terminal SILENTLY — two of the four advertised dangers were
/// effectively suppressed. The embedder could only ever DROP a warning libghostty already tripped,
/// never ADD one.
///
/// The fix — run the danger analyzer at the renderer's paste path BEFORE handing the bytes to the
/// engine, so all four danger classes are reachable regardless of newlines — outlived the fork it fixed:
/// `libghostty-vt` exposes no `isSafe`/`confirm_read_clipboard_cb` callback at all (the FFI boundary is
/// pull-only now), so this client-side pre-check is the ONLY gate paste protection has. This enum is the
/// **testable heart** of that pre-check; the GUI surface (`MacTerminalRendererView` /
/// `PhoneTerminalRendererView`) is the thin actuator that reads the pasteboard, calls
/// ``decide(clipboard:protectionOn:isAlternateScreen:)``, and either pastes directly or shows the sheet.
///
/// It supplies the two program-state booleans `PasteSafetyAnalyzer.shouldWarn` also takes from the LIVE
/// terminal/settings state: `bracketedSafe` is the "Paste Bracketed Safe" setting, and
/// `programAdvertisedBracketed` is the real DECSET `?2004h` state parsed by the client `TerminalModeTracker`.
/// When both hold, the foreground program frames the paste as an inert bracketed block, so the sheet is
/// skipped — matching the `clipboard-paste-bracketed-safe` config gate this pre-check preempts. They
/// default to `false` so a caller that cannot resolve the live state stays conservative (favouring
/// an extra warning over a missed danger).
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
