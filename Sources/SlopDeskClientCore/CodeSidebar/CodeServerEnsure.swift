// CodeServerEnsure — ONE ensure round for the code panel, and the font-push dedupe that rides it.
//
// It was written twice, byte for byte, in ``SlopDeskMacUI/MacCodePanelSurfaces`` and in the phone's
// then-SwiftUI `CodePanelSurfaces` (now ``SlopDeskPhoneUI/PhonePanelSurfacesViewController``): the
// same guard, the same two RPCs in the same order, the
// same static `lastPushedFontSpec`, and the same two-paragraph justification comment. Nothing in it
// names a view type — it is `(String, WorkspaceStore, PreferencesStore?) async -> ServiceEndpoint?`
// — so by docs/56 §3 it never belonged in a UI target at all. Both halves now pass it to
// `CodeSidebarModel.poll(ensure:)` as the same closure.
//
// TWO STATICS WERE THE REAL DEFECT, not the duplicated lines. `lastPushedFontSpec` is a dedupe key
// against a HOST-GLOBAL settings file, and each shell held its own — which is invisible while only
// one shell runs, and is exactly the fact a reader of either file would have believed was singular.

import SlopDeskProtocol
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore

/// The code panel's ensure round: verb 18, plus the terminal-font seed (verb 20) when it applies.
@MainActor
package enum CodeServerEnsure {
    /// One ensure round: verb 18 through whichever pane carries a live metadata channel (resolved per
    /// call, like the host-info/vitals fetchers — survives pane churn/reconnects). `nil` when no pane
    /// is connected (→ `.offline`, and the loop keeps polling). A round that reaches a host which HAS
    /// code-server also pushes the client's terminal-font spec (verb 20) — the seed has to land before
    /// the workbench reads its settings, so the push rides the starting rounds rather than waiting for
    /// `.ready`. An old host's `.unsupportedVerb` is silently ignored (the editor keeps the seeded
    /// defaults).
    ///
    /// Two things it deliberately does NOT do, both of them ``CodeFontSync/shouldPush(endpoint:spec:lastSent:)``'s
    /// call. It does not push to an `.unavailable` host: the poll keeps running every ~3.6 s while the
    /// panel is open, and patching a settings file for a workbench that will never boot is pure churn.
    /// And it does not re-push a spec identical to the last one it sent — the host no-ops such a write,
    /// but the round trip still occupies the metadata queue behind real work.
    package static func round(
        projectRoot: String, store: WorkspaceStore, preferences: PreferencesStore?,
    ) async -> MetadataCodec.ServiceEndpoint? {
        guard let client = store.firstConnectedMetadataClient else { return nil }
        let endpoint = await client.ensureCodeServer(projectRoot: projectRoot)
        if let terminal = preferences?.terminal {
            let spec = CodeFontSync.spec(terminal: terminal)
            if CodeFontSync.shouldPush(endpoint: endpoint, spec: spec, lastSent: lastPushedFontSpec) {
                lastPushedFontSpec = spec
                await client.syncCodeFont(spec)
            }
        }
        return endpoint
    }

    /// Records a spec a shell pushed OUTSIDE an ensure round — the live Settings edit each half
    /// watches for — so the next round does not re-send what just landed.
    package static func recordPushed(_ spec: MetadataCodec.CodeFontSpec) {
        lastPushedFontSpec = spec
    }

    /// The spec the last push carried — the dedupe key above.
    ///
    /// Static because the poll is restarted per project/reload and the settings file it writes is
    /// host-global anyway; a project switch must not re-push a spec the host already has. ONE static,
    /// not one per shell: the file it dedupes against is the host's, and there is one host.
    package private(set) static var lastPushedFontSpec: MetadataCodec.CodeFontSpec?
}
