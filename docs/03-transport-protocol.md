# 03 — Transport, Discovery & Protocol

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Current architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

Everything uses **Network.framework** (native, no libwebrtc). Three parts: discovery (Bonjour), transport (UDP/QUIC), and the packet format.

---

## 1. Discovery — Bonjour zero-config

> ⚠️ **Bonjour ONLY works on the same physical LAN** — it does NOT traverse the NetBird mesh (WireGuard doesn't forward multicast). For peers across the mesh: use **NetBird DNS (`host.netbird.cloud`)** / `100.64/10` IPs / the NetBird API. The app should support both: Bonjour for same-LAN, entering/picking a NetBird hostname for remote. Details in [13](13-netbird-transport.md).

### Host advertise (`NWListener`)

```swift
let listener = try NWListener(using: params)   // port auto-assigned; read it back from .port
var txt = NWTXTRecord()
txt["v"] = "1"; txt["codec"] = "hevc"; txt["res"] = "3840x2160"
listener.service = NWListener.Service(name: "Living Room Mac",
                                      type: "_panecast._udp", domain: nil, txtRecord: txt)
listener.serviceRegistrationUpdateHandler = { change in /* actual name after collision resolution */ }
listener.newConnectionHandler = { conn in /* accept, start on a queue */ }
listener.start(queue: .main)
```

### Client discover (`NWBrowser`)

Use `.bonjourWithTXTRecord` to filter by codec/version **before** connecting:

```swift
let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_panecast._udp", domain: nil), using: .udp)
browser.browseResultsChangedHandler = { results, _ in
    for r in results {
        if case let .bonjour(txt) = r.metadata { _ = txt["codec"] }   // check before connecting
        // use r.endpoint directly — no manual IP/port resolution needed
    }
}
browser.start(queue: .main)
// Connect: NWConnection(to: result.endpoint, using: params)
```

> 📋 **Required Info.plist entries** (iOS 14+; otherwise discovery silently finds nothing): `NSLocalNetworkUsageDescription` + `NSBonjourServices = ["_panecast._udp"]`.

---

## 2. Transport — choosing UDP vs QUIC

| | Plain UDP | QUIC datagram | QUIC stream |
|--|-----------|---------------|-------------|
| Reliability | None (exactly what video wants) | None (like UDP) | Yes + ordered (**HOL blocking — bad for video**) |
| Congestion control | Build your own | **Built-in, reacts to RTT/loss** | Built-in |
| Encryption | Roll your own | TLS 1.3 built-in | TLS 1.3 built-in |
| Min OS | iOS 12 | iOS 16 / Ventura | iOS 15 |
| Overhead | Zero handshake | 1-RTT (or 0-RTT) | — |

> ⚠️ **The transport runs ON TOP OF NetBird (WireGuard mesh)** — see [13-netbird-transport.md](13-netbird-transport.md). This overrides several recommendations below: encryption already exists at the VPN layer (drop TLS/QUIC-crypto), the interface is `utun` (`.other` — do NOT pin `.wiredEthernet`), `serviceClass` has no effect through the tunnel, Bonjour doesn't cross the mesh. Read doc 13 first.

**Recommendation (updated for NetBird):**
- **Video → plain UDP.** WireGuard already encrypts → **drop QUIC** (the main reasons for QUIC are TLS + congestion control; TLS is redundant, and we do congestion adaptively ourselves). Loss/jitter depends on the tier: direct P2P ~0 (LAN-like), relayed needs adaptive/FEC.
- **Terminal → plain TCP** (no TLS). Framing: 1-byte type + 4-byte length.

### NWParameters → single source in [13 §2]

> **The full `NWParameters` recipe (utun: do NOT pin `.wiredEthernet`; `serviceClass`/DSCP are no-ops through the tunnel; plain UDP/TCP — no QUIC; `includePeerToPeer=false`) = single source in [13-netbird-transport.md §2](13-netbird-transport.md).** Not repeating the recipe here to avoid drift.

### MTU & fragmentation

- `NWConnection.maximumDatagramSize` ≈ 1472 (Ethernet) — the ceiling at which IP does **not** fragment.
- **Never let the IP layer fragment** a realtime datagram: losing 1 fragment loses the whole datagram, and the IP stack has no context to recover.
- Target payload **~1200 bytes** (margin for Wi-Fi/IPv6/VPN).
- Keyframes weigh tens–hundreds of KB → **fragment at the app layer** into N datagrams, reassembled by frameID.

---

## 3. Control (input) channel — reliable, separate

Input events (mouse/keyboard) are small and **must not be lost**. **Use a separate reliable channel**; don't mix them into the lossy video channel:

> ⭐ **Input rules (from Moonlight, ported directly):** batch mouse/pen motion in a **1ms** window (paradoxically this *reduces* latency, because it prevents queueing inside the reliable stack); **button/key down/up are NEVER batched** — send immediately. Timestamp + sequence every input. This channel also carries the **cursor position** so the client can draw the cursor overlay (see [10 §6–7](10-latency-optimization.md)).

- **Cleanest:** a second `NWConnection` over **TCP `noDelay = true`** (disables Nagle → every keypress sent immediately), separate port.
- **If video uses QUIC:** open a **QUIC reliable stream** for control on the same connection, with video over QUIC datagrams → 1 handshake, 1 encrypted connection, reliable/unreliable separated naturally.

```swift
var tcp = NWProtocolTCP.Options()
tcp.noDelay = true
tcp.enableKeepalive = true; tcp.keepaliveIdle = 2; tcp.keepaliveInterval = 1; tcp.keepaliveCount = 3
let controlParams = NWParameters(tls: nil, tcp: tcp)
controlParams.serviceClass = .signaling
```

---

## 4. Packet format (Moonlight-style, simplified)

One header per datagram, big-endian:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| ver |  type   |     flags     |           (reserved)          |  type: 0=video 1=fec 2=control-ack
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+  flags: SOF=1 EOF=2 KEY=4
|                         frameID (u32)                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|        fragIndex (u16)        |        fragCount (u16)        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                streamSeq (u32) — loss detection               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    payload (≤ ~1200 bytes)                    |
```

- `frameID`: increments per frame. The `KEY` flag is set on IDRs.
- `fragIndex`/`fragCount`: fragmenting one frame. `EOF` (or `fragIndex==fragCount-1`) marks the last fragment.
- `streamSeq`: monotonically increasing across **all** datagrams → one missing number = one lost fragment, detected instantly.

---

## 5. Loss handling — no large jitter buffer

Moonlight's strategy (`VideoDepacketizer.c`). The receiver tracks `nextFrameNumber` + `lastStreamSeq`:

1. **Gap in `streamSeq`** → corrupt frame → `dropFrame`, set `nextFrameNumber = frameID+1`, **request an IDR** (do NOT retransmit).
2. **Whole frame missing** (frameID jumps ahead) → drop the partial, wait for the next clean frame.
3. **Stale fragment** (frameID < nextFrameNumber) → drop silently.

Recovery requests go over the **reliable control channel**. Buffer limited to ~1 frame → no latency accumulation.

> ⭐ **Recovery prefers LTR, not keyframes.** VideoToolbox supports Long-Term Reference: the client acks the frames it received; on packet loss the host emits a small LTR-P predicted from an already-acked LTR (avoiding the 5–20× "keyframe spike"). Only force an IDR when no acked LTR remains. This is an important revision over the first draft — details in [10 §1](10-latency-optimization.md). Additionally: **speculative loss detection** (guessing a loss before the next frame arrives) saves one frame-time.

### FEC vs retransmit on LAN

- **Retransmit (ARQ):** costs 1 RTT → visible stutter. **Avoid for video.**
- **FEC (Reed-Solomon):** recovers loss with zero added latency, in exchange for bandwidth.
- **Wired-LAN recommendation:** low/no FEC (0–10%), rely on drop-frame→request-keyframe. **Wi-Fi:** FEC ~15–20%, adaptive based on loss measured over the control channel.
- ARQ retransmission is **only for the control channel** (that's what it's for).

### Pacing

- Don't "blast" all of a keyframe's fragments in one microburst → it overflows switch buffers, causing loss even on LAN. Spread the fragments across the frame interval (a simple token/interval pacer).
- Couple the encoder bitrate to loss/RTT measured from the control channel: loss rises → lower the bitrate / raise FEC; clean → ramp back up.

---

## 6. Phase 1 tasks

- [ ] `NWListener`/`NWBrowser` Mac↔Mac discovery, show the host list.
- [ ] Packetizer + reassembler per the §4 format, with unit tests for packet loss/reordering.
- [ ] Send a keyframe (multiple fragments) + delta frames end-to-end.
- [ ] TCP `noDelay` control channel + a `request-keyframe` message.
