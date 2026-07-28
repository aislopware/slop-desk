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
    /// The gates that exec the app binary directly. `scripts/` sits beside `Tests/` in the package
    /// root — walk up from this file rather than relying on a bundle resource (a script is not a
    /// SwiftPM resource; it is a working-tree artefact).
    ///
    /// `check-multiclient.sh` execs it TWICE (one instance per client), which is exactly why it
    /// belongs here: a persistence-path launch would give the second instance zero windows and the
    /// gate would compare one real projection against one that never mounted.
    ///
    /// `check-launch-restore.sh` execs it twice as well (a launch and a relaunch) and is the one gate
    /// that sets NO `SLOPDESK_AUTOCONNECT_*` at all — which makes the flag matter more there, not
    /// less: with zero windows its client would never restore, never dial, and never open its control
    /// socket, and the failure would read as a timeout rather than as a launch that made no UI.
    private static let gateScripts = [
        "scripts/check-macos.sh",
        "scripts/check-video.sh",
        "scripts/check-multiclient.sh",
        "scripts/check-launch-restore.sh",
    ]

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

    /// The lines that actually INVOKE the binary: `"${APP_BIN}" …`. The `APP_BIN=…` assignment and
    /// the `pkill` process patterns never carry the braces inside quotes, so they drop out, and
    /// comments are stripped so prose about the flag can never satisfy the assertion.
    private func launchLines(of script: String) throws -> [String] {
        try codeBody(of: script)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("\"${APP_BIN}\"") }
    }

    /// REVERT-TO-FAIL: drop `-ApplePersistenceIgnoreState YES` from either gate's launch and this
    /// names the script and the line.
    func testEveryDirectAppLaunchIgnoresPersistedState() throws {
        for script in Self.gateScripts {
            let lines = try launchLines(of: script)
            XCTAssertFalse(
                lines.isEmpty,
                "\(script) no longer execs \"${APP_BIN}\" — either it switched to `open` (which cannot "
                    + "forward the SLOPDESK_* automation env) or this contract lost its subject.",
            )
            for line in lines {
                XCTAssertTrue(
                    line.contains("-ApplePersistenceIgnoreState YES"),
                    "\(script) execs the app binary without `-ApplePersistenceIgnoreState YES`, so the "
                        + "app launches with ZERO windows and every scene `.task` seam the gate depends "
                        + "on never runs. Offending line: \(line.trimmingCharacters(in: .whitespaces))",
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
        for script in Self.gateScripts {
            let offenders = try codeBody(of: script)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { $0.contains("open \"${APP") }
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

    /// Every GUI gate that launches a window must ASSERT there is one.
    ///
    /// "The process is alive" is not "the app came up": a macOS app with zero windows is a healthy
    /// process in a run loop, and `check-macos.sh`'s default and --renderer modes had nothing else to
    /// say about it — no auto-connect, so no ESTABLISHED check, no OUT-path proof. They printed
    /// `alive after Ns ✅` and screenshotted whatever was on the desktop. The other gates each assert
    /// it implicitly, by needing a scene `.task` to have run: a projection read back over the client
    /// control socket, or a UDP flow that only a mounted video pane can open.
    func testTheMacosGateAssertsTheAppHasAWindow() throws {
        let code = try codeBody(of: "scripts/check-macos.sh")
        XCTAssertTrue(
            code.contains("windows --json"),
            "check-macos.sh no longer asks the running app what it is rendering, so a launch that "
                + "made no UI at all still passes `alive after Ns`",
        )
        XCTAssertTrue(
            code.contains("FAIL: the app is running with NO window"),
            "check-macos.sh's window check no longer terminates the run",
        )
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
        for script in Self.gateScripts {
            let expected = try XCTUnwrap(shellRule[script], "\(script) has no shell-count rule declared")
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
