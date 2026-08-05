// WebBrowserHardwareTests — the Web path's dedicated gate (`scripts/check-web.sh`).
//
// These do NOT run under `make test`: they exec a real browser and bind a real relay, which the
// hang-safety rule keeps out of the unit bundle. `docs/46-gates-env-paths.md` records each path's
// gate; this one is `SLOPDESK_WEB_HW=1`. Without it every test here returns early, so a clean
// checkout stays green on a machine with no Chrome.
//
// What only a real run can prove — and what the fake-seam suite beside this therefore cannot:
// whether the launch flags still produce a debugging port at all (Chrome has twice changed the
// rules: `--remote-allow-origins` in 111, the default-profile refusal in 136), and whether the
// relay carries Chrome's own bytes unaltered.

import Foundation
import XCTest
@testable import SlopDeskHost

final class WebBrowserHardwareTests: XCTestCase {
    /// The gate. Off ⇒ every test here is a no-op.
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SLOPDESK_WEB_HW"] == "1"
    }

    /// A manager on a THROWAWAY profile: the real one persists logins, and a test must not touch it.
    private func makeManager() throws -> (WebBrowserManager, URL) {
        guard WebBrowserToolchain.locate() != nil else { throw XCTSkip("no Chrome-family browser on this host") }
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-web-hw-\(UUID().uuidString)", isDirectory: true)
        return (WebBrowserManager(profileLocator: { profile.path }), profile)
    }

    /// Polls `ensure` the way the client does, up to `timeout`.
    private func waitForReady(_ manager: WebBrowserManager, timeout: TimeInterval = 30) throws -> UInt16 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let endpoint = manager.ensure()
            if endpoint.state == .ready { return endpoint.port }
            if endpoint.state == .unavailable { throw XCTSkip("browser reported unavailable") }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("browser never became ready")
        return 0
    }

    /// The completion handler runs off this thread, so the reply crosses back in a box.
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (Int, String) = (0, "")

        var value: (Int, String) {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }

    /// One HTTP GET through the RELAY — i.e. exactly the path a mesh client takes.
    private func get(_ path: String, port: UInt16, timeout: TimeInterval = 10) throws -> (Int, String) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let done = XCTestExpectation(description: "GET \(path)")
        let reply = Reply()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            reply.value = (
                (response as? HTTPURLResponse)?.statusCode ?? 0,
                data.flatMap { String(data: $0, encoding: .utf8) } ?? "",
            )
            done.fulfill()
        }.resume()
        guard XCTWaiter().wait(for: [done], timeout: timeout + 2) == .completed else {
            XCTFail("GET \(path) timed out")
            return (0, "")
        }
        return reply.value
    }

    /// Kills the browser this test started — matched on its own throwaway profile path, which is a
    /// fresh UUID, so a browser the USER is running can never match.
    private func killBrowser(onProfile profile: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", profile.path]
        try process.run()
        process.waitUntilExit()
        // The manager notices through `isRunning`, which needs the child to be reaped first.
        Thread.sleep(forTimeInterval: 1)
    }

    /// The whole host-side contract in one run: the browser starts on our flags, the announce line
    /// is parsed, the relay binds, and Chrome's own endpoints answer THROUGH it.
    func testBrowserBecomesReachableThroughTheRelay() throws {
        try XCTSkipUnless(isEnabled, "set SLOPDESK_WEB_HW=1 (scripts/check-web.sh)")
        let (manager, profile) = try makeManager()
        defer {
            manager.shutdown()
            try? FileManager.default.removeItem(at: profile)
        }
        let port = try waitForReady(manager)

        let (versionStatus, versionBody) = try get("/json/version", port: port)
        XCTAssertEqual(versionStatus, 200)
        XCTAssertTrue(versionBody.contains("webSocketDebuggerUrl"), versionBody)
        // Loopback is what the browser binds and what the relay must therefore dial; a debugger URL
        // naming anything else means the flags moved and the client's own relay would mis-target.
        XCTAssertTrue(versionBody.contains("ws://127.0.0.1:"), versionBody)
        // The user-agent flag reached the real browser. Only a live run can say so: the flag is
        // built from a version read out of the bundle, and a browser that ignored it (or a bundle
        // whose plist moved) still answers everything else exactly the same way. `HeadlessChrome`
        // on the wire is the difference between a page serving the panel and a page serving a wall.
        XCTAssertFalse(versionBody.contains("HeadlessChrome"), versionBody)

        // A page target must exist without the client minting one — that is what `about:blank` in
        // the argument vector buys.
        let (listStatus, listBody) = try get("/json/list", port: port)
        XCTAssertEqual(listStatus, 200)
        XCTAssertTrue(listBody.contains("\"type\": \"page\""), listBody)

        // The frontend is served by the browser itself, so there is nothing to vendor and it can
        // never fall out of step with the protocol behind it.
        let (frontendStatus, frontendBody) = try get("/devtools/inspector.html", port: port)
        XCTAssertEqual(frontendStatus, 200)
        XCTAssertTrue(frontendBody.contains("<html"), String(frontendBody.prefix(200)))
    }

    /// A respawn must keep the client's address: the DevTools frontend stores its panel layout
    /// against the origin, so a relay that moved would reset the user's inspector on every crash.
    func testRelayPortSurvivesABrowserRespawn() throws {
        try XCTSkipUnless(isEnabled, "set SLOPDESK_WEB_HW=1 (scripts/check-web.sh)")
        let (manager, profile) = try makeManager()
        defer {
            manager.shutdown()
            try? FileManager.default.removeItem(at: profile)
        }
        let firstPort = try waitForReady(manager)
        let firstVersion = try get("/json/version", port: firstPort).1

        try killBrowser(onProfile: profile)
        let secondPort = try waitForReady(manager)
        XCTAssertEqual(secondPort, firstPort, "the relay outlives the child")

        let secondVersion = try get("/json/version", port: secondPort).1
        XCTAssertTrue(secondVersion.contains("webSocketDebuggerUrl"), secondVersion)
        XCTAssertNotEqual(firstVersion, secondVersion, "a fresh browser has a fresh debugger UUID")
    }
}
