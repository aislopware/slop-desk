import Foundation
import SlopDeskProtocol
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskHost

/// ``WebBrowserManager`` against FAKE seams. Hang-safety is the shape of this suite: the real
/// manager execs a browser and binds a mesh-facing listener in front of it, and a unit test may do
/// neither — so the locator, profile, spawner, probe AND relay are injected on every construction.
final class WebBrowserManagerTests: XCTestCase {
    private final class FakeHandle: HostServiceProcessHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private(set) var terminated = false

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return running
        }

        func terminate() {
            lock.lock()
            defer { lock.unlock() }
            running = false
            terminated = true
        }

        /// The browser died on its own (a crash, an operator's `pkill`, a profile lock it lost) —
        /// no `terminate` call, so `isRunning` flips without the manager being told.
        func exitSilently() {
            lock.lock()
            defer { lock.unlock() }
            running = false
        }
    }

    private final class FakeRelay: WebDebugRelayHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var storedPort: UInt16
        private(set) var targets: [UInt16] = []
        private(set) var stopped = false

        init(port: UInt16, target: UInt16) {
            storedPort = port
            targets = [target]
        }

        var port: UInt16 {
            lock.lock()
            defer { lock.unlock() }
            return storedPort
        }

        /// A listener that has not finished binding reports `0`; the test flips it to model that.
        func setPort(_ value: UInt16) {
            lock.lock()
            storedPort = value
            lock.unlock()
        }

        func retarget(toLoopbackPort port: UInt16) {
            lock.lock()
            targets.append(port)
            lock.unlock()
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    private final class FakeSpawner: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var spawnCount = 0
        private(set) var lastArguments: [String] = []
        private(set) var handles: [FakeHandle] = []
        private(set) var lineSinks: [@Sendable (String) -> Void] = []
        var throwsOnSpawn = false

        func spawn(
            binary _: String, arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        ) throws -> any HostServiceProcessHandle {
            lock.lock()
            defer { lock.unlock() }
            if throwsOnSpawn { throw CocoaError(.fileNoSuchFile) }
            spawnCount += 1
            lastArguments = arguments
            let handle = FakeHandle()
            handles.append(handle)
            lineSinks.append(onLine)
            return handle
        }

        /// The line Chrome prints on stderr once its debugging socket is bound.
        func announcePort(_ port: UInt16, instance: Int = 0) {
            lineSinks[instance](
                "DevTools listening on ws://127.0.0.1:\(port)/devtools/browser/6f0f-4d1a-9c33",
            )
        }
    }

    private final class RelayFactorySpy: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var relays: [FakeRelay] = []
        /// When true the listener could not even be constructed (a port exhaustion / sandbox denial).
        var failsToBuild = false

        func make(target: UInt16) -> (any WebDebugRelayHandle)? {
            lock.lock()
            defer { lock.unlock() }
            if failsToBuild { return nil }
            let relay = FakeRelay(port: 51000 + UInt16(relays.count), target: target)
            relays.append(relay)
            return relay
        }

        var only: FakeRelay {
            lock.lock()
            defer { lock.unlock() }
            return relays[0]
        }
    }

    private func makeManager(
        spawner: FakeSpawner,
        relays: RelayFactorySpy = RelayFactorySpy(),
        binary: String? = "/fake/Google Chrome",
        profile: String? = "/fake/profile",
        probe: @escaping @Sendable (UInt16) -> Bool = { _ in true },
    ) -> WebBrowserManager {
        WebBrowserManager(
            binaryLocator: { binary },
            profileLocator: { profile },
            spawner: { bin, args, onLine in try spawner.spawn(binary: bin, arguments: args, onLine: onLine) },
            readinessProbe: probe,
            relayFactory: { relays.make(target: $0) },
            probeInterval: .zero,
        )
    }

    // MARK: Lifecycle

    func testEnsureSpawnsOnceAndReportsStartingUntilPortKnown() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)

        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 1)

        // A second pane rides the SAME browser — one host, one set of tabs.
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 1)
    }

    func testReadyReportsTheRelaysPortNotTheBrowsers() {
        // The whole reason the relay exists: the browser's port is loopback-only, so publishing it
        // would hand a mesh client an address it can never reach.
        let spawner = FakeSpawner()
        let relays = RelayFactorySpy()
        let manager = makeManager(spawner: spawner, relays: relays)
        _ = manager.ensure()
        spawner.announcePort(9222)

        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .ready, port: 51000))
        XCTAssertEqual(relays.only.targets, [9222])
    }

    func testFailedProbeStaysStartingAndBuildsNoRelay() {
        // A listener in front of a port nothing answers on would accept the client's connection and
        // drop it, which reads as a DEAD browser rather than a booting one.
        let spawner = FakeSpawner()
        let relays = RelayFactorySpy()
        let manager = makeManager(spawner: spawner, relays: relays, probe: { _ in false })
        _ = manager.ensure()
        spawner.announcePort(9222)

        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
        XCTAssertTrue(relays.relays.isEmpty)
    }

    func testRelayThatHasNotBoundYetReadsAsStarting() {
        let spawner = FakeSpawner()
        let relays = RelayFactorySpy()
        let manager = makeManager(spawner: spawner, relays: relays)
        _ = manager.ensure()
        spawner.announcePort(9222)
        _ = manager.ensure()
        relays.only.setPort(0)

        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
    }

    func testRelayFactoryFailureKeepsReportingStartingAndRetries() {
        let spawner = FakeSpawner()
        let relays = RelayFactorySpy()
        relays.failsToBuild = true
        let manager = makeManager(spawner: spawner, relays: relays)
        _ = manager.ensure()
        spawner.announcePort(9222)
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))

        relays.failsToBuild = false
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .ready, port: 51000))
    }

    func testReadinessLatches() {
        // Once the browser has answered, a transient connect refusal must not flap the panel back
        // to a spinner.
        let spawner = FakeSpawner()
        let probeAnswer = LockedFlag(true)
        let manager = makeManager(spawner: spawner, probe: { _ in probeAnswer.value })
        _ = manager.ensure()
        spawner.announcePort(9222)
        XCTAssertEqual(manager.ensure().state, .ready)

        probeAnswer.value = false
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .ready, port: 51000))
    }

    func testRespawnKeepsTheRelayAndRetargetsIt() {
        // The client's loopback origin is derived from the relay's port, and the DevTools frontend
        // stores its whole panel layout against that origin. A relay that moved on every browser
        // crash would silently reset the user's inspector every time.
        let spawner = FakeSpawner()
        let relays = RelayFactorySpy()
        let manager = makeManager(spawner: spawner, relays: relays)
        _ = manager.ensure()
        spawner.announcePort(9222)
        XCTAssertEqual(manager.ensure().port, 51000)

        spawner.handles[0].exitSilently()
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 2)
        spawner.announcePort(9333, instance: 1)

        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .ready, port: 51000))
        XCTAssertEqual(relays.relays.count, 1, "the relay outlives the child")
        XCTAssertEqual(relays.only.targets, [9222, 9333])
    }

    func testRelayIsRetargetedOnlyWhenTheBrowserActuallyMoved() {
        // `ensure` is a poll: a client asks every few hundred ms. Retargeting on each of those would
        // churn the relay's state for nothing.
        let spawner = FakeSpawner()
        let relays = RelayFactorySpy()
        let manager = makeManager(spawner: spawner, relays: relays)
        _ = manager.ensure()
        spawner.announcePort(9222)
        for _ in 0..<5 { _ = manager.ensure() }

        XCTAssertEqual(relays.only.targets, [9222])
    }

    func testStaleAnnounceLineCannotPoisonTheRespawn() {
        // The dead browser's pipe can flush its old announce line AFTER the respawn; the fresh child
        // must learn ITS OWN port, or the relay points at a closed socket.
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner)
        _ = manager.ensure()
        spawner.handles[0].exitSilently()
        _ = manager.ensure()
        XCTAssertEqual(spawner.spawnCount, 2)

        spawner.announcePort(1111, instance: 0)
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0), "stale line ignored")
        spawner.announcePort(2222, instance: 1)
        XCTAssertEqual(manager.ensure().state, .ready)
    }

    func testMissingBrowserIsUnavailableAndSpawnsNothing() {
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, binary: nil)
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0))
        XCTAssertEqual(spawner.spawnCount, 0)
    }

    func testUnresolvableProfileIsUnavailableAndSpawnsNothing() {
        // Launching without `--user-data-dir` would either be refused by Chrome 136+ or land on the
        // user's REAL profile and fight its singleton lock. Neither is a browser worth spawning.
        let spawner = FakeSpawner()
        let manager = makeManager(spawner: spawner, profile: nil)
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0))
        XCTAssertEqual(spawner.spawnCount, 0)
    }

    func testFailedExecIsUnavailableAndRetriesLater() {
        let spawner = FakeSpawner()
        spawner.throwsOnSpawn = true
        let manager = makeManager(spawner: spawner)
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .unavailable, port: 0))

        spawner.throwsOnSpawn = false
        XCTAssertEqual(manager.ensure(), MetadataCodec.ServiceEndpoint(state: .starting, port: 0))
        XCTAssertEqual(spawner.spawnCount, 1)
    }

    func testShutdownTerminatesTheBrowserAndStopsTheRelay() {
        // Unlike a booted simulator or emulator, this child is headless and invisible: a daemon stop
        // that left it running would strand a process the user cannot see to kill.
        let spawner = FakeSpawner()
        let relays = RelayFactorySpy()
        let manager = makeManager(spawner: spawner, relays: relays)
        _ = manager.ensure()
        spawner.announcePort(9222)
        _ = manager.ensure()

        manager.shutdown()
        XCTAssertTrue(spawner.handles[0].terminated)
        XCTAssertTrue(relays.only.stopped)

        _ = manager.ensure()
        XCTAssertEqual(spawner.spawnCount, 2)
    }

    func testShutdownWithoutAnInstanceIsHarmless() {
        let spawner = FakeSpawner()
        makeManager(spawner: spawner).shutdown()
        XCTAssertEqual(spawner.spawnCount, 0)
    }

    // MARK: Launch arguments

    func testLaunchArgumentsCarryEveryLoadBearingFlag() {
        let arguments = WebBrowserManager.launchArguments(profileDirectory: "/tmp/web-profile")
        XCTAssertEqual(
            arguments,
            [
                "--headless=new",
                "--remote-debugging-port=0",
                "--remote-allow-origins=*",
                "--user-data-dir=/tmp/web-profile",
                "--no-first-run",
                "--no-default-browser-check",
                "--window-size=1440,900",
                "about:blank",
            ],
        )
    }

    func testAllowedOriginsAreWideOpen() {
        // Chrome 111+ closes any debugging websocket whose `Origin` is not allow-listed, and the
        // frontend is loaded from the client's own loopback origin — a port that varies per client
        // and per machine, so there is nothing narrower to name. The mesh is the boundary.
        XCTAssertTrue(
            WebBrowserManager.launchArguments(profileDirectory: "/tmp/p").contains("--remote-allow-origins=*"),
        )
    }

    func testProfileDirectoryIsNeverTheDefaultOne() {
        // Chrome 136+ REFUSES remote debugging on the OS-default profile, and a Chrome the user is
        // already running holds its lock. The flag must always name a directory of ours.
        let arguments = WebBrowserManager.launchArguments(profileDirectory: "/tmp/web-profile")
        XCTAssertEqual(arguments.filter { $0.hasPrefix("--user-data-dir=") }.count, 1)
    }

    // MARK: Port parsing

    func testParsesChromesAnnounceLine() {
        XCTAssertEqual(
            WebBrowserManager.parseDevToolsPort(
                fromLogLine:
                "DevTools listening on ws://127.0.0.1:59123/devtools/browser/6f0f1c0e-1a2b-3c4d-5e6f-708192a3b4c5",
            ),
            59123,
        )
    }

    func testParsesATimestampedAnnounceLine() {
        XCTAssertEqual(
            WebBrowserManager.parseDevToolsPort(
                fromLogLine: "[12345:259:0805/091500.123456:INFO:devtools_http_handler.cc(326)] "
                    + "DevTools listening on ws://127.0.0.1:60001/devtools/browser/abc",
            ),
            60001,
        )
    }

    func testIgnoresUnrelatedLines() {
        for line in [
            "",
            "DevTools listening on ws://127.0.0.1:/devtools/browser/abc",
            "DevTools listening on ws://127.0.0.1:notaport/devtools/browser/abc",
            "DevTools listening on ws://127.0.0.1:0/devtools/browser/abc",
            "Opening in existing browser session.",
            "connecting to ws://127.0.0.1:9222/devtools/page/1",
            "[ERROR:socket_posix.cc] bind() failed on 127.0.0.1:9222",
        ] {
            XCTAssertNil(
                WebBrowserManager.parseDevToolsPort(fromLogLine: line), "unexpected match: \(line)",
            )
        }
    }

    func testRejectsAPortAboveTheSixteenBitRange() {
        XCTAssertNil(
            WebBrowserManager.parseDevToolsPort(fromLogLine: "DevTools listening on ws://127.0.0.1:70000/devtools/x"),
        )
    }

    // MARK: Profile directory

    func testProfileDirectoryOverrideWins() {
        XCTAssertEqual(
            WebBrowserManager.profileDirectory(
                environment: [WebBrowserManager.profileDirectoryEnvKey: "/tmp/somewhere-else"],
            )?.path,
            "/tmp/somewhere-else",
        )
    }

    func testProfileDirectoryLivesInsideTheAppSupportContainer() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-web-profile-test-\(UUID().uuidString)", isDirectory: true)
        let resolved = try XCTUnwrap(
            WebBrowserManager.profileDirectory(environment: [SlopDeskAppSupport.directoryEnvKey: container.path]),
        )
        XCTAssertEqual(resolved.path, container.appendingPathComponent("web-profile").path)
    }

    /// A `Sendable` box for a probe answer the test flips mid-run.
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool {
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
}

