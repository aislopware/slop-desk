import SlopDeskFileTransfer
import SlopDeskInspector
import SlopDeskProtocol
import SlopDeskVideoProtocol

// Micro-benchmark for the Swift-level hot paths the all-Swift migration produced. Isolates the
// CPU codecs (frame hash, GF region multiply, Reed-Solomon FEC encode/recover) from the
// VideoToolbox-dominated pipeline so a before/after optimization delta is visible.
//
//   swift build -c release --product slopdesk-bench && .build/release/slopdesk-bench
import Dispatch
import Foundation

@inline(__always)
func timeNs(_ iters: Int, _ body: () -> Void) -> Double {
    // warmup
    for _ in 0..<max(1, iters / 10) { body() }
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iters { body() }
    let t1 = DispatchTime.now().uptimeNanoseconds
    return Double(t1 - t0) / Double(iters)
}

func fmt(_ ns: Double) -> String {
    if ns >= 1000 { return String(format: "%.2f µs", ns / 1000) }
    return String(format: "%.1f ns", ns)
}

// Deterministic filler (no Math.random) so runs are comparable.
func fill(_ n: Int, _ seed: UInt64) -> [UInt8] {
    var s = seed
    var out = [UInt8](repeating: 0, count: n)
    for i in 0..<n {
        s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        out[i] = UInt8(truncatingIfNeeded: s >> 33)
    }
    return out
}

print("=== slopdesk hot-path micro-benchmark (release) ===")

// ---- 1. Frame hash: a 1080p NV12 plane (the per-row lane-fold hot loop) ----
do {
    let w = 1920, h = 1080
    let y = fill(w * h, 1)
    let cbcr = fill(w * (h / 2), 2)
    var sink: UInt64 = 0
    let ns = y.withUnsafeBytes { yb in
        cbcr.withUnsafeBytes { cb in
            timeNs(300) {
                sink &+= FrameHasher.hashNV12(
                    y: yb.baseAddress, yStride: w, width: w, height: h,
                    cbcr: cb.baseAddress, cbcrStride: w,
                )
            }
        }
    }
    let mbps = Double(w * h + w * (h / 2)) / ns // bytes per ns = GB/s
    print("  frameHash 1080p      : \(fmt(ns))/frame   (\(String(format: "%.1f", mbps)) GB/s)   [sink \(sink & 0xFF)]")

    // The other two per-frame measurements walk the same luma plane, twice each: a scroll estimate
    // and a change fraction. `cur` is `y` moved down eight rows, which is the shape both are for.
    var cur = [UInt8](repeating: 0, count: w * h)
    for row in 8..<h {
        cur[(row * w)..<(row * w + w)] = y[((row - 8) * w)..<((row - 8) * w + w)]
    }
    y.withUnsafeBytes { pb in
        cur.withUnsafeBytes { cb in
            var shifts = 0
            let scrollNs = timeNs(20) {
                shifts &+= Int(ScrollShiftEstimator.estimateNV12(
                    prevY: pb.baseAddress, prevStride: w, curY: cb.baseAddress, curStride: w,
                    width: w, height: h, maxShift: max(8, h / 4), quantizeShift: 3,
                ).shift)
            }
            var ceilings = 0
            let qpNs = timeNs(50) {
                ceilings &+= Int(AdaptiveFrameQP.computeNV12(
                    prevY: pb.baseAddress, prevStride: w, curY: cb.baseAddress, curStride: w,
                    width: w, height: h, qpSharp: 20, qpMax: 44, bLoMilli: 10, bHiMilli: 200,
                ).qp)
            }
            print("  scrollShift 1080p    : \(fmt(scrollNs))/frame   [shift \(shifts != 0)]")
            print("  adaptiveQP 1080p     : \(fmt(qpNs))/frame   [qp \(ceilings != 0)]")
        }
    }
}

// ---- 2. (retired) GF(2^8) region multiply ----
// This measured `NeonGf.mulAdd`, the hand-written NEON kernel the Swift FEC folded parity through.
// The codec is `rust/slopdesk-video` now and has no such kernel — safe Rust over slices — so there
// is nothing here to time that section 3 does not time end to end. Deleted rather than pointed at
// the Rust: a micro-benchmark of an inner loop nobody calls directly measures the benchmark.

// ---- 3. Reed-Solomon FEC: encode + recover, k=8 shards x 1200B, m=2, 2 holes ----
do {
    let k = 8, shardLen = 1200
    let data: [Data] = (0..<k).map { Data(fill(shardLen, UInt64(10 + $0))) }
    let fec = RustReedSolomonFEC(groupSize: k, parityCount: 2)
    var sink = 0
    let encNs = timeNs(3000) { sink &+= fec.parity(forDataFragments: data, groupSize: k).count }
    let parity = fec.parity(forDataFragments: data, groupSize: k)
    var holed: [Data?] = data
    holed[2] = nil
    holed[5] = nil // 2 erasures, recoverable with m=2
    let par: [Data?] = parity.map(\.self)
    let recNs = timeNs(3000) { sink &+= (fec.recover(dataFragments: holed, parityFragments: par, groupSize: k).count) }
    print("  FEC encode (k8 m2)   : \(fmt(encNs))/group")
    print("  FEC recover (2 holes): \(fmt(recNs))/group   [sink \(sink & 0xFF)]")
}

