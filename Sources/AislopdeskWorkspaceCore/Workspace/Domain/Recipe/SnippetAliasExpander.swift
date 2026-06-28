import Foundation

// MARK: - SnippetAliasExpander (E16 ES-E16-4 — at-prompt alias auto-expansion)

/// The PURE, headless-tested brain for otty's "typing a snippet alias at the shell prompt expands it" feature
/// (`customization__custom-commands.md` §Text Snippets + `textsnippet-apply.gif`). The spec's Aislopdesk
/// Mapping Notes call this a 1:1 **client-side** interceptor on the terminal input path, "before bytes reach
/// `libghostty` or the PTY write path" — so this type owns the decision and the per-surface key path is a thin
/// actuator (it feeds outbound bytes + prompt marks in, and on a trigger key asks for the expansion to send).
///
/// ## The mirror-of-confidence model (why this is safe to run on the live input path)
///
/// At-prompt expansion is only correct if we know EXACTLY what the user has typed since the prompt began, so we
/// can replace the trailing alias word without corrupting ordinary typing. We keep a best-effort mirror of the
/// in-progress prompt line and a `trusted` bit that says "this mirror provably matches the shell's line":
///
/// - ``notePromptMark()`` (OSC-133;A) establishes a KNOWN-EMPTY, trusted line — the only thing that sets trust.
/// - ``noteSent(_:)`` maintains the mirror from outbound bytes, but ONLY for the exact shapes we can mirror
///   faithfully: a single printable ASCII byte appends; a single DEL/BS pops; **anything else** (CR/LF, a
///   control byte, a multi-byte paste / IME commit, a mouse report, an ESC sequence) drops trust — we refuse to
///   guess. This is the same conservative discipline the glitch-caret predictor uses (`TerminalViewModel`
///   `GlitchCaretMode`): mirror only the unambiguous single-printable-ASCII case, clear on everything else.
/// - ``expansion()`` fires ONLY while trusted AND the injected gates hold (the `snippetAutoExpand` setting is on
///   AND the shell is at an OSC-133;A prompt) AND the trailing word equals a known alias. On a hit it returns
///   the bytes to send INSTEAD of the trigger key — `alias.count` DELs to erase the typed alias, then the
///   resolved snippet body — and drops trust (the cursor may now sit mid-body via `{{cursor}}`, so the mirror no
///   longer matches; the next prompt mark re-establishes a known line before another expansion can fire).
///
/// Default-OFF (`snippetAutoExpand` defaults `false`): with the setting off, ``expansion()`` always returns
/// `nil`, so ordinary typing is untouched unless the user opts in. Foundation-only; `@MainActor` because the
/// surface key paths it serves are already main-actor and it is owned 1:1 by a ``TerminalViewModel``.
@preconcurrency
@MainActor
public final class SnippetAliasExpander {
    /// The bytes to send INSTEAD of the trigger key on a successful expansion, plus how many trailing alias
    /// characters they erase (so the caller / a test can reason about the replacement without re-deriving it).
    public struct Expansion: Equatable, Sendable {
        /// `erasedCharacters` DEL bytes (0x7F) followed by the resolved snippet body (reserved vars +
        /// `<Token>` control bytes + the `{{cursor}}` caret repositioning). Send these to the PTY; swallow the
        /// trigger key.
        public let bytes: [UInt8]
        /// The count of leading DEL bytes — the alias-word length erased before the body is injected.
        public let erasedCharacters: Int

        public init(bytes: [UInt8], erasedCharacters: Int) {
            self.bytes = bytes
            self.erasedCharacters = erasedCharacters
        }
    }

    /// The shell line-editor erase byte (DEL). Matches ``SendKeysParser`` `<bs>`/`<backspace>` and the
    /// `BackspaceSelectionPolicy` actuator: at a shell prompt readline/zle deletes the grapheme before the
    /// cursor on DEL, so `alias.count` DELs remove exactly the just-typed alias word.
    private static let del: UInt8 = 0x7F

    /// The snippets to match an alias against (the live ``WorkspaceStore/snippets``). Read only inside
    /// ``expansion()`` (on a trigger key), never per keystroke.
    private let snippets: () -> [Snippet]

    /// Whether the `snippetAutoExpand` setting is on. Read inside ``expansion()`` so a Settings toggle takes
    /// effect on the very next trigger key.
    private let isEnabled: () -> Bool

    /// Whether the shell is at an OSC-133;A prompt right now (the live ``TerminalViewModel/isAtShellPrompt``) —
    /// a belt-and-suspenders gate on top of `trusted` so expansion can only fire at a genuine prompt.
    private let isAtPrompt: () -> Bool

