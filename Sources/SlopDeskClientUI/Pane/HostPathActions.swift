// HostPathActions — the CLIENT actuator behind the host open / reveal path RPC. A detected PATH lives on
// the HOST Mac, so ⌘click "Open" / ⌘⇧click "Reveal in Finder" (and the
// right-click items, Jump-To, and Hint-to-open/reveal) must round-trip to the host — not the client. The
// renderer / overlays resolve ``LinkActionPolicy`` to ``LinkAction/openHost(_:)`` / ``LinkAction/revealHost(_:)``
// and fire the model's `onRequestOpenHostPath` / `onRequestRevealHostPath` closures; THIS is where those
// closures get wired to the pane's ``MetadataClient`` (``MetadataClient/openPath(_:)`` = verb 9 /
// ``MetadataClient/revealPath(_:)`` = verb 10).
//
// Extracted out of ``TerminalLeafView`` so the wiring is a pure, headless-testable seam (the leaf is a SwiftUI
// struct; this enum is not). The leaf wires it in `wirePaneCallbacks` and clears it in `clearPaneCallbacks`,
// exactly like the find / hint / navigator callbacks.

import Foundation
import SlopDeskWorkspaceCore

/// The client-side actuator for the host path-action verbs. All members `@MainActor` (the
/// view-model layer's isolation); `MetadataClient` is `@MainActor`.
@MainActor
enum HostPathActions {
    /// Which host path action fired — used by the result callback to phrase the right failure message.
    enum Action {
        case open
        case reveal
    }

    /// Perform `action` on the resolved ABSOLUTE host `path` through `client`, returning whether the HOST
    /// reported success. `false` when there is no live client (disconnected) OR the host replied `.notFound`
    /// (the path is gone) / `.error` (open failed) / dropped the reply (the client's 5 s timeout → `false`).
    /// Never throws — the UI must not hang or crash on a hostile/missing reply.
    static func perform(_ action: Action, path: String, client: MetadataClient?) async -> Bool {
        guard let client else { return false }
        switch action {
        case .open: return await client.openPath(path)
        case .reveal: return await client.revealPath(path)
        }
    }

    /// Wire the pane model's host open/reveal path callbacks to the pane's metadata client. The synchronous
    /// model closure (fired by the renderer / Jump-To / Hint actuator) launches a `@MainActor` task that
    /// performs the async RPC and reports the result via `onResult` (so a `.notFound`/`.error`/timeout can be
    /// surfaced to the user rather than swallowed). `client` is a provider so it always reads the pane's
    /// CURRENT live client (the façade is replaced on each reconnect); pass it capturing the live session
    /// weakly so the model→leaf closure never forms a retain cycle.
    static func wire(
        model: TerminalViewModel,
        client: @escaping @MainActor () -> MetadataClient?,
        onResult: @escaping @MainActor (_ action: Action, _ path: String, _ ok: Bool) -> Void = { _, _, _ in },
    ) {
        model.onRequestOpenHostPath = { path in
            Task { @MainActor in
                let ok = await perform(.open, path: path, client: client())
                onResult(.open, path, ok)
            }
        }
        model.onRequestRevealHostPath = { path in
            Task { @MainActor in
                let ok = await perform(.reveal, path: path, client: client())
                onResult(.reveal, path, ok)
            }
        }
    }

    /// Nil the host path callbacks so the durable terminal model stops referencing a torn-down leaf.
    static func clear(model: TerminalViewModel) {
        model.onRequestOpenHostPath = nil
        model.onRequestRevealHostPath = nil
    }
}