// ---- 3b. Reed-Solomon FEC at m == 1 (the PRODUCTION wire: plain XOR) ----
do {
    let k = 8, shardLen = 1200
    let data = (0..<k).map { i in Data(fill(shardLen, UInt64(70 + i))) }
    let fec = RustReedSolomonFEC(groupSize: k, parityCount: 1)
    let parity = fec.parity(forDataFragments: data, groupSize: k)
    let encNs = timeNs(20000) { _ = fec.parity(forDataFragments: data, groupSize: k) }
    var lossy: [Data?] = data
    lossy[3] = nil
    let recNs = timeNs(20000) {
        _ = fec.recover(dataFragments: lossy, parityFragments: parity.map(\.self), groupSize: k)
    }
    print("  FEC encode (k8 m1)   : \(fmt(encNs))/group")
    print("  FEC recover (1 hole) : \(fmt(recNs))/group")
}

// ---- 3c. A whole FRAME rather than one group — the shape production actually calls ----
// `parity(forDataFragments:groupSize:)` takes a frame's ENTIRE fragment list, so the boundary's
// fixed cost (one descriptor list, one answer buffer, one codec) is paid per FRAME while the
// per-byte cost scales with the groups. Timing a single group, as 3 and 3b do, charges the whole
// fixed cost to that one group and reads ~4x pessimistic for a real frame.
do {
    let fragments = 32, shardLen = 1200, k = 8
    let groups = fragments / k
    let data = (0..<fragments).map { i in Data(fill(shardLen, UInt64(200 + i))) }
    for m in [1, 2] {
        let fec = RustReedSolomonFEC(groupSize: k, parityCount: m)
        let parity = fec.parity(forDataFragments: data, groupSize: k)
        var sink = 0
        let encNs = timeNs(5000) { sink &+= fec.parity(forDataFragments: data, groupSize: k).count }
        var lossy: [Data?] = data
        for group in 0..<groups {
            for hole in 0..<m { lossy[group * k + hole] = nil }
        }
        let par: [Data?] = parity.map(\.self)
        let recNs = timeNs(5000) {
            sink &+= fec.recover(dataFragments: lossy, parityFragments: par, groupSize: k).count
        }
        print("  FEC frame32 m\(m) encode : \(fmt(encNs / Double(groups)))/group   (\(fmt(encNs))/frame)")
        print(
            "  FEC frame32 m\(m) recover: \(fmt(recNs / Double(groups)))/group   (\(fmt(recNs))/frame)   [sink \(sink & 0xFF)]",
        )
    }
}

// ---- 3d. The whole SEND path, which is what the FEC is a part of ----
// `packetizeRaw` is the host's one CPU-heavy stretch per frame: MTU-split, parity, wire-encode.
// Timing it says whether the FEC boundary is worth more work or whether the copies around it are.
do {
    for (label, size) in [("inter 36KB", 36 * 1024), ("IDR 400KB", 400 * 1024)] {
        let frame = Data(fill(size, 4242))
        for m in [1, 2] {
            let pk = VideoPacketizer(fec: RustReedSolomonFEC(groupSize: 8, parityCount: m))
            var sink = 0
            let ns = timeNs(300) {
                sink &+= pk.packetizeRaw(
                    frame: frame, keyframe: true, hostSendTsMillis: 1,
                    fecTier: m >= 2 ? 4 : 0, isLTR: false,
                ).count
            }
            let noFec = VideoPacketizer(fec: nil)
            let bare = timeNs(300) {
                sink &+= noFec.packetizeRaw(frame: frame, keyframe: true, hostSendTsMillis: 1).count
            }
            print("  packetizeRaw \(label) m\(m): \(fmt(ns))/frame   (no FEC: \(fmt(bare)))   [sink \(sink & 0xFF)]")
        }
    }
}

