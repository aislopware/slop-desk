// TerminalHintActuator — what a confirmed Hint Mode label DOES, spelled once below the UI (docs/56 §3).
//
// The model resolves a label (macOS key-resolve or iOS tap-on-label) and fires
// ``TerminalViewModel/onHintConfirmed`` with a target + an intent. Everything after that is a DECISION —
// which of the four target kinds is in hand, which intent the user pressed, and therefore which
// ``LinkAction`` (or which custom-template branch) applies — followed by a thin platform dispatch that
// is already spelled once in ``LinkActionActuator``. It used to live as three `private static` members
// of `TerminalLeafView`, where the phone half could see it and the AppKit half could not.
//
// The `{0}` template rule is split from its actuation on purpose. `customAction(template:raw:)` answers
// "what should happen", with no sink, no pasteboard and no `URL` opened — so the one rule that decides
// whether an arbitrary string runs on the CLIENT or on the HOST shell is a value a test can hold.
// `runCustomAction` is the four lines that then do it.
//
// SAFETY note, kept from the leaf: a custom `hint-pattern` action template is an ARBITRARY shell string
// and it runs on the HOST, verbatim down the PTY. The one exception is a `open <url>` whose argument
// parses as a URL WITH a scheme — that opens on the client, because a bare `open` of a URL is the thing
// users actually mean and the host has no browser the user is looking at.

import Foundation
import SlopDeskWorkspaceCore

/// The Hint Mode confirmation path: the pure intent→action mapping plus the thin dispatch behind it.
@MainActor
package enum TerminalHintActuator {
    // MARK: - The decision

    /// Map a hint `intent` on a detected `link` to a ``LinkAction`` through the SAME pure
    /// ``LinkActionPolicy`` the Jump-To (copy) / ⌘⇧click (reveal) paths use — open = best handler,
    /// copy = copy path/URL, reveal = reveal-in-Finder (a no-op for a URL).
    ///
    /// The OPEN intent is an EXPLICIT open (⌘⇧J Hint-to-Open), so it routes through the
    /// config-INDEPENDENT ``LinkActionPolicy/explicitOpenAction`` — NOT the configurable ⌘click
    /// gesture, which would silently copy / no-op under `link-cmd-click = copy/nothing`. The renderer's
    /// mouse ⌘click / ⌘⇧click keeps the gesture path.
    package static func linkAction(for intent: HintIntent, link: DetectedLink) -> LinkAction {
        switch intent {
        case .open: LinkActionPolicy.explicitOpenAction(link: link)
        case .copy: LinkActionPolicy.action(for: .copyPath, link: link)
        case .reveal: LinkActionPolicy.action(for: .revealInFinder, link: link)
        }
    }

    /// What a custom `hint-pattern`'s action template resolves to for the matched text `raw`.
    ///
    /// Three outcomes and no fourth: no template at all copies the text; a known-safe `open <url>` (the
    /// argument parses as a `URL` that actually HAS a scheme) opens on the CLIENT; anything else runs on
    /// the HOST shell. The `{0}` substitution happens first, so a template can place the match anywhere
    /// in its line, including inside the `open` argument.
    package enum CustomAction: Equatable {
        /// No template (or an empty one) — copy the matched text, the safest thing a hint can do.
        case copyRaw
        /// `open <url>` with a real scheme — the CLIENT opens it.
        case openURLClient(String)
        /// Everything else — verbatim down the PTY, with the trailing newline that makes the shell run it.
        case runOnHost(String)
    }

    /// The `{0}`-substitution + `open `-prefix rule, as a value. No sink is touched.
    package static func customAction(template: String?, raw: String) -> CustomAction {
        guard let template, !template.isEmpty else { return .copyRaw }
        let resolved = template.replacingOccurrences(of: "{0}", with: raw)
        if resolved.hasPrefix("open ") {
            let rest = String(resolved.dropFirst("open ".count)).trimmingCharacters(in: .whitespaces)
            // `URL(string:)` accepts almost anything, so the SCHEME is the real test: `open ./notes`
            // is a shell command about a local file and belongs on the host, `open https://…` is not.
            if let url = URL(string: rest), url.scheme != nil {
                return .openURLClient(rest)
            }
        }
        return .runOnHost(resolved)
    }

    // MARK: - The dispatch

    /// Actuate a resolved hint `target` for `intent`.
    ///
    /// A path/URL link routes through the SAME pure ``LinkActionPolicy`` the ⌘click / Jump-To paths use
    /// (no parallel mapping to drift); an IP OPENS (`http://<ip>`) on Hint-to-Open and copies otherwise;
    /// a git-hash copies its text on every intent (no open target for a bare hash — a deliberate gap,
    /// see DECISIONS.md); a custom `hint-pattern` runs its `{0}` action template.
    package static func perform(_ target: HintTarget, intent: HintIntent, model: TerminalViewModel) {
        switch target.kind {
        case let .link(link):
            LinkActionActuator.actuate(linkAction(for: intent, link: link), model: model)
        case .ipAddress:
            // Hint-to-OPEN on a bare IP browses to it as a host. `copy`/`reveal` copy the text — no
            // Finder target for an IP. `http://` (not `https://`): a bare IP almost always serves plain
            // HTTP and a TLS cert won't match a raw address.
            switch intent {
            case .open: ExternalOpen.url("http://" + target.raw)
            case .copy,
                 .reveal: copy(target.raw, model: model)
            }
        case .gitHash:
            // A bare commit hash has NO open target (no repo URL to resolve it against), so every
            // intent copies the text — a deliberate gap in docs/DECISIONS.md rather than faking an open.
            copy(target.raw, model: model)
        case let .custom(actionTemplate):
            switch intent {
            case .copy: copy(target.raw, model: model)
            case .open,
                 .reveal: runCustomAction(template: actionTemplate, raw: target.raw, model: model)
            }
        }
    }

    /// Actuate ``customAction(template:raw:)`` — the only part of the custom-template path that touches
    /// a sink.
    package static func runCustomAction(template: String?, raw: String, model: TerminalViewModel) {
        switch customAction(template: template, raw: raw) {
        case .copyRaw:
            copy(raw, model: model)
        case let .openURLClient(urlString):
            ExternalOpen.url(urlString)
        case let .runOnHost(line):
            model.sendInput(Data((line + "\n").utf8))
        }
    }

    /// Copy through the ONE actuator, so the pane's `COPIED · N` receipt is published exactly where
    /// every other copy publishes it.
    private static func copy(_ text: String, model: TerminalViewModel) {
        LinkActionActuator.actuate(.copyPathClient(text), model: model)
    }
}