    /// Resolve a snippet to the bytes to inject, or `[]` to DECLINE (the wiring declines a snippet that still
    /// has unresolved user-prompt `{{placeholders}}` — those need the value-entry sheet only the palette arms).
    /// The live wiring routes this through ``WorkspaceStore/autoExpandBytes(for:)`` (reserved vars + caret).
    private let resolveBytes: (Snippet) -> [UInt8]

    /// The best-effort mirror of the in-progress prompt line (everything typed since the last prompt mark).
    private var line = ""

    /// Whether ``line`` provably matches the shell's prompt line. Only ``notePromptMark()`` sets it; any input
    /// we cannot mirror faithfully (and any expansion) clears it. Expansion never fires while untrusted.
    private var trusted = false

    public init(
        snippets: @escaping () -> [Snippet] = { [] },
        isEnabled: @escaping () -> Bool = { false },
        isAtPrompt: @escaping () -> Bool = { false },
        resolveBytes: @escaping (Snippet) -> [UInt8] = { _ in [] },
    ) {
        self.snippets = snippets
        self.isEnabled = isEnabled
        self.isAtPrompt = isAtPrompt
        self.resolveBytes = resolveBytes
    }

    /// An OSC-133;A prompt mark arrived on the MAIN screen: the shell line is now empty and KNOWN. Resets the
    /// mirror to a trusted empty line — the single event that establishes trust. Wired from the
    /// ``TerminalViewModel`` ingest path (the same `promptStart` edge the prompt-queue idle dispatch reads).
    public func notePromptMark() {
        line = ""
        trusted = true
    }

    /// Drop the mirror to an UNTRUSTED state (focus loss / alt-screen entry / any caller-side uncertainty).
    /// Expansion cannot fire again until the next ``notePromptMark()``.
    public func reset() {
        line = ""
        trusted = false
    }

    /// Maintain the line mirror from bytes the surface is about to send to the PTY. A no-op while untrusted (we
    /// only track a line we can prove). Mirrors ONLY the unambiguous shapes:
    ///   - a single printable ASCII byte (0x20…0x7E) → append the character;
    ///   - a single DEL (0x7F) / BS (0x08) → pop the last grapheme;
    ///   - **everything else** (CR/LF, any other control byte, or a multi-byte chunk = paste / committed IME /
    ///     mouse report / ESC sequence) → drop trust, because we cannot mirror it faithfully and a stale mirror
    ///     must never drive an expansion.
    public func noteSent(_ bytes: [UInt8]) {
        guard trusted else { return }
        if bytes.count == 1, let b = bytes.first {
            switch b {
            case 0x20...0x7E:
                line.unicodeScalars.append(Unicode.Scalar(b))
                return
            case 0x7F,
                 0x08:
                if !line.isEmpty { line.removeLast() }
                return
            default:
                break // CR / LF / other C0 — fall through to drop trust
            }
        }
        // Multi-byte (paste / IME commit / mouse report / ESC sequence) or an un-mirrorable control byte: we
        // cannot keep the mirror faithful, so refuse to expand until the next prompt mark re-establishes it.
        line = ""
        trusted = false
    }

    /// The expansion to send INSTEAD of a word-boundary trigger key (Tab / Space), or `nil` to let the key type
    /// normally. Fires ONLY when every gate holds: the mirror is trusted, the `snippetAutoExpand` setting is on,
    /// the shell is at a prompt, the trailing typed word equals a known alias, and the snippet resolves to a
    /// non-empty body. On a hit it drops trust (the post-expansion cursor may sit mid-body) so a second
    /// expansion cannot fire until the next prompt mark. Pure decision — no I/O; the caller sends `bytes`.
    public func expansion() -> Expansion? {
        guard trusted, isEnabled(), isAtPrompt() else { return nil }
        guard let snippet = SnippetAliasIndex.match(typed: line, snippets: snippets()) else { return nil }
        let body = resolveBytes(snippet)
        guard !body.isEmpty else { return nil }
        let erase = snippet.alias.count
        var bytes = [UInt8](repeating: Self.del, count: erase)
        bytes.append(contentsOf: body)
        // The line was rewritten by the injection (and the caret may now be mid-body): the mirror no longer
        // matches, so untrust until a fresh prompt mark. Never chain two expansions on one line.
        line = ""
        trusted = false
        return Expansion(bytes: bytes, erasedCharacters: erase)
    }
}
