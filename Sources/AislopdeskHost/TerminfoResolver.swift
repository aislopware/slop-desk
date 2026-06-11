#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Resolves the **effective** `TERM` to advertise into the spawned PTY, mirroring the
/// ssh / kitty terminfo-bootstrap model (audit finding #17).
///
/// ## The problem
/// aislopdesk's client renders with libghostty, so the host's first instinct is to advertise
/// `TERM=xterm-ghostty` unconditionally — that unlocks the kitty keyboard protocol + DEC
/// 2026 synchronized output. But a *fresh remote host* almost never has the `xterm-ghostty`
/// terminfo entry installed (it ships with Ghostty, not the base OS). On such a host every
/// curses / TUI app — `vim`, `htop`, `less`, `tmux`, `top` — calls `setupterm("xterm-ghostty")`,
/// fails to find the entry, and either errors (`'terminal is not fully functional'`) or
/// degrades to a dumb fallback with the wrong key sequences.
///
/// ## Prior art (what the canonical tools do)
/// - **ssh** forwards `TERM` verbatim and RELIES on the remote already having the entry —
///   exactly the failure mode above when the entry is missing.
/// - **mosh** forces a known-good `TERM` it ships terminfo for.
/// - **kitty's `ssh` kitten** PUSHES its compiled terminfo to the remote (`tic`-installs it
///   under `~/.terminfo`) before launching the shell — the gold-standard but host-mutating fix.
/// - **Ghostty itself** documents the `xterm-256color` fallback (#54700) for hosts that lack
///   the ghostty entry: `xterm-256color` is present on effectively every Unix host and is
///   "correct enough" for all the TUI apps above (truecolor via `COLORTERM`, 256-color,
///   standard cursor keys) — it only loses the ghostty-specific kitty/DEC-2026 extras.
///
/// ## This resolver — the SAFE, self-contained fix
/// We implement the auto-fallback (Ghostty #54700 model), NOT the host-mutating `tic` push:
/// 1. If the host can already resolve `xterm-ghostty` → keep it (best features).
/// 2. If it CANNOT → fall back to `xterm-256color` (universally present, correct enough).
/// 3. An EXPLICIT operator override (`--xterm256`) always wins regardless of probing.
///
/// The detection is split into a **pure decision function** (``effectiveTerm(requested:explicitOverride:isGhosttyResolvable:)``,
/// no I/O — trivially unit-testable) and an **injectable probe** (``GhosttyTerminfoProbe``,
/// the only part that touches the filesystem / runs `infocmp`). Tests inject a fake probe.
///
/// - TODO (future round, the kitty-kitten model): the heavier, best-fidelity fix is to PUSH
///   the compiled `xterm-ghostty` terminfo to the remote host and `tic`-install it under
///   `~/.terminfo` (so `xterm-ghostty` itself resolves and we keep full features even on a
///   bare host). That mutates the host filesystem, so it is deliberately out of scope for
///   this round — the safe auto-fallback above is the deliverable. See kitty's
///   `kittens/ssh` terminfo-bootstrap for the reference implementation.
public enum TerminfoResolver {