// ---- 3e. The whole RECEIVE path, which is where hostile UDP is parsed ----
// `ingest` per datagram: decode the 19-byte header, buffer, and on the last one splice the AVCC back
// (plus FEC recovery when a hole exists). The client's per-frame CPU, on the weaker of the two ends.
do {
    for (label, size) in [("inter 36KB", 36 * 1024), ("IDR 400KB", 400 * 1024)] {
        let frame = Data(fill(size, 909))
        for m in [1, 2] {
            let pk = VideoPacketizer(fec: RustReedSolomonFEC(groupSize: 8, parityCount: m))
            let wire = pk.packetizeRaw(
                frame: frame, keyframe: true, hostSendTsMillis: 1, fecTier: m >= 2 ? 4 : 0,
            )
            let frags = wire.compactMap { try? FrameFragment.decode($0) }
            var sink = 0
            let clean = timeNs(200) {
                let ra = FrameReassembler(fec: RustReedSolomonFEC(groupSize: 8, parityCount: m))
                for f in frags { if case .completed = ra.ingest(f) { sink &+= 1 } }
            }
            // One data fragment lost per frame: the FEC path, which is the one that has to be fast
            // when the link is actually losing packets.
            let holed = frags.enumerated().filter { $0.offset != 3 }.map(\.element)
            let lossy = timeNs(200) {
                let ra = FrameReassembler(fec: RustReedSolomonFEC(groupSize: 8, parityCount: m))
                for f in holed { if case .completed = ra.ingest(f) { sink &+= 1 } }
            }
            print("  ingest \(label) m\(m): \(fmt(clean))/frame   (1 hole: \(fmt(lossy)))   [sink \(sink & 0xFF)]")
        }
    }
}

// ---- 3f. The datagram codec alone, which both paths meet at ----
// `decode` runs once per datagram on the CLIENT before the router even knows where the datagram
// goes, so it is the receive path's per-packet floor. Measured over a whole frame's worth.
do {
    let frame = Data(fill(36 * 1024, 909))
    let pk = VideoPacketizer()
    let wire = pk.packetizeRaw(frame: frame, keyframe: true, hostSendTsMillis: 7)
    var sink = 0
    let decode = timeNs(2000) {
        for datagram in wire {
            if let f = try? FrameFragment.decode(datagram) { sink &+= Int(f.header.frameID) }
        }
    }
    let frags = wire.compactMap { try? FrameFragment.decode($0) }
    let encode = timeNs(2000) {
        for f in frags { sink &+= f.encode().count }
    }
    let each = Double(decode) / Double(wire.count)
    print(
        "  fragment codec \(wire.count) datagrams: decode \(fmt(decode))/frame "
            + "(\(String(format: "%.0f", each))ns each)   encode \(fmt(encode))/frame   [sink \(sink & 0xFF)]",
    )
}

// ---- 3g. The recovery channel: the client's back-talk ----
// Stats go out on a timer and the host decodes one per client per window, so encode+decode is a
// per-report cost, not a per-frame one. The NACK decode and the loss-window note are the two that
// scale with LOSS: both run once per unrecovered fragment burst, which is exactly when the client
// has least headroom. The window is fed the same `now` deliberately — nothing ages out, so the ring
// sits saturated and every note pays the drop-oldest shift.
do {
    var sink = 0
    let stats = RecoveryMessage.networkStats(NetworkStatsReport(
        framesReceived: 120, fecRecovered: 4, unrecovered: 1, latestHostSendTs: 90000,
        clientHoldMs: 3, owdJitterMicros: 850,
    ))
    let wire = stats.encode()
    let enc = timeNs(200_000) { sink &+= stats.encode().count }
    let dec = timeNs(200_000) { sink &+= (try? RecoveryMessage.decode(wire)).map { _ in 1 } ?? 0 }
    let nack = RecoveryMessage.requestFragments(frameID: 9, fragIndices: [1, 2, 3, 4, 5, 6, 7, 8])
    let nackWire = nack.encode()
    let nackDec = timeNs(200_000) { sink &+= (try? RecoveryMessage.decode(nackWire)).map { _ in 1 } ?? 0 }
    var window = LossObservationWindow()
    let note = timeNs(200_000) { window.noteEvent(now: 0.5)
        sink &+= 1
    }
    print(
        "  recovery: stats encode \(fmt(enc))  decode \(fmt(dec))  "
            + "nack decode \(fmt(nackDec))  window note \(fmt(note))   [sink \(sink & 0xFF)]",
    )
}

// ---- 3h. The mux prefix, which every datagram on the flow pays ----
// Four bytes in front on the way out and a split on the way in, on both ends: the highest-frequency
// codec in the system after the fragment header itself. A 1200-byte payload is the MTU-sized case.
do {
    let payload = Data(repeating: 7, count: 1200)
    var sink = 0
    let enc = timeNs(200_000) {
        sink &+= VideoMuxHeaderCodec.encodeMedia(channelID: 3, tag: 2, payload: payload).count
    }
    let wire = VideoMuxHeaderCodec.encodeMedia(channelID: 3, tag: 2, payload: payload)
    let dec = timeNs(200_000) { sink &+= Int((try? VideoMuxHeaderCodec.decode(wire).channelID) ?? 0) }
    let bare = timeNs(200_000) {
        sink &+= VideoMuxHeaderCodec.encode(channelID: 3, payload: payload).count
    }
    print(
        "  mux prefix 1200B: encodeMedia \(fmt(enc))  encode \(fmt(bare))  "
            + "decode \(fmt(dec))   [sink \(sink & 0xFF)]",
    )
}

