import CSlopDeskFFI
import Foundation
import SlopDeskArena

// `slopdesk jump` path resolution — the Swift face of `rust/slopdesk-workspace`'s `jump`.
//
// The headless core of the `jump [query]` / `--no-cd` command (see `docs/ui-shell/spec/reference__cli.md`):
// resolve a target directory over the client's frecency database. No I/O, no store, no socket, no view —
// the running app's `WorkspaceControlBackend` feeds it the frecency entries + the focused pane's cached
// OSC-7 cwd + the `$HOME` path + the persisted last-jump-source, then applies the result (sends
// `cd <path>` VERBATIM unless `--no-cd`). Unit-tested in isolation (`JumpResolverTests`).
//
// It sits BESIDE ``FolderFrecency`` rather than in `SlopDeskCLICore`, which is where it was written:
// it lends that database to the same crate through the same `lent(_:_:)`, and the only GUI caller
// (`WorkspaceControlBackend.jump`) had to name the whole CLI core to reach it. `slopdesk jump` still
// resolves through it — `SlopDeskCLICore` depends on this target.
//
// Jump semantics (faithful to `docs/ui-shell/spec/reference__cli.md`, and the crate's own doc):
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
    /// An absent query / cwd / source crosses as an EMPTY string, which is what a blank one already trims
    /// to on the far side — so the three optionals need no companion flags.
    ///
    /// - Parameters:
    ///   - query: the optional frecency query (a substring of a visited path). `nil`/blank → the home toggle.
    ///   - entries: the frecency database (ranked internally by the shared scorer).
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
        FolderFrecency.lent(entries) { records, pool in
            asked(query, homePath, currentCwd, lastJumpSource) { asked, home, cwd, source in
                var record = SlopDeskJumpResolution()
                func ask(
                    _ out: UnsafeMutablePointer<SlopDeskJumpResolution>?,
                    _ arena: UnsafeMutableRawPointer?,
                    _ cap: Int,
                ) -> Int {
                    slopdesk_jump_resolve(
                        asked.baseAddress, asked.count, records.baseAddress, records.count,
                        pool.baseAddress, pool.count, now.timeIntervalSinceReferenceDate,
                        home.baseAddress, home.count, cwd.baseAddress, cwd.count,
                        source.baseAddress, source.count, changeDirectory, out, arena, cap,
                    )
                }
                let needed = ask(&record, nil, 0)
                guard record.resolved else { return nil }
                var arena = Data(count: needed)
                let written = arena.withUnsafeMutableBytes { out in
                    ask(&record, out.baseAddress, out.count)
                }
                guard written == needed else { return nil }
                return Resolution(
                    path: string(record.path, arena),
                    lastJumpSource: record.has_source ? string(record.source, arena) : nil,
                )
            }
        }
    }

    /// Lends the query and the three paths as bytes for exactly one call.
    private static func asked<Answer>(
        _ query: String?,
        _ home: String,
        _ cwd: String?,
        _ source: String?,
        _ ask: (
            UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<UInt8>,
            UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<UInt8>,
        ) -> Answer,
    ) -> Answer {
        let asked = Array((query ?? "").utf8)
        let home = Array(home.utf8)
        let cwd = Array((cwd ?? "").utf8)
        let source = Array((source ?? "").utf8)
        return asked.withUnsafeBufferPointer { asked in
            home.withUnsafeBufferPointer { home in
                cwd.withUnsafeBufferPointer { cwd in
                    source.withUnsafeBufferPointer { source in ask(asked, home, cwd, source) }
                }
            }
        }
    }

    /// The text a span names, or "" when it names nothing — ``ArenaText/text(_:offset:length:)``
    /// wearing this door's C struct.
    private static func string(_ span: SlopDeskByteSpan, _ arena: Data) -> String {
        ArenaText.text(arena, offset: Int(span.offset), length: Int(span.length))
    }
}
