import XCTest
@testable import AislopdeskHost

/// WF4: the zsh shell-integration shim (generated ZDOTDIR) that forces a post-resize prompt
/// reprint. Deterministic + HostServer-free: pure string assembly + temp-dir file writes.
final class ShellIntegrationTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aislopdesk-si-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Opt-out gate

    func testEnabledByDefault() {
        XCTAssertTrue(ShellIntegration.isEnabled(parent: [:]))
        XCTAssertTrue(ShellIntegration.isEnabled(parent: ["AISLOPDESK_SHELL_INTEGRATION": "1"]))
        XCTAssertTrue(ShellIntegration.isEnabled(parent: ["AISLOPDESK_SHELL_INTEGRATION": "yes"]))
    }

    func testDisabledByFalsyOptOut() {
        for value in ["0", "false", "no", "off", "OFF", "False", "No"] {
            XCTAssertFalse(
                ShellIntegration.isEnabled(parent: ["AISLOPDESK_SHELL_INTEGRATION": value]),
                "AISLOPDESK_SHELL_INTEGRATION=\(value) must disable the shim",
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
            parent: ["HOME": "/Users/x"],
            shellPath: "/bin/bash",
            tmpDir: makeTempDir(),
        )
        XCTAssertNil(overrides, "a non-zsh shell must not get a ZDOTDIR shim")
    }

    func testNoOverridesWhenOptedOut() {
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": "/Users/x", "AISLOPDESK_SHELL_INTEGRATION": "0"],
            shellPath: "/bin/zsh",
            tmpDir: makeTempDir(),
        )
        XCTAssertNil(overrides, "opt-out must skip the shim entirely")
    }

    func testOverridesPointZDotDirAtFreshShimAndCarryRealZDotDir() {
        let tmp = makeTempDir()
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": "/Users/x"],
            shellPath: "/bin/zsh",
            tmpDir: tmp,
        )
        let env = try? XCTUnwrap(overrides)
        let shim = try? XCTUnwrap(env?["ZDOTDIR"])
        XCTAssertNotNil(shim)
        // The shim is a fresh subdir of tmp, not the user's HOME.
        XCTAssertTrue(shim?.hasPrefix(tmp.path) ?? false, "ZDOTDIR must be the generated shim dir")
        XCTAssertNotEqual(shim, "/Users/x")
        // The real ZDOTDIR defaults to HOME when the parent has no explicit ZDOTDIR.
        XCTAssertEqual(env?["AISLOPDESK_REAL_ZDOTDIR"], "/Users/x")
    }

    func testRealZDotDirHonoursInheritedZDotDir() {
        let overrides = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": "/Users/x", "ZDOTDIR": "/Users/x/.config/zsh"],
            shellPath: "/bin/zsh",
            tmpDir: makeTempDir(),
        )
        XCTAssertEqual(
            overrides?["AISLOPDESK_REAL_ZDOTDIR"],
            "/Users/x/.config/zsh",
            "an explicit inherited ZDOTDIR must win over HOME",
        )
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
        XCTAssertTrue(zshrc.contains("$__aislopdesk_real/.zshrc"), "must source the real .zshrc")
        // Chains any pre-existing TRAPWINCH, then unconditionally reset-prompt under ZLE.
        XCTAssertTrue(
            zshrc.contains("functions[__aislopdesk_user_winch]=$functions[TRAPWINCH]"),
            "must chain the user's existing TRAPWINCH",
        )
        XCTAssertTrue(zshrc.contains("TRAPWINCH()"), "must define a TRAPWINCH wrapper")
        XCTAssertTrue(
            zshrc.contains("zle && zle reset-prompt"),
            "must redraw via reset-prompt guarded by an active ZLE",
        )
        // Restores ZDOTDIR so the running shell sees its real env.
        XCTAssertTrue(
            zshrc.contains("ZDOTDIR=\"$__aislopdesk_real\"") || zshrc.contains("unset ZDOTDIR"),
            "must restore the user's real ZDOTDIR",
        )
    }

    /// REGRESSION (live-host bug, 2026-06-07): macOS's system `/etc/zshrc` runs between our shim's
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
            zshrc.contains("\"$__aislopdesk_shim\"/*)"),
            "must match a HISTFILE that points INTO the shim dir",
        )
        XCTAssertTrue(
            zshrc.contains("HISTFILE=\"${__aislopdesk_real%/}/${HISTFILE##*/}\""),
            "must redirect the shim-relative HISTFILE to the real ZDOTDIR, same basename",
        )
        // The redirect must come BEFORE the user's real .zshrc is sourced (so history loads from the
        // real file and a user HISTFILE override in their rc still wins).
        let caseIdx = try XCTUnwrap(zshrc.range(of: "${HISTFILE##*/}"))
        let sourceIdx = try XCTUnwrap(zshrc.range(of: "$__aislopdesk_real/.zshrc"))
        XCTAssertTrue(
            caseIdx.lowerBound < sourceIdx.lowerBound,
            "HISTFILE repair must precede sourcing the user's real .zshrc",
        )
    }

    // MARK: OSC 133 shell integration (WF11)

    func testZshrcInstallsOSC133HooksViaAddZshHook() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        // Composes with the user's hooks via add-zsh-hook (APPENDS, never overwrites).
        XCTAssertTrue(
            zshrc.contains("autoload -Uz add-zsh-hook"),
            "must autoload add-zsh-hook",
        )
        XCTAssertTrue(
            zshrc.contains("add-zsh-hook preexec __aislopdesk_osc133_preexec"),
            "must register the preexec hook via add-zsh-hook",
        )
        XCTAssertTrue(
            zshrc.contains("add-zsh-hook precmd  __aislopdesk_osc133_precmd")
                || zshrc.contains("add-zsh-hook precmd __aislopdesk_osc133_precmd"),
            "must register the precmd hook via add-zsh-hook",
        )
        // Emits the C (preexec) and D / A (precmd) marks.
        XCTAssertTrue(zshrc.contains("133;C"), "preexec must emit OSC 133;C")
        XCTAssertTrue(zshrc.contains("133;D;%s"), "precmd must emit OSC 133;D;<exit>")
        XCTAssertTrue(zshrc.contains("133;A"), "precmd must emit OSC 133;A")
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
        guard let funcRange = zshrc.range(of: "__aislopdesk_osc133_precmd() {") else {
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
            "local __aislopdesk_exit=$?",
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

    func testZshrcOSC133IsGatedByAislopdeskOSC133() throws {
        let dir = try XCTUnwrap(ShellIntegration.writeShimDirectory(into: makeTempDir()))
        let zshrc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        // A finer opt-out keeping the resize fix: AISLOPDESK_OSC133=0 skips just the marks.
        XCTAssertTrue(
            zshrc.contains("AISLOPDESK_OSC133"),
            "OSC 133 emission must be gated by AISLOPDESK_OSC133",
        )
        XCTAssertTrue(
            zshrc.contains("0|false|no|off"),
            "AISLOPDESK_OSC133 must accept the standard falsy opt-out values",
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
                body.contains("source \"$__aislopdesk_real/\(name)\""),
                "\(name) must forward to the real \(name)",
            )
            XCTAssertTrue(
                body.contains("ZDOTDIR=\"$__aislopdesk_shim\""),
                "\(name) must re-assert ZDOTDIR back to the shim for the next file",
            )
        }
    }

    func testEachCallGeneratesAFreshShimDir() {
        let tmp = makeTempDir()
        let a = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": "/Users/x"], shellPath: "/bin/zsh", tmpDir: tmp,
        )?["ZDOTDIR"]
        let b = ShellIntegration.makeEnvironmentOverrides(
            parent: ["HOME": "/Users/x"], shellPath: "/bin/zsh", tmpDir: tmp,
        )?["ZDOTDIR"]
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b, "each session must get its own shim dir")
    }
}
