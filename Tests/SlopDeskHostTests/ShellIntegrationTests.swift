import XCTest
@testable import SlopDeskHost

/// The zsh shell-integration shim (generated ZDOTDIR) that forces a post-resize prompt
/// reprint. Deterministic + HostServer-free: pure string assembly + temp-dir file writes.
final class ShellIntegrationTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("slopdesk-si-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A fake user home (or ZDOTDIR) holding the given zsh startup files — the new-install guard
    /// (kitty parity) skips the shim when NONE exist, so tests that expect a shim must provide one.
    private func makeHome(rcFiles: [String] = [".zshrc"]) -> URL {
        let dir = makeTempDir()
        for name in rcFiles {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        return dir
    }

    // MARK: Opt-out gate

    func testEnabledByDefault() {
        XCTAssertTrue(ShellIntegration.isEnabled(parent: [:]))
        XCTAssertTrue(ShellIntegration.isEnabled(parent: ["SLOPDESK_SHELL_INTEGRATION": "1"]))
        XCTAssertTrue(ShellIntegration.isEnabled(parent: ["SLOPDESK_SHELL_INTEGRATION": "yes"]))
    }

    func testDisabledByFalsyOptOut() {
        for value in ["0", "false", "no", "off", "OFF", "False", "No"] {
            XCTAssertFalse(
                ShellIntegration.isEnabled(parent: ["SLOPDESK_SHELL_INTEGRATION": value]),
                "SLOPDESK_SHELL_INTEGRATION=\(value) must disable the shim",
            )
        }
    }

    // MARK: Shell gating (zsh only)

    func testOnlyZshIsShimmed() {
        XCTAssertTrue(ShellIntegration.isZsh(shellPath: "/bin/zsh"))
        XCTAssertTrue(ShellIntegration.isZsh(shellPath: "/usr/local/bin/zsh"))
        XCTAssertFalse(ShellIntegration.isZsh(shellPath: "/bin/bash"))
        XCTAssertFalse(ShellIntegration.isZsh(shellPath: "/usr/local/bin/fish"))
    }

    // MARK: makeEnvironmentOverrides

    func testNoOverridesForNonZsh() {
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": makeHome().path],
            shellPath: "/bin/bash",
            tmpDir: makeTempDir(),
        )
        XCTAssertNil(overrides, "a non-zsh shell must not get a ZDOTDIR shim")
    }

    func testNoOverridesWhenOptedOut() {
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": makeHome().path, "SLOPDESK_SHELL_INTEGRATION": "0"],
            shellPath: "/bin/zsh",
            tmpDir: makeTempDir(),
        )
        XCTAssertNil(overrides, "opt-out must skip the shim entirely")
    }

    func testOverridesPointZDotDirAtFreshShimAndCarryRealZDotDir() {
        let tmp = makeTempDir()
        let home = makeHome()
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": home.path],
            shellPath: "/bin/zsh",
            tmpDir: tmp,
        )
        let env = try? XCTUnwrap(overrides)
        let shim = try? XCTUnwrap(env?["ZDOTDIR"])
        XCTAssertNotNil(shim)
        // The shim is a fresh subdir of tmp, not the user's HOME.
        XCTAssertTrue(shim?.hasPrefix(tmp.path) ?? false, "ZDOTDIR must be the generated shim dir")
        XCTAssertNotEqual(shim, home.path)
        // The real ZDOTDIR defaults to HOME when the parent has no explicit ZDOTDIR.
        XCTAssertEqual(env?["SLOPDESK_REAL_ZDOTDIR"], home.path)
    }

    func testRealZDotDirHonoursInheritedZDotDir() {
        let zdot = makeHome()
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": makeTempDir().path, "ZDOTDIR": zdot.path],
            shellPath: "/bin/zsh",
            tmpDir: makeTempDir(),
        )
        XCTAssertEqual(
            overrides?["SLOPDESK_REAL_ZDOTDIR"],
            zdot.path,
            "an explicit inherited ZDOTDIR must win over HOME",
        )
    }

    // MARK: New-install guard (kitty parity)

    /// kitty's `is_new_zsh_install` guard: when the user has NO zsh startup files at all
    /// (`.zshrc`/`.zshenv`/`.zprofile`/`.zlogin` in the effective real ZDOTDIR), injecting the shim
    /// would suppress `zsh-newuser-install` (zsh only offers it when no `.zshrc` resolves — and the
    /// shim dir always has one). Skip the shim so a fresh install still gets zsh's first-run setup.
    ///
    /// Revert-to-confirm-fail: on the un-guarded code this fails (a shim is created for the empty home).
    func testSkipsShimForFreshZshInstall() {
        let emptyHome = makeTempDir()
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": emptyHome.path],
            shellPath: "/bin/zsh",
            tmpDir: makeTempDir(),
        )
        XCTAssertNil(overrides, "a home with zero zsh startup files must not be shimmed (zsh-newuser-install)")
    }

    /// ANY of the four startup files marks an established install — the shim must engage.
    func testShimsWhenAnyStartupFileExists() {
        for rc in [".zshrc", ".zshenv", ".zprofile", ".zlogin"] {
            let overrides = ShellIntegration.makeEnvironmentOverrides(
                parent: ["HOME": makeHome(rcFiles: [rc]).path],
                shellPath: "/bin/zsh",
                tmpDir: makeTempDir(),
            )
            XCTAssertNotNil(overrides, "a home with \(rc) is an established install — shim must engage")
        }
    }

    /// The guard checks the EFFECTIVE real dir: an inherited ZDOTDIR holding the rc files must
    /// count even when $HOME itself is empty.
    func testNewInstallGuardHonoursInheritedZDotDir() {
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": makeTempDir().path, "ZDOTDIR": makeHome().path],
            shellPath: "/bin/zsh",
            tmpDir: makeTempDir(),
        )
        XCTAssertNotNil(overrides, "rc files in an inherited ZDOTDIR mark an established install")
    }

    // MARK: /etc/zshenv ZDOTDIR-override detection (kitty parity)

    /// A system `/etc/zshenv` that reassigns `ZDOTDIR` runs BEFORE `$ZDOTDIR/.zshenv` is resolved,
    /// so the injected shim would never load — integration silently dark. The survival probe must
    /// detect the stomp and skip the shim with a warning instead of shipping dead weight.
    ///
    /// Revert-to-confirm-fail: on the un-guarded code this fails (a shim is created regardless).
    func testEtcZshenvOverrideSkipsShimWithWarning() throws {
        let etc = makeTempDir().appendingPathComponent("zshenv")
        try Data().write(to: etc)
        var warned: [String] = []
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": makeHome().path],
            shellPath: "/bin/zsh",
            tmpDir: makeTempDir(),
            etcZshenvPath: etc.path,
            probe: { _, _ in "/somewhere/else" }, // sentinel did NOT survive
            warn: { warned.append($0) },
        )
        XCTAssertNil(overrides, "a stomped sentinel means the shim would never load — must skip")
        XCTAssertEqual(warned.count, 1, "the skip must be surfaced, never silent")
        XCTAssertTrue(warned[0].contains("ZDOTDIR"), "the warning must name the mechanism")
    }

    /// A benign `/etc/zshenv` (present but preserving `ZDOTDIR`) must keep the shim ON — the probe
    /// echoes the sentinel back and injection proceeds exactly as with no `/etc/zshenv` at all.
    func testEtcZshenvPreservingZDotDirKeepsShim() throws {
        let etc = makeTempDir().appendingPathComponent("zshenv")
        try Data().write(to: etc)
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": makeHome().path],
            shellPath: "/bin/zsh",
            tmpDir: makeTempDir(),
            etcZshenvPath: etc.path,
            probe: { _, env in env["ZDOTDIR"] }, // sentinel survives; unset-probe reports unset
        )
        XCTAssertNotNil(overrides, "a preserving /etc/zshenv must not disable the shim")
    }

    /// A probe FAILURE (spawn error / timeout → nil) must fail OPEN: shim on, status quo — a broken
    /// probe must never degrade integration below today's behavior.
    func testProbeFailureFailsOpen() throws {
        let etc = makeTempDir().appendingPathComponent("zshenv")
        try Data().write(to: etc)
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": makeHome().path],
            shellPath: "/bin/zsh",
            tmpDir: makeTempDir(),
            etcZshenvPath: etc.path,
            probe: { _, _ in nil },
        )
        XCTAssertNotNil(overrides, "a failed probe must fail open (shim on)")
    }

    /// An only-if-unset `/etc/zshenv` (`[ -z "$ZDOTDIR" ] && export ZDOTDIR=…`) leaves our injected
    /// value alone — but for a NORMAL shell it picks the user's real config dir. The shim must
    /// forward `SLOPDESK_REAL_ZDOTDIR` to THAT dir (discovered by the unset-env probe), not to a
    /// bare `$HOME` whose rc files don't exist — otherwise the user's real config never loads.
    func testOnlyIfUnsetEtcZshenvRedirectsRealZDotDirToDiscoveredDir() throws {
        let etc = makeTempDir().appendingPathComponent("zshenv")
        try Data().write(to: etc)
        let configDir = makeHome() // the dir /etc/zshenv would pick; holds the rc files
        let emptyHome = makeTempDir()
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": emptyHome.path],
            shellPath: "/bin/zsh",
            tmpDir: makeTempDir(),
            etcZshenvPath: etc.path,
            // Mimics only-if-unset: an injected ZDOTDIR survives; unset → the config dir.
            probe: { _, env in env["ZDOTDIR"] ?? configDir.path },
        )
        XCTAssertEqual(
            overrides?["SLOPDESK_REAL_ZDOTDIR"],
            configDir.path,
            "the discovered only-if-unset dir must become the forwarded real ZDOTDIR",
        )
    }

    /// An explicit inherited ZDOTDIR must SKIP the discovery probe — the operator's value wins
    /// (mirrors the realZDotDir precedence) and no second subprocess is spent.
    func testInheritedZDotDirSkipsDiscoveryProbe() throws {
        let etc = makeTempDir().appendingPathComponent("zshenv")
        try Data().write(to: etc)
        let zdot = makeHome()
        var unsetProbes = 0
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": makeTempDir().path, "ZDOTDIR": zdot.path],
            shellPath: "/bin/zsh",
            tmpDir: makeTempDir(),
            etcZshenvPath: etc.path,
            probe: { _, env in
                if env["ZDOTDIR"] == nil { unsetProbes += 1 }
                return env["ZDOTDIR"]
            },
        )
        XCTAssertEqual(overrides?["SLOPDESK_REAL_ZDOTDIR"], zdot.path)
        XCTAssertEqual(unsetProbes, 0, "an explicit inherited ZDOTDIR must skip the discovery probe")
    }

    /// No `/etc/zshenv` (stock macOS) → ZERO probes: the common path must not spawn any subprocess.
    func testNoProbeWhenEtcZshenvAbsent() {
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": makeHome().path],
            shellPath: "/bin/zsh",
            tmpDir: makeTempDir(),
            etcZshenvPath: makeTempDir().appendingPathComponent("zshenv").path, // never written
            probe: { _, _ in
                XCTFail("no probe may run when /etc/zshenv is absent")
                return nil
            },
        )
        XCTAssertNotNil(overrides)
    }

    /// The REAL subprocess probe against the system zsh: an injected sentinel `ZDOTDIR` must echo
    /// back verbatim. Skipped on hosts whose actual `/etc/zshenv` exists (it could legitimately
    /// reassign and the assertion would be about that machine, not our code).
    func testRealProbeEchoesInjectedZDotDir() throws {
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: "/etc/zshenv"),
            "host has a real /etc/zshenv — sentinel survival is machine-dependent here",
        )
        let out = ShellIntegration.probeZDotDir(
            shellPath: "/bin/zsh",
            environment: ["ZDOTDIR": "/nonexistent-slopdesk-probe-echo", "HOME": NSHomeDirectory()],
        )
        XCTAssertEqual(out, "/nonexistent-slopdesk-probe-echo", "the probe must echo $ZDOTDIR from a real zsh")
    }

    // MARK: Generated shim files

    func testShimDirContainsAllFourStartupFiles() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let fm = FileManager.default
        for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            XCTAssertTrue(
                fm.fileExists(atPath: dir.appendingPathComponent(name).path),
                "shim is missing \(name)",
            )
        }
    }

    func testZshrcInstallsChainedResetPromptWinchHook() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        // Sources the user's real .zshrc (so p10k etc. still load).
        XCTAssertTrue(zshrc.contains("$__slopdesk_real/.zshrc"), "must source the real .zshrc")
        // Chains any pre-existing TRAPWINCH, then unconditionally reset-prompt under ZLE.
        XCTAssertTrue(
            zshrc.contains("functions[__slopdesk_user_winch]=$functions[TRAPWINCH]"),
            "must chain the user's existing TRAPWINCH",
        )
        XCTAssertTrue(zshrc.contains("TRAPWINCH()"), "must define a TRAPWINCH wrapper")
        XCTAssertTrue(
            zshrc.contains("zle && zle reset-prompt"),
            "must redraw via reset-prompt guarded by an active ZLE",
        )
        // Restores ZDOTDIR so the running shell sees its real env.
        XCTAssertTrue(
            zshrc.contains("ZDOTDIR=\"$__slopdesk_real\"") || zshrc.contains("unset ZDOTDIR"),
            "must restore the user's real ZDOTDIR",
        )
    }

    /// macOS's system `/etc/zshrc` runs between our shim's
    /// `.zprofile` and `.zshrc` with `ZDOTDIR` STILL pointed at the throwaway shim dir, and sets
    /// `HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history` — so Ctrl-R history recall + zsh-autosuggestions
    /// (both read `$HISTFILE`) silently aimed at an always-empty per-session file. The shim's `.zshrc`
    /// must redirect a shim-relative `HISTFILE` back to the user's real ZDOTDIR BEFORE sourcing the
    /// user's rc (so the real history loads), without clobbering a user-set HISTFILE.
    func testZshrcRedirectsShimRelativeHistfileToRealDir() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        // Guards on the shim-dir prefix and rewrites to the real dir keeping the basename.
        XCTAssertTrue(
            zshrc.contains("\"$__slopdesk_shim\"/*)"),
            "must match a HISTFILE that points INTO the shim dir",
        )
        XCTAssertTrue(
            zshrc.contains("HISTFILE=\"${__slopdesk_real%/}/${HISTFILE##*/}\""),
            "must redirect the shim-relative HISTFILE to the real ZDOTDIR, same basename",
        )
        // The redirect must come BEFORE the user's real .zshrc is sourced (so history loads from the
        // real file and a user HISTFILE override in their rc still wins).
        let caseIdx = try XCTUnwrap(zshrc.range(of: "${HISTFILE##*/}"))
        let sourceIdx = try XCTUnwrap(zshrc.range(of: "$__slopdesk_real/.zshrc"))
        XCTAssertTrue(
            caseIdx.lowerBound < sourceIdx.lowerBound,
            "HISTFILE repair must precede sourcing the user's real .zshrc",
        )
    }

    // MARK: OSC 133 shell integration

    func testZshrcInstallsOSC133HooksViaAddZshHook() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        // Composes with the user's hooks via add-zsh-hook (APPENDS, never overwrites).
        XCTAssertTrue(
            zshrc.contains("autoload -Uz add-zsh-hook"),
            "must autoload add-zsh-hook",
        )
        XCTAssertTrue(
            zshrc.contains("add-zsh-hook preexec __slopdesk_osc133_preexec"),
            "must register the preexec hook via add-zsh-hook",
        )
        XCTAssertTrue(
            zshrc.contains("add-zsh-hook precmd  __slopdesk_osc133_precmd")
                || zshrc.contains("add-zsh-hook precmd __slopdesk_osc133_precmd"),
            "must register the precmd hook via add-zsh-hook",
        )
        // Emits the C (preexec), D / A (precmd), and B (prompt-end / command-start) marks.
        XCTAssertTrue(zshrc.contains("133;C"), "preexec must emit OSC 133;C")
        XCTAssertTrue(zshrc.contains("133;D;%s"), "precmd must emit OSC 133;D;<exit>")
        XCTAssertTrue(zshrc.contains("133;A"), "precmd must emit OSC 133;A")
        XCTAssertTrue(zshrc.contains("133;B"), "precmd must emit OSC 133;B (end of prompt / start of input)")
    }

    /// `preexec` must report the EXACT command line via `133;E;%s` (from `$1`) BEFORE `C`, so the
    /// host does not reconstruct commandText from the redraw-polluted echo. Pins the escape helper is defined,
    /// invoked with `$1`, and that the E mark's payload is the escaped command (`%s`), emitted before C.
    func testZshrcPreexecEmitsExplicitCommandLineMark() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        XCTAssertTrue(
            zshrc.contains("\\033]133;E;%s\\007"),
            "preexec must printf the explicit command-line mark 133;E;<escaped> with literal octal escapes",
        )
        XCTAssertTrue(
            zshrc.contains("__slopdesk_osc133_escape \"$1\""),
            "preexec must escape the exact typed command ($1) before emitting E",
        )
        XCTAssertTrue(
            zshrc.contains("__slopdesk_osc133_escape()"),
            "the byte-wise command-line escape helper must be defined",
        )
        // The escape must map the dangerous bytes to \\xNN and NOTHING must let a raw ';' / ESC / BEL leak
        // into the payload (they would split the field or terminate the OSC).
        for token in ["\\x5c", "\\x3b", "\\x1b", "\\x07", "\\x0d", "\\x0a"] {
            XCTAssertTrue(zshrc.contains(token), "escape must encode a special byte as \(token)")
        }
        // Byte-wise, locale-independent processing (VS Code's approach) so UTF-8 round-trips exactly.
        XCTAssertTrue(zshrc.contains("local LC_ALL=C"), "the escape must process bytes under LC_ALL=C")
        // E must precede C in the preexec body (the host opens the block, sets the command, THEN starts output).
        let eRange = try XCTUnwrap(zshrc.range(of: "133;E;%s"))
        let preexecTail = zshrc[eRange.upperBound...]
        XCTAssertTrue(preexecTail.contains("133;C"), "the E mark must be emitted BEFORE the C mark")
    }

    /// REGRESSION (live-host bug): the printf escapes must reach the shell as the LITERAL text
    /// `\033` / `\007` (backslash-zero-three-three), NOT as a Swift `\0` NUL escape + "33". If the
    /// source were written `\033` (single backslash) Swift would compile it to a NUL byte + "33",
    /// the shell would `printf` a corrupt ` 33]133;C 07` (no ESC/BEL), and the host OSC 133 parser
    /// would NEVER recognize the marks (running/idle silently broken). Pin the literal bytes.
    func testZshrcOSC133EscapesAreShellLiteralsNotSwiftNUL() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        // The shell text must contain a real backslash-0-3-3 / backslash-0-0-7 octal escape.
        XCTAssertTrue(
            zshrc.contains("\\033]133;C\\007"),
            "preexec C must printf the literal \\033...\\007 octal escapes",
        )
        XCTAssertTrue(
            zshrc.contains("\\033]133;D;%s\\007"),
            "precmd D must printf the literal \\033...\\007 octal escapes",
        )
        XCTAssertTrue(
            zshrc.contains("\\033]133;A\\007"),
            "precmd A must printf the literal \\033...\\007 octal escapes",
        )
        // And crucially: NO embedded NUL byte (the symptom of a Swift `\0` mis-escape).
        XCTAssertFalse(
            zshrc.utf8.contains(0),
            "the generated .zshrc must not contain a NUL byte (Swift \\0 mis-escape)",
        )
    }

    func testZshrcCapturesExitCodeFirstInPrecmd() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        // The FIRST statement of the precmd function must capture $? before anything clobbers it.
        guard let funcRange = zshrc.range(of: "__slopdesk_osc133_precmd() {") else {
            XCTFail("precmd function not found")
            return
        }
        let afterBrace = zshrc[funcRange.upperBound...]
        let firstNonEmptyLine = afterBrace
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        XCTAssertEqual(
            firstNonEmptyLine,
            "local __slopdesk_exit=$?",
            "precmd must capture $? as its very first statement",
        )
    }

    func testZshrcDoesNotClobberUserPrecmdOrPreexec() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        // A bare `precmd()`/`preexec()` redefinition would OVERWRITE starship's hooks — we must
        // only define our PREFIXED functions and register them via add-zsh-hook.
        XCTAssertFalse(zshrc.contains("\nprecmd()"), "must not define a bare precmd() (would clobber starship)")
        XCTAssertFalse(zshrc.contains("\npreexec()"), "must not define a bare preexec() (would clobber starship)")
    }

    func testZshrcOSC133IsGatedBySlopDeskOSC133() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        // A finer opt-out keeping the resize fix: SLOPDESK_OSC133=0 skips just the marks.
        XCTAssertTrue(
            zshrc.contains("SLOPDESK_OSC133"),
            "OSC 133 emission must be gated by SLOPDESK_OSC133",
        )
        XCTAssertTrue(
            zshrc.contains("0|false|no|off"),
            "SLOPDESK_OSC133 must accept the standard falsy opt-out values",
        )
    }

    /// OSC 133 B mark: the host CommandBlockSegmenter captures bytes between B and C as
    /// `commandText`. B must fire AFTER the prompt is drawn (not before it), so it uses
    /// `PROMPT+=` — bytes between B and C are then only the echoed command, not the prompt text.
    ///
    /// Revert-to-confirm-fail: on the un-fixed code this test fails because `133;B` is absent.
    func testZshrcOSC133BMarkIsAppendedToPromptAfterA() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        // The B mark must be present.
        XCTAssertTrue(zshrc.contains("133;B"), "zshrc must emit OSC 133;B")
        // B must be appended to $PROMPT via a STANDALONE `$'…'` token so zsh stores the REAL ESC/BEL
        // bytes. (It fires at the end of the rendered prompt, after the prompt text — NOT printed before
        // the prompt, which would leak the prompt text into commandText.)
        XCTAssertTrue(
            zshrc.contains("PROMPT+=$'%{\\033]133;B\\007%}'"),
            "B must be appended via a standalone $'…' token (real ESC/BEL bytes)",
        )
        // Regression guard (revert-to-confirm-fail): the old `PROMPT+="%{$'…'%}"` form put $'…' inside
        // DOUBLE quotes, where zsh does NOT ANSI-C-expand it — the LITERAL text $'\033]133;B\007' leaked
        // onto the prompt line (visible junk) and, wrapped in zero-width %{…%}, corrupted column math.
        XCTAssertFalse(
            zshrc.contains("PROMPT+=\"%{$'"),
            "B must NOT use the double-quoted \"%{$'…'%}\" form ($'…' is not expanded inside double quotes)",
        )
        // The PROMPT+= must appear INSIDE the precmd function and AFTER the A mark emit — A first,
        // then prompt rendered, then B (at the end of the prompt) — so the OSC bytes arrive in the
        // correct order in the PTY stream.
        guard let precmdRange = zshrc.range(of: "__slopdesk_osc133_precmd()") else {
            XCTFail("precmd function not found in zshrc")
            return
        }
        let afterPrecmd = zshrc[precmdRange.lowerBound...]
        guard let aRange = afterPrecmd.range(of: "133;A"),
              let bRange = afterPrecmd.range(of: "133;B")
        else {
            XCTFail("A or B mark not found in zshrc after precmd definition")
            return
        }
        XCTAssertTrue(
            aRange.lowerBound < bRange.lowerBound,
            "A must appear before B in the precmd body (A for prompt-start, B for prompt-end)",
        )
    }

    // MARK: Cursor-shape shell integration (ghostty/kitty parity)

    /// The ghostty/kitty "cursor" shell-integration feature: a BAR caret at the prompt (no foreground
    /// command), restored to the configured default (block) while a command runs. precmd emits
    /// DECSCUSR 5 (blinking bar — ghostty's exact sequence) right before the prompt draws; preexec
    /// emits DECSCUSR 0 (reset to the terminal's configured `cursor-style`) as the command starts.
    /// libghostty on the client handles DECSCUSR natively, so the shim only has to emit the bytes.
    ///
    /// Revert-to-confirm-fail: on the un-fixed shim this fails because no DECSCUSR is emitted.
    func testZshrcInstallsCursorShapeHooksViaAddZshHook() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        // Registered via add-zsh-hook (composes with starship/omz/p10k — never a bare precmd()).
        XCTAssertTrue(
            zshrc.contains("add-zsh-hook precmd  __slopdesk_cursor_precmd")
                || zshrc.contains("add-zsh-hook precmd __slopdesk_cursor_precmd"),
            "must register the cursor precmd hook via add-zsh-hook",
        )
        XCTAssertTrue(
            zshrc.contains("add-zsh-hook preexec __slopdesk_cursor_preexec"),
            "must register the cursor preexec hook via add-zsh-hook",
        )
        // precmd → blinking bar (DECSCUSR 5); preexec → reset to configured default (DECSCUSR 0).
        // Literal octal escapes (\\033) — same shell-literal rule as the OSC 133 marks.
        guard let precmdRange = zshrc.range(of: "__slopdesk_cursor_precmd()") else {
            XCTFail("cursor precmd function not found")
            return
        }
        let precmdBody = zshrc[precmdRange.upperBound...].prefix(while: { $0 != "}" })
        XCTAssertTrue(
            precmdBody.contains("\\033[5 q"),
            "the cursor precmd must emit DECSCUSR 5 (blinking bar at the prompt)",
        )
        guard let preexecRange = zshrc.range(of: "__slopdesk_cursor_preexec()") else {
            XCTFail("cursor preexec function not found")
            return
        }
        let preexecBody = zshrc[preexecRange.upperBound...].prefix(while: { $0 != "}" })
        XCTAssertTrue(
            preexecBody.contains("\\033[0 q"),
            "the cursor preexec must emit DECSCUSR 0 (reset to the configured default while a command runs)",
        )
    }

    /// A marks-independent opt-out: `SLOPDESK_SHELL_CURSOR=0` disables JUST the cursor-shape
    /// feature (OSC 133 marks and the resize reprint fix stay on), mirroring the SLOPDESK_OSC133
    /// idiom (`${…:-1}` default-ON, standard falsy values disable, evaluated in the CHILD shell).
    func testZshrcCursorShapeIsGatedBySlopDeskShellCursor() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        XCTAssertTrue(
            zshrc.contains("case \"${SLOPDESK_SHELL_CURSOR:-1}\" in"),
            "cursor-shape emission must be gated by SLOPDESK_SHELL_CURSOR, default-ON",
        )
        // The gate must accept the standard falsy opt-out values inside ITS OWN case (not just the
        // OSC 133 gate's): assert the falsy arm appears after the cursor gate.
        let gateRange = try XCTUnwrap(zshrc.range(of: "case \"${SLOPDESK_SHELL_CURSOR:-1}\" in"))
        let afterGate = zshrc[gateRange.upperBound...]
        XCTAssertTrue(
            afterGate.contains("0|false|no|off"),
            "SLOPDESK_SHELL_CURSOR must accept the standard falsy opt-out values",
        )
    }

    func testZshrcKeepsResizeReprintFixAlongsideOSC133() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        // The ctty/resize reprint fix (TRAPWINCH + reset-prompt) must remain intact — OSC 133 is
        // purely additive, never a replacement.
        XCTAssertTrue(zshrc.contains("TRAPWINCH()"), "the resize TRAPWINCH hook must still be installed")
        XCTAssertTrue(zshrc.contains("zle && zle reset-prompt"), "the reset-prompt reprint must still be present")
    }

    func testEnvShimsForwardRealStartupFilesAndReassertZDotDir() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        for name in [".zshenv", ".zprofile", ".zlogin"] {
            let body = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(
                body.contains("source \"$__slopdesk_real/\(name)\""),
                "\(name) must forward to the real \(name)",
            )
            XCTAssertTrue(
                body.contains("ZDOTDIR=\"$__slopdesk_shim\""),
                "\(name) must re-assert ZDOTDIR back to the shim for the next file",
            )
        }
    }

    /// The common XDG-layout `~/.zshenv` that `export ZDOTDIR="$HOME/.config/zsh"` reassigns
    /// the real dir. Each shim file that sources a user startup file must RE-CAPTURE a reassigned
    /// `ZDOTDIR` back into `SLOPDESK_REAL_ZDOTDIR` (exported, so the NEXT shim file sees it) — before it
    /// re-asserts `ZDOTDIR` to the shim. Without this, `.zprofile`/`.zshrc`/`.zlogin` forward to the stale
    /// `$HOME` and the user's real rc files under `~/.config/zsh` never load (bare default shell).
    func testShimRecapturesReassignedRealZDotDir() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        for name in [".zshenv", ".zprofile", ".zlogin"] {
            let body = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(
                body.contains("export SLOPDESK_REAL_ZDOTDIR"),
                "\(name) must re-export a reassigned real ZDOTDIR so later shim files forward to it",
            )
            // The re-capture must happen AFTER sourcing the user file (so it sees the reassignment) and
            // BEFORE re-asserting ZDOTDIR to the shim (so it reads the user's value, not ours).
            let sourceIdx = try XCTUnwrap(body.range(of: "source \"$__slopdesk_real/\(name)\""))
            let recaptureIdx = try XCTUnwrap(body.range(of: "export SLOPDESK_REAL_ZDOTDIR"))
            let reassertIdx = try XCTUnwrap(body.range(of: "ZDOTDIR=\"$__slopdesk_shim\""))
            XCTAssertTrue(sourceIdx.lowerBound < recaptureIdx.lowerBound, "\(name): re-capture must follow the source")
            XCTAssertTrue(
                recaptureIdx.lowerBound < reassertIdx.lowerBound,
                "\(name): re-capture must precede the reassert",
            )
        }
        // The .zshrc likewise re-captures a real-.zshrc reassignment so its final restore + .zlogin land
        // on the user's real dir, not the stale one.
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        XCTAssertTrue(
            zshrc.contains("export SLOPDESK_REAL_ZDOTDIR"),
            ".zshrc must re-capture a reassigned real ZDOTDIR",
        )
    }

    func testEachCallGeneratesAFreshShimDir() {
        let tmp = makeTempDir()
        let home = makeHome().path
        let a = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": home], shellPath: "/bin/zsh", tmpDir: tmp,
        )?["ZDOTDIR"]
        let b = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": home], shellPath: "/bin/zsh", tmpDir: tmp,
        )?["ZDOTDIR"]
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b, "each session must get its own shim dir")
    }
}
