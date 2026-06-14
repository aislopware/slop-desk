/// PANE REBIND (2026-06-12): pure stale-binding resolution for a restored `.remoteGUI` pane.
///
/// WHY: a pane persists the host's CGWindowID, but CGWindowIDs die with the window (host restart,
/// app relaunch) AND macOS recycles the 32-bit ids — after a restart the same number can belong to
/// a DIFFERENT app's window. A stale binding used to stream a dead/black window silently (the
/// host's `helloAck(accepted:false)` produces zero client effects). The endpoint now also persists
/// the owning app's name + the title at pick time, and on the first open the live window list is
/// consulted: the id is KEPT only if it still exists AND still belongs to the same app; otherwise
/// the binding re-resolves by app name with the title as tiebreaker.
///
/// MATCHING (deliberately simple, single-user tool):
///  - keep: saved id present in the list and the app matches (or no app was saved — legacy/manual
///    entry can't be verified, presence is the best signal).
///  - rebind: windows of the SAME app — exact title first; a sole window wins; then title
///    containment either way (editors mutate titles per file: "a.ts — proj" ⊃/⊂ variants); else
///    the list's first window of that app (host z-order — deterministic, and one window per app
///    is the overwhelmingly common case).
///  - unresolved: the app has no windows on the host (quit) — the caller falls back to the picker.
///
/// Pure + headlessly testable (no discovery, no UI).
public enum WindowRebind {
    public enum Resolution: Equatable, Sendable {
        /// The saved binding is still valid — stream it as-is.
        case keep
        /// The saved id is stale; this window is the same app+title lineage — rebind to it.
        case rebind(RemoteWindowSummary)
        /// Nothing of that app remains on the host — show the picker.
        case unresolved
    }

    public static func resolve(
        windowID: UInt32,
        appName: String,
        title: String,
        in windows: [RemoteWindowSummary],
    ) -> Resolution {
        if let current = windows.first(where: { $0.windowID == windowID }),
           appName.isEmpty || current.appName == appName
        {
            return .keep
        }
        // Id stale (or recycled by another app). Without a saved app name there is nothing safe
        // to match on — re-picking is the only honest answer.
        guard !appName.isEmpty else { return .unresolved }
        let candidates = windows.filter { $0.appName == appName }
        guard !candidates.isEmpty else { return .unresolved }
        if !title.isEmpty, let exact = candidates.first(where: { $0.title == title }) {
            return .rebind(exact)
        }
        if candidates.count == 1 { return .rebind(candidates[0]) }
        if !title.isEmpty, let fuzzy = candidates.first(where: {
            !$0.title.isEmpty && ($0.title.contains(title) || title.contains($0.title))
        }) {
            return .rebind(fuzzy)
        }
        return .rebind(candidates[0])
    }
}
