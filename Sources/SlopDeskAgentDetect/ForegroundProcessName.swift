import CSlopDeskFFI

/// What a PTY foreground process is CALLED, and whether it is a session nobody may drive.
///
/// A face over `slopdesk-agent`'s `process`, which is where the `claude`/wrapper matches beside it
/// already live. The three answers are one vocabulary — a name is reduced the same way whether it is
/// about to be classified, labelled, or refused — so they cross one door apiece rather than being
/// re-derived on the near side.
public enum ForegroundProcessName {
    /// The basename of a process path: the last non-empty `/`-separated component.
    /// `"/usr/local/bin/claude"` → `"claude"`, `"zsh"` → `"zsh"`, `""` → `""`. A path with no
    /// component at all (`"/"`, `"///"`) answers itself, which equals no program name.
    ///
    /// `/`-only on purpose: this is what a Unix host's foreground poll reported, where a backslash
    /// is a filename character. The crate's `path_basename` (`rust/slopdesk-agent/src/kind.rs`) splits on both, because it reads
    /// names that may have been written on another platform.
    public static func basename(of name: String) -> String {
        agentTransform(name) { bytes, len, out, cap in
            slopdesk_agent_process_basename(bytes, len, out, cap)
        }
    }

    /// The CANONICAL name of an executable path: the basename, except a VERSION-named executable,
    /// which resolves to the owning app directory.
    ///
    /// The Claude Code native installer lays the binary out as `…/claude/versions/2.1.218` — the
    /// executable file IS the version string, so the raw basename would defeat the exact-basename
    /// `claude` match and read as a meaningless `2.1.218` in the sidebar's shell-label slot.
    public static func canonicalName(of path: String) -> String {
        agentTransform(path) { bytes, len, out, cap in
            slopdesk_agent_canonical_name(bytes, len, out, cap)
        }
    }

    /// Whether `processName` names a credential prompt or remote-shell entry point the control RPC
    /// must refuse outright. An EMPTY / unresolved name is NOT sensitive: the host could not prove a
    /// sensitive session, and the send-keys gate already guards the mutating path.
    public static func isSensitive(processName: String) -> Bool {
        agentPredicate(processName) { bytes, len in
            slopdesk_agent_is_sensitive(bytes, len)
        }
    }
}
