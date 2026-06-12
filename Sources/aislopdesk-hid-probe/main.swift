// aislopdesk-hid-probe — drives the REAL ``VirtualHIDKeyboardClient`` (videohostd's virtual-HID keyboard
// backend) to type 'x' every 700ms through aislopdesk-hid-bridge, so we can confirm the host→bridge→
// virtual-keyboard chain reaches even a SecurityAgent secure password field (Secure Event Input blocks the
// CGEvent path). Run the bridge as root first: `sudo hid-bridge/build/aislopdesk-hid-bridge`.
//
// Usage: aislopdesk-hid-probe [--key 0x07] [--interval-ms 700]
#if os(macOS)
import Foundation
import AislopdeskVideoHost

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

var keyCode: UInt16 = 0x07   // kVK_ANSI_X → HID 'x'
var intervalMs: UInt32 = 700
var it = Array(CommandLine.arguments.dropFirst()).makeIterator()
while let a = it.next() {
    switch a {
    case "--key": if let v = it.next() { keyCode = v.hasPrefix("0x") ? (UInt16(v.dropFirst(2), radix: 16) ?? keyCode) : (UInt16(v) ?? keyCode) }
    case "--interval-ms": if let v = it.next(), let n = UInt32(v) { intervalMs = n }
    default: eprint("unknown arg: \(a)"); exit(1)
    }
}

guard let client = VirtualHIDKeyboardClient() else { eprint("could not open UDP socket to the bridge"); exit(1) }
eprint("typing key 0x\(String(keyCode, radix: 16)) every \(intervalMs)ms via VirtualHIDKeyboardClient → bridge (127.0.0.1:9100). Ctrl-C to stop.")
eprint("(run the bridge as root first: sudo hid-bridge/build/aislopdesk-hid-bridge)")

while true {
    client.send(keyCode: keyCode, down: true, modifiers: [])
    usleep(40_000)
    client.send(keyCode: keyCode, down: false, modifiers: [])
    usleep(intervalMs * 1000)
}
#else
fatalError("aislopdesk-hid-probe is macOS-only")
#endif
