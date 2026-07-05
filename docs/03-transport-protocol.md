# 03 — Transport, Discovery & Protocol

> **STATUS: REFERENCE — GUI video-path design depth.** This path is shipped and co-equal with terminal panes — the old "Phase 4 / secondary" framing is retired. Current architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

Three parts: discovery (Bonjour, same-LAN only), transport (plain UDP/TCP), and the packet format. The Swift shell owns the sockets (**Network.framework**, native — no libwebrtc) and the HW codec; the **Rust core** (`rust/slopdesk-core`, video-protocol namespace, behind the C-ABI) implements the wire codec, FEC, frame reassembly, loss handling, and the congestion/ABR controllers.

---

## 1. Discovery — Bonjour zero-config

> ⚠️ **Bonjour works on the same physical LAN only** — multicast does not traverse a WireGuard mesh. For peers reached over the mesh, connect by **IP/hostname** (e.g. a mesh DNS name, `100.64/10` address, or the mesh API). Support both: Bonjour same-LAN, manual IP/hostname for remote. Network-model reference: [13](13-network-transport.md).

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
        // use r.endpoint directly — no manual IP/port resolution
    }
}
browser.start(queue: .main)
// Connect: NWConnection(to: result.endpoint, using: params)
```

> 📋 **Required Info.plist entries** (else discovery silently finds nothing): `NSLocalNetworkUsageDescription` + `NSBonjourServices = ["_panecast._udp"]`.

---

## 2. Transport — plain UDP + plain TCP

**Decision:** video → **plain UDP**; terminal + control → **plain TCP** (`TCP_NODELAY` mandatory). No app-layer TLS/QUIC: deployment **assumes a trusted private network** — typically a WireGuard mesh (e.g. NetBird/Tailscale) that already supplies E2E encryption, node auth, and per-port ACLs. The security boundary is the network, not the app; congestion and loss are handled adaptively in-app.

Why not QUIC for video:

| | Plain UDP | QUIC datagram | QUIC stream |
|--|-----------|---------------|-------------|
| Reliability | None (what video wants) | None | Yes + ordered (**HOL blocking — bad for video**) |
| Congestion control | App-layer adaptive (ours) | Built-in | Built-in |
| Encryption | Provided by the WG mesh | TLS 1.3 (redundant here) | TLS 1.3 (redundant here) |
| Handshake | Zero | 1-RTT (0-RTT) | 1-RTT |

TLS is redundant behind the mesh, and we run congestion control ourselves — so QUIC's two main draws don't apply.

### NWParameters → single source in [13 §2]

> The full `NWParameters` recipe lives in [13-network-transport.md §2](13-network-transport.md); not repeated here to avoid drift. Net-model facts that matter over any userspace-WireGuard mesh: a WG interface is `utun` / `.other` → **do not pin `requiredInterfaceType` / `.wiredEthernet`**; `serviceClass`/DSCP are zeroed through the tunnel → rely on **app-layer adaptive rate**; Bonjour doesn't cross the mesh; **clamp the UDP payload to the runtime MTU**.

### MTU & fragmentation

- `NWConnection.maximumDatagramSize` ≈ 1472 (Ethernet) — the ceiling below which IP does **not** fragment.
- **Never let IP fragment** a realtime datagram: losing one fragment loses the whole datagram with no recovery context.
- Target payload **~1200 bytes** (margin for Wi-Fi/IPv6/VPN).
- Keyframes are tens–hundreds of KB → **fragment at the app layer** into N datagrams, reassembled by `frameID` (Rust core).

---

## 3. Control (input) channel — reliable, separate

Input events (mouse/keyboard) are small and **must not be lost**. Carry them on a separate reliable channel — never mix them into the lossy video channel.

> ⭐ **Input rules (from Moonlight):** batch mouse/pen motion in a **1ms** window (this *reduces* latency by preventing queueing inside the reliable stack); **button/key down/up are NEVER batched** — send immediately. Timestamp + sequence every input. This channel also carries the **cursor position** for the client-side overlay (see [10 §6–7](10-latency-optimization.md)).

- A second `NWConnection` over **TCP `noDelay = true`** (disables Nagle → every keypress sent immediately), separate port.

```swift
var tcp = NWProtocolTCP.Options()
tcp.noDelay = true
tcp.enableKeepalive = true; tcp.keepaliveIdle = 2; tcp.keepaliveInterval = 1; tcp.keepaliveCount = 3
let controlParams = NWParameters(tls: nil, tcp: tcp)
controlParams.serviceClass = .signaling   // no-op through a WG tunnel; harmless
```

---

## 4. Packet format (Moonlight-style, simplified)

Video datagram header, big-endian (encoded/decoded by the Rust core):

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

- `frameID`: increments per frame; the `KEY` flag is set on IDRs.
- `fragIndex`/`fragCount`: fragments of one frame. `EOF` (or `fragIndex==fragCount-1`) marks the last.
- `streamSeq`: monotonically increasing across **all** datagrams → one missing number = one lost fragment, detected instantly.

---

## 5. Loss handling — no large jitter buffer

Implemented in the Rust core (Moonlight `VideoDepacketizer.c`-style). The receiver tracks `nextFrameNumber` + `lastStreamSeq`:

1. **Gap in `streamSeq`** → corrupt frame → `dropFrame`, set `nextFrameNumber = frameID+1`, **request recovery** (do NOT retransmit).
2. **Whole frame missing** (frameID jumps ahead) → drop the partial, wait for the next clean frame.
3. **Stale fragment** (frameID < nextFrameNumber) → drop silently.

Recovery requests go over the **reliable control channel**. The buffer is limited to ~1 frame → no latency accumulation.

> ⭐ **Recovery prefers LTR, not keyframes.** VideoToolbox Long-Term Reference: the client acks frames it received; on loss the host emits a small LTR-P predicted from an already-acked LTR, avoiding the 5–20× "keyframe spike". Force an IDR only when no acked LTR remains — details in [10 §1](10-latency-optimization.md). **Speculative loss detection** (guessing a loss before the next frame arrives) saves one frame-time.

### FEC vs retransmit

The video path **ships FEC + ABR + congestion control** (Rust core), with **FEC first** and a
**selective-retransmit (NACK) backstop** for what FEC can't recover.

- **FEC (Reed–Solomon over GF(2⁸), NEON-accelerated):** recovers loss with **no added latency**, at a bandwidth cost — the primary mechanism. `m=1` is byte-identical to the original XOR parity; `m≥2` recovers multi-packet loss. **Adaptive tiering** (`FECScheme` + `AdaptiveFECPolicy`): low/none on a clean wired LAN (rely on drop-frame → request-recovery), ramping on Wi-Fi/lossy links. **Adaptive parity-`m`** (2026-06-18) steps `m` per-frame by measured loss (clean → m=2, burst → m=5) via the wire FEC-tier field — no format change.
- **Retransmit (NACK / selective ARQ)** — *re-scoped 2026-06-18, `SLOPDESK_NACK`, default OFF.* The original rule ("ARQ costs 1 RTT → visible stutter; never for video") assumed the **naive** form — replay the lost frame and stall the stream. That premise does **not** hold with a jitter/**playout buffer ≫ RTT** (e.g. 80 ms buffer vs a ~21 ms WAN RTT): a NACK'd fragment retransmit lands *inside* the buffer window → it fills the hole **before playout, no stutter** (the WebRTC model). So a frame FEC can't recover is **held** for a small retransmit grace, the client NACKs exactly the missing fragments, and the host re-sends them from a bounded send-history ring — far cheaper than the old recovery-IDR (and it recovers whole-frame losses FEC fundamentally cannot). The LTR-refresh / IDR path remains the fallback when the grace expires. Retransmit stays opt-in + deploy-together (adds wire recovery type 6).

### Pacing

- Don't blast all of a keyframe's fragments in one microburst → it overflows switch buffers and causes loss even on LAN. Spread fragments across the frame interval (a token/interval pacer).
- Couple encoder bitrate to loss/RTT from the control channel (`LiveCongestionController` + `LiveBitratePolicy`): loss rises → lower bitrate / raise FEC; clean → ramp back up.

---

## 6. Phase 1 tasks

- [ ] `NWListener`/`NWBrowser` Mac↔Mac discovery, show the host list.
- [ ] Packetizer + reassembler per the §4 format, with unit tests for packet loss/reordering.
- [ ] Send a keyframe (multiple fragments) + delta frames end-to-end.
- [ ] TCP `noDelay` control channel + a recovery-request message.
