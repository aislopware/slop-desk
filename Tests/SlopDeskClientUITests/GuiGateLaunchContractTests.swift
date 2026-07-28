import Foundation
import XCTest

/// The one thing every GUI gate must do when it execs `SlopDesk.app`'s binary directly.
///
/// `check-macos.sh`, `check-video.sh` and `check-multiclient.sh` all launch the bundle binary rather
/// than `open`ing it, because LaunchServices does not forward the shell environment and the whole
/// automation seam is `SLOPDESK_*` env vars. That launch has one non-obvious requirement:
/// `-ApplePersistenceIgnoreState YES`. Without it AppKit brings the app up on its persistence path
/// and the app runs with **zero windows** — no window means no scene, and every seam these gates
/// depend on is a scene `.task`: the auto-connect, the workspace-document channel, the video pane.
/// The process sits happily in its run loop with no UI, no TCP and no UDP, and both gates then
/// "prove" whatever the desktop happened to look like.
///
/// RED before the fix: `check-video.sh` omitted the flag, so the first hardware run of the video
/// gate after the docs/45 cutover produced no client window, no session on the terminal daemon that
/// owns the workspace document, no UDP flow, and an empty client log — while still printing DONE.
/// (HW-confirmed 2026-07-28: `YES` ⇒ window + session + frames; omitted or `NO` ⇒ 0 windows, every
/// time.) `check-macos.sh` carried the flag and a comment explaining it; nothing made that a rule.
///
/// A text-level contract over a shell script is unusual, and deliberate: these gates only ever run
/// on real hardware from an Aqua session, so a silent regression in one costs a whole GUI cycle to
/// notice. The same discipline as `HostOutputSnifferGoldenGuardTests` reading the committed corpus
/// out of the working tree.
final class GuiGateLaunchContractTests: XCTestCase {
    /// Every script under `scripts/` that brings up `SlopDesk.app` — DISCOVERED, never listed.
    ///
    /// `scripts/` sits beside `Tests/` in the package root, so walk up from this file rather than
    /// relying on a bundle resource (a script is not a SwiftPM resource; it is a working-tree
    /// artefact).
    ///
    /// The daemon contract below derives its subjects this way and the derivation immediately found a
    /// sixth daemon launch a hardcoded list had missed. The client side carried the list the whole
    /// time, and a list only covers the gates somebody remembered to add to it: a new script that
    /// execs the bundle binary escaped every isolation pin at once — no `CFFIXED_USER_HOME`, no
    /// private `UserDefaults` suite, no `-ApplePersistenceIgnoreState YES` — and was free to dial the
    /// developer's own live `slopdesk-hostd`. Deriving the set means the pins arrive with the script.
    ///
    /// Two ways to bring the app up and both are subjects: an exec of the bundle binary (which is
    /// what these gates do, because LaunchServices forwards no environment) and an `open` of the
    /// bundle (which ``testNoGateLaunchesTheAppThroughOpen`` exists to ban — it has to be able to SEE
    /// the script to ban it).
    ///
    /// RED when this was first derived rather than listed: a throwaway `scripts/*.sh` that execs
    /// `"${APP_BIN}"` bare is named by six separate assertions. Under the list it was named by none.
    private func appLaunchingScripts() throws -> [String] {
        let scripts = try FileManager.default
            .contentsOfDirectory(atPath: scriptURL("scripts").path)
            .filter { $0.hasSuffix(".sh") }
            .sorted()
            .map { "scripts/\($0)" }
        XCTAssertFalse(scripts.isEmpty, "scripts/ holds no shell scripts — the walk found nothing to read")
        let discovered = try scripts.filter {
            try !launchCommands(of: $0, invoking: appBinaryTokens(of: $0)).isEmpty
                || !openLaunchLines(of: $0).isEmpty
        }
        // A CANARY, not the subject set. Six contracts iterate this list, so a derivation that matched
        // NOTHING would leave all six green while pinning nothing at all — the failure a list at least
        // fails loudly at. These four are known to bring the app up.
        for known in [
            "scripts/check-macos.sh",
            "scripts/check-video.sh",
            "scripts/check-multiclient.sh",
            "scripts/check-launch-restore.sh",
        ] {
            XCTAssertTrue(
                discovered.contains(known),
                "\(known) launches the app and the walk over scripts/ did not find it — the discovery "
                    + "is broken, and a contract that silently reads nothing passes",
            )
        }
        return discovered
    }

