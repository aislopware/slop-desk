import XCTest
@testable import AislopdeskClientUI

/// Pins the secret-aware paste guard (`SecretPasteClassifier`) that gates "Paste as Keystrokes": refuse an
/// over-long payload, warn before a bulk/multi-line paste into a password field, warn before typing a
/// credential into an echoing field, and stay quiet for ordinary text + normal passwords.
final class SecretPasteClassifierTests: XCTestCase {
    func testOverLongIsTooLarge() {
        let big = String(repeating: "a", count: KeystrokeReplay.maxLength + 1)
        XCTAssertEqual(SecretPasteClassifier.assess(text: big, targetIsSecure: true), .tooLarge)
        XCTAssertEqual(SecretPasteClassifier.assess(text: big, targetIsSecure: false), .tooLarge)
    }

    func testBulkIntoSecureFieldWarns() {
        // Multi-line into a password field is a mis-paste.
        XCTAssertEqual(
            SecretPasteClassifier.assess(text: "line one\nline two", targetIsSecure: true),
            .bulkIntoSecureField,
        )
        // A very long single line into a password field is also suspicious.
        let long = String(repeating: "x", count: 300)
        XCTAssertEqual(SecretPasteClassifier.assess(text: long, targetIsSecure: true), .bulkIntoSecureField)
    }

    func testNormalPasswordIntoSecureFieldIsOK() {
        XCTAssertEqual(SecretPasteClassifier.assess(text: "Hunter2-Pa$$w0rd", targetIsSecure: true), .ok)
        // A single-line diceware passphrase (has spaces, but it's the password) is fine into a secure field.
        XCTAssertEqual(SecretPasteClassifier.assess(text: "correct horse battery staple", targetIsSecure: true), .ok)
    }

    func testSecretIntoInsecureFieldWarns() {
        // A high-entropy token typed into a NON-secure (echoing) field is a leak risk.
        let token = "aB3dE6fG9hJ2kL5mN8pQ1rS4tU7vW0xY" // 32 chars, mixed classes, no spaces
        XCTAssertEqual(SecretPasteClassifier.assess(text: token, targetIsSecure: false), .secretIntoInsecureField)
        // A recognized key=value secret too.
        XCTAssertEqual(
            SecretPasteClassifier.assess(text: "PASSWORD=s3cr3tValueHere", targetIsSecure: false),
            .secretIntoInsecureField,
        )
    }

    func testDigitFreeHighEntropyTokenIsFlagged() {
        // A random base64 secret with no digit (or single-case) must still warn — the digit requirement
        // was redundant with the redactor's own digit lookahead and left these uncovered on both paths.
        let token = "AbCdEfGhIjKlMnOpQrStUvWxYzAbCdEfGh" // 34 chars, no digit, mixed case, high entropy
        XCTAssertTrue(SecretPasteClassifier.looksSecret(token))
        XCTAssertEqual(SecretPasteClassifier.assess(text: token, targetIsSecure: false), .secretIntoInsecureField)
    }

    func testOrdinaryTextIntoInsecureFieldIsOK() {
        XCTAssertEqual(SecretPasteClassifier.assess(text: "ls -la", targetIsSecure: false), .ok)
        XCTAssertEqual(
            SecretPasteClassifier.assess(text: "git commit -m \"fix the thing\"", targetIsSecure: false),
            .ok,
        )
        XCTAssertEqual(SecretPasteClassifier.assess(text: "~/Workspace/oss/aislopdesk", targetIsSecure: false), .ok)
        XCTAssertEqual(SecretPasteClassifier.assess(text: "hello", targetIsSecure: false), .ok)
    }

    func testLooksSecretHeuristic() {
        XCTAssertTrue(SecretPasteClassifier.looksSecret("aB3dE6fG9hJ2kL5mN8pQ1rS4tU7vW0xY"), "high-entropy token")
        XCTAssertFalse(SecretPasteClassifier.looksSecret("the quick brown fox"), "a sentence is not a secret")
        XCTAssertFalse(SecretPasteClassifier.looksSecret("/usr/local/bin/swift"), "a path is not a secret")
        XCTAssertFalse(SecretPasteClassifier.looksSecret("short"), "too short")
    }

    func testEntropyOrdering() {
        let repeated = SecretPasteClassifier.shannonEntropyPerChar("aaaaaaaaaaaaaaaa")
        let mixed = SecretPasteClassifier.shannonEntropyPerChar("aB3dE6fG9hJ2kL5m")
        XCTAssertEqual(repeated, 0, accuracy: 1e-9, "a single repeated char has zero entropy")
        XCTAssertGreaterThan(mixed, 3.0, "a mixed random token has high per-char entropy")
    }
}