// ---- 3h-2. The TCP mux envelope, which every terminal frame is wrapped in ----
// One envelope per inner frame in each direction, so a flooding pane pays this on top of the
// terminal codec. The 32 KiB case is the merged host output frame; the 30-byte open is the
// lifecycle frame a reconnect storm repeats.
do {
    var sink = 0
    let payload = Data(repeating: 7, count: 32 * 1024)
    let data = MuxFrame.channelData(channelID: 3, payload: payload)
    let open = MuxFrame.channelOpen(
        channelID: 3, sessionID: UUID(), lastReceivedSeq: 42, channelClass: 0, initialCwd: nil,
    )
    let enc = timeNs(50000) { sink &+= MuxEnvelopeCodec.encode(data).count }
    let encOpen = timeNs(200_000) { sink &+= MuxEnvelopeCodec.encode(open).count }
    let wire = MuxEnvelopeCodec.encode(data)
    let inner = wire.dropFirst(4)
    let dec = timeNs(50000) { sink &+= Int((try? MuxEnvelopeCodec.decode(inner: inner))?.channelID ?? 0) }
    let openWire = MuxEnvelopeCodec.encode(open).dropFirst(4)
    let decOpen = timeNs(200_000) {
        sink &+= Int((try? MuxEnvelopeCodec.decode(inner: openWire))?.channelID ?? 0)
    }
    let stream = timeNs(50000) {
        let decoder = MuxFrameDecoder()
        decoder.append(wire)
        sink &+= Int((try? decoder.nextFrame())?.channelID ?? 0)
    }
    print(
        "  mux envelope: data 32K encode \(fmt(enc))  decode \(fmt(dec))  stream \(fmt(stream))  "
            + "open encode \(fmt(encOpen))  decode \(fmt(decOpen))   [sink \(sink & 0xFF)]",
    )
}

// ---- 3i. Input events, the other direction's per-event cost ----
// A pointer move is encoded on the client and decoded on the host once per pointer sample — up to
// the display's rate while a drag is live — and the decode is the shortest path in the system from
// a hostile datagram to a window-server call.
do {
    var sink = 0
    let move = InputEvent.mouseMove(normalized: VideoPoint(x: 0.5, y: 0.25), tag: 7)
    let scroll = InputEvent.scroll(
        dx: 1.5, dy: -2.5, normalized: VideoPoint(x: 0.5, y: 0.25),
        scrollPhase: 2, momentumPhase: 0, continuous: true, tag: 7,
    )
    let moveWire = move.encode()
    let scrollWire = scroll.encode()
    let em = timeNs(200_000) { sink &+= move.encode().count }
    let dm = timeNs(200_000) { sink &+= Int((try? InputEvent.decode(moveWire))?.messageType ?? 0) }
    let es = timeNs(200_000) { sink &+= scroll.encode().count }
    let ds = timeNs(200_000) { sink &+= Int((try? InputEvent.decode(scrollWire))?.messageType ?? 0) }
    print(
        "  input event: move encode \(fmt(em)) decode \(fmt(dm))  "
            + "scroll encode \(fmt(es)) decode \(fmt(ds))   [sink \(sink & 0xFF)]",
    )
}