    /// The pure decision: given what was *requested*, whether the request was an *explicit*
    /// operator override, and whether the host can resolve `xterm-ghostty`, return the
    /// `TERM` to actually advertise.
    ///
    /// Decision table:
    /// | requested  | explicitOverride | ghostty resolvable | → effective    | fellBack |
    /// |------------|------------------|--------------------|----------------|----------|
    /// | .xterm256  | true             | (any)              | .xterm256      | false    |
    /// | .ghostty   | (any)            | true               | .ghostty       | false    |
    /// | .ghostty   | (any)            | false              | .xterm256      | true     |
    /// | .xterm256  | false            | (any)              | .xterm256      | false    |
    ///
    /// Notes:
    /// - An explicit `.xterm256` request (`--xterm256`) ALWAYS wins — we never "upgrade" the
    ///   operator's deliberate choice back to ghostty, and there is nothing to probe.
    /// - Auto-fallback only fires for a `.ghostty` request that the host cannot resolve. A
    ///   `.xterm256` is already universally resolvable, so it never triggers a fallback.
    ///
    /// - Returns: the effective `Term` and whether this was an automatic fallback (so the
    ///   caller can log it — gated — exactly once at session start).
    public static func effectiveTerm(
        requested: ClaudeCodeProfile.Term,
        explicitOverride: Bool,
        isGhosttyResolvable: Bool
    ) -> (term: ClaudeCodeProfile.Term, fellBack: Bool) {
        // An explicit operator choice of xterm-256color is authoritative — never re-probe,
        // never "fall back" (there is nothing to fall back FROM). This is the `--xterm256`
        // lever from `HostdArguments` winning over auto-detection.
        if requested == .xterm256 {
            return (.xterm256, false)
        }
        // requested == .ghostty: keep it only if the host can resolve the entry; otherwise
        // auto-fall back to the universally-present xterm-256color (#54700).
        if isGhosttyResolvable {
            return (.ghostty, false)
        }
        return (.xterm256, true)
        // `explicitOverride` is unused on the `.ghostty` branch by design: a `.ghostty`
        // request — whether the default or explicitly chosen — must still auto-fall back on
        // a host that cannot resolve it (advertising an unresolvable TERM helps no one). The
        // parameter is kept in the signature so the override semantics are explicit at the
        // call site and so a future "force ghostty even if unresolvable" lever has a home.
    }

    /// The full resolution: probe the host (injectable), then apply the pure decision.
    ///
    /// - Parameters:
    ///   - requested: the `TERM` the launch mode wants (`.ghostty` default, or `.xterm256`
    ///     when `--xterm256` was passed).
    ///   - explicitOverride: whether `requested` came from an explicit operator flag (so it
    ///     must win over auto-detection).
    ///   - probe: the terminfo probe (defaults to the live ``GhosttyTerminfoProbe``). Tests
    ///     inject a deterministic fake.
    public static func resolve(
        requested: ClaudeCodeProfile.Term,
        explicitOverride: Bool,
        probe: GhosttyTerminfoProbe = .live
    ) -> (term: ClaudeCodeProfile.Term, fellBack: Bool) {
        // Short-circuit: an explicit `.xterm256` needs no probe at all (we'd discard the
        // result anyway). Avoids spawning `infocmp` / stat'ing dirs for nothing.
        if requested == .xterm256 {
            return (.xterm256, false)
        }
        let resolvable = probe.isGhosttyResolvable()
        return effectiveTerm(
            requested: requested,
            explicitOverride: explicitOverride,
            isGhosttyResolvable: resolvable
        )
    }
}

/// An injectable predicate that answers "can THIS host resolve the `xterm-ghostty` terminfo
/// entry?". The live implementation probes the standard terminfo search path and, as a
/// fallback, runs `/usr/bin/infocmp xterm-ghostty`. Tests inject a constant.
///
/// Kept as a struct holding a closure (not a protocol) so a test can build one inline:
/// `GhosttyTerminfoProbe { true }`.
public struct GhosttyTerminfoProbe: Sendable {
    /// Returns `true` iff the host can resolve `xterm-ghostty`.
    public let isGhosttyResolvable: @Sendable () -> Bool

    public init(isGhosttyResolvable: @escaping @Sendable () -> Bool) {
        self.isGhosttyResolvable = isGhosttyResolvable
    }

