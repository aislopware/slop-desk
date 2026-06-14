#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// The curated launch profile for a **Claude Code** session inside the host PTY.
///
/// WF-7 owns the Claude-Code-specific environment policy (the WF-7 seam noted in
/// ``HostEnvironment``). This type produces:
/// - the curated child environment (forced Claude keys merged over a sanitized
///   inherited env — never clobbering the user's environment wholesale), and
/// - the argv used to launch `claude` in a login shell (vs. the existing plain-shell
///   path, which stays intact).
///
/// ## TERM choice (doc 14 — "Quyết định 1") + the documented toggle
/// Default `TERM=xterm-ghostty`: native libghostty TERM → kitty keyboard protocol
/// (Shift+Enter, modifier combos) + DEC 2026 synchronized-output auto-detect. This
/// accepts the risk of the multi-line paste bug (#54700). If that manifests, the
/// operator toggles to `.xterm256` (`xterm-256color`), which disables DEC 2026 but
/// avoids the paste-tokenization bug. The toggle is a first-class field, not a flag.
///
/// ## Forced vs inherited (doc 14 §P0 + DECISIONS "Claude Code integration")
/// - **Forced** (curated, always overwrite): `TERM`, `COLORTERM=truecolor`,
///   `CLAUDE_CODE_NO_FLICKER=1` (fullscreen mode for the remote PTY),
///   `CLAUDE_CODE_ENTRYPOINT=remote_mobile` (non-SDK headless resume).
/// - **Inherited** (passed through from the parent when present, never clobbered):
///   `HOME`, `USER`, `LOGNAME`, `SHELL`, `PATH`, `TMPDIR`, `LANG`, every `LC_*`,
///   `TERM_PROGRAM`. `HOME` is load-bearing for auth: a `claude` spawned with the
///   real `HOME` inherits the user's `~/.claude/.credentials.json` login.
public struct ClaudeCodeProfile: Sendable, Equatable {
    /// The `TERM` value to advertise into the PTY.
    public enum Term: String, Sendable, Equatable {
        /// Native libghostty TERM (kitty keyboard + DEC 2026). Default.
        case ghostty = "xterm-ghostty"
        /// Documented fallback that mitigates the multi-line paste bug (#54700);
        /// disables DEC 2026 synchronized output.
        case xterm256 = "xterm-256color"
    }

    /// The advertised `TERM`. Default `.ghostty`.
    public var term: Term

    /// The `claude` command to run inside the login shell. Default `"claude"` (resolved
    /// from the shell's `PATH`). An operator may override (e.g. an absolute path).
    public var command: String

    public init(term: Term = .ghostty, command: String = "claude") {
        self.term = term
        self.command = command
    }

    // MARK: Curated environment

    /// The keys this profile FORCES (overwrites) on top of the inherited env. Exposed so
    /// tests + reviewers can see exactly what is curated vs. passed through.
    public static let forcedKeys = [
        "TERM", "COLORTERM", "CLAUDE_CODE_NO_FLICKER", "CLAUDE_CODE_ENTRYPOINT",
    ]

    /// The inherited-env allowlist: keys mirrored from the parent when present. `LC_*`
    /// is matched by prefix (see ``environment(parent:)``) and is not enumerated here.
    public static let inheritedKeys = [
        "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "LANG", "TERM_PROGRAM",
        // TERMINFO / TERMINFO_DIRS (R8 #2): the terminfo PROBE honours them, so the child must inherit
        // them or a "resolvable" xterm-ghostty verdict it can't actually find degrades every TUI. See
        // HostEnvironment.curated().
        "TERMINFO", "TERMINFO_DIRS",
    ]

    /// Builds the curated environment for launching `claude`.
    ///
    /// Strategy: start from a **sanitized inherited env** (the allowlist above + every
    /// `LC_*`), then layer the forced Claude keys on top. We do not copy the parent's
    /// environment wholesale — only the allowlist passes through — and we never drop an
    /// inherited key just because we also force one (the forced set and the inherited
    /// allowlist are disjoint, except `TERM`, which is intentionally forced).
    public func environment(
        parent: [String: String] = ProcessInfo.processInfo.environment,
    ) -> [String: String] {
        var env: [String: String] = [:]

        // Inherited allowlist (identity / locale / path), passed through untouched.
        for key in Self.inheritedKeys {
            if let value = parent[key] { env[key] = value }
        }
        // Every LC_* locale var (LC_CTYPE, LC_NUMERIC, ...) passes through.
        for (key, value) in parent where key.hasPrefix("LC_") {
            env[key] = value
        }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }

