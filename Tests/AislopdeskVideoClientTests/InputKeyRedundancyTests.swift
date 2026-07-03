import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoClient

/// C5 BUG B (client side): a MODIFIER key-UP rides the same N-times redundancy as `sendMouseUp` —
/// over lossy UDP a single lost modifier release permanently latches the flag on the host's shared
/// `hidSystemState` source (every later plain scroll becomes ⌘-scroll, clicks become ⌘-clicks) until
/// the user happens to press+release that modifier again. `keySendCount` is the pure send-count
/// policy `sendKey` loops on; the host's `InputButtonBalance` collapses the burst to one post.
final class InputKeyRedundancyTests: XCTestCase {
    /// Every held-modifier keyCode (left/right ⌘⇧⌃⌥ + fn) gets the mouseUp-parity redundancy (3)
    /// on its RELEASE edge.
    func testModifierKeyUpIsSentRedundantly() {
        for keyCode: UInt16 in [54, 55, 56, 58, 59, 60, 61, 62, 63] {
            XCTAssertEqual(
                AislopdeskVideoClientSession.keySendCount(keyCode: keyCode, down: false), 3,
                "modifier keyCode \(keyCode) release must ride the 3× loss-resilient burst",
            )
        }
    }

    /// The DOWN edge is a single datagram — a lost down is a visible, self-healing miss (the user
    /// re-presses); only the invisible stuck-release case warrants redundancy.
    func testModifierKeyDownIsSentOnce() {
        for keyCode: UInt16 in [54, 55, 56, 58, 59, 60, 61, 62, 63] {
            XCTAssertEqual(AislopdeskVideoClientSession.keySendCount(keyCode: keyCode, down: true), 1)
        }
    }

    /// Ordinary keys are never duplicated on either edge.
    func testOrdinaryKeysAreSentOnce() {
        XCTAssertEqual(AislopdeskVideoClientSession.keySendCount(keyCode: 0, down: false), 1) // 'a' up
        XCTAssertEqual(AislopdeskVideoClientSession.keySendCount(keyCode: 0, down: true), 1)
        XCTAssertEqual(AislopdeskVideoClientSession.keySendCount(keyCode: 36, down: false), 1) // return up
    }

    /// Caps Lock (57) is a TOGGLE — a duplicated edge on a host missing the dedup would flip Caps
    /// twice, so it is excluded from the redundancy AND from the shared held-modifier vocabulary.
    func testCapsLockIsNeverDuplicated() {
        XCTAssertEqual(AislopdeskVideoClientSession.keySendCount(keyCode: 57, down: false), 1)
        XCTAssertEqual(AislopdeskVideoClientSession.keySendCount(keyCode: 57, down: true), 1)
        XCTAssertFalse(InputModifierKeys.isHeldModifier(57))
        XCTAssertFalse(InputModifierKeys.heldModifierKeyCodes.contains(InputModifierKeys.capsLockKeyCode))
    }
}
