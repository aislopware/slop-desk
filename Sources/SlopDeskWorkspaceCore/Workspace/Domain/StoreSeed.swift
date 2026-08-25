import CSlopDeskFFI

// MARK: - StoreSeed (what a new pane inherits, and which readings are kept at all)

/// What a pane born beside another one inherits, and which readings the store writes down, as
/// `slopdesk-workspace::store_seed` answers them.
///
/// Two facts follow a pane everywhere it is drawn: where its shell is, and which project section it
/// belongs to. A split, a new tab and a new window each mint a pane that has neither yet, and the
/// surfaces that name it draw on the FIRST frame — long before the host's own answer for the child's
/// PTY round-trips. So both are seeded from the pane the gesture was made on.
///
/// The seeds and the write gates are one namespace because they are one guard read from two ends. A
/// plugin manager that steps into its cache directory to source a plugin makes the kernel's answer
/// to "where is this shell" briefly true and completely useless, and the two sides of that are:
/// never inherit such a reading, and never store one. Three transcriptions of the same guard is how
/// one of them ends up missing.
public enum StoreSeed {
    /// A pane's directory sanitized as an INHERIT SOURCE for a new tab, split or window — `nil`
    /// when there is nothing worth inheriting, which is what a plugin manager's cache directory
    /// reads as.
    ///
    /// Without this, a directory probe that caught the shell mid plugin-manager `cd` seeds the new
    /// pane's directory — and then its spawn directory, its folder-name title and its project
    /// section are all that plugin's. `nil` also for a pane with no directory yet; the caller's own
    /// policy resolves the host default from there.
    public static func inheritableCwd(_ cwd: String?) -> String? {
        let bytes = Array((cwd ?? "").utf8)
        // The answer is the input or nothing, so one buffer of that size always fits.
        var out = [UInt8](repeating: 0, count: max(1, bytes.count))
        let count = bytes.withUnsafeBufferPointer { lending in
            out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_ws_seed_inheritable_cwd(
                    lending.baseAddress, lending.count, buffer.baseAddress, buffer.count,
                )
            }
        }
        guard count > 0, count <= out.count else { return nil }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: out.prefix(count), as: UTF8.self)
    }

    /// The parent's project key seeded onto a child whose shell will start in `coveringCwd`, or
    /// `nil` to seed nothing.
    ///
    /// Guarded three ways, each a different way of being wrong: a blank or plugin-cache key is not a
    /// project; a parent still on its own directory fallback seeds nothing, because the child's
    /// identical fallback already sections it beside the parent; and a key that does not cover the
    /// inherited directory is not this child's project — a stale key across an un-re-pushed `cd`
    /// would otherwise file the child under a project it is not in, visibly, until the host's push
    /// corrects it.
    public static func inheritableProjectKey(_ key: String?, coveringCwd cwd: String?) -> String? {
        let parent = Array((key ?? "").utf8)
        let inherited = Array((cwd ?? "").utf8)
        // The answer is the key or nothing, so a buffer the size of the key always fits.
        var out = [UInt8](repeating: 0, count: max(1, parent.count))
        let count = parent.withUnsafeBufferPointer { lending in
            inherited.withUnsafeBufferPointer { covering in
                out.withUnsafeMutableBufferPointer { buffer in
                    slopdesk_ws_seed_inheritable_project_key(
                        lending.baseAddress, lending.count, covering.baseAddress, covering.count,
                        buffer.baseAddress, buffer.count,
                    )
                }
            }
        }
        guard count > 0, count <= out.count else { return nil }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: out.prefix(count), as: UTF8.self)
    }

    /// Whether a freshly-observed working directory is worth writing: not a plugin-cache reading,
    /// and not the value already stored.
    ///
    /// The dirty half is load-bearing beyond the saved write — the store treats a changed directory
    /// as a genuine VISIT, so an unchanged re-assert must not record one.
    public static func acceptsCwd(_ candidate: String, current: String?) -> Bool {
        gate(candidate, current, slopdesk_ws_seed_accepts_cwd)
    }

    /// Whether a host-pushed project key is worth writing: the mirror of ``acceptsCwd(_:current:)``
    /// with one guard more, because a blank key is not an answer.
    public static func acceptsProjectKey(_ candidate: String, current: String?) -> Bool {
        gate(candidate, current, slopdesk_ws_seed_accepts_project_key)
    }

    /// Lends a candidate and the stored value to a write gate.
    ///
    /// The presence of the stored value crosses as its own flag: a fact that has never been
    /// recorded and one recorded as blank are different things to a dirty guard, and a
    /// `(pointer, length)` pair alone cannot tell them apart.
    private static func gate(
        _ candidate: String,
        _ current: String?,
        _ door: (
            UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int, Bool,
        ) -> Bool,
    ) -> Bool {
        let fresh = Array(candidate.utf8)
        let stored = Array((current ?? "").utf8)
        return fresh.withUnsafeBufferPointer { lending in
            stored.withUnsafeBufferPointer { held in
                door(
                    lending.baseAddress, lending.count, held.baseAddress, held.count,
                    current != nil,
                )
            }
        }
    }
}
