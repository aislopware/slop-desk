#if os(macOS)
import AislopdeskVideoProtocol
import Darwin
import Foundation

/// Sends 8-byte HID boot keyboard reports to **aislopdesk-hid-bridge** (the small root process that owns
/// the Karabiner virtual keyboard) over localhost UDP, so keystrokes reach even a SecurityAgent secure
/// password field — which Secure Event Input blocks for the `CGEvent` path ``InputInjector`` otherwise
/// uses (HID-device input is not blocked; HW-proven on Tahoe 26.5.1).
///
/// Folds key down/up + modifier state via ``HIDKeyboardState`` (each report is the FULL key state, so a
/// dropped/reordered loopback datagram self-corrects on the next one). Best-effort fire-and-forget: a
/// connected UDP socket to loopback always "sends" even if the bridge is down, so this is gated by env
/// (``InputInjector`` only constructs it under `AISLOPDESK_VIRTUAL_HID=1`, and the operator runs the
/// bridge). `@unchecked Sendable` — the `fd` is immutable post-init and the folded state is lock-guarded.
public final class VirtualHIDKeyboardClient: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var state = HIDKeyboardState()

    /// Opens a connected UDP socket to `127.0.0.1:port` (the bridge). Returns `nil` only if the socket
    /// itself can't be created — NOT if the bridge is absent (UDP connect to loopback always succeeds).
    public init?(port: UInt16 = 9100) {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { close(s)
            return nil
        }
        fd = s
    }

    /// Fold one key event and ship the resulting boot report to the bridge. Returns `false` if the event
    /// maps to nothing (unmapped key) or the datagram couldn't be queued.
    @discardableResult
    public func send(keyCode: UInt16, down: Bool, modifiers: InputModifiers) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let report = state.apply(virtualKey: keyCode, down: down, modifiers: modifiers) else { return false }
        let n = report.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, report.count, 0) }
        return n == report.count
    }

    /// Release every key/modifier (sent on teardown / on the virtual-HID→CGEvent backend switch so a held
    /// key can't stick on the host). Clears the folded state too (``HIDKeyboardState/releaseAll()``), so a
    /// later keystroke can't re-assert a previously-held key as a phantom press into the next secure field.
    public func releaseAll() {
        lock.lock()
        defer { lock.unlock() }
        let report = state.releaseAll()
        _ = report.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, report.count, 0) }
    }

    deinit { close(fd) }
}
#endif
