// ToastSecretRedactionTests — pins that the in-app OSC 9/777 toast masks likely secrets when
// `redactSecrets` (default ON) is set, at the SAME ingress as the macOS Notification-Center banner
// (`CommandCompletionNotifier`) and the redacted sidebar/pill title (`PanePresentation`).
//
// The toast push sat OUTSIDE the `#if os(macOS)` redaction guard, so the toast — the ONLY notification
// surface on iOS — rendered an OSC-supplied API key / token VERBATIM. Revert-to-confirm-fail: remove the
// `SecretRedactor.redact` call inside `Toast.explicitOSC` / `Toast.redactSecretsIfEnabled` and
// `testOSCToastMasksSecretWhenOn` fails (the AWS key appears verbatim in the constructed Toast's title).
//
// Pure value-type construction — no view, no SCStream/VT/Metal (hang-safe).

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

final class ToastSecretRedactionTests: XCTestCase {
    private var priorRedact: Any?

    override func setUp() {
        super.setUp()
        priorRedact = SettingsKey.store.object(forKey: SettingsKey.redactSecrets)
    }

    override func tearDown() {
        if let priorRedact {
            SettingsKey.store.set(priorRedact, forKey: SettingsKey.redactSecrets)
        } else {
            SettingsKey.store.removeObject(forKey: SettingsKey.redactSecrets)
        }
        super.tearDown()
    }

    /// A canonical AWS access-key id in an OSC 9/777 title is masked in the Toast that the in-app surface
    /// builds — the key never reaches `Toast.title` verbatim. This is the on-screen / iOS leak the finding
    /// flagged; it fails if the redaction inside `Toast.explicitOSC` is removed.
    func testOSCToastMasksSecretWhenOn() {
        SettingsKey.store.set(true, forKey: SettingsKey.redactSecrets)
        XCTAssertTrue(SettingsKey.redactSecretsEnabled, "precondition: redactSecrets ON")

        let secretKey = "AKIAIOSFODNN7EXAMPLE" // AKIA + 16 — masked whole by SecretRedactor rule 3.
        let secretToken = "ghp_0123456789abcdefghijklmnopqrstuvwx"
        let toast = Toast.explicitOSC(
            paneIDRaw: UUID(),
            title: "Deploy complete \(secretKey)",
            body: "token=\(secretToken)",
        )

        XCTAssertFalse(toast.title.contains(secretKey), "secret AWS key must not appear verbatim in the toast title")
        XCTAssertTrue(toast.title.contains(SecretRedactor.mask), "the key is replaced by the redaction mask")
        XCTAssertEqual(toast.title, "Deploy complete \(SecretRedactor.mask)")
        XCTAssertNotNil(toast.body)
        XCTAssertFalse(toast.body?.contains(secretToken) ?? true, "secret token must not appear verbatim in the body")
    }

    /// When the opt-out is OFF the title/body pass through verbatim — proving the toast HONORS the gate
    /// (it is not unconditionally masking, and it is not unconditionally leaking).
    func testOSCToastPassesThroughWhenOff() {
        SettingsKey.store.set(false, forKey: SettingsKey.redactSecrets)
        XCTAssertFalse(SettingsKey.redactSecretsEnabled, "precondition: redactSecrets OFF")

        let secretKey = "AKIAIOSFODNN7EXAMPLE"
        let toast = Toast.explicitOSC(paneIDRaw: UUID(), title: "Deploy complete \(secretKey)", body: nil)
        XCTAssertEqual(toast.title, "Deploy complete \(secretKey)", "OFF ⇒ verbatim title")
    }

    // MARK: - Long-command completion toast (the iOS-only notification surface)

    /// The LONG-command "your build finished" toast carries the live OSC 0/2 pane title (`mysql -pSECRET` and
    /// the like). With redaction ON it must be masked at the `Toast.longCommand` construction site — the same
    /// leak the OSC toast had, on the only iOS notification surface. REVERT-TO-CONFIRM-FAIL: drop the
    /// `redactSecretsIfEnabled(paneTitle)` call inside `Toast.longCommand` and this fails (the password value
    /// appears verbatim in the toast title).
    func testLongCommandToastMasksSecretTitleWhenOn() {
        SettingsKey.store.set(true, forKey: SettingsKey.redactSecrets)
        XCTAssertTrue(SettingsKey.redactSecretsEnabled, "precondition: redactSecrets ON")

        let secretValue = "supersecretvalue123"
        let toast = Toast.longCommand(
            paneIDKey: UUID().uuidString,
            paneTitle: "Deploy PASSWORD=\(secretValue)",
            exitCode: 0,
            durationMS: 42000,
        )
        XCTAssertFalse(toast.title.contains(secretValue), "the PASSWORD value must not appear verbatim in the title")
        XCTAssertTrue(toast.title.contains(SecretRedactor.mask), "the secret is replaced by the redaction mask")
        XCTAssertEqual(toast.flavor, .success, "a clean (exit 0) long command is a success toast")
        // The body is a fixed exit-code + duration template — no untrusted text to leak.
        XCTAssertEqual(toast.body, "command finished (exit 0, 42s)")
    }

    /// With the opt-out OFF the long-command title passes through verbatim — proving the new factory HONORS the
    /// gate (mirrors `testOSCToastPassesThroughWhenOff`).
    func testLongCommandToastPassesThroughWhenOff() {
        SettingsKey.store.set(false, forKey: SettingsKey.redactSecrets)
        XCTAssertFalse(SettingsKey.redactSecretsEnabled, "precondition: redactSecrets OFF")

        let secretValue = "supersecretvalue123"
        let toast = Toast.longCommand(
            paneIDKey: UUID().uuidString,
            paneTitle: "Deploy PASSWORD=\(secretValue)",
            exitCode: 1,
            durationMS: 12000,
        )
        XCTAssertEqual(toast.title, "Deploy PASSWORD=\(secretValue)", "OFF ⇒ verbatim title")
        XCTAssertEqual(toast.flavor, .error, "a non-zero exit is an error toast")
    }

    /// An empty pane title falls back to the fixed "Command finished" string (never blank, never redacted —
    /// there is no untrusted text to mask).
    func testLongCommandToastEmptyTitleFallsBack() {
        SettingsKey.store.set(true, forKey: SettingsKey.redactSecrets)
        let toast = Toast.longCommand(paneIDKey: UUID().uuidString, paneTitle: "", exitCode: 0, durationMS: 10000)
        XCTAssertEqual(toast.title, "Command finished")
    }
}
