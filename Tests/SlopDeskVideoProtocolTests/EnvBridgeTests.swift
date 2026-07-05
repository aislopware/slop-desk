import Foundation
import XCTest
@testable import SlopDeskVideoProtocol

/// W12 bridge tests: setting → env mapping, the symmetric-key flagging, the `video-prefs.json`
/// sidecar round-trip, and the daemon-launch overlay fold. The load-bearing assertion is that a
/// DEFAULT (all-`nil`) ``VideoPreferences`` maps to an EMPTY overlay — so the empty-overlay
/// behaviour-preservation invariant in ``EnvConfigTests`` is reachable from the real settings model.
final class EnvBridgeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EnvConfig.overlay = [:]
    }

    override func tearDown() {
        EnvConfig.overlay = [:]
        super.tearDown()
    }

    // MARK: VideoPreferences → env

    /// A default (unset) model emits NO env entries — the empty-overlay invariant's source.
    func testDefaultVideoPreferencesEmitsEmptyEnv() {
        XCTAssertTrue(EnvBridge.toEnv(VideoPreferences()).isEmpty)
    }

    func testVideoPreferencesMapsKeys() {
        let prefs = VideoPreferences(
            qpSharp: 22,
            qpCoarse: 44,
            qpDecouple: true,
            fecM: 2,
            fecK: 5,
            pacer: .deadline,
            playoutMs: 10,
            captureScale: 1,
            displayCapture: .include,
            virtualDisplay: false,
            sharpen: 0.4,
        )
        let env = EnvBridge.toEnv(prefs)
        XCTAssertEqual(env["SLOPDESK_QP_SHARP"], "22")
        XCTAssertEqual(env["SLOPDESK_QP_COARSE"], "44")
        XCTAssertEqual(env["SLOPDESK_QP_DECOUPLE"], "1")
        XCTAssertEqual(env["SLOPDESK_FEC_M"], "2")
        XCTAssertEqual(env["SLOPDESK_FEC_K"], "5")
        XCTAssertEqual(env["SLOPDESK_PACER"], "deadline")
        XCTAssertEqual(env["SLOPDESK_PLAYOUT_MS"], "10") // integral double prints without ".0"
        XCTAssertEqual(env["SLOPDESK_CAPTURE_SCALE"], "1")
        XCTAssertEqual(env["SLOPDESK_DISPLAY_CAPTURE"], "include")
        XCTAssertEqual(env["SLOPDESK_VD"], "0") // virtualDisplay OFF ⇒ the "0" the !="0" site reads
        XCTAssertEqual(env["SLOPDESK_SHARPEN"], "0.4")
    }

    /// The `SLOPDESK_VD` mapping survives a ROUND-TRIP through the actual default-ON read idiom: an
    /// OFF pref makes the `!= "0"` site read false; an ON pref (or unset) reads true.
    func testVirtualDisplayPolarityRoundTrips() {
        EnvConfig.overlay = EnvBridge.toEnv(VideoPreferences(virtualDisplay: false))
        XCTAssertFalse(EnvConfig.boolDefaultOn("SLOPDESK_VD")) // OFF
        EnvConfig.overlay = EnvBridge.toEnv(VideoPreferences(virtualDisplay: true))
        XCTAssertTrue(EnvConfig.boolDefaultOn("SLOPDESK_VD")) // ON
        EnvConfig.overlay = EnvBridge.toEnv(VideoPreferences()) // unset
        XCTAssertTrue(EnvConfig.boolDefaultOn("SLOPDESK_VD")) // default ON
    }

    func testAgentPreferencesMapsKeys() {
        XCTAssertTrue(EnvBridge.toEnv(AgentPreferences()).isEmpty) // unset ⇒ empty
        let env = EnvBridge.toEnv(AgentPreferences(agentDetect: true, agentHooks: false))
        XCTAssertEqual(env["SLOPDESK_AGENT_DETECT"], "1")
        XCTAssertEqual(env["SLOPDESK_AGENT_HOOKS"], "0")
        // Default-OFF read idiom: detect ON reads true, hooks OFF reads false.
        EnvConfig.overlay = env
        XCTAssertTrue(EnvConfig.boolDefaultOff("SLOPDESK_AGENT_DETECT"))
        XCTAssertFalse(EnvConfig.boolDefaultOff("SLOPDESK_AGENT_HOOKS"))
    }

    /// E13 WI-3: the two new sidecar agent flags map 1:1 to their host env keys; an unset field emits nothing.
    func testAgentPreferencesMapsPreventSleepAndResumeKeys() {
        // Only the new fields set — the detect/hooks keys stay absent (unset emits nothing).
        let onOff = EnvBridge.toEnv(AgentPreferences(preventSleep: true, resumeOnRecovery: false))
        XCTAssertEqual(onOff["SLOPDESK_AGENT_PREVENT_SLEEP"], "1")
        XCTAssertEqual(onOff["SLOPDESK_AGENT_RESUME_ON_RECOVERY"], "0")
        XCTAssertNil(onOff["SLOPDESK_AGENT_DETECT"], "an unset field emits nothing")
        XCTAssertNil(onOff["SLOPDESK_AGENT_HOOKS"])

        let offOn = EnvBridge.toEnv(AgentPreferences(preventSleep: false, resumeOnRecovery: true))
        XCTAssertEqual(offOn["SLOPDESK_AGENT_PREVENT_SLEEP"], "0")
        XCTAssertEqual(offOn["SLOPDESK_AGENT_RESUME_ON_RECOVERY"], "1")
    }

    // MARK: Symmetric keys

    func testSymmetricKeysFlagged() {
        XCTAssertTrue(EnvBridge.symmetricKeys.contains("SLOPDESK_FEC_M"))
        XCTAssertTrue(EnvBridge.symmetricKeys.contains("SLOPDESK_FEC_K"))
        XCTAssertTrue(EnvBridge.symmetricKeys.contains("SLOPDESK_MUX_WINDOW"))
        // A host-only key (QP sharp) is NOT symmetric.
        XCTAssertFalse(EnvBridge.symmetricKeys.contains("SLOPDESK_QP_SHARP"))
    }

    // MARK: Sidecar round-trip

    func testSidecarRoundTrip() throws {
        let sidecar = EnvBridge.VideoSidecar(
            video: VideoPreferences(qpSharp: 24, fecM: 2, fecK: 5, virtualDisplay: false),
            agent: AgentPreferences(agentDetect: true),
        )
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-w12-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("video-prefs.json")

        try EnvBridge.writeSidecar(sidecar, to: url)
        let read = EnvBridge.readSidecar(at: url)
        XCTAssertEqual(read, sidecar)

        // The combined env overlay it contributes (video ∪ agent).
        let env = sidecar.toEnv()
        XCTAssertEqual(env["SLOPDESK_QP_SHARP"], "24")
        XCTAssertEqual(env["SLOPDESK_FEC_M"], "2")
        XCTAssertEqual(env["SLOPDESK_VD"], "0")
        XCTAssertEqual(env["SLOPDESK_AGENT_DETECT"], "1")
    }

    /// Raw overrides survive the sidecar round-trip AND take LAST-WINS precedence over a typed field for
    /// the same key — so a host-only knob typed in the free-text box reaches the daemon (BUG B).
    func testSidecarRawOverridesRoundTripAndPrecedence() throws {
        let sidecar = EnvBridge.VideoSidecar(
            video: VideoPreferences(qpSharp: 24, fecM: 2),
            agent: AgentPreferences(agentDetect: true),
            rawOverrides: ["SLOPDESK_QP_SHARP": "18", "SLOPDESK_HOST_ONLY": "z"],
        )
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-w12-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("video-prefs.json")

        try EnvBridge.writeSidecar(sidecar, to: url)
        let read = EnvBridge.readSidecar(at: url)
        XCTAssertEqual(read, sidecar)
        XCTAssertEqual(read?.rawOverrides, ["SLOPDESK_QP_SHARP": "18", "SLOPDESK_HOST_ONLY": "z"])

        // The combined overlay: a raw override folds LAST, so it beats the typed field for the SAME key,
        // and a host-only key the typed fields never emit still lands.
        let env = sidecar.toEnv()
        XCTAssertEqual(env["SLOPDESK_QP_SHARP"], "18", "raw override wins over the typed field")
        XCTAssertEqual(env["SLOPDESK_FEC_M"], "2")
        XCTAssertEqual(env["SLOPDESK_HOST_ONLY"], "z")
        XCTAssertEqual(env["SLOPDESK_AGENT_DETECT"], "1")
    }

    /// A stale sidecar written BEFORE `rawOverrides` existed must still decode (→ empty), not brick the
    /// daemon — the [[rwork-no-backcompat]] "new optional field" discipline.
    func testSidecarWithoutRawOverridesFieldDecodes() throws {
        let json = """
        { "schemaVersion": 1, "video": {}, "agent": {} }
        """
        let read = try JSONDecoder().decode(EnvBridge.VideoSidecar.self, from: Data(json.utf8))
        XCTAssertEqual(read.rawOverrides, [:])
        XCTAssertEqual(read.schemaVersion, 1)
    }

    /// A missing or malformed sidecar returns `nil` (validate-then-drop) — the daemon must not brick.
    func testSidecarMissingOrMalformedReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-w12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appendingPathComponent("nope.json")
        XCTAssertNil(EnvBridge.readSidecar(at: missing))

        let bad = dir.appendingPathComponent("bad.json")
        try Data("{ not valid json ".utf8).write(to: bad)
        XCTAssertNil(EnvBridge.readSidecar(at: bad))
    }

    // MARK: Daemon-launch overlay fold

    func testLoadSidecarFillsOverlayButRealEnvWins() throws {
        let sidecar = EnvBridge.VideoSidecar(video: VideoPreferences(qpSharp: 24, virtualDisplay: false))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-w12-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("video-prefs.json")
        try EnvBridge.writeSidecar(sidecar, to: url)

        // A key already in the overlay (simulating an explicit env / earlier write) is NOT clobbered.
        var overlay = ["SLOPDESK_QP_SHARP": "30"]
        let applied = EnvBridge.loadSidecar(at: url, into: &overlay)
        XCTAssertEqual(overlay["SLOPDESK_QP_SHARP"], "30") // pre-existing wins
        XCTAssertEqual(overlay["SLOPDESK_VD"], "0") // gap filled from the sidecar
        XCTAssertTrue(applied.contains("SLOPDESK_VD"))
        XCTAssertFalse(applied.contains("SLOPDESK_QP_SHARP"))
    }
}