// ---- 3i-2. The metadata RPC payloads: what a sidebar poll and a paste actually cost ----
// A dir listing is one lazy expand; a process list, a port list and a git status are the per-pane
// poll the sidebar repeats while a session is open; the clipboard is the one payload that can be
// megabytes, and the one this codec elides rather than copies.
do {
    var sink = 0
    let procs = (0..<64).map {
        MetadataCodec.ProcessInfo(pid: UInt32($0), uptimeSec: UInt32($0 * 7), name: "process-\($0)")
    }
    let entries = (0..<256).map {
        MetadataCodec.DirEntry(isDir: $0.isMultiple(of: 4), name: "entry-\($0).swift")
    }
    let status = MetadataCodec.GitStatusPayload(
        hasRepo: true, branch: "main", remoteURL: "git@example.com:slop/desk.git",
        repoRoot: "/Volumes/Lacie/Workspace/oss/slop-desk", ahead: 3, behind: 1, stashCount: 2,
        files: (0..<128).map {
            MetadataCodec.GitFileChange(statusCode: UInt8($0 % 10), path: "Sources/File\($0).swift")
        },
    )
    let clip = MetadataCodec.ClipboardClip(kind: .imagePNG, bytes: Data(repeating: 9, count: 4 * 1024 * 1024))
    let procWire = MetadataCodec.encodeProcessList(procs)
    let dirWire = MetadataCodec.encodeDirListing(entries)
    let gitWire = MetadataCodec.encodeGitStatus(status)
    let clipWire = MetadataCodec.encodeClipboardSet(clip)
    let ep = timeNs(20000) { sink &+= MetadataCodec.encodeProcessList(procs).count }
    let dp = timeNs(20000) { sink &+= ((try? MetadataCodec.decodeProcessList(procWire)) ?? []).count }
    let ed = timeNs(5000) { sink &+= MetadataCodec.encodeDirListing(entries).count }
    let dd = timeNs(5000) { sink &+= ((try? MetadataCodec.decodeDirListing(dirWire)) ?? []).count }
    let eg = timeNs(5000) { sink &+= MetadataCodec.encodeGitStatus(status).count }
    let dg = timeNs(5000) { sink &+= ((try? MetadataCodec.decodeGitStatus(gitWire))?.files.count ?? 0) }
    let fold = timeNs(20000) { sink &+= status.foldedCounts.staged }
    let ec = timeNs(2000) { sink &+= MetadataCodec.encodeClipboardSet(clip).count }
    let dc = timeNs(2000) { sink &+= ((try? MetadataCodec.decodeClipboardSet(clipWire))?.bytes.count ?? 0) }
    print(
        "  metadata: procs64 encode \(fmt(ep)) decode \(fmt(dp))  dir256 encode \(fmt(ed)) "
            + "decode \(fmt(dd))  git128 encode \(fmt(eg)) decode \(fmt(dg)) fold \(fmt(fold))  "
            + "clip 4M encode \(fmt(ec)) decode \(fmt(dc))   [sink \(sink & 0xFF)]",
    )
}

// ---- 3i-3. The workspace CHANNEL payloads: one per connect, one per view change ----
// A subscribe is per connection; a presence update rides every focus or resize a client makes; an
// intent is every mutation, with an opaque argument body this codec elides rather than copies; the
// roster is broadcast WHOLE to everyone on any change, so it is the one that repeats under load.
do {
    var sink = 0
    let subscribe = WorkspaceSubscribe(
        clientInstanceID: UUID(), clientKind: 0, knownEpoch: UUID(), knownStateNum: 4096,
        flags: 3, label: "Mac Studio (office)",
    )
    let presence = WorkspacePresenceUpdate(
        presenceClock: 99, viewingTabID: UUID(), viewingPaneID: UUID(), cols: 200, rows: 60, flags: 1,
    )
    let intent = WorkspaceIntent(intentID: UUID(), op: 7, args: Data(repeating: 0xAB, count: 4096))
    let result = WorkspaceIntentResult(intentID: UUID(), statusByte: 0)
    let clients = (0..<8).map { index in
        WorkspaceRosterClient(
            clientInstanceID: UUID(), clientKind: UInt8(index % 2), flags: 1,
            viewingTabID: UUID(), viewingPaneID: UUID(), cols: 180, rows: 50,
            label: "device-\(index).local",
        )
    }
    let roster = WorkspacePresenceRoster(
        clients: clients,
        panes: (0..<16).map { pane in
            WorkspaceRosterPane(
                paneID: UUID(), resolvedCols: 120, resolvedRows: 40,
                attachments: (0..<3).map { slot in
                    WorkspaceRosterPane.Attachment(
                        clientInstanceID: clients[(pane + slot) % 8].clientInstanceID,
                        contributes: slot == 0, cols: 120, rows: 40,
                    )
                },
            )
        },
    )
    let subWire = subscribe.encode()
    let presWire = presence.encode()
    let intentWire = intent.encode()
    let resultWire = result.encode()
    let rosterWire = roster.encode()
    let es = timeNs(200_000) { sink &+= subscribe.encode().count }
    let ds = timeNs(200_000) { sink &+= ((try? WorkspaceSubscribe.decode(subWire))?.label.count ?? 0) }
    let ep = timeNs(200_000) { sink &+= presence.encode().count }
    let dp = timeNs(200_000) { sink &+= Int((try? WorkspacePresenceUpdate.decode(presWire))?.cols ?? 0) }
    let ei = timeNs(100_000) { sink &+= intent.encode().count }
    let di = timeNs(100_000) { sink &+= ((try? WorkspaceIntent.decode(intentWire))?.args.count ?? 0) }
    let er = timeNs(200_000) { sink &+= result.encode().count }
    let dr = timeNs(200_000) { sink &+= Int((try? WorkspaceIntentResult.decode(resultWire))?.status ?? 0) }
    let ero = timeNs(20000) { sink &+= roster.encode().count }
    let dro = timeNs(20000) { sink &+= ((try? WorkspacePresenceRoster.decode(rosterWire))?.panes.count ?? 0) }
    print(
        "  workspace: subscribe encode \(fmt(es)) decode \(fmt(ds))  presence encode \(fmt(ep)) "
            + "decode \(fmt(dp))  intent 4K encode \(fmt(ei)) decode \(fmt(di))  result encode "
            + "\(fmt(er)) decode \(fmt(dr))  roster 8x16 encode \(fmt(ero)) decode \(fmt(dro))   "
            + "[sink \(sink & 0xFF)]",
    )
}

