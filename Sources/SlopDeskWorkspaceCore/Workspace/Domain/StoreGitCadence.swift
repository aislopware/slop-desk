import CSlopDeskFFI
import Foundation

// MARK: - StoreGitCadence (when the git line is re-probed, and where the reply is filed)

/// The sidebar git line's CADENCE and BOOKING rules, as `slopdesk-workspace::store_git_cadence`
/// answers them.
///
/// `git_line` (`rust/slopdesk-workspace/src/git_line.rs`) decides what the line says. This decides when it is asked for and which section
/// header the answer lands under — two questions the store used to answer in place, with the
/// project-key precedence transcribed at three of the call sites.
///
/// **The clocks stay here.** Nothing across the boundary holds a `Date`. What the rule reads is how
/// long ago something happened, so this side subtracts and lends the interval; a project that has
/// never been fetched, or never been pushed to, lends `.infinity`, which is the literal reading and
/// lands on the branch the absent case wants — infinitely stale is due, and a push infinitely long
/// ago grants no grace.
///
/// **The two sets stay here too.** Which projects have a probe out and which one is focused are
/// facts about collections this side owns, so they cross as the two booleans the rule actually
/// reads rather than as the sets themselves.
public enum StoreGitCadence {
    /// How long a BACKGROUND project's header line stays fresh on the ~3 s snapshot edge before a
    /// re-fetch is allowed — long enough that the snapshot cadence is never a git-status poll, short
    /// enough that every visible section self-heals within a minute.
    ///
    /// Read through the door on every access rather than cached in a `static let`: a bare scalar
    /// door is the boundary's cheapest call, and the three readers are the cadence gate and its
    /// tests — none of them a render path.
    public static var staleWindow: TimeInterval { slopdesk_ws_git_windows().stale }

    /// The tighter window for the ACTIVE project — the section the focused pane sits in, whose
    /// header the user is most likely acting on.
    public static var staleWindowActiveProject: TimeInterval { slopdesk_ws_git_windows().active }

    /// The poll back-off while HOST PUSHES are fresh: the watcher already delivers event-driven
    /// updates, so the poll degrades to a slow safety net that re-arms itself when they stop.
    public static var pushGraceWindow: TimeInterval { slopdesk_ws_git_windows().push_grace }

    /// Whether the snapshot edge should re-fetch this project's git line.
    ///
    /// - Parameters:
    ///   - inFlight: whether a probe for this project is already out. The de-dupe is BY PROJECT: N
    ///     same-repo panes completing together collapse to one RPC.
    ///   - sinceFetch: seconds since this project's line was last fetched, `nil` for a project with
    ///     no line yet — the initial populate, which is always due.
    ///   - sincePush: seconds since the last host push for this project, `nil` if none has landed.
    ///   - activeProject: whether this is the focused pane's project.
    public static func refreshDue(
        inFlight: Bool,
        sinceFetch: TimeInterval?,
        sincePush: TimeInterval?,
        activeProject: Bool,
    ) -> Bool {
        slopdesk_ws_git_refresh_due(
            inFlight, sinceFetch ?? .infinity, sincePush ?? .infinity, activeProject,
        )
    }

    /// A pane's SECTION key for git bookkeeping: the project-key precedence — host-pushed key, else
    /// the directory, with a plugin-cache reading guarded out of both — normalized to the rail's own
    /// bucketing key so the two always name the same section. `nil` ⇒ the pane has no section
    /// identity yet, and gets no git bookkeeping.
    public static func sectionKey(hostKey: String?, cwd: String?) -> String? {
        answer(hostKey, cwd, slopdesk_ws_git_section_key)
    }

    /// A pane's HOST-PUSHED key alone, RAW — `nil` while the pane is still on its directory
    /// fallback. Not normalized: its readers compare it against the host's own word and use it as a
    /// filesystem root.
    public static func hostPushedKey(_ hostKey: String?) -> String? {
        answer(hostKey, nil) { key, keyLength, _, _, out, cap in
            slopdesk_ws_git_host_key(key, keyLength, out, cap)
        }
    }

