// slopdesk-fake-client — minimal UDP trigger that makes the REAL video host start capturing a
// window, so the full host pipeline (capture → encode → FEC → send) can be exercised + measured on
// ONE machine without the GUI client app. It sends a valid `hello` on the control channel repeatedly
// (UDP is lossy) and drains incoming datagrams. Optionally self-scrolls the captured window's pid
// (CGEvent.postToPid wheel, no focus steal) so content changes continuously.
//
// Usage: slopdesk-fake-client --window-id N --width W --height H [--host 127.0.0.1] [--port 9000]
//        [--seconds 20] [--self-scroll PID]
// The host logs `capture gap`/`send gap` (SLOPDESK_VIDEO_DEBUG=1); grep those to measure.
// Diagnostic instrument (not shipped product) — excluded from strict lint in .swiftlint.yml, like
// slopdesk-loopback-validate.

#if os(macOS)
import CoreGraphics
import Darwin
import Foundation
import SlopDeskVideoProtocol

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

var windowID: UInt32 = 0
var vw = 1440.0, vh = 900.0
var host = "127.0.0.1"
var port: UInt16 = 9000
var seconds = 20.0
var scrollPid: pid_t?
var scrollX = 720.0, scrollY = 480.0
var it = Array(CommandLine.arguments.dropFirst()).makeIterator()
while let a = it.next() {
    switch a {
    case "--window-id": windowID = it.next().flatMap { UInt32($0) } ?? 0
    case "--width": vw = it.next().flatMap(Double.init) ?? vw
    case "--height": vh = it.next().flatMap(Double.init) ?? vh
    case "--host": host = it.next() ?? host
    case "--port": port = it.next().flatMap { UInt16($0) } ?? port
    case "--seconds": seconds = it.next().flatMap(Double.init) ?? seconds
    case "--self-scroll": scrollPid = it.next().flatMap { Int32($0) }
    case "--scroll-at": // "x,y" hit-test location for the wheel events
        if let s = it.next() { let p = s.split(separator: ",")
            if p.count == 2 {
                scrollX = Double(p[0]) ?? scrollX
                scrollY = Double(p[1]) ?? scrollY
            }
        }
    default: eprint("unknown arg: \(a)")
        exit(1)
    }
}

guard windowID != 0 else { eprint("need --window-id")
    exit(1)
}

// BSD UDP socket → host media port.
nonisolated(unsafe) let fd = socket(AF_INET, SOCK_DGRAM, 0)
guard fd >= 0 else { eprint("socket failed")
    exit(1)
}

var addrTmp = sockaddr_in()
addrTmp.sin_family = sa_family_t(AF_INET)
addrTmp.sin_port = port.bigEndian
inet_pton(AF_INET, host, &addrTmp.sin_addr)
nonisolated(unsafe) let addr = addrTmp

func sendDatagram(_ data: Data) {
    var a = addr
    _ = withUnsafePointer(to: &a) { ap in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
            data.withUnsafeBytes { raw in
                sendto(fd, raw.baseAddress, raw.count, 0, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

// hello on the control channel (channelID 0): [u32 BE 0] + hello.encode()
let hello = VideoControlMessage.hello(
    protocolVersion: SlopDeskVideoProtocol.version,
    requestedWindowID: windowID,
    viewport: VideoSize(width: vw, height: vh),
)
// Mux header = [u32 BE channelID] + payload; control channel = 0 ⇒ 4 zero bytes prefix.
let helloDatagram = Data([0, 0, 0, 0]) + hello.encode()
eprint("fake-client → \(host):\(port) hello(window=\(windowID), \(Int(vw))x\(Int(vh))), \(seconds)s")

// Drain incoming so the socket buffer never fills.
let drain = Thread { var buf = [UInt8](repeating: 0, count: 65536)
    while true { _ = recv(fd, &buf, buf.count, 0) }
}

drain.start()

// Self-scroll the captured window's pid (continuous + reversing) so content changes every frame.
final class SFlag: @unchecked Sendable { var run = true }
let sflag = SFlag()
if let spid = scrollPid {
    eprint("self-scroll → pid \(spid) @\(Int(scrollX)),\(Int(scrollY))")
    Thread.detachNewThread {
        var i = 0
        while sflag.run {
            let dir: Int32 = (i / 64) % 2 == 0 ? -3 : 3
            if let ev = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: dir,
                wheel2: 0,
                wheel3: 0,
            ) {
                ev.location = CGPoint(x: scrollX, y: scrollY)
                ev.postToPid(spid)
            }
            i += 1
            Thread.sleep(forTimeInterval: 0.008)
        }
    }
}

// Resend the (unreliable) hello every 300ms until the run ends.
let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    sendDatagram(helloDatagram)
    Thread.sleep(forTimeInterval: 0.3)
}

sflag.run = false
eprint("fake-client done")
exit(0)
#else
fatalError("slopdesk-fake-client is macOS-only")
#endif