// ---- 3i-4. PATH 4's client end: the frame a 256 KiB chunk rides in ----
// An upload is one `offer`, then one chunk frame per 256 KiB — a gigabyte is four thousand of them —
// then a `finish`. The chunk is the only frame with a body, so it is the only one whose encode can
// matter: what is timed is the framing around a body the caller already holds, not the body. The
// splitter is timed on the reply side, where every frame is a handful of bytes and the cost is the
// call rather than the bytes.
do {
    var sink = 0
    let body = Data(fill(FileTransferProtocolConstants.chunkByteCount, 0x5107))
    let offer = FileTransferRequest.offer(transferId: 7, fileSize: 1 << 30, name: "recording-2026-08-14.mov")
    let chunk = FileTransferRequest.chunk(transferId: 7, data: body)
    let finish = FileTransferRequest.finish(transferId: 7)
    var failedPayload = Data([9, 0, 0, 0, 7, 0, 15])
    failedPayload.append(contentsOf: Array("no room on disk".utf8))
    let acceptPayload = Data([7, 0, 0, 0, 7])
    var replyStream = Data([0, 0, 0, 5])
    replyStream.append(acceptPayload)
    let eo = timeNs(200_000) { sink &+= FileTransferCodec.encodeFrame(offer).count }
    let ec = timeNs(20000) { sink &+= FileTransferCodec.encodeFrame(chunk).count }
    let ef = timeNs(200_000) { sink &+= FileTransferCodec.encodeFrame(finish).count }
    let da = timeNs(200_000) {
        sink &+= (try? FileTransferCodec.decodeReplyPayload(acceptPayload)) == nil ? 0 : 1
    }
    let dr = timeNs(200_000) {
        guard case let .failed(_, reason)? = try? FileTransferCodec.decodeReplyPayload(failedPayload) else { return }
        sink &+= reason.count
    }
    let split = timeNs(200_000) {
        let decoder = FileTransferFrameDecoder()
        decoder.append(replyStream)
        sink &+= (try? decoder.nextReply()) == nil ? 0 : 1
    }
    print(
        "  drop: offer encode \(fmt(eo))  chunk 256K encode \(fmt(ec))  finish encode \(fmt(ef))  "
            + "accept decode \(fmt(da))  failed decode \(fmt(dr))  split one frame \(fmt(split))   "
            + "[sink \(sink & 0xFF)]",
    )
}

// ---- 3i-5. The inspector channel: framing around a JSON body ----
// Events are per-turn, not per-keystroke, so this is not a hot path — it is measured because a port
// with no measurement is a port with an unmeasured regression. The shape that matters is the
// RECONNECT: the daemon replays its whole history, which arrives as one chunk packed with small
// frames, so the splitter drains many frames per append.
do {
    var sink = 0
    let event = (try? JSONEncoder().encode(
        InspectorEvent.message(MessageEvent(role: .assistant, text: String(repeating: "a turn of prose. ", count: 24))),
    )) ?? Data()
    var frame = Data([0, 0, 0, 0])
    frame.append(1)
    frame.append(event)
    let length = UInt32(frame.count - 4)
    frame[0] = UInt8(truncatingIfNeeded: length >> 24)
    frame[1] = UInt8(truncatingIfNeeded: length >> 16)
    frame[2] = UInt8(truncatingIfNeeded: length >> 8)
    frame[3] = UInt8(truncatingIfNeeded: length)
    let keepAlive = Data([0, 0, 0, 1, 2])
    var replay = Data()
    for _ in 0..<200 { replay.append(frame) }
    var payload = Data([1])
    payload.append(event)
    let es = timeNs(200_000) { sink &+= InspectorCodec.encodeSubscribe(fromSeq: 4096).count }
    let dk = timeNs(200_000) { sink &+= (try? InspectorCodec.decode(payload: Data([2]))) == nil ? 0 : 1 }
    let de = timeNs(50000) { sink &+= (try? InspectorCodec.decode(payload: payload)) == nil ? 0 : 1 }
    // One decoder, as a connection has: what repeats is the append-and-drain, not the setup.
    let decoder = InspectorFrameDecoder()
    let one = timeNs(100_000) {
        decoder.append(keepAlive)
        sink &+= (try? decoder.nextMessage()) == nil ? 0 : 1
    }
    let burst = timeNs(500) {
        let decoder = InspectorFrameDecoder()
        decoder.append(replay)
        while let message = try? decoder.nextMessage() { sink &+= message == .keepAlive ? 0 : 1 }
    }
    print(
        "  inspector: subscribe encode \(fmt(es))  keepAlive decode \(fmt(dk))  event decode "
            + "\(fmt(de))  split one frame \(fmt(one))  replay 200 frames \(fmt(burst))   "
            + "[sink \(sink & 0xFF)]",
    )
}