        // Forced (curated) keys — these OVERWRITE whatever the parent had.
        env["TERM"] = term.rawValue
        env["COLORTERM"] = "truecolor"
        env["CLAUDE_CODE_NO_FLICKER"] = "1"
        env["CLAUDE_CODE_ENTRYPOINT"] = "remote_mobile"

        return env
    }

    // MARK: Launch argv

    /// The argv (after `argv[0]`) for launching `claude` via the user's login shell:
    /// `[shell, -lc, <command>]` shape → arguments are `["-lc", command]`. Using `-lc`
    /// (login + command) makes the shell source the user's profile so `claude` is on
    /// `PATH` and the env the user expects is present, then exec the command.
    ///
    /// The plain-shell path (``HostEnvironment/loginArgv0(forShell:)`` with no arguments)
    /// is unchanged — this is an *additional* launch option, not a replacement.
    public func loginShellArguments() -> [String] {
        ["-lc", command]
    }
}

/// How a spawned `claude` will obtain its credentials. Resolved by FILE EXISTENCE /
/// PATH only — the bytes of the real credentials file are NEVER read, logged, or
/// transmitted (doc 14 "Quyết định 2"; privacy constraint).
public enum AuthStrategy: Sendable, Equatable {
    /// `~/.claude/.credentials.json` EXISTS. The spawned `claude` inherits it via `HOME`
    /// (we resolve by `stat`, we do not open or read the file). The associated value is
    /// the resolved path — for diagnostics / wiring only; its contents are off-limits.
    case inheritedCredentials(path: String)

    /// No credentials file present. The operator must establish a headless token via
    /// `claude setup-token` (1-year token, doc 14). `needed == true` signals the host /
    /// CLI to prompt for the setup-token flow.
    case setupToken(needed: Bool)
}

/// Resolves the Claude Code auth strategy **without exfiltrating credentials**.
///
/// CRITICAL PRIVACY CONSTRAINT: this resolver uses `stat`/`FileManager.fileExists` ONLY.
/// It never opens, reads, logs, or transmits the bytes of `~/.claude/.credentials.json`.
/// Tests assert on the resolved strategy / path and verify (via an injected open-hook)
/// that the file is never opened.
public enum ClaudeAuthResolver {
    /// The conventional credentials path under a given `HOME`.
    public static func credentialsPath(home: String) -> String {
        // NSString.appendingPathComponent is the Cocoa path API; the pure-Swift String has no exact
        // equivalent (URL would change normalization/encoding) and this is privacy-critical.
        // swiftlint:disable:next legacy_objc_type
        (home as NSString).appendingPathComponent(".claude/.credentials.json")
    }

    /// Resolves the strategy from the parent env's `HOME`.
    ///
    /// - `existsCheck`: injected existence predicate (defaults to `FileManager`'s
    ///   `fileExists`, which `stat`s — it does NOT read the file). Tests inject a fixture
    ///   path + a predicate that records it was a stat, not an open.
    public static func resolve(
        home: String,
        existsCheck: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) -> AuthStrategy {
        let path = credentialsPath(home: home)
        if existsCheck(path) {
            // Resolve by existence/path only — we deliberately do NOT read the bytes.
            return .inheritedCredentials(path: path)
        }
        return .setupToken(needed: true)
    }

    /// Convenience: resolve from a full environment dictionary. Returns `.setupToken`
    /// when `HOME` is absent (we cannot locate the file, so a token is needed).
    public static func resolve(
        parent: [String: String] = ProcessInfo.processInfo.environment,
        existsCheck: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) -> AuthStrategy {
        guard let home = parent["HOME"], !home.isEmpty else {
            return .setupToken(needed: true)
        }
        return resolve(home: home, existsCheck: existsCheck)
    }
}
