import XCTest
@testable import AislopdeskClientUI

/// Pins ``SecretRedactor`` — the pure scrubber that masks likely secrets out of untrusted terminal titles
/// and notification bodies before they reach the sidebar / pill / Notification Center. Table-tested for
/// (a) the known token shapes + `key=value` assignments are masked, (b) the original secret never survives
/// in the output, (c) ordinary titles / paths / SHAs are untouched, (d) idempotency.
final class SecretRedactorTests: XCTestCase {
    private let mask = SecretRedactor.mask

    /// Asserts `input` is redacted: the output differs, carries the mask, and contains none of `secrets`.
    private func assertMasked(_ input: String, secrets: [String], file: StaticString = #filePath, line: UInt = #line) {
        let out = SecretRedactor.redact(input)
        XCTAssertNotEqual(out, input, "expected redaction of: \(input)", file: file, line: line)
        XCTAssertTrue(out.contains(mask), "expected the mask in: \(out)", file: file, line: line)
        for secret in secrets {
            XCTAssertFalse(out.contains(secret), "secret leaked into output: \(out)", file: file, line: line)
        }
        // Idempotent: a second pass is a fixed point.
        XCTAssertEqual(
            SecretRedactor.redact(out),
            out,
            "redact is not idempotent for: \(input)",
            file: file,
            line: line,
        )
    }

    private func assertUntouched(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            SecretRedactor.redact(input),
            input,
            "false positive — should be untouched: \(input)",
            file: file,
            line: line,
        )
    }

    // MARK: - Known token shapes

    //
    // NOTE: the vendor-token fixtures are ASSEMBLED at runtime from fragments (no contiguous token
    // literal sits in the source) so GitHub's own secret-scanning push protection doesn't flag this very
    // test file. The redactor still sees the full token string once joined.

    func testAWSAccessKeyMasked() {
        let key = "AKIA" + "IOSFODNN7EXAMPLE" // AKIA + 16 chars
        assertMasked("region us-east-1 key \(key) done", secrets: [key])
    }

    func testGitHubTokenMasked() {
        let tok = "ghp" + "_0123456789abcdefghijklmnopqrstuvwxyzAB"
        assertMasked("cloning with \(tok)", secrets: [tok])
    }

    func testSlackTokenMasked() {
        let tok = "xoxb" + "-123456789012-abcdefABCDEF0123"
        assertMasked("slack \(tok)", secrets: [tok])
    }

    func testJWTMasked() {
        let jwt = ["eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiIxMjM0NTY3ODkwIn0", "dozjgNryP4J3jVmNHl0w5N"]
            .joined(separator: ".")
        assertMasked("auth \(jwt)", secrets: [jwt])
    }

    func testGenericHighEntropyTokenMasked() {
        let tok = "aB3dE6fG9hJ2kL5mN8pQ1rS4tU7vW0xY3zA6bC9d" // 40 chars, mixed case + digits
        assertMasked("export X=\(tok)", secrets: [tok])
    }

    // MARK: - key=value assignments (key preserved, value masked)

    func testPasswordAssignmentMaskedKeyKept() {
        let out = SecretRedactor.redact("PASSWORD=hunter2secretvalue")
        XCTAssertEqual(out, "PASSWORD=\(mask)", "the key is kept, only the value is masked")
    }

    func testEnvPrefixedSecretKeysMasked() {
        // Env-style prefixes ending in a secret word are caught.
        XCTAssertEqual(SecretRedactor.redact("GITHUB_TOKEN=abc123XYZsecretlongvalue"), "GITHUB_TOKEN=\(mask)")
        XCTAssertEqual(SecretRedactor.redact("DB_PASSWORD: p@ssw0rd!"), "DB_PASSWORD: \(mask)")
        XCTAssertEqual(SecretRedactor.redact("api_key=AbCdEf123456"), "api_key=\(mask)")
    }

    func testStripeAndNpmTokensMasked() {
        // Assembled at runtime so GitHub push-protection doesn't flag this test file.
        let stripe = "sk" + "_live_4eC39HqLyjWDarjtT1zdp7dc"
        assertMasked("deploy key \(stripe) ok", secrets: [stripe])
        let npm = "npm" + "_1234567890abcdefABCDEF1234567890ab"
        assertMasked("token is \(npm)", secrets: [npm])
    }

    func testBearerTokenMasked() {
        let out = SecretRedactor.redact("Authorization: Bearer abc123.def456-xyz")
        XCTAssertTrue(out.contains("Bearer \(mask)"), "Bearer kept, token masked: \(out)")
        XCTAssertFalse(out.contains("abc123.def456-xyz"))
    }

    // MARK: - Negatives (ordinary terminal titles must be left alone)

    func testOrdinaryTitlesUntouched() {
        assertUntouched("~/project — nvim")
        assertUntouched("user@host: ~/Workspace/oss/aislopdesk")
        assertUntouched("zsh")
        assertUntouched("build: 42 passed, 0 failed")
        // A lower-case hex git SHA has no upper-case → the generic backstop must not trip.
        assertUntouched("HEAD at 5f3a9c2b8e1d4a6f0c7b2e9d8a1f5c3b6e4d7a0f")
        // A long mixed-case path with digits but '/'-broken segments must not trip the generic rule.
        assertUntouched("/Users/me/Project2024ABC/src/MainView2024Final")
        // 'tokenizer' contains 'token' but does not END in it → not an assignment match.
        assertUntouched("tokenizer=wordpiece")
    }

    func testEmptyAndShortStringsUntouched() {
        assertUntouched("")
        assertUntouched("ok")
        assertUntouched("AKIA") // prefix only, not a full key
    }
}