// ---- 3j. The metadata wires: geometry per drag-frame, audio per ~10 ms ----
// Geometry is produced once per polled frame while a remote window is being dragged; an audio
// datagram is one ~10 ms frame, so a hundred a second each way for as long as sound is on.
do {
    var sink = 0
    let bounds = WindowGeometryMessage.bounds(VideoRect(x: 10, y: 20, width: 800, height: 600))
    let boundsWire = bounds.encode()
    let ge = timeNs(200_000) { sink &+= bounds.encode().count }
    let gd = timeNs(200_000) { sink &+= Int((try? WindowGeometryMessage.decode(boundsWire))?.messageType ?? 0) }
    let frame = AudioChannelMessage.frame(seq: 5, hostSendTsMillis: 90, payload: Data(repeating: 9, count: 640))
    let frameWire = frame.encode()
    let ae = timeNs(200_000) { sink &+= frame.encode().count }
    let ad = timeNs(200_000) { sink &+= ((try? AudioChannelMessage.decode(frameWire)) != nil ? 1 : 0) }
    print(
        "  metadata: geometry encode \(fmt(ge)) decode \(fmt(gd))  "
            + "audio encode \(fmt(ae)) decode \(fmt(ad))   [sink \(sink & 0xFF)]",
    )
}

// ---- 3k. The cursor socket, and the AVCC split every frame pays ----
// A cursor update is encoded and decoded once per pointer sample, up to 120 Hz for as long as the
// pointer moves — the highest-rate message in the system after the fragment header. The shape is
// rare by comparison but carries a PNG, so what is timed there is whether the bitmap is copied to
// describe itself. `split` runs once per decoded frame on the client.
do {
    var sink = 0
    let update = CursorUpdate(
        position: VideoPoint(x: 640.5, y: 360.25), shapeID: 3,
        hotspot: VideoPoint(x: 4, y: 4), visible: true,
    )
    let updateWire = update.encode()
    let ue = timeNs(200_000) { sink &+= update.encode().count }
    let ud = timeNs(200_000) { sink &+= Int((try? CursorUpdate.decode(updateWire))?.shapeID ?? 0) }
    let shape = CursorShapeMessage(
        shapeID: 3, size: VideoSize(width: 32, height: 32),
        hotspot: VideoPoint(x: 4, y: 4), bitmap: Data(repeating: 0x89, count: 900),
    )
    let shapeWire = shape.encode()
    let se = timeNs(50000) { sink &+= shape.encode().count }
    let sd = timeNs(50000) { sink &+= (try? CursorShapeMessage.decode(shapeWire))?.bitmap.count ?? 0 }
    // One 40 KB IDR's worth of AVCC, as three units — the shape a parameter-set frame arrives in.
    let avcc = NALUnit.join([
        Data(repeating: 1, count: 22), Data(repeating: 2, count: 60), Data(repeating: 3, count: 40000),
    ])
    let ns = timeNs(50000) { sink &+= NALUnit.split(avcc).count }
    print(
        "  cursor: update encode \(fmt(ue)) decode \(fmt(ud))  shape encode \(fmt(se)) decode \(fmt(sd))  "
            + "avcc split \(fmt(ns))   [sink \(sink & 0xFF)]",
    )
}

// ---- 3l. The control channel: the handshake, the heartbeat, and the window feed ----
// `keepalive` is the bodyless floor — what the boundary itself costs. `helloAck` is the widest
// scalar arm (four Float64 plus five integers). A feed snapshot is the only arm with a LIST of
// strings, and it is the one that moved the needle: one chunk carries as many records as fit in a
// datagram, three strings each, and the client re-reads them on every host window change.
do {
    var sink = 0
    let alive = VideoControlMessage.keepalive
    let aliveWire = alive.encode()
    let ke = timeNs(200_000) { sink &+= alive.encode().count }
    let kd = timeNs(200_000) { sink &+= Int((try? VideoControlMessage.decode(aliveWire))?.messageType ?? 0) }
    let ack = VideoControlMessage.helloAck(
        accepted: true, streamID: 7, captureWidth: 1920, captureHeight: 1080,
        windowBoundsCG: VideoRect(x: 100, y: 200, width: 1600, height: 900), fullRange: true,
    )
    let ackWire = ack.encode()
    let he = timeNs(200_000) { sink &+= ack.encode().count }
    let hd = timeNs(200_000) { sink &+= Int((try? VideoControlMessage.decode(ackWire))?.messageType ?? 0) }
    let records = (0..<12).map { index in
        HostWindowRecord(
            windowID: UInt32(1000 + index), widthPt: 1280, heightPt: 800,
            flags: [.onScreen, .frontmostApp], displayIndex: 0,
            bundleID: "com.mitchellh.ghostty", appName: "Ghostty",
            title: "slop-desk — main — \(index) — ~/Workspace/oss/slop-desk",
        )
    }
    let feed = VideoControlMessage.windowFeedSnapshot(
        generation: 41, chunkIndex: 0, chunkCount: 1, records: records,
    )
    let feedWire = feed.encode()
    let fe = timeNs(50000) { sink &+= feed.encode().count }
    let fd = timeNs(50000) { sink &+= Int((try? VideoControlMessage.decode(feedWire))?.messageType ?? 0) }
    print(
        "  control: keepalive encode \(fmt(ke)) decode \(fmt(kd))  helloAck encode \(fmt(he)) decode \(fmt(hd))  "
            + "feed(12) encode \(fmt(fe)) decode \(fmt(fd))   [sink \(sink & 0xFF)]",
    )
}

