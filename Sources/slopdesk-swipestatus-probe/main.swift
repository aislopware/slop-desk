// slopdesk-swipestatus-probe — runtime proof that a RUNNING videohostd actually pushes type-3
// `SwipeNavStatus` datagrams (the swipe-peel eligibility push, docs/20-wire-protocol.md §9.6).
// The push path (SwipeNavStatusKicker → registry.forEachSession → pushSwipeNavStatus →
// scheduleCursor → cursor flow) has NO host-side logging, so "the chip never lit up" and
// "everything works" look identical from the host log. This probe is the discriminator: it mints a
// real display session like a GUI client would (helloDisplay on the media socket, cursor-flow
// prime on the cursor socket) and reports every cursor-socket message it receives for a few
// seconds. The kicker heartbeats every 2 s, so a healthy host shows type-3 within ~4 s.
//
// Usage: slopdesk-swipestatus-probe [--host 127.0.0.1] [--port 9000] [--cursor-port 9001]
//        [--display-id 0] [--seconds 12]
// Exit 0 ⇒ at least one SwipeNavStatus arrived; exit 2 ⇒ none did (push path dead or gated).
// Diagnostic instrument (not shipped product), sibling of slopdesk-fake-client.

#if os(macOS)
import Darwin
import Foundation
import SlopDeskVideoProtocol

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

var argHost = "127.0.0.1"
var argMediaPort: UInt16 = 9000
var argCursorPort: UInt16 = 9001
var argDisplayID: UInt32 = 0
var argSeconds = 12.0
var it = Array(CommandLine.arguments.dropFirst()).makeIterator()
while let a = it.next() {
    switch a {
    case "--host": argHost = it.next() ?? argHost
    case "--port": argMediaPort = it.next().flatMap { UInt16($0) } ?? argMediaPort
    case "--cursor-port": argCursorPort = it.next().flatMap { UInt16($0) } ?? argCursorPort
    case "--display-id": argDisplayID = it.next().flatMap { UInt32($0) } ?? argDisplayID
    case "--seconds": argSeconds = it.next().flatMap(Double.init) ?? argSeconds
    default: eprint("unknown arg: \(a)")
        exit(1)
    }
}

// Snapshot the parsed args into nonisolated constants so the drain threads (nonisolated contexts)
// can read them — same idiom as slopdesk-fake-client.
nonisolated(unsafe) let host = argHost
nonisolated(unsafe) let displayID = argDisplayID
nonisolated(unsafe) let seconds = argSeconds

// A high, random lane id: the GUI client's allocator is monotonic from small values, so a random
// id in a high band cannot collide with a live lane on the shared daemon.
nonisolated(unsafe) let chan = UInt32.random(in: 0x6000_0000...0x6FFF_FFFF)

func udpSocket(to port: UInt16) -> (fd: Int32, addr: sockaddr_in) {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { eprint("socket failed")
        exit(1)
    }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    inet_pton(AF_INET, host, &addr.sin_addr)
    return (fd, addr)
}

nonisolated(unsafe) let media = udpSocket(to: argMediaPort)
nonisolated(unsafe) let cursor = udpSocket(to: argCursorPort)

func sendDatagram(_ data: Data, over sock: (fd: Int32, addr: sockaddr_in)) {
    var a = sock.addr
    _ = withUnsafePointer(to: &a) { ap in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
            data.withUnsafeBytes { raw in
                sendto(sock.fd, raw.baseAddress, raw.count, 0, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

// Media-socket framing: [u32 BE chan][u8 tag][payload]; control tag = 0 (the VideoChannel wire
// contract — the enum itself lives host/client-side, the raw tag is the agreement).
let controlTag: UInt8 = 0
func sendControl(_ message: VideoControlMessage) {
    sendDatagram(
        VideoMuxHeaderCodec.encodeMedia(channelID: chan, tag: controlTag, payload: message.encode()),
        over: media,
    )
}

let hello = VideoControlMessage.helloDisplay(
    protocolVersion: SlopDeskVideoProtocol.version,
    requestedDisplayID: displayID,
    viewport: VideoSize(width: 1280, height: 800),
)
eprint(
    "probe → \(host):\(argMediaPort)/\(argCursorPort) helloDisplay(display=\(displayID)) chan=\(chan), \(Int(seconds))s",
)

final class ProbeState: @unchecked Sendable {
    let lock = NSLock()
    var acked = false
    var videoPkts = 0
    var cursorUpdates = 0
    var cursorShapes = 0
    var statusCount = 0
    var lastStatus: SwipeNavStatusMessage?
    let started = Date()
    func stamp() -> String { String(format: "t+%.1fs", Date().timeIntervalSince(started)) }
}

let state = ProbeState()

// Media drain: watch for the helloAck (accepted?) and count video datagrams (mediaFlowing proof).
Thread.detachNewThread {
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = recv(media.fd, &buf, buf.count, 0)
        guard n > 4 else { continue }
        let payload = Data(buf[5..<n])
        let tag = buf[4]
        if tag == 1 {
            state.lock.lock()
            state.videoPkts += 1
            state.lock.unlock()
        } else if tag == 0, let msg = try? VideoControlMessage.decode(payload),
                  case let .helloAck(accepted, streamID, w, h, _, _) = msg
        {
            state.lock.lock()
            let firstAck = !state.acked
            state.acked = true
            state.lock.unlock()
            if firstAck {
                eprint("\(state.stamp()) helloAck accepted=\(accepted) stream=\(streamID) \(w)x\(h)")
            }
        }
    }
}

// Cursor drain: [u32 BE chan][CursorChannelMessage bytes] — the datagrams under test.
Thread.detachNewThread {
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = recv(cursor.fd, &buf, buf.count, 0)
        guard n > 4, let (_, payload) = try? VideoMuxHeaderCodec.decode(Data(buf[0..<n])) else { continue }
        guard let msg = try? CursorChannelMessage.decode(payload) else { continue }
        state.lock.lock()
        switch msg {
        case .update: state.cursorUpdates += 1
        case .shape: state.cursorShapes += 1
        case let .swipeNavStatus(s):
            state.statusCount += 1
            state.lastStatus = s
            eprint(
                "\(state.stamp()) SwipeNavStatus #\(state.statusCount): eligible=\(s.eligible) slowTier=\(s.slowTier) fireTravel=\(s.fireTravel)",
            )
        }
        state.lock.unlock()
    }
}

// Re-send hello until acked (UDP is lossy) + re-prime the cursor flow each second, exactly the
// keepalive re-prime idiom the GUI client uses.
let prime = VideoMuxHeaderCodec.encode(channelID: chan, payload: Data([0x00]))
let deadline = Date().addingTimeInterval(seconds)
var tick = 0
while Date() < deadline {
    state.lock.lock()
    let acked = state.acked
    state.lock.unlock()
    if !acked { sendControl(hello) }
    if tick.isMultiple(of: 3) { sendDatagram(prime, over: cursor) }
    tick += 1
    Thread.sleep(forTimeInterval: 0.3)
}

sendControl(.bye)
state.lock.lock()
let summary =
    "probe done — helloAck=\(state.acked) videoPkts=\(state.videoPkts) cursorUpdates=\(state.cursorUpdates) "
        + "shapes=\(state.cursorShapes) swipeNavStatus=\(state.statusCount) last=\(String(describing: state.lastStatus))"
let ok = state.statusCount > 0
state.lock.unlock()
eprint(summary)
exit(ok ? 0 : 2)
#else
fatalError("slopdesk-swipestatus-probe is macOS-only")
#endif
