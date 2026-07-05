import Foundation
import SlopDeskWorkspaceCore

// E20 WI-5 — `slopdesk jump` path resolution (PURE).
//
// The headless core of the `jump [query]` / `--no-cd` command (see `docs/ui-shell/spec/reference__cli.md`): resolve a
// target directory over the client's frecency database. No I/O, no store, no socket, no SwiftUI — the
// running app's `WorkspaceControlBackend` feeds it the frecency entries + the focused pane's cached
// OSC-7 cwd + the `$HOME` path + the persisted last-jump-source, then applies the result (sends
// `cd <path>` VERBATIM unless `--no-cd`). Unit-tested in isolation (`JumpResolverTests`).
//
// Jump semantics (faithful to `docs/ui-shell/spec/reference__cli.md`):
//   - **With a query** → the most-frecent visited folder whose path CONTAINS the query (case-insensitive
//     substring), ranked by the shared ``FolderFrecency`` scorer. No match → `nil` (the caller errors).
//     A query jump does NOT touch the `$HOME` toggle state.
//   - **No query** → toggles between `$HOME` and the *last jump source*: away from home, jump home and
//     remember the cwd we left as the new source; at home, jump back to that source. With no recorded
//     source yet, fall back to the single most-frecent folder, else stay at `$HOME`.
//   - **`--no-cd`** is a non-committing PREVIEW: it resolves the same path but must NOT advance the
//     home-toggle source (no jump actually happened), so the caller can print the target without
//     perturbing the toggle.

/// PURE resolution of an `slopdesk jump` target over the frecency database. A caseless namespace so it
/// is the single source of truth shared by the live backend and the unit tests.
public enum JumpResolver {
    /// The outcome of a resolution: the resolved `path` to `cd` into, and the `lastJumpSource` the caller
    /// should persist. On a committed jump this is the advanced toggle source; on a `--no-cd` preview it is
    /// the caller's existing source UNCHANGED (so the caller can assign it unconditionally).
    public struct Resolution: Equatable, Sendable {
        /// The resolved directory to `cd` into (or print under `--no-cd`).
        public let path: String
        /// The home-toggle source the caller should persist (unchanged on a `--no-cd` preview).
        public let lastJumpSource: String?

        public init(path: String, lastJumpSource: String?) {
            self.path = path
            self.lastJumpSource = lastJumpSource
        }
    }

    /// Resolve the jump target.
    ///
    /// - Parameters:
    ///   - query: the optional frecency query (a substring of a visited path). `nil`/blank → the home toggle.
    ///   - entries: the frecency database (ranked internally by ``FolderFrecency/ranked(entries:now:limit:)``).
    ///   - now: the clock used to score recency (injected for deterministic tests).
    ///   - homePath: the resolved `$HOME` path — the one fixed pole of the no-query toggle.
    ///   - currentCwd: the focused pane's cached OSC-7 cwd (`nil`/blank when never seen).
    ///   - lastJumpSource: the persisted toggle source (the place a prior committed jump left).
    ///   - changeDirectory: `true` for a real jump (advances the toggle source); `false` for a `--no-cd`
    ///     preview (resolves the path but leaves the toggle source untouched).
    /// - Returns: the resolution, or `nil` when a query matched no visited folder.
    public static func resolve(
        query: String?,
        entries: [FolderEntry],
        now: Date,
        homePath: String,
        currentCwd: String?,
        lastJumpSource: String?,
        changeDirectory: Bool,
    ) -> Resolution? {
        // Validate-then-default: an all-whitespace query / cwd / source is treated as absent.
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = nonEmpty(currentCwd)
        let source = nonEmpty(lastJumpSource)

        // Resolve the target path + the source the toggle WOULD record on a committed jump.
        let path: String
        var nextSource = source

        if let q = trimmedQuery, !q.isEmpty {
            // Query jump — frecency-ranked substring match; leaves the home-toggle source untouched.
            let needle = q.lowercased()
            guard let match = FolderFrecency.ranked(entries: entries, now: now)
                .first(where: { $0.path.lowercased().contains(needle) })
            else {
                return nil // no visited folder matched the query
            }
            path = match.path
        } else if let cwd, cwd != homePath {
            // Away from home → go home, remembering where we left as the new source.
            path = homePath
            nextSource = cwd
        } else if let source {
            // At home (or cwd unknown) → return to the recorded source, KEEPING it so the toggle alternates.
            path = source
        } else if let top = FolderFrecency.ranked(entries: entries, now: now).first {
            // No recorded source yet → fall back to the single most-frecent folder.
            path = top.path
        } else {
            // Nothing learned at all → stay at home (last resort).
            path = homePath
        }

        // `--no-cd` resolves + prints the path but does NOT advance the home-toggle source (no jump happened).
        let committedSource = changeDirectory ? nextSource : source
        return Resolution(path: path, lastJumpSource: committedSource)
    }

    /// `s` trimmed of surrounding whitespace/newlines; `nil` when empty/whitespace-only.
    private static func nonEmpty(_ s: String?) -> String? {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