// ---- 3m. The PATH-1 terminal wire: the message every keystroke and every byte of output rides ----
// `.output` is the highest-volume message in the product — one per PTY read chunk under a flood, at
// whatever rate the child writes. What is timed there is whether the payload is copied more than
// once, which is the whole reason the boundary answers WHERE the run is instead of handing one
// back. Decode goes through `FrameDecoder`, because that is how the receive loop reaches it and the
// framing is the same on both sides of this port. `wireByteCount` is charged per consumed message
// by the receive-side flow control.
do {
    var sink = 0
    let frames = FrameDecoder()
    func decodeOnce(_ frame: Data) -> Int {
        frames.append(frame)
        return Int((try? frames.nextMessage())??.messageType ?? 0)
    }
    for (label, size) in [("1KB", 1024), ("32KB", 32 * 1024)] {
        let out = WireMessage.output(seq: 7, bytes: Data(fill(size, 5150)))
        let outWire = out.encode()
        let oe = timeNs(20000) { sink &+= out.encode().count }
        let od = timeNs(20000) { sink &+= decodeOnce(outWire) }
        let ob = timeNs(200_000) { sink &+= out.wireByteCount }
        print("  wire output \(label): encode \(fmt(oe)) decode \(fmt(od)) byteCount \(fmt(ob))")
    }
    let ack = WireMessage.ack(seq: 900_000)
    let ackWire = ack.encode()
    let ae = timeNs(200_000) { sink &+= ack.encode().count }
    let ad = timeNs(200_000) { sink &+= decodeOnce(ackWire) }
    let title = WireMessage.title("slop-desk — main — ~/Workspace/oss/slop-desk")
    let titleWire = title.encode()
    let te = timeNs(200_000) { sink &+= title.encode().count }
    let td = timeNs(200_000) { sink &+= decodeOnce(titleWire) }
    print(
        "  wire ack: encode \(fmt(ae)) decode \(fmt(ad))  title: encode \(fmt(te)) decode \(fmt(td))"
            + "   [sink \(sink & 0xFF)]",
    )
}

// ---- reference values (value-stability pins for the optimization pass) ----
if CommandLine.arguments.contains("--dump") {
    print("=== reference values (must stay identical after optimization) ===")
    for (w, h, seed) in [(64, 4, UInt64(7)), (1920, 1080, UInt64(99)), (17, 9, UInt64(123))] {
        let y = fill(w * h, seed)
        let cbcr = fill(w * (h / 2 == 0 ? 1 : h / 2), seed &+ 1)
        let hv = y.withUnsafeBytes { yb in
            cbcr.withUnsafeBytes { cb in
                FrameHasher.hashNV12(
                    y: yb.baseAddress,
                    yStride: w,
                    width: w,
                    height: h,
                    cbcr: cb.baseAddress,
                    cbcrStride: w,
                )
            }
        }
        // stride > width case (padded plane)
        let yp = fill((w + 13) * h, seed &+ 2)
        let hp = yp.withUnsafeBytes { yb in
            FrameHasher.hashNV12(
                y: yb.baseAddress,
                yStride: w + 13,
                width: w,
                height: h,
                cbcr: nil,
                cbcrStride: 0,
            )
        }
        print("  hashNV12 w=\(w) h=\(h): contiguous=0x\(String(hv, radix: 16)) padded=0x\(String(hp, radix: 16))")
    }
    let k = 8
    let data: [Data] = (0..<k).map { Data(fill(1200, UInt64(10 + $0))) }
    let p = RustReedSolomonFEC(groupSize: k, parityCount: 2).parity(forDataFragments: data, groupSize: k)
    print("  FEC parity[0] first8: \(p[0].prefix(8).map { String($0, radix: 16) }.joined(separator: ","))")
}

print("=== done ===")