/// ``WebBrowserToolchain``: which browsers count, and in what order. The search runs over a temp
/// tree rather than the real `/Applications`, so the result does not depend on what this machine
/// has installed.
final class WebBrowserToolchainTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-browser-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates an executable file at `relative`, returning its path.
    @discardableResult
    private func makeExecutable(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testPrefersChromeOverTheOtherBlinkBrowsers() throws {
        // Any Blink browser serves the same DevTools frontend, so the others are real fallbacks —
        // but the pages under test are written for Chrome, so Chrome leads.
        try makeExecutable("apps/Brave Browser.app/Contents/MacOS/Brave Browser")
        let chrome = try makeExecutable("apps/Google Chrome.app/Contents/MacOS/Google Chrome")

        XCTAssertEqual(
            WebBrowserToolchain.resolve(
                applicationDirectories: [root.appendingPathComponent("apps").path], pathDirectories: [],
            ),
            chrome,
        )
    }

    func testFallsBackToAnotherBlinkBrowser() throws {
        let edge = try makeExecutable("apps/Microsoft Edge.app/Contents/MacOS/Microsoft Edge")
        XCTAssertEqual(
            WebBrowserToolchain.resolve(
                applicationDirectories: [root.appendingPathComponent("apps").path], pathDirectories: [],
            ),
            edge,
        )
    }

    func testSystemApplicationsBeatTheUsersOwn() throws {
        let system = try makeExecutable("apps/Google Chrome.app/Contents/MacOS/Google Chrome")
        try makeExecutable("home/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

        XCTAssertEqual(
            WebBrowserToolchain.resolve(
                applicationDirectories: [
                    root.appendingPathComponent("apps").path,
                    root.appendingPathComponent("home/Applications").path,
                ],
                pathDirectories: [],
            ),
            system,
        )
    }

    func testBundlesBeatPathNames() throws {
        // A `PATH` name is usually a wrapper script; the bundle executable is the real binary that
        // takes `--remote-debugging-port`.
        let bundle = try makeExecutable("apps/Chromium.app/Contents/MacOS/Chromium")
        try makeExecutable("bin/chromium")

        XCTAssertEqual(
            WebBrowserToolchain.resolve(
                applicationDirectories: [root.appendingPathComponent("apps").path],
                pathDirectories: [root.appendingPathComponent("bin").path],
            ),
            bundle,
        )
    }

    func testPathFallbackForANonBundleInstall() throws {
        let binary = try makeExecutable("bin/google-chrome")
        XCTAssertEqual(
            WebBrowserToolchain.resolve(
                applicationDirectories: [root.appendingPathComponent("missing").path],
                pathDirectories: [root.appendingPathComponent("bin").path],
            ),
            binary,
        )
    }

    func testNoBrowserResolvesToNil() {
        XCTAssertNil(
            WebBrowserToolchain.resolve(
                applicationDirectories: [root.appendingPathComponent("missing").path],
                pathDirectories: [root.appendingPathComponent("also-missing").path],
            ),
        )
    }

    func testOverrideNamesTheBinaryExactly() throws {
        let binary = try makeExecutable("custom/my-chrome")
        XCTAssertEqual(
            WebBrowserToolchain.locate(environment: [WebBrowserToolchain.overrideVariable: binary]), binary,
        )
    }

    func testSetButUnrunnableOverrideResolvesToNilRatherThanSearching() throws {
        // An operator who named a binary meant THAT one; falling through would silently drive a
        // different browser than the one they pointed at.
        try makeExecutable("apps/Google Chrome.app/Contents/MacOS/Google Chrome")
        XCTAssertNil(
            WebBrowserToolchain.locate(
                environment: [
                    WebBrowserToolchain.overrideVariable: root.appendingPathComponent("custom/absent").path,
                    "HOME": root.path,
                ],
            ),
        )
    }

    func testUsersApplicationsComeFromTheEnvironmentsHome() {
        // Never `NSHomeDirectory()`: a hostd whose `HOME` was overridden must resolve against THAT
        // home. A relative or empty value names no directory and is dropped.
        XCTAssertEqual(
            WebBrowserToolchain.applicationDirectories(environment: ["HOME": "/Users/someone"]),
            ["/Applications", "/Users/someone/Applications"],
        )
        XCTAssertEqual(WebBrowserToolchain.applicationDirectories(environment: [:]), ["/Applications"])
        XCTAssertEqual(
            WebBrowserToolchain.applicationDirectories(environment: ["HOME": "relative/path"]), ["/Applications"],
        )
    }
}

/// ``HostWebPerformer`` routing: verb 23 → the manager; every other verb → `nil` (fall through to
/// the read-only builder).
final class HostWebPerformerTests: XCTestCase {
    private final class NeverExitingHandle: HostServiceProcessHandle, @unchecked Sendable {
        var isRunning: Bool { true }
        func terminate() {}
    }

    private func makeManager(binary: String? = "/fake/Google Chrome") -> WebBrowserManager {
        WebBrowserManager(
            binaryLocator: { binary },
            profileLocator: { "/fake/profile" },
            spawner: { _, _, _ in NeverExitingHandle() },
            readinessProbe: { _ in false },
            relayFactory: { _ in nil },
            probeInterval: .zero,
        )
    }

    func testOtherVerbsFallThrough() {
        for verb in MetadataVerb.allCases where verb != .ensureWebBrowser {
            XCTAssertNil(
                HostWebPerformer.response(
                    requestID: 1, verb: verb.rawValue, payload: Data(), manager: makeManager(),
                ),
                "verb \(verb) must fall through to the read-only builder",
            )
        }
        XCTAssertNil(
            HostWebPerformer.response(requestID: 1, verb: 250, payload: Data(), manager: makeManager()),
            "an unknown future verb must fall through (the builder answers unsupportedVerb)",
        )
    }

    func testEnsureAnswersTheEncodedEndpoint() throws {
        let response = HostWebPerformer.response(
            requestID: 42, verb: MetadataVerb.ensureWebBrowser.rawValue, payload: Data(),
            manager: makeManager(),
        )
        guard case let .metadataResponse(requestID, status, payload)? = response else {
            XCTFail("expected a metadataResponse")
            return
        }
        XCTAssertEqual(requestID, 42)
        XCTAssertEqual(status, MetadataStatus.ok.rawValue)
        try XCTAssertEqual(
            MetadataCodec.decodeServiceEndpoint(payload),
            MetadataCodec.ServiceEndpoint(state: .starting, port: 0),
        )
    }

    func testHostWithoutABrowserStillAnswersOK() throws {
        // No browser is a normal answer, not a failure: the panel renders the install hint. An
        // `error` status would make the client show "offline" and keep retrying blind.
        let response = HostWebPerformer.response(
            requestID: 5, verb: MetadataVerb.ensureWebBrowser.rawValue, payload: Data(),
            manager: makeManager(binary: nil),
        )
        guard case let .metadataResponse(_, status, payload)? = response else {
            XCTFail("expected a metadataResponse")
            return
        }
        XCTAssertEqual(status, MetadataStatus.ok.rawValue)
        try XCTAssertEqual(MetadataCodec.decodeServiceEndpoint(payload).state, .unavailable)
    }

    func testNonEmptyPayloadIsError() {
        // The request is defined as empty. Silently ignoring trailing bytes would let a future
        // client add a field that this host drops without either side noticing.
        let response = HostWebPerformer.response(
            requestID: 9, verb: MetadataVerb.ensureWebBrowser.rawValue, payload: Data([0x00]),
            manager: makeManager(),
        )
        guard case let .metadataResponse(requestID, status, payload)? = response else {
            XCTFail("expected a metadataResponse")
            return
        }
        XCTAssertEqual(requestID, 9)
        XCTAssertEqual(status, MetadataStatus.error.rawValue)
        XCTAssertTrue(payload.isEmpty)
    }
}