    /// The live probe used in production.
    ///
    /// Strategy (cheapest first):
    /// 1. **Search the terminfo directories directly** for a `x/xterm-ghostty` (or
    ///    `78/xterm-ghostty`, the hex-of-`x` layout some `tic` builds emit) compiled entry,
    ///    across `$TERMINFO`, `~/.terminfo`, `$TERMINFO_DIRS`, and the system dirs
    ///    (`/usr/share/terminfo`, `/usr/lib/terminfo`, `/etc/terminfo`,
    ///    `/usr/share/misc/terminfo`). This is a pure `stat` — no subprocess.
    /// 2. If the directory probe is inconclusive, run `/usr/bin/infocmp xterm-ghostty`
    ///    and treat **exit status 0** as resolvable. `infocmp` consults the same database
    ///    ncurses will, so its verdict matches what the spawned TUI apps will see.
    public static let live = GhosttyTerminfoProbe {
        liveProbe(
            term: "xterm-ghostty",
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// The live probe body, factored out with injected `environment` + `fileExists` +
    /// `infocmpExitStatus` so the directory-search and infocmp branches are themselves
    /// unit-testable without touching the real machine. Production passes the live env, a
    /// real `stat`, and a real `infocmp` invocation.
    static func liveProbe(
        term: String,
        environment: [String: String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        infocmpExitStatus: (String) -> Int32? = GhosttyTerminfoProbe.runInfocmp
    ) -> Bool {
        // 1. Direct terminfo-database search (pure stat, no subprocess).
        if terminfoEntryExists(term: term, environment: environment, fileExists: fileExists) {
            return true
        }
        // 2. Authoritative fallback: ask infocmp (consults the same DB ncurses uses).
        if let status = infocmpExitStatus(term) {
            return status == 0
        }
        // infocmp unavailable AND the directory probe found nothing → treat as unresolvable
        // and let the caller fall back to xterm-256color (the safe default).
        return false
    }

    /// Does a compiled `term` entry exist under any terminfo search directory?
    ///
    /// terminfo stores `<name>` under a `<first-char>/<name>` subdirectory — and on some
    /// `tic` builds (notably ncurses configured `--enable-term-driver`/macOS) under a
    /// `<hex-of-first-char>/<name>` directory too — so for `xterm-ghostty` we check both
    /// `x/xterm-ghostty` and `78/xterm-ghostty`.
    static func terminfoEntryExists(
        term: String,
        environment: [String: String],
        fileExists: (String) -> Bool
    ) -> Bool {
        guard let first = term.first else { return false }
        let firstChar = String(first)
        let hexDir = String(format: "%02x", Int(first.asciiValue ?? 0))

        for base in searchDirectories(environment: environment) {
            for sub in [firstChar, hexDir] {
                let candidate = (base as NSString)
                    .appendingPathComponent(sub)
                    .appending("/")
                    .appending(term)
                if fileExists(candidate) { return true }
            }
        }
        return false
    }

    /// The ordered terminfo search directories, mirroring ncurses' lookup:
    /// `$TERMINFO`, then `~/.terminfo`, then each dir in `$TERMINFO_DIRS` (`:`-separated;
    /// an empty element means the compiled-in default), then the conventional system dirs.
    static func searchDirectories(environment: [String: String]) -> [String] {
        var dirs: [String] = []

        if let ti = environment["TERMINFO"], !ti.isEmpty {
            dirs.append(ti)
        }
        if let home = environment["HOME"], !home.isEmpty {
            dirs.append((home as NSString).appendingPathComponent(".terminfo"))
        }
        if let tiDirs = environment["TERMINFO_DIRS"], !tiDirs.isEmpty {
            for element in tiDirs.split(separator: ":", omittingEmptySubsequences: false) {
                // An empty element in TERMINFO_DIRS means "the compiled-in default location";
                // we approximate that with the system dirs appended below, so skip the blank.
                if !element.isEmpty { dirs.append(String(element)) }
            }
        }
        // Conventional system locations (present on macOS + most Linux).
        dirs.append(contentsOf: [
            "/usr/share/terminfo",
            "/usr/lib/terminfo",
            "/etc/terminfo",
            "/usr/share/misc/terminfo",
        ])
        return dirs
    }

    /// Runs `/usr/bin/infocmp <term>` and returns its exit status, or `nil` if the binary
    /// could not be launched at all (missing / not executable / sandbox-blocked). A `0`
    /// status means the entry resolved; non-zero means it did not.
    ///
    /// We redirect stdout/stderr to `/dev/null` — we care ONLY about the exit code, never the
    /// dumped capabilities, so nothing pollutes the host's byte stream.
    static func runInfocmp(_ term: String) -> Int32? {
        let infocmpPath = "/usr/bin/infocmp"
        guard FileManager.default.isExecutableFile(atPath: infocmpPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: infocmpPath)
        process.arguments = [term]
        let devNull = FileHandle.nullDevice
        process.standardOutput = devNull
        process.standardError = devNull
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            // Could not spawn infocmp — report "unknown" so the caller falls back safely.
            return nil
        }
    }
}