    /// The key a probe's reply may be ALIASED under, or `nil` when it may not be aliased at all.
    ///
    /// Only a pane still sectioned by its DIRECTORY is eligible: a host-pushed key can be stale
    /// across a cross-repo `cd` nothing client-side invalidates, and booking the new repo's reply
    /// under the old repo's key would overwrite an unrelated section's correct header.
    public static func aliasCandidate(hostKey: String?, cwd: String?) -> String? {
        answer(hostKey, cwd, slopdesk_ws_git_alias_candidate)
    }

    /// Where a HOST-PUSHED reading is filed, or `nil` to drop it. The push carries a repo root the
    /// host resolved, so there is no fallback leg and no alias — only the plugin-cache guard, which
    /// stands because the host's own resolver races a plugin manager's `cd` exactly as a
    /// client-side probe does.
    public static func pushedKey(repoRoot: String) -> String? {
        answer(repoRoot, nil) { root, rootLength, _, _, out, cap in
            slopdesk_ws_git_pushed_key(root, rootLength, out, cap)
        }
    }

    /// Where a freshly-fetched reading is filed, or `nil` to DROP the whole reading.
    public struct Booking: Equatable {
        /// The section key this reading is the truth for.
        public var primary: String
        /// Whether to file it under the probing pane's own fallback key as well — the interim
        /// section, whose header is then already correct before the host's key for it lands.
        public var alias: Bool
    }

    /// Where a freshly-fetched reading is filed, given the reply's repo `toplevel` and the probing
    /// pane's own `fallbackKey`.
    ///
    /// `nil` means drop it whole: the reading was taken while the shell was transiently inside a
    /// plugin manager's cache directory, so its branch and its counts are that plugin's repo rather
    /// than the user's project, and half of it is not better than none of it.
    public static func booking(toplevel: String, fallbackKey: String?) -> Booking? {
        let top = Array(toplevel.utf8)
        let fallback = Array((fallbackKey ?? "").utf8)
        // The primary key is either the toplevel normalized (which only ever trims) or the fallback
        // verbatim, so the larger of the two inputs is an arithmetic bound and the retry path is
        // never travelled.
        var out = [UInt8](repeating: 0, count: max(top.count, fallback.count))
        let plan = top.withUnsafeBufferPointer { first in
            fallback.withUnsafeBufferPointer { second in
                out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_ws_git_booking(
                        first.baseAddress, first.count, second.baseAddress, second.count,
                        buffer.baseAddress, buffer.count,
                    )
                }
            }
        }
        guard plan.booked, plan.primary > 0, plan.primary <= out.count else { return nil }
        return Booking(
            primary: String(decoding: out.prefix(plan.primary), as: UTF8.self), alias: plan.alias,
        )
    }

    /// Lends two optional strings to a counted text door and reads the answer back.
    ///
    /// Every answer here is one of the inputs, trimmed at most, so a buffer the size of the larger
    /// input always fits and the size-then-retry path is never travelled.
    private static func answer(
        _ first: String?,
        _ second: String?,
        _ door: (
            UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?,
            Int,
        ) -> Int,
    ) -> String? {
        let left = Array((first ?? "").utf8)
        let right = Array((second ?? "").utf8)
        var out = [UInt8](repeating: 0, count: max(1, max(left.count, right.count)))
        let count = left.withUnsafeBufferPointer { lending in
            right.withUnsafeBufferPointer { other in
                out.withUnsafeMutableBufferPointer { buffer in
                    door(
                        lending.baseAddress, lending.count, other.baseAddress, other.count,
                        buffer.baseAddress, buffer.count,
                    )
                }
            }
        }
        guard count > 0, count <= out.count else { return nil }
        return String(decoding: out.prefix(count), as: UTF8.self)
    }
}