    /// Every shell token in `script` that denotes the app's bundle binary: the literal path inside the
    /// bundle, plus `"${VAR}"` for any variable assigned one — the same indirection the daemon side
    /// needs, because every gate today launches through an `APP_BIN=…` assignment and a rule that
    /// knew only the literal would read the ASSIGNMENT and never the exec.
    private func appBinaryTokens(of script: String) throws -> [String] {
        let marker = "Contents/MacOS/SlopDesk"
        var tokens = [marker]
        for line in try codeBody(of: script).split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "="), trimmed.starts(with: /[A-Z_]/) else { continue }
            let name = String(trimmed[..<equals])
            guard name.allSatisfy({ $0.isUppercase || $0 == "_" }) else { continue }
            if trimmed[trimmed.index(after: equals)...].contains(marker) { tokens.append("\"${\(name)}\"") }
        }
        return tokens
    }

    /// The lines that hand the bundle to LaunchServices. Both the discovery signal for an
    /// `open`-only script and the offender list ``testNoGateLaunchesTheAppThroughOpen`` reports.
    private func openLaunchLines(of script: String) throws -> [String] {
        try codeBody(of: script)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("open \"${APP") || $0.contains("open \"") && $0.contains("SlopDesk.app") }
    }

    /// Every script under `scripts/` that stands up a HOST DAEMON — DISCOVERED, never listed.
    ///
    /// A hardcoded list is the exact shape of the defect this file exists for. The daemon-side
    /// isolation rule was written into `check-macos.sh`'s comments; the three gates that look like
    /// `check-macos.sh` copied it, and the two that do not — `soak-fanout-laggard.sh`, which looks
    /// like a soak, and `video-input-test.sh`, which looks like a manual harness — went without for
    /// months. A list has to be edited by the same person who forgot the rule. A directory does not:
    /// the moment a new `scripts/*.sh` execs `slopdesk-hostd` or `slopdesk-videohostd`, this contract
    /// picks it up and demands the isolation, whether or not anybody thought to say so.
    ///
    /// RED when this was first derived rather than listed: it found `scripts/video-input-test.sh`,
    /// a sixth daemon launch nobody had counted, running `slopdesk-videohostd` with no container at
    /// all.
    private func daemonLaunchingScripts() throws -> [String] {
        let scripts = try FileManager.default
            .contentsOfDirectory(atPath: scriptURL("scripts").path)
            .filter { $0.hasSuffix(".sh") }
            .sorted()
            .map { "scripts/\($0)" }
        XCTAssertFalse(scripts.isEmpty, "scripts/ holds no shell scripts — the walk found nothing to read")
        return try scripts.filter { try !launchCommands(of: $0, invoking: daemonBinaryTokens(of: $0)).isEmpty }
    }

    private func scriptURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SlopDeskClientUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <package root>
            .appendingPathComponent(relativePath)
    }

    /// A script with every comment line dropped — what it DOES, never what it says about itself.
    /// Load-bearing here: `check-multiclient.sh`'s header names the observation strategies it
    /// rejected, so a whole-file substring search would find `workspace-state.json` in the prose
    /// explaining why the gate must not read it.
    private func codeBody(of script: String) throws -> String {
        try String(contentsOf: scriptURL(script), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }

    /// REVERT-TO-FAIL: drop `-ApplePersistenceIgnoreState YES` from any gate's launch and this names
    /// the script and the launch.
    func testEveryDirectAppLaunchIgnoresPersistedState() throws {
        for script in try appLaunchingScripts() {
            let commands = try launchCommands(of: script, invoking: appBinaryTokens(of: script))
            XCTAssertFalse(
                commands.isEmpty,
                "\(script) brings the app up without ever exec'ing the bundle binary — `open` cannot "
                    + "forward the SLOPDESK_* automation env, so there is nothing here to isolate with.",
            )
            for command in commands {
                XCTAssertTrue(
                    command.contains("-ApplePersistenceIgnoreState YES"),
                    "\(script) execs the app binary without `-ApplePersistenceIgnoreState YES`, so the "
                        + "app launches with ZERO windows and every scene `.task` seam the gate depends "
                        + "on never runs. Offending launch: "
                        + command.trimmingCharacters(in: .whitespacesAndNewlines),
                )
            }
        }
    }

    /// The same contract from the other side: NO gate may launch the app through `open`.
    ///
    /// `open` cannot carry either half of the rule above. LaunchServices forwards no environment, so
    /// an `open`ed app is one the gate cannot address at all — no autoconnect, no control socket; and
    /// the flag would need `--args`. There is a third edge, and it is the nastiest: `open`ing an app
    /// that is ALREADY running with zero windows makes AppKit RE-OPEN one. `check-macos.sh` used
    /// `open "${APP}"` to raise the app for its screenshot, which repaired the exact failure the gate
    /// is meant to observe — one line before the grab, after every assertion had already passed.
    ///
    /// RED before the fix: `check-macos.sh`'s default and --renderer modes launched with
    /// `open "${APP}"` and no flag, and had no assertion that could notice either way.
    func testNoGateLaunchesTheAppThroughOpen() throws {
        for script in try appLaunchingScripts() {
            let offenders = try openLaunchLines(of: script)
            XCTAssertTrue(
                offenders.isEmpty,
                "\(script) launches (or raises) the app through `open`, which forwards no environment "
                    + "and silently re-opens a window for an app that has none. Offending line(s): "
                    + offenders.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ⏎ "),
            )
        }
    }

    /// The video gate's connectivity checks must be FATAL. It once observed the UDP flow, printed a
    /// warning when it was missing, and carried on to a screenshot — so a client that never dialled
    /// still exited 0. A gate that cannot go red on the failure it exists to catch is not a gate.
    ///
    /// Connectivity is only half of it: every one of those checks passes on a client that dialled and
    /// then rendered NOTHING (a VT session that errors out, a `CAMetalLayer` that never vends a
    /// drawable). So the decoded-frame and presented-frame assertions are pinned here too — they are
    /// the only thing between "the socket exists" and a human deciding to open a PNG.
    func testTheVideoGateFailsHardWhenNothingConnected() throws {
        let source = try String(contentsOf: scriptURL("scripts/check-video.sh"), encoding: .utf8)
        XCTAssertFalse(
            source.contains("WARN: did not observe a client→host UDP flow"),
            "a missing UDP flow must exit non-zero, not warn and screenshot the desktop",
        )
        for expected in [
            "FAIL: no client→host UDP flow", // the video leg dialled
            "FAIL: slopdesk-hostd never accepted a workspace channel", // the document leg opened
            "FAIL: one auto-connect must attach exactly 1 shell", // one connect ⇒ one PTY
            "FAIL: the client decoded NOT ONE frame", // the decode leg produced a picture
            "PRESENTED none", // …and the picture reached a drawable
        ] {
            XCTAssertTrue(source.contains(expected), "check-video.sh lost its `\(expected)` assertion")
        }
    }

    /// The PRESENTED half must count a marker printed AFTER the present, not before the guards.
    ///
    /// `MetalVideoRenderer.render` writes `RENDER#N` as soon as `metalLayer.nextDrawable()` returns.
    /// Between that line and `commandBuffer.present(drawable)` sit four `return`s — `makeTexture` for
    /// either plane, `CVMetalTextureGetTexture`, `makeCommandBuffer` / `makeRenderCommandEncoder` —
    /// and each leaves the frame undrawn and unpresented. So a decoder that starts vending a
    /// non-NV12 or 10-bit `CVPixelBuffer` prints `RENDER#0` once, presents nothing ever, and a gate
    /// that counted `RENDER#` called that "PRESENTED ✅".
    ///
    /// Pinned from both sides: the renderer must still emit a marker after the present, and the gate
    /// must count THAT one. Asserted on the code body so the prose above `PRESENTED#` in either file
    /// cannot satisfy it.
    func testThePresentedAssertionCountsAMarkerPrintedAfterThePresent() throws {
        let renderer = try String(
            contentsOf: scriptURL("Sources/SlopDeskVideoClient/MetalVideoRenderer.swift"),
            encoding: .utf8,
        )
        let presentIndex = try XCTUnwrap(
            renderer.range(of: "commandBuffer.present(drawable)")?.upperBound,
            "MetalVideoRenderer no longer presents a drawable — this contract lost its subject",
        )
        XCTAssertTrue(
            renderer[presentIndex...].contains("PRESENTED#"),
            "MetalVideoRenderer emits no PRESENTED# marker after `commandBuffer.present(drawable)`, so "
                + "check-video.sh has nothing to assert the present leg on",
        )
        XCTAssertFalse(
            renderer[..<presentIndex].contains("PRESENTED#"),
            "the PRESENTED# marker is printed BEFORE the present — every guard between the two returns "
                + "without drawing, which is the exact bug this marker exists to catch",
        )

        let gate = try codeBody(of: "scripts/check-video.sh")
        let presentProbes = gate
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("PRESENTED=\"$(grep") }
        XCTAssertFalse(presentProbes.isEmpty, "check-video.sh no longer counts a present marker at all")
        for probe in presentProbes {
            XCTAssertTrue(
                probe.contains("PRESENTED#"),
                "check-video.sh's present check counts a marker that is not PRESENTED#. `RENDER#` prints "
                    + "before the texture/encoder guards, so counting it passes on a client that draws "
                    + "nothing. Offending line: \(probe.trimmingCharacters(in: .whitespaces))",
            )
        }
    }

    /// Every GUI gate that launches a window must ASSERT there is one — off the WINDOW SERVER.
    ///
    /// "The process is alive" is not "the app came up": a macOS app with zero windows is a healthy
    /// process in a run loop, and `check-macos.sh`'s default and --renderer modes had nothing else to
    /// say about it — no auto-connect, so no ESTABLISHED check, no OUT-path proof. They printed
    /// `alive after Ns ✅` and screenshotted whatever was on the desktop. The other gates each assert
    /// it implicitly, by needing a scene `.task` to have run: a projection read back over the client
    /// control socket, or a UDP flow that only a mounted video pane can open.
    ///
    /// The window claim may NOT be read off the control socket, which is what it used to be. Two
    /// independent reasons, both HW-observed 2026-07-28: `WorkspaceControlBackend.listWindows()` maps
    /// `WorkspaceStore.tree.sessions`, a value the App's `init()` builds before any scene exists — a
    /// SESSION count with no window information in it; and `ClientControlServer.start()` hands its
    /// listener to `Thread.detachNewThread` with no `stop()` anywhere, so a bound socket outlives the
    /// scene. Close the app's window and the process answered `1` for as long as it ran.
    func testTheMacosGateAssertsTheAppHasAWindow() throws {
        let code = try codeBody(of: "scripts/check-macos.sh")
        XCTAssertTrue(
            code.contains("window-census"),
            "check-macos.sh no longer asks the WINDOW SERVER how many windows the app has. Whatever it "
                + "counts now, a windowless process can satisfy it.",
        )
        XCTAssertTrue(
            code.contains("FAIL: the app is running with NO window"),
            "check-macos.sh's window check no longer terminates the run",
        )
        // The counted variable must come off the census, never off the socket read.
        let windowCounts = code
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("WINDOW_COUNT=\"$(") }
        XCTAssertFalse(windowCounts.isEmpty, "check-macos.sh no longer computes a window count")
        for line in windowCounts {
            XCTAssertTrue(
                line.contains("${CENSUS}"),
                "check-macos.sh derives its window count from something other than the window-server "
                    + "census. Offending line: \(line.trimmingCharacters(in: .whitespaces))",
            )
        }
    }

    /// The census the gate leans on has to exist, and has to answer about WINDOWS.
    ///
    /// `CGWindowListCopyWindowInfo` is the seam: owner pid / layer / bounds are TCC-free (only window
    /// TITLES are behind Screen Recording), which is what lets `check-macos.sh` keep its promise of
    /// needing neither Screen-Recording nor Accessibility.
    func testTheWindowCensusReadsTheWindowServer() throws {
        // Comment lines dropped, same discipline as `codeBody`: the census's own header explains why it
        // must NOT read `kCGWindowName`, and that prose would otherwise satisfy the ban on reading it.
        let census = try String(contentsOf: scriptURL("scripts/window-census.swift"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(
            census.contains("CGWindowListCopyWindowInfo"),
            "scripts/window-census.swift no longer asks the window server anything",
        )
        XCTAssertTrue(
            census.contains("kCGWindowOwnerPID"),
            "scripts/window-census.swift no longer attributes windows to a pid, so it cannot answer "
                + "about the app this gate launched",
        )
        XCTAssertFalse(
            census.contains("kCGWindowName"),
            "scripts/window-census.swift reads window TITLES, which requires Screen-Recording TCC — "
                + "check-macos.sh promises it needs none",
        )
    }

    /// An automation run must never be able to reshape the developer's live state.
    ///
    /// Every gate here execs the bundle binary, and a direct exec starts a SECOND instance even while
    /// the developer's own SlopDesk is running (`open` would not). `check-macos.sh`'s default and
    /// --renderer modes set no `SLOPDESK_AUTOCONNECT_*`, so `hasAutomationEnvironment()` is FALSE for
    /// them and the app builds a real `WorkspacePersistence()` + `DevicePreferencesStore()` and runs
    /// `connectIfSavedTarget()`. Two things must therefore be true of every launch in every gate:
    ///
    ///   - `CFFIXED_USER_HOME` — redirects `NSHomeDirectory()` / Application Support, so `workspace.json`
    ///     and friends are the run's own. HW-observed 2026-07-28: without it a default-mode launch
    ///     RESTORED the container's saved layout and wrote `device-prefs.json` into it.
    ///   - the auto-reconnect dial must be shut off. `CFFIXED_USER_HOME` does NOT redirect
    ///     `UserDefaults`, so `connection.recentTargets` stays the DEVELOPER's MRU and
    ///     `connectIfSavedTarget()` dials whatever is at the top of it — their live `slopdesk-hostd`,
    ///     which owns the workspace layout (docs/45). No amount of client-side file isolation protects
    ///     against that. HW-observed: a decoy listener on the MRU entry took 17 bytes from a
    ///     default-mode launch, and 0 with `SLOPDESK_SKIP_AUTO_RECONNECT=1` set.
    ///
    /// Three spellings satisfy the second rule, because the gates need different ones: an autoconnect
    /// host (the app takes the automation branch and skips the reconnect task), the skip flag itself,
    /// or an argument-domain `-connection.recentTargets` — which is what `check-launch-restore.sh`
    /// must use, since running the real auto-reconnect IS its subject.
    func testNoGateLaunchCanReachTheDevelopersOwnState() throws {
        for script in try appLaunchingScripts() {
            let commands = try launchCommands(of: script, invoking: appBinaryTokens(of: script))
            XCTAssertFalse(commands.isEmpty, "\(script) no longer execs the app — no launch to check")
            for command in commands {
                let shown = command.trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertTrue(
                    command.contains("CFFIXED_USER_HOME="),
                    "\(script) execs the app without CFFIXED_USER_HOME, so this run's `workspace.json` / "
                        + "`device-prefs.json` / `video-prefs.json` are the DEVELOPER's own files. "
                        + "Offending launch: \(shown)",
                )
                XCTAssertTrue(
                    command.contains("SLOPDESK_SKIP_AUTO_RECONNECT=1")
                        || command.contains("SLOPDESK_AUTOCONNECT_HOST=")
                        || command.contains("SLOPDESK_VIDEO_AUTOCONNECT_HOST=")
                        || command.contains("-connection.recentTargets"),
                    "\(script) execs the app with nothing that stops `connectIfSavedTarget()`, so it "
                        + "dials the DEVELOPER's MRU host — the live daemon that owns their layout. "
                        + "Offending launch: \(shown)",
                )
            }
        }
    }

    /// An automation run must not be able to WRITE the developer's `UserDefaults` either.
    ///
    /// `CFFIXED_USER_HOME` moves Application Support; it does NOT move `UserDefaults` — cfprefsd
    /// resolves the real home whatever the environment says (probed on this host: a
    /// `UserDefaults(suiteName:)` write under `CFFIXED_USER_HOME=/private/tmp/…` still landed in
    /// `~/Library/Preferences`). So every gate that connects has been pushing its own loopback port
    /// onto `connection.recentTargets` in the developer's real domain, where it shows up as the
    /// gate's "recent hosts" menu and — the MRU is capped at five — evicts the host they actually use.
    ///
    /// `SLOPDESK_DEFAULTS_SUITE` binds ``SettingsKey/store`` to a throwaway suite instead. It isolates
    /// BOTH directions: a suite-backed `UserDefaults` cannot see the app's own persistent domain
    /// (probed with a real bundled app: a key written to the bundle-id domain read back `nil` through
    /// the suite), while `NSArgumentDomain` still outranks it — which is what keeps
    /// `check-launch-restore.sh`'s `-connection.recentTargets` fixture working.
    func testNoGateLaunchWritesTheDevelopersUserDefaults() throws {
        for script in try appLaunchingScripts() {
            let commands = try launchCommands(of: script, invoking: appBinaryTokens(of: script))
            XCTAssertFalse(commands.isEmpty, "\(script) no longer execs the app — no launch to check")
            for command in commands {
                XCTAssertTrue(
                    command.contains("SLOPDESK_DEFAULTS_SUITE="),
                    "\(script) execs the app without SLOPDESK_DEFAULTS_SUITE, so `SettingsKey.store` is "
                        + "the DEVELOPER's own `UserDefaults` domain and this run's connect pushes its "
                        + "loopback port onto their recent-hosts MRU. Offending launch: "
                        + command.trimmingCharacters(in: .whitespacesAndNewlines),
                )
            }
        }
    }

    /// …and it has to take the suite away again on the way out — the DOMAIN and the FILE.
    ///
    /// `defaults delete` empties the domain and leaves the plist: measured, 42 bytes of it, per run.
    /// The scale of that is on this machine already — `~/Library/Preferences` holds 55,003
    /// `slopdesk.tests.pid*.plist` files, one per xctest process ever run here, every one emptied by
    /// `SettingsKey`'s `atexit` hook and none of them removed. A gate leaks the same way and cannot
    /// even rely on that hook: the app is `pkill`ed, so nothing inside it runs at exit.
    ///
    /// Both halves are pinned, and they are pinned as ONE routine the trap calls, so a gate cannot
    /// end up doing the delete on one exit path and the unlink on another.
    func testEveryGateRemovesTheDefaultsSuiteItCreated() throws {
        for script in try appLaunchingScripts() {
            let code = try codeBody(of: script)
            XCTAssertTrue(
                code.contains("defaults delete \"${DEFAULTS_SUITE}\""),
                "\(script) never removes the `UserDefaults` suite it binds, so every run leaves a plist "
                    + "in the developer's ~/Library/Preferences",
            )
            XCTAssertTrue(
                code.contains(#"rm -f "${HOME}/Library/Preferences/${DEFAULTS_SUITE}.plist""#),
                "\(script) empties its suite without unlinking the plist, which is a 42-byte file per "
                    + "run in the developer's ~/Library/Preferences. `defaults delete` does not remove "
                    + "the file; only `rm -f` does, and `${HOME}` is the right home because cfprefsd "
                    + "writes the real one whatever CFFIXED_USER_HOME says.",
            )
            XCTAssertTrue(
                code.contains("  remove_defaults_suite"),
                "\(script)'s cleanup trap no longer calls `remove_defaults_suite`, so an exit path can "
                    + "leave the run's suite — or half of it — behind",
            )
        }
    }

    /// A private suite starts EMPTY, and an empty defaults domain is a FRESH INSTALL.
    ///
    /// `FirstLaunchModel.shouldPresent(hasCompleted:automationActive:)` is `!hasCompleted &&
    /// !automationActive`, so the guided welcome sheet opens over the window in every mode that sets
    /// no `SLOPDESK_AUTOCONNECT_*` — `check-macos.sh`'s default and --renderer modes, and the whole of
    /// `check-launch-restore.sh`, whose entire premise is a RETURNING user. While the gates shared the
    /// developer's own domain this was covered by accident: they had dismissed the sheet long ago.
    /// Isolating the domain takes that accident away, so the flag is seeded explicitly.
    ///
    /// It must be a real `defaults write -bool`, not an argv pair. `firstLaunch.completed` is read
    /// through a typed `Defaults.Key<Bool>`; Cocoa parses `-key YES` into `NSArgumentDomain` as the
    /// STRING "YES", which a Bool read does not accept. `check-launch-restore.sh` carried
    /// `-hasCompletedFirstLaunch YES` for exactly this job and it never did anything — wrong domain
    /// type, and the Swift property name instead of the key.
    func testEveryGateSeedsTheFirstLaunchFlag() throws {
        for script in try appLaunchingScripts() {
            let code = try codeBody(of: script)
            XCTAssertTrue(
                code.contains("defaults write \"${DEFAULTS_SUITE}\" firstLaunch.completed -bool YES"),
                "\(script) launches the app against an unseeded defaults suite, so the app reads it as a "
                    + "fresh install and the guided first-launch sheet can open over the window the gate "
                    + "is asserting on",
            )
            XCTAssertFalse(
                code.contains("-hasCompletedFirstLaunch"),
                "\(script) still passes `-hasCompletedFirstLaunch` in the argument domain. That is the "
                    + "Swift property name, not the key (`firstLaunch.completed`), and an argv value "
                    + "arrives as a String where a typed Bool is read — it suppresses nothing.",
            )
        }
    }

    /// The same rule for the DAEMONS, which have no `CFFIXED_USER_HOME` at all.
    ///
    /// `HOME` alone does not move Application Support — it does not even move `NSHomeDirectory()`
    /// (probed on this host: `HOME=/private/tmp/fakehome` still resolves
    /// `/Users/<me>/Library/Application Support`). Only `CFFIXED_USER_HOME` does, and pointing a
    /// `slopdesk-hostd` at one made `check-launch-restore.sh` flake 3 runs in 5, so the daemons are
    /// isolated by the per-path variables the product already reads instead.
    ///
    /// The set is required UNIFORMLY on both daemons rather than per-binary. `slopdesk-videohostd`
    /// reads none of the three terminal-side ones today, and requiring them anyway is the point: the
    /// rule stays "every daemon launch carries the set", not "carries whichever member of the set
    /// that daemon happened to read the last time somebody checked".
    ///
    /// RED before the fix: none of the five gates set `SLOPDESK_SCROLLBACK_DIR`, so every one of them
    /// swept and wrote the developer's own `~/Library/Application Support/SlopDesk/scrollback/`.
    /// Measured on this host: ONE `check-macos.sh --connect` unlinked 5 of their journals and left
    /// one of its own behind.
    func testNoGateLaunchesADaemonAgainstTheDevelopersContainer() throws {
        let scripts = try daemonLaunchingScripts()
        // A CANARY, not the subject set: five scripts known to stand a daemon up, so a walk that
        // silently matched nothing is caught reading nothing rather than passing vacuously.
        for known in [
            "scripts/check-macos.sh",
            "scripts/check-video.sh",
            "scripts/check-multiclient.sh",
            "scripts/check-launch-restore.sh",
            "scripts/soak-fanout-laggard.sh",
        ] {
            XCTAssertTrue(
                scripts.contains(known),
                "\(known) launches a daemon and the walk over scripts/ did not find it — the "
                    + "discovery is broken, and a contract that silently reads nothing passes",
            )
        }
        for script in scripts {
            let commands = try launchCommands(of: script, invoking: daemonBinaryTokens(of: script))
            for command in commands {
                let shown = command.trimmingCharacters(in: .whitespacesAndNewlines)
                for variable in [
                    "SLOPDESK_APP_SUPPORT_DIR=", // the whole <App Support>/SlopDesk container
                    "SLOPDESK_SCROLLBACK_DIR=", // the journals — the sweep DELETES in this one
                    "SLOPDESK_WORKSPACE_STATE_DIR=", // workspace-state.json (docs/45 host truth)
                    "SLOPDESK_FILE_DROP_DIR=", // the PATH-4 drop dir, else ~/Downloads
                ] {
                    XCTAssertTrue(
                        command.contains(variable),
                        "\(script) launches a host daemon with no \(variable) — it lands on the "
                            + "DEVELOPER's own state. Offending launch: \(shown)",
                    )
                }
            }
        }
    }

    /// Every shell token in `script` that denotes a host-daemon binary: the literal build-product
    /// paths, plus `"${VAR}"` for any variable assigned one.
    ///
    /// The indirection is not cosmetic — `soak-fanout-laggard.sh` and `check-video.sh` both launch
    /// through a `HOSTD=…` variable, so a contract that grepped for the literal binary name would
    /// find the ASSIGNMENT, call it a launch, and never read the exec at all.
    private func daemonBinaryTokens(of script: String) throws -> [String] {
        let names = ["slopdesk-hostd", "slopdesk-videohostd"]
        // debug AND release: `video-input-test.sh` runs the release build, and a rule that only knows
        // one configuration is a rule with a documented way around it.
        var tokens = names.flatMap { [".build/debug/\($0)", ".build/release/\($0)"] }
        for line in try codeBody(of: script).split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "="), trimmed.starts(with: /[A-Z_]/) else { continue }
            let name = String(trimmed[..<equals])
            guard name.allSatisfy({ $0.isUppercase || $0 == "_" }) else { continue }
            let value = String(trimmed[trimmed.index(after: equals)...])
            if names.contains(where: value.contains) { tokens.append("\"${\(name)}\"") }
        }
        return tokens
    }

    /// Every WHOLE shell command that execs the app: the `"${APP_BIN}"` line plus its backslash
    /// continuations BOTH ways. The env assignments sit above that line and the `-key value`
    /// argument-domain fixtures sit below it, so a rule read off the exec line alone misses either
    /// half.
    ///
    /// Walked BY INDEX rather than by looking a line up in the file. `check-macos.sh` execs the app
    /// from two branches whose exec lines are character-for-character identical, so a lookup by string
    /// resolves both to the first one — and the second branch, which is the one with no autoconnect
    /// env and therefore the one that needs the rule most, would never be read at all.
    ///
    /// `invoking` generalises the same walk to the daemons: a token list rather than one literal,
    /// because a gate may launch through `"${HOSTD}"` as readily as through the build-product path.
    /// Lines that merely NAME a binary — the `HOSTD=…` assignment, the `pkill -f` that frees the
    /// port, the `swift build --product` that produces it, the `[[ ! -x` existence check — are not
    /// launches and are dropped, or every gate would be asked to put a container on its own cleanup.
    private func launchCommands(
        of script: String,
        invoking tokens: [String] = ["\"${APP_BIN}\""],
    ) throws -> [String] {
        let lines = try codeBody(of: script)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let notALaunch = ["pkill", "swift build", "! -x", "-x ${", "await ", "grep "]
        var commands: [String] = []
        for (index, line) in lines.enumerated() {
            guard tokens.contains(where: line.contains) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if notALaunch.contains(where: trimmed.contains) { continue }
            // `HOSTD="${ROOT}/.build/debug/slopdesk-hostd"` names the binary and launches nothing.
            if let equals = trimmed.firstIndex(of: "="),
               trimmed[..<equals].allSatisfy({ $0.isUppercase || $0 == "_" }),
               !trimmed[..<equals].isEmpty,
               !trimmed.contains("$(")
            { continue }
            var start = index
            while start > 0, lines[start - 1].hasSuffix("\\") { start -= 1 }
            var end = index
            while end < lines.count - 1, lines[end].hasSuffix("\\") { end += 1 }
            commands.append(lines[start...end].joined(separator: "\n"))
        }
        return commands
    }

    /// EVERY gate counts the shells, because neither the OUT-path proof nor the pixels nor the two
    /// projections can.
    ///
    /// One auto-connect must attach exactly one shell. A second is the client mounting a pane, giving
    /// it a PTY, and then letting the workspace document replace it — the first shell abandoned on the
    /// host. `check-macos.sh` used to catch that as a side effect: the autotype latch was spent by the
    /// doomed pane, so the OUT-path proof went red. The seam now re-arms and rides the replacement
    /// pane's connect edge — correct in itself, and it leaves the OUT-path proof green while a shell is
    /// abandoned on every launch. So the count is asserted OUT LOUD, in the gate that can run without
    /// Screen Recording TCC as well as the one that cannot.
    ///
    /// Each gate states the rule in its own terms: the single-client gates connect once and may see
    /// exactly one shell; the two-client gate builds a multi-pane layout, so its rule is that the LIVE
    /// shell count equals the pane count. Same invariant either way — a PTY nobody's layout claims is
    /// a leak.
    func testEveryConnectGateCountsTheShells() throws {
        let shellRule = [
            "scripts/check-macos.sh": "FAIL: one auto-connect must attach exactly 1 shell",
            "scripts/check-video.sh": "FAIL: one auto-connect must attach exactly 1 shell",
            "scripts/check-multiclient.sh": "pane(s) but the host is running",
            // The restore gate states it twice over, because it is the only one whose panes exist
            // before the connection does: LIVE shells must equal the restored pane count, and the
            // CUMULATIVE spawn count must never exceed it (a pane torn down and re-dialled leaves
            // the live count right and abandons a PTY).
            "scripts/check-launch-restore.sh": "restored panes but",
        ]
        // Keyed by script rather than derived: a gate that launches the app without CONNECTING has no
        // shell to count. The declared set is checked against the walk instead, so a rule cannot
        // outlive the gate it names.
        let discovered = try appLaunchingScripts()
        for (script, expected) in shellRule.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(
                discovered.contains(script),
                "\(script) has a shell-count rule but no longer launches the app — the rule is stale",
            )
            XCTAssertTrue(
                try codeBody(of: script).contains(expected),
                "\(script) no longer asserts its shell-count rule — an abandoned PTY is invisible to it",
            )
        }
    }

    /// The two-client gate must read the SECOND CLIENT, not the host.
    ///
    /// Its whole reason to exist is "client B's view followed", and the cheapest way to make that
    /// green is also the wrong one: read the host's `workspace-state.json` and call it proof. That
    /// asserts the host applied the intent — the PREMISE — and says nothing about what B is
    /// rendering. The gate instead asks each instance over its own `SLOPDESK_CLIENT_SOCKET`, which
    /// `WorkspaceControlBackend` answers off `WorkspaceStore.tree`. Two sockets, two answers,
    /// compared.
    func testTheMulticlientGateObservesBothClientsRatherThanTheHost() throws {
        let code = try codeBody(of: "scripts/check-multiclient.sh")
        XCTAssertTrue(
            code.contains("--socket \"${socket}\""),
            "check-multiclient.sh no longer asks a client what it is rendering over the client-control "
                + "socket — whatever it compares now, it is not the projection",
        )
        for socket in ["${SOCK_A}", "${SOCK_B}"] {
            XCTAssertTrue(
                code.contains("signature \"\(socket)\""),
                "check-multiclient.sh stopped taking a signature from \(socket) — it can no longer be "
                    + "comparing BOTH clients' own projections",
            )
        }
        XCTAssertFalse(
            code.contains("workspace-state.json"),
            "check-multiclient.sh reads the HOST's document file. `the host applied it` is the "
                + "premise of this gate, not its claim — the assertion has to come off the clients.",
        )
    }

    /// Two instances are two DEVICES only if they have two containers.
    ///
    /// `CFFIXED_USER_HOME` is what redirects `NSHomeDirectory()`/Application Support per instance, so
    /// the pair do not share `workspace-cache.json` / `device-prefs.json`. Sharing one would let a
    /// device-local file carry state between them and the gate would pass on a layout neither client
    /// learned over the wire.
    func testTheMulticlientGateGivesEachInstanceItsOwnContainer() throws {
        let code = try codeBody(of: "scripts/check-multiclient.sh")
        XCTAssertTrue(
            code.contains("CFFIXED_USER_HOME="),
            "check-multiclient.sh no longer isolates each instance's container — the two clients share "
                + "one Application Support directory and are no longer two devices",
        )
        XCTAssertTrue(
            code.contains("SLOPDESK_CLIENT_SOCKET="),
            "check-multiclient.sh no longer gives each instance its own control socket, so the two "
                + "cannot be addressed independently",
        )
    }

    /// A disagreement between the two clients must EXIT NON-ZERO. The video gate once observed a
    /// missing UDP flow, warned, and screenshotted the desktop anyway; the same shape here would
    /// print two divergent projections and still pass.
    func testTheMulticlientGateFailsHardOnDivergence() throws {
        let code = try codeBody(of: "scripts/check-multiclient.sh")
        for expected in [
            "did not converge on", // the two projections disagreed
            "expected 2 accepted workspace channels", // both clients hold a channelClass 1
        ] {
            XCTAssertTrue(code.contains(expected), "check-multiclient.sh lost its `\(expected)` check")
        }
        // Every one of those paths goes through `fatal`, which exits 1. A `converge` that returned a
        // status nobody read would leave the gate green on the one failure it exists to catch.
        XCTAssertTrue(
            code.contains("fatal \"${what}: the two clients did not converge"),
            "check-multiclient.sh's convergence check no longer terminates the run",
        )
    }

    /// The restore gate must wait for THIS phase's link-down, not for any link-down ever.
    ///
    /// `${HOSTD_LOG}` is never truncated — the spawn counts it asserts on are cumulative by design —
    /// so a bare "has the host parked these sessions?" is satisfied FOR EVER by the first phase's
    /// parking. The phase-C wait then returned on its first poll and the relaunch dialled while phase
    /// B's sessions were still bound; the host answered `already attached on another connection` and
    /// the three restored panes came up with DEAD terminals. Every phase-C assertion still passed:
    /// they read the workspace document, which is host truth whether or not anything is attached to
    /// it, plus a live-PTY count a refusal leaves untouched.
    ///
    /// RED before the fix, on hardware: freeze the phase-B client with `SIGSTOP` (a slow link-down,
    /// no FIN) and the gate exits 0 with three `refused — … is already attached on another
    /// connection` lines in the host log.
    func testTheRestoreGateWaitsForThisPhasesDetach() throws {
        let code = try codeBody(of: "scripts/check-launch-restore.sh")
        XCTAssertTrue(
            code.contains("DETACH_BASELINE=\"$(detach_counts)\""),
            "check-launch-restore.sh no longer snapshots the per-pane park count before it stops a "
                + "client, so its wait for the host to park them cannot tell this phase from the last",
        )
        let waits = code
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("await ") && $0.contains("to park") }
        XCTAssertFalse(waits.isEmpty, "check-launch-restore.sh no longer waits for the host to park")
        for wait in waits {
            XCTAssertTrue(
                wait.contains("detached_all_since"),
                "check-launch-restore.sh waits on an unbaselined park check, which the PREVIOUS "
                    + "phase's log lines already satisfy. Offending line: "
                    + wait.trimmingCharacters(in: .whitespaces),
            )
        }
    }

    /// The workspace-document gate must match the ACCEPT line, not the channel's name.
    ///
    /// hostd prefixes every refusal and error on that channel with `workspace channel …` too —
    /// `refused — already open`, `receive ended`, `malformed subscribe dropped`, `unknown verb
    /// dropped` — and the refusal is logged with no accept anywhere, so a substring match reports
    /// "accepted ✅" for a channel the host explicitly turned away.
    func testTheDocumentGateMatchesTheAcceptLine() throws {
        let source = try String(contentsOf: scriptURL("scripts/check-video.sh"), encoding: .utf8)
        let probes = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .filter { $0.contains("grep") && $0.contains("workspace channel") }
        XCTAssertFalse(probes.isEmpty, "check-video.sh no longer probes hostd for the workspace channel")
        for probe in probes {
            XCTAssertTrue(
                probe.contains("accepted"),
                "check-video.sh accepts any `workspace channel` line, including hostd's refusals. "
                    + "Offending line: \(probe.trimmingCharacters(in: .whitespaces))",
            )
        }
    }
}
