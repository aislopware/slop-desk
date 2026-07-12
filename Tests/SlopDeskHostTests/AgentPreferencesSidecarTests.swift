import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskHost

/// The two host-LOCAL agent flags (prevent-sleep, resume-on-recovery) round-trip
/// from the ``AgentPreferences`` sidecar through ``EnvBridge`` into the ``HostEnvironment`` readers, with the
/// correct default idiom on each (prevent-sleep DEFAULT-OFF `== "1"`, resume-on-recovery DEFAULT-ON `!= "0"`).
final class AgentPreferencesSidecarTests: XCTestCase {
    override func tearDown() {
        EnvConfig.overlay = [:] // the overlay is process-wide; never leak a reaches-consumer override
        super.tearDown()
    }

    // MARK: SLOPDESK_AGENT_PREVENT_SLEEP — DEFAULT-OFF (`== "1"`)

    func testPreventSleepDefaultsOff() {
        let key = HostEnvironment.agentPreventSleepEnvKey
        XCTAssertFalse(HostEnvironment.agentPreventSleepEnabled(environment: [:]), "unset → disabled (default-OFF)")
        XCTAssertFalse(HostEnvironment.agentPreventSleepEnabled(environment: [key: "0"]))
        XCTAssertFalse(
            HostEnvironment.agentPreventSleepEnabled(environment: [key: "yes"]),
            "only the exact string \"1\" enables",
        )
        XCTAssertTrue(HostEnvironment.agentPreventSleepEnabled(environment: [key: "1"]))
    }

    // MARK: SLOPDESK_AGENT_RESUME_ON_RECOVERY — DEFAULT-ON (`!= "0"`)

    func testResumeOnRecoveryDefaultsOn() {
        let key = HostEnvironment.agentResumeOnRecoveryEnvKey
        XCTAssertTrue(HostEnvironment.agentResumeOnRecoveryEnabled(environment: [:]), "unset → enabled (default-ON)")
        XCTAssertTrue(HostEnvironment.agentResumeOnRecoveryEnabled(environment: [key: "1"]))
        XCTAssertTrue(
            HostEnvironment.agentResumeOnRecoveryEnabled(environment: [key: "anything"]),
            "any value other than exactly \"0\" enables",
        )
        XCTAssertFalse(
            HostEnvironment.agentResumeOnRecoveryEnabled(environment: [key: "0"]),
            "only the exact string \"0\" disables",
        )
    }

    // MARK: EnvBridge → HostEnvironment round-trip (the sidecar transport preserves polarity)

    func testPreferencesRoundTripThroughEnvReaders() {
        // ON prevent-sleep + OFF resume → the readers resolve exactly those values.
        let onOff = EnvBridge.toEnv(AgentPreferences(preventSleep: true, resumeOnRecovery: false))
        XCTAssertTrue(HostEnvironment.agentPreventSleepEnabled(environment: onOff))
        XCTAssertFalse(HostEnvironment.agentResumeOnRecoveryEnabled(environment: onOff))

        // OFF prevent-sleep + ON resume.
        let offOn = EnvBridge.toEnv(AgentPreferences(preventSleep: false, resumeOnRecovery: true))
        XCTAssertFalse(HostEnvironment.agentPreventSleepEnabled(environment: offOn))
        XCTAssertTrue(HostEnvironment.agentResumeOnRecoveryEnabled(environment: offOn))
    }

    /// A default (all-`nil`) ``AgentPreferences`` contributes NO entries, so the readers keep their compile-time
    /// defaults (prevent-sleep OFF, resume-on-recovery ON) — the empty-overlay behaviour-preservation rule.
    func testDefaultPreferencesLeaveCompileTimeDefaults() {
        let env = EnvBridge.toEnv(AgentPreferences())
        XCTAssertNil(env["SLOPDESK_AGENT_PREVENT_SLEEP"])
        XCTAssertNil(env["SLOPDESK_AGENT_RESUME_ON_RECOVERY"])
        XCTAssertFalse(HostEnvironment.agentPreventSleepEnabled(environment: env))
        XCTAssertTrue(HostEnvironment.agentResumeOnRecoveryEnabled(environment: env))
    }

    // "Resume Session on Recovery" maps onto `DetachedSessionStore`, so the actuation AND-s the flag into
    // `HostServer.detachEnabled` — the single reattach gate. These pin that the consumer exists: OFF forces
    // detach off (a recovered terminal spawns a fresh shell instead of reattaching), ON leaves it on.
    // Regression guard: a `detachEnabled` that ignores the flag and stays ON regardless fails both.

    // MARK: - ACTUATION — `resumeOnRecovery` gates `HostServer.detachEnabled` (the reattach machinery)

    /// Explicit override: `resumeOnRecovery: false` forces `detachEnabled` off even when detach is requested.
    func testResumeOffForcesDetachOffViaInitOverride() {
        let on = HostServer(port: 0, detachEnabled: true, resumeOnRecovery: true)
        XCTAssertTrue(on.detachEnabled, "resume ON + detach requested ⇒ reattach machinery stays enabled")
        XCTAssertTrue(on.resumeOnRecovery)

        let off = HostServer(port: 0, detachEnabled: true, resumeOnRecovery: false)
        XCTAssertFalse(
            off.detachEnabled,
            "resume OFF must disable the reattach machinery — recovery spawns a fresh shell, not a no-op toggle",
        )
        XCTAssertFalse(off.resumeOnRecovery)
    }

    /// The sidecar path: a client `resumeOnRecovery: false` reaches the host as `SLOPDESK_AGENT_RESUME_ON_RECOVERY=0`
    /// (the EnvConfig overlay), and a default-constructed `HostServer` (flag `nil` ⇒ reads the env) actuates it
    /// — proving the wire from the toggle to the detach gate is live, not the old zero-consumer reader.
    func testResumeFlagFromSidecarOverlayActuatesDetachGate() {
        // resume=0 via the same overlay the sidecar populates → detach forced off.
        EnvConfig.overlay = EnvBridge.toEnv(AgentPreferences(resumeOnRecovery: false))
        let serverOff = HostServer(port: 0, detachEnabled: true)
        XCTAssertFalse(
            serverOff.detachEnabled,
            "sidecar resume=0 must reach HostServer and disable detach (the actuation consumer)",
        )

        // resume=1 → detach honoured.
        EnvConfig.overlay = EnvBridge.toEnv(AgentPreferences(resumeOnRecovery: true))
        let serverOn = HostServer(port: 0, detachEnabled: true)
        XCTAssertTrue(serverOn.detachEnabled, "sidecar resume=1 leaves the detach/reattach machinery enabled")
    }
}
