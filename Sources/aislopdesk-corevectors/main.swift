import AislopdeskProtocol // WireMessage, MuxEnvelopeCodec (terminal/PTY path)
import AislopdeskVideoClient // TrendlineEstimator, OwdLateDetector, PacerDepthPolicy
import AislopdeskVideoHost // NetworkEstimate, FPSGovernor (pure controllers)
import AislopdeskVideoProtocol
import Foundation

// aislopdesk-corevectors — emits a deterministic JSON corpus of golden vectors from the
// REAL Swift `AislopdeskVideoProtocol` codecs, using ONLY the public API. The Rust
// `aislopdesk-core` crate's `golden_parity` integration test replays this corpus and
// asserts byte-/bit-identical output, proving the two implementations agree on the wire.
//
// Determinism: floats that feed bytes use exactly-representable values; pure-numeric
// outputs (coordinate math, YCbCr, loss thresholds) are emitted as IEEE bit patterns so
// JSON float formatting can never blur the comparison. Re-running this dumper produces a
// byte-identical file (sorted keys), so the committed corpus stays clean in git.

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
func hex(_ bytes: [UInt8]) -> String { hex(Data(bytes)) }

var root: [String: Any] = [:]

// MARK: FrameFragment.encode

func fragmentRecord(
    streamSeq: UInt32,
    frameID: UInt32,
    fragIndex: UInt16,
    fragCount: UInt16,
    flags: UInt8,
    hostTs: UInt32,
    payload: [UInt8],
) -> [String: Any] {
    let header = FrameFragmentHeader(
        streamSeq: streamSeq,
        frameID: frameID,
        fragIndex: fragIndex,
        fragCount: fragCount,
        flags: .init(rawValue: flags),
        payloadLength: UInt16(payload.count),
        hostSendTsMillis: hostTs,
    )
    let frag = FrameFragment(header: header, payload: Data(payload))
    return [
        "streamSeq": streamSeq,
        "frameID": frameID,
        "fragIndex": fragIndex,
        "fragCount": fragCount,
        "flags": flags,
        "hostTs": hostTs,
        "payloadHex": hex(payload),
        "hex": hex(frag.encode()),
    ]
}

root["fragmentEncode"] = [
    fragmentRecord(
        streamSeq: 0x0102_0304,
        frameID: 0x0506_0708,
        fragIndex: 0x090A,
        fragCount: 0x0B0C,
        flags: 0b0000_0101,
        hostTs: 0x0D0E_0F10,
        payload: [0xAA, 0xBB, 0xCC],
    ),
    fragmentRecord(streamSeq: 0, frameID: 0, fragIndex: 0, fragCount: 1, flags: 0, hostTs: 0, payload: []),
    fragmentRecord(
        streamSeq: 0xFFFF_FFFF,
        frameID: 7,
        fragIndex: 2,
        fragCount: 9,
        flags: 0b1101_1010,
        hostTs: 1234,
        payload: Array(0..<UInt8(200)).map(\.self),
    ),
]

// MARK: XORParityFEC.parity + recover

func fecParityRecord(data: [[UInt8]], groupSize: Int) -> [String: Any] {
    let fec = XORParityFEC(groupSize: 5)
    let parity = fec.parity(forDataFragments: data.map { Data($0) }, groupSize: groupSize)
    return ["dataHex": data.map { hex($0) }, "groupSize": groupSize, "parityHex": parity.map { hex($0) }]
}

root["fecParity"] = [
    fecParityRecord(data: [[1, 2], [3], [4, 5, 6], [7], [8, 9]], groupSize: 5),
    fecParityRecord(data: (0..<12).map { [UInt8($0), UInt8($0) &+ 1, UInt8($0) &+ 2] }, groupSize: 5),
    fecParityRecord(data: [[10], [20], [30], [40], [50]], groupSize: 2),
    fecParityRecord(data: [[0xAB, 0xCD, 0xEF]], groupSize: 1),
]

func fecRecoverRecord(data: [[UInt8]?], parity: [[UInt8]?], groupSize: Int) -> [String: Any] {
    let fec = XORParityFEC(groupSize: 5)
    let recovered = fec.recover(
        dataFragments: data.map { (bytes: [UInt8]?) in bytes.map { Data($0) } },
        parityFragments: parity.map { (bytes: [UInt8]?) in bytes.map { Data($0) } },
        groupSize: groupSize,
    )
    func opt(_ b: [UInt8]?) -> Any { b.map { hex($0) } ?? NSNull() }
    func optD(_ d: Data?) -> Any { d.map { hex($0) } ?? NSNull() }
    return [
        "dataHex": data.map(opt),
        "parityHex": parity.map(opt),
        "groupSize": groupSize,
        "recoveredHex": recovered.map(optD),
    ]
}

let g5parity = XORParityFEC(groupSize: 5).parity(
    forDataFragments:
    [[1, 2], [3], [4, 5, 6], [7], [8, 9]].map { Data($0) },
    groupSize: 5,
).map { Array($0) }
root["fecRecover"] = [
    // lose the middle data fragment; group parity recovers it.
    fecRecoverRecord(data: [[1, 2], [3], nil, [7], [8, 9]], parity: [g5parity[0]], groupSize: 5),
    // two holes in one group → both stay nil (unrecoverable).
    fecRecoverRecord(data: [nil, nil, [4, 5, 6], [7], [8, 9]], parity: [g5parity[0]], groupSize: 5),
    // hole but parity also lost → stays nil.
    fecRecoverRecord(data: [[1, 2], nil, [4, 5, 6], [7], [8, 9]], parity: [nil], groupSize: 5),
]

// MARK: NALUnit.join / split

root["naluJoin"] = [
    [
        "unitsHex": [hex([1, 2, 3]), hex([4, 5]), hex([6])],
        "hex": hex(NALUnit.join([[1, 2, 3], [4, 5], [6]].map { Data($0) })),
    ],
    ["unitsHex": [hex([0xAA, 0xBB])], "hex": hex(NALUnit.join([Data([0xAA, 0xBB])]))],
]
func naluSplitRecord(_ avcc: [UInt8]) -> [String: Any] {
    ["avccHex": hex(avcc), "unitsHex": NALUnit.split(Data(avcc)).map { hex($0) }]
}

root["naluSplit"] = [
    naluSplitRecord([0, 0, 0, 1, 0x42, 0, 0, 0, 9, 1, 2]), // valid then truncated tail
    naluSplitRecord([0, 0, 0, 0, 1, 2, 3]), // zero-length prefix
    naluSplitRecord(Array(NALUnit.join([[9], [8, 7]].map { Data($0) })) + [1, 2, 3]), // trailing partial
]

// MARK: CursorUpdate / CursorShapeMessage

func cursorUpdateRecord(shapeID: UInt16, visible: Bool, x: Double, y: Double, hx: Double, hy: Double) -> [String: Any] {
    let u = CursorUpdate(
        position: VideoPoint(x: x, y: y),
        shapeID: shapeID,
        hotspot: VideoPoint(x: hx, y: hy),
        visible: visible,
    )
    return ["shapeID": shapeID, "visible": visible, "x": x, "y": y, "hx": hx, "hy": hy, "hex": hex(u.encode())]
}

root["cursorUpdate"] = [
    cursorUpdateRecord(shapeID: 0xBEEF, visible: false, x: 12.5, y: -3.25, hx: 1.0, hy: 2.0),
    cursorUpdateRecord(shapeID: 0, visible: true, x: 0.0, y: 0.0, hx: 0.0, hy: 0.0),
]
func cursorShapeRecord(
    shapeID: UInt16,
    w: Double,
    h: Double,
    hx: Double,
    hy: Double,
    bitmap: [UInt8],
) -> [String: Any] {
    let s = CursorShapeMessage(
        shapeID: shapeID,
        size: VideoSize(width: w, height: h),
        hotspot: VideoPoint(x: hx, y: hy),
        bitmap: Data(bitmap),
    )
    return ["shapeID": shapeID, "w": w, "h": h, "hx": hx, "hy": hy, "bitmapHex": hex(bitmap), "hex": hex(s.encode())]
}

root["cursorShape"] = [
    cursorShapeRecord(shapeID: 7, w: 32.0, h: 32.0, hx: 4.0, hy: 4.0, bitmap: [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]),
    cursorShapeRecord(shapeID: 1, w: 16.0, h: 16.0, hx: 0.0, hy: 0.0, bitmap: []),
]

// MARK: WindowGeometryMessage

func wg(_ name: String, _ msg: WindowGeometryMessage, _ extra: [String: Any]) -> [String: Any] {
    var r: [String: Any] = ["variant": name, "hex": hex(msg.encode())]
    r.merge(extra) { a, _ in a }
    return r
}

root["windowGeometry"] = [
    wg("move", .move(VideoPoint(x: 10.0, y: 20.0)), ["x": 10.0, "y": 20.0]),
    wg("resize", .resize(VideoSize(width: 640.0, height: 480.0)), ["w": 640.0, "h": 480.0]),
    wg("bounds", .bounds(VideoRect(x: 1.0, y: 2.0, width: 3.0, height: 4.0)), ["x": 1.0, "y": 2.0, "w": 3.0, "h": 4.0]),
    wg("title", .title("héllo · 窗口"), ["title": "héllo · 窗口"]),
]

// MARK: InputEvent

func ie(_ name: String, _ msg: InputEvent, _ extra: [String: Any]) -> [String: Any] {
    var r: [String: Any] = ["variant": name, "hex": hex(msg.encode())]
    r.merge(extra) { a, _ in a }
    return r
}

let mods: UInt8 = InputModifiers([.shift, .command]).rawValue
root["inputEvent"] = [
    ie("mouseMove", .mouseMove(normalized: VideoPoint(x: 0.25, y: 0.75), tag: 42), ["nx": 0.25, "ny": 0.75, "tag": 42]),
    ie(
        "mouseDown",
        .mouseDown(
            button: .right,
            normalized: VideoPoint(x: 0.1, y: 0.2),
            clickCount: 2,
            modifiers: .init(rawValue: mods),
            tag: 7,
        ),
        ["button": 1, "nx": 0.1, "ny": 0.2, "clickCount": 2, "mods": mods, "tag": 7],
    ),
    ie(
        "mouseUp",
        .mouseUp(
            button: .left,
            normalized: VideoPoint(x: 0.3, y: 0.4),
            clickCount: 1,
            modifiers: .init(rawValue: 0),
            tag: 8,
        ),
        ["button": 0, "nx": 0.3, "ny": 0.4, "clickCount": 1, "mods": 0, "tag": 8],
    ),
    ie(
        "mouseDrag",
        .mouseDrag(
            button: .other,
            normalized: VideoPoint(x: 0.5, y: 0.6),
            clickCount: 1,
            modifiers: .init(rawValue: InputModifiers.control.rawValue),
            tag: 9,
        ),
        ["button": 2, "nx": 0.5, "ny": 0.6, "clickCount": 1, "mods": InputModifiers.control.rawValue, "tag": 9],
    ),
    ie(
        "scroll",
        .scroll(dx: -3.5, dy: 12.0, normalized: VideoPoint(x: 0.0, y: 1.0), tag: 10),
        ["dx": -3.5, "dy": 12.0, "nx": 0.0, "ny": 1.0, "tag": 10],
    ),
    ie(
        "key",
        .key(keyCode: 0x35, down: true, modifiers: .init(rawValue: InputModifiers.option.rawValue), tag: 11),
        ["keyCode": 0x35, "down": true, "mods": InputModifiers.option.rawValue, "tag": 11],
    ),
    ie("text", .text("gõ được 文字", tag: 12), ["text": "gõ được 文字", "tag": 12]),
]

// MARK: VideoControlMessage

func vc(_ name: String, _ msg: VideoControlMessage, _ extra: [String: Any]) -> [String: Any] {
    var r: [String: Any] = ["variant": name, "hex": hex(msg.encode())]
    r.merge(extra) { a, _ in a }
    return r
}

root["videoControl"] = [
    vc(
        "hello",
        .hello(protocolVersion: 7, requestedWindowID: 0xDEAD_BEEF, viewport: VideoSize(width: 1280.0, height: 800.0)),
        ["version": 7, "windowID": 0xDEAD_BEEF, "vw": 1280.0, "vh": 800.0],
    ),
    vc(
        "helloAck",
        .helloAck(
            accepted: true,
            streamID: 42,
            captureWidth: 1920,
            captureHeight: 1080,
            windowBoundsCG: VideoRect(x: 0.0, y: 25.0, width: 800.0, height: 600.0),
            fullRange: true,
        ),
        [
            "accepted": true,
            "streamID": 42,
            "cw": 1920,
            "ch": 1080,
            "bx": 0.0,
            "by": 25.0,
            "bw": 800.0,
            "bh": 600.0,
            "fullRange": true,
        ],
    ),
    vc("bye", .bye, [:]),
    vc(
        "resizeRequest",
        .resizeRequest(desired: VideoSize(width: 640.5, height: 480.25), epoch: 3),
        ["w": 640.5, "h": 480.25, "epoch": 3],
    ),
    vc("resizeAck", .resizeAck(captureWidth: 640, captureHeight: 480, epoch: 3), ["cw": 640, "ch": 480, "epoch": 3]),
    vc("keepalive", .keepalive, [:]),
    vc("listWindows", .listWindows, [:]),
    vc("windowList", .windowList([
        WindowSummary(windowID: 1, appName: "Google Chrome", title: "Tab — Title", width: 1200, height: 800),
        WindowSummary(windowID: 2, appName: "Terminal", title: "", width: 80, height: 24),
    ]), ["windows": [
        ["windowID": 1, "appName": "Google Chrome", "title": "Tab — Title", "width": 1200, "height": 800],
        ["windowID": 2, "appName": "Terminal", "title": "", "width": 80, "height": 24],
    ]]),
    vc("focusWindow", .focusWindow, [:]),
    vc("streamCadence", .streamCadence(fps: 60), ["fps": 60]),
    vc("listSystemDialogs", .listSystemDialogs, [:]),
    vc("systemDialogList", .systemDialogList([
        SystemDialogSummary(windowID: 9, owner: "SecurityAgent", title: "", width: 400, height: 200, isSecure: true),
    ]), ["dialogs": [
        ["windowID": 9, "owner": "SecurityAgent", "title": "", "width": 400, "height": 200, "isSecure": true],
    ]]),
]

// MARK: RecoveryMessage

func rc(_ name: String, _ msg: RecoveryMessage, _ extra: [String: Any]) -> [String: Any] {
    var r: [String: Any] = ["variant": name, "hex": hex(msg.encode())]
    r.merge(extra) { a, _ in a }
    return r
}

root["recovery"] = [
    rc("ack", .ack(streamSeq: 123), ["streamSeq": 123]),
    rc(
        "requestLTRRefresh",
        .requestLTRRefresh(fromFrameID: 10, toFrameID: 12, lastDecodedFrameID: RecoveryMessage.noFrameDecodedSentinel),
        ["from": 10, "to": 12, "lastDecoded": RecoveryMessage.noFrameDecodedSentinel],
    ),
    rc("requestIDR", .requestIDR(lastDecodedFrameID: 9), ["lastDecoded": 9]),
    rc("requestCursorShape", .requestCursorShape(shapeID: 0xABCD), ["shapeID": 0xABCD]),
    rc(
        "networkStats",
        .networkStats(NetworkStatsReport(
            framesReceived: 100, fecRecovered: 5, unrecovered: 2, latestHostSendTs: 999, clientHoldMs: 3,
            owdJitterMicros: 1500, owdTrendMilli: UInt32(bitPattern: -1234), owdTrendFlags: (255 << 8) | 0x1,
            pacerLateFrames: 4, pacerPresentGaps: 6, pacerDepth: 2,
        )),
        [
            "framesReceived": 100,
            "fecRecovered": 5,
            "unrecovered": 2,
            "latestHostSendTs": 999,
            "clientHoldMs": 3,
            "owdJitterMicros": 1500,
            "owdTrendMilli": UInt32(bitPattern: -1234),
            "owdTrendFlags": (255 << 8) | 0x1,
            "pacerLateFrames": 4,
            "pacerPresentGaps": 6,
            "pacerDepth": 2,
        ],
    ),
]

// MARK: Mux header

root["muxBare"] = [
    [
        "channelID": 0x0102_0304,
        "payloadHex": hex([9, 8, 7]),
        "hex": hex(VideoMuxHeaderCodec.encode(channelID: 0x0102_0304, payload: Data([9, 8, 7]))),
    ],
]
let muxHeader = MuxFrameFragmentHeader(
    channelID: 0xAABB_CCDD,
    streamSeq: 1,
    frameID: 2,
    fragIndex: 3,
    fragCount: 4,
    flags: .keyframe,
    payloadLength: 2,
)
root["muxFragment"] = [
    [
        "channelID": 0xAABB_CCDD,
        "streamSeq": 1,
        "frameID": 2,
        "fragIndex": 3,
        "fragCount": 4,
        "flags": FrameFragmentHeader.Flags.keyframe.rawValue,
        "payloadHex": hex([0xEE, 0xFF]),
        "hex": hex(muxHeader.encode(payload: Data([0xEE, 0xFF]))),
    ],
]

// MARK: CoordinateMapping (numeric — bit-pattern exact)

func coordRecord(nx: Double, ny: Double, bx: Double, by: Double, bw: Double, bh: Double) -> [String: Any] {
    let p = CoordinateMapping.windowPoint(
        normalized: VideoPoint(x: nx, y: ny),
        windowBounds: VideoRect(x: bx, y: by, width: bw, height: bh),
    )
    return [
        "nx": nx,
        "ny": ny,
        "bx": bx,
        "by": by,
        "bw": bw,
        "bh": bh,
        "outXBits": p.x.bitPattern,
        "outYBits": p.y.bitPattern,
    ]
}

root["coordWindowPoint"] = [
    coordRecord(nx: 0.5, ny: 0.25, bx: 100.0, by: 200.0, bw: 800.0, bh: 600.0),
    coordRecord(nx: 0.0, ny: 1.0, bx: -50.0, by: 0.0, bw: 1024.0, bh: 768.0),
]

// MARK: YCbCr coefficients (f32 — bit-pattern exact)

func ycbcrRecord(_ range: ColorRange, _ name: String) -> [String: Any] {
    let c = YCbCrConversion.coefficients(range)
    return [
        "range": name,
        "lumaScale": c.lumaScale.bitPattern,
        "lumaBias": c.lumaBias.bitPattern,
        "chromaBias": c.chromaBias.bitPattern,
        "crToR": c.crToR.bitPattern,
        "cbToG": c.cbToG.bitPattern,
        "crToG": c.crToG.bitPattern,
        "cbToB": c.cbToB.bitPattern,
    ]
}

root["ycbcr"] = [ycbcrRecord(.video, "video"), ycbcrRecord(.full, "full")]

// MARK: AdaptiveFEC decisions

func tierRecord(loss: Double, prevTier: UInt8, allowOff: Bool) -> [String: Any] {
    [
        "lossBits": loss.bitPattern,
        "prevTier": prevTier,
        "allowOff": allowOff,
        "tier": AdaptiveFECPolicy.tier(forLossRate: loss, previousTier: prevTier, allowOff: allowOff),
    ]
}

var tierCases: [[String: Any]] = []
for loss in [0.0, 0.001, 0.005, 0.015, 0.02, 0.05, 0.10, 0.15] {
    for prev in [UInt8(0), 1, 2, 3, 4] {
        for allowOff in [false, true] {
            tierCases.append(tierRecord(loss: loss, prevTier: prev, allowOff: allowOff))
        }
    }
}

root["adaptiveTier"] = tierCases

func groupSizeRecord(tier: UInt8, def: Int) -> [String: Any] {
    let g = AdaptiveFECPolicy.groupSize(forTier: tier, default: def)
    return ["tier": tier, "def": def, "groupSize": g.map { $0 as Any } ?? NSNull()]
}

root["adaptiveGroupSize"] = (0...7).map { groupSizeRecord(tier: UInt8($0), def: 5) } + [groupSizeRecord(
    tier: 200,
    def: 7,
)]

// MARK: - Realtime controllers (FLOAT-determinism parity)

//
// The controllers' decisions are internal (not on the wire), but their f64 EWMA / OLS / median
// math is the trickiest code in the port. These vectors drive each pure controller through a
// deterministic input sequence and dump the resulting float STATE as IEEE bit patterns, proving
// the Rust port reproduces Swift's floating-point arithmetic operation-for-operation. The inputs
// use the SAME literal expressions the Rust replay uses, so accumulated f64 values are identical.

// MARK: NetworkEstimate — EWMA RTT / min-RTT re-baseline / loss EWMA.

do {
    var est = NetworkEstimate()
    // (rttMillis | nil, framesReceived, unrecovered, owdJitterMicros)
    let folds: [(Int?, UInt32, UInt32, UInt32)] = [
        (50, 1000, 0, 100), (50, 1000, 0, 200), (500, 1000, 50, 9000), (80, 1000, 0, 100),
        (nil, 1000, 0, 100), (6, 3, 1, 500), (300, 1000, 0, 100), (40, 1000, 0, 100),
        (60, 1000, 0, 100), (120, 1000, 0, 100), (5, 1000, 1000, 100), (50, 1000, 0, 100),
    ]
    var steps: [[String: Any]] = []
    for (rtt, frames, unrec, jit) in folds {
        est.fold(rttMillis: rtt, framesReceived: frames, unrecovered: unrec, owdJitterMicros: jit)
        steps.append([
            "rtt": rtt.map { $0 as Any } ?? NSNull(), "frames": frames, "unrec": unrec, "jitter": jit,
            "smoothedBits": est.smoothedRTTMillis.bitPattern,
            "minBits": est.minRTTMillis.bitPattern,
            "lossRateBits": est.lossRate.bitPattern,
            "lastLossBits": est.lastLossSample.bitPattern,
        ])
    }
    root["networkEstimateFold"] = steps
}

// MARK: TrendlineEstimator — windowed OLS slope + adaptive threshold (the float-heaviest path).

do {
    var est = TrendlineEstimator()
    var arrival = 1000.0
    var ts: UInt32 = 5000
    est.note(arrivalMs: arrival, sendTs: ts)
    for _ in 0..<60 { arrival += 16
        ts &+= 16
        est.note(arrivalMs: arrival, sendTs: ts)
    } // steady
    for _ in 0..<40 { arrival += 41
        ts &+= 16
        est.note(arrivalMs: arrival, sendTs: ts)
    } // +25ms ramp
    root["trendlineDrive"] = [
        "modifiedTrendBits": est.modifiedTrend.bitPattern,
        "thresholdBits": est.threshold.bitPattern,
        "stateRaw": est.state.rawValue, "numDeltas": est.numDeltas,
        "wireTrendMilli": est.wireTrendMilli, "wireTrendFlags": est.wireTrendFlags,
    ]
}

// MARK: OwdLateDetector — two-bucket min baseline + per-sample deviation (bits-or-null per step).

do {
    var d = OwdLateDetector()
    let interval = 1000.0 / 60.0
    var arrival = 5000.0
    var send: UInt32 = 91000
    var steps: [[String: Any]] = []
    func step(_ darr: Double, _ dsend: UInt32) {
        arrival += darr
        send &+= dsend
        let v = d.note(arrivalMs: arrival, sendTs: send, intervalMs: interval)
        steps.append(["devBits": v.map { $0.bitPattern as Any } ?? NSNull()])
    }
    for _ in 0..<30 { step(16.7, 17) } // warm
    step(16.7 + 40, 17) // spike
    for _ in 0..<5 { step(16.7 + 30, 17) } // queue build
    for _ in 0..<12 { step(1, 17) } // drain back toward baseline
    root["owdLateDrive"] = steps
}

// MARK: FPSGovernor — bytes-per-frame EWMA fold.

do {
    var gov = FPSGovernor(baseFps: 60)
    let sizes: [Int] = [10000, 20000, 15000, 30000, 12000, 18000, 22000, 9000, 40000, 11000]
    for s in sizes { gov.noteEncodedFrame(bytes: s, isAnchor: false) }
    gov.noteEncodedFrame(bytes: 500_000, isAnchor: true) // anchor excluded
    root["fpsGovernorEwma"] = ["bytesEwmaBits": gov.bytesPerFrameEWMA.bitPattern]
}

// MARK: PacerDepthPolicy — interval-ring median + late-threshold float math.

do {
    var dp = PacerDepthPolicy(adaptEnabled: true)
    var t = 0.0
    // 30 arrivals at a deliberately uneven cadence so the median is exercised (not all equal).
    let gaps = [1.0 / 60, 1.0 / 60, 1.0 / 50, 1.0 / 60, 1.0 / 72, 1.0 / 60]
    for i in 0..<30 { t += gaps[i % gaps.count]
        dp.noteArrival(t)
        dp.notePresent(t)
    }
    root["pacerDepthFloats"] = [
        "expectedIntervalBits": dp.expectedIntervalSeconds.bitPattern,
        "lateThresholdBits": dp.lateThresholdSeconds.bitPattern,
    ]
    var hinted = PacerDepthPolicy(adaptEnabled: true)
    hinted.setIntervalHint(1.0 / 30.0)
    root["pacerDepthHinted"] = [
        "expectedIntervalBits": hinted.expectedIntervalSeconds.bitPattern,
        "lateThresholdBits": hinted.lateThresholdSeconds.bitPattern,
    ]
}

// MARK: AislopdeskProtocol — terminal WireMessage.encode (byte parity)

//
// Each record carries a `kind` discriminator + the fields needed to reconstruct the
// message in Rust, plus the full encoded frame `hex`. The Rust `golden_parity` test rebuilds
// the message from the fields, re-encodes, and asserts byte-identical output. Session ids are
// FIXED byte patterns (never `UUID()`) so the corpus regenerates byte-identically.

let sidA = UUID(uuid: (
    0x11,
    0x22,
    0x33,
    0x44,
    0x55,
    0x66,
    0x77,
    0x88,
    0x99,
    0xAA,
    0xBB,
    0xCC,
    0xDD,
    0xEE,
    0xFF,
    0x00,
))
let sidB = UUID(uuid: (
    0x01,
    0x02,
    0x03,
    0x04,
    0x05,
    0x06,
    0x07,
    0x08,
    0x09,
    0x0A,
    0x0B,
    0x0C,
    0x0D,
    0x0E,
    0x0F,
    0x10,
))

// The UUID's 16 raw bytes via the public Foundation API (`dataBytes` is internal to the module).
func uuidBytes(_ u: UUID) -> [UInt8] { withUnsafeBytes(of: u.uuid) { Array($0) } }

func wmRecord(_ kind: String, _ m: WireMessage, _ fields: [String: Any]) -> [String: Any] {
    var r = fields
    r["kind"] = kind
    r["hex"] = hex(m.encode())
    return r
}

root["terminalWireMessages"] = [
    wmRecord(
        "output",
        .output(seq: 1, bytes: Data("hello".utf8)),
        ["seq": Int64(1), "bytesHex": hex(Data("hello".utf8))],
    ),
    wmRecord(
        "output",
        .output(seq: Int64.max, bytes: Data()),
        ["seq": Int64.max, "bytesHex": ""],
    ),
    wmRecord(
        "output",
        .output(seq: 42, bytes: Data([0x1B, 0x5B, 0x32, 0x4A])),
        ["seq": Int64(42), "bytesHex": hex([0x1B, 0x5B, 0x32, 0x4A])],
    ),
    wmRecord("exit", .exit(code: -1), ["code": Int(-1)]),
    wmRecord("exit", .exit(code: Int32.min), ["code": Int(Int32.min)]),
    wmRecord(
        "input",
        .input(Data([0x00, 0xFF, 0x80, 0x7F])),
        ["bytesHex": hex([0x00, 0xFF, 0x80, 0x7F])],
    ),
    wmRecord(
        "hello",
        .hello(protocolVersion: 1, sessionID: WireMessage.newSessionID, lastReceivedSeq: 0),
        [
            "protocolVersion": Int(1),
            "sessionIdHex": hex(uuidBytes(WireMessage.newSessionID)),
            "lastReceivedSeq": Int64(0),
        ],
    ),
    wmRecord(
        "hello",
        .hello(protocolVersion: UInt16.max, sessionID: sidA, lastReceivedSeq: Int64.max),
        ["protocolVersion": Int(UInt16.max), "sessionIdHex": hex(uuidBytes(sidA)), "lastReceivedSeq": Int64.max],
    ),
    wmRecord(
        "resize",
        .resize(cols: 80, rows: 24, pxWidth: 640, pxHeight: 384),
        ["cols": Int(80), "rows": Int(24), "pxWidth": Int(640), "pxHeight": Int(384)],
    ),
    wmRecord(
        "resize",
        .resize(cols: 65535, rows: 65535, pxWidth: 65535, pxHeight: 65535),
        ["cols": Int(65535), "rows": Int(65535), "pxWidth": Int(65535), "pxHeight": Int(65535)],
    ),
    wmRecord("ack", .ack(seq: -1), ["seq": Int64(-1)]),
    wmRecord("bye", .bye, [:]),
    wmRecord("ping", .ping(timestampMS: 1_749_700_000_123), ["timestampMs": UInt64(1_749_700_000_123)]),
    wmRecord("pong", .pong(timestampMS: UInt64.max), ["timestampMs": UInt64.max]),
    wmRecord(
        "helloAck",
        .helloAck(sessionID: sidB, resumeFromSeq: 9, returningClient: true),
        ["sessionIdHex": hex(uuidBytes(sidB)), "resumeFromSeq": Int64(9), "returningClient": true],
    ),
    wmRecord(
        "helloAck",
        .helloAck(sessionID: WireMessage.newSessionID, resumeFromSeq: 0, returningClient: false),
        [
            "sessionIdHex": hex(uuidBytes(WireMessage.newSessionID)),
            "resumeFromSeq": Int64(0),
            "returningClient": false,
        ],
    ),
    wmRecord("title", .title("build ✅ done 🚀 — café"), ["title": "build ✅ done 🚀 — café"]),
    wmRecord("title", .title(""), ["title": ""]),
    wmRecord("bell", .bell, [:]),
    wmRecord("commandStatus", .commandStatus(.running), ["cmd": "running"]),
    wmRecord(
        "commandStatus",
        .commandStatus(.idle(exitCode: 130, durationMS: 12000)),
        ["cmd": "idle", "hasExit": true, "exitCode": Int(130), "durationMs": UInt64(12000)],
    ),
    wmRecord(
        "commandStatus",
        .commandStatus(.idle(exitCode: Int32.min, durationMS: UInt32.max)),
        ["cmd": "idle", "hasExit": true, "exitCode": Int(Int32.min), "durationMs": UInt64(UInt32.max)],
    ),
    wmRecord(
        "commandStatus",
        .commandStatus(.idle(exitCode: nil, durationMS: 0)),
        ["cmd": "idle", "hasExit": false, "exitCode": Int(0), "durationMs": UInt64(0)],
    ),
    wmRecord(
        "notification",
        .notification(title: "CI", body: "green ✅ — đa byte"),
        ["title": "CI", "body": "green ✅ — đa byte"],
    ),
    wmRecord(
        "notification",
        .notification(title: "", body: "build done"),
        ["title": "", "body": "build done"],
    ),
    wmRecord(
        "notification",
        .notification(title: "semis;in;title", body: "and;in;body;too"),
        ["title": "semis;in;title", "body": "and;in;body;too"],
    ),
]

// MARK: AislopdeskProtocol — MuxEnvelopeCodec.encode (byte parity)

func muxRecord(_ kind: String, _ f: MuxFrame, _ fields: [String: Any]) -> [String: Any] {
    var r = fields
    r["kind"] = kind
    r["hex"] = hex(MuxEnvelopeCodec.encode(f))
    return r
}

root["muxEnvelopes"] = [
    muxRecord(
        "channelOpen",
        .channelOpen(channelID: 1, sessionID: WireMessage.newSessionID, lastReceivedSeq: 0, channelClass: 0),
        [
            "channelId": UInt32(1),
            "sessionIdHex": hex(uuidBytes(WireMessage.newSessionID)),
            "lastReceivedSeq": Int64(0),
            "channelClass": Int(0),
        ],
    ),
    muxRecord(
        "channelOpen",
        .channelOpen(channelID: UInt32.max, sessionID: sidA, lastReceivedSeq: -1, channelClass: 255),
        [
            "channelId": UInt32.max,
            "sessionIdHex": hex(uuidBytes(sidA)),
            "lastReceivedSeq": Int64(-1),
            "channelClass": Int(255),
        ],
    ),
    muxRecord(
        "channelOpenAck",
        .channelOpenAck(channelID: 3, accepted: true),
        ["channelId": UInt32(3), "accepted": true],
    ),
    muxRecord(
        "channelOpenAck",
        .channelOpenAck(channelID: 5, accepted: false),
        ["channelId": UInt32(5), "accepted": false],
    ),
    muxRecord(
        "channelData",
        .channelData(channelID: 9, payload: WireMessage.output(seq: 42, bytes: Data("vt ✅".utf8)).encode()),
        ["channelId": UInt32(9), "payloadHex": hex(WireMessage.output(seq: 42, bytes: Data("vt ✅".utf8)).encode())],
    ),
    muxRecord(
        "channelData",
        .channelData(channelID: 4, payload: Data()),
        ["channelId": UInt32(4), "payloadHex": ""],
    ),
    muxRecord("channelClose", .channelClose(channelID: 6), ["channelId": UInt32(6)]),
    muxRecord(
        "windowAdjust",
        .windowAdjust(channelID: 7, bytesToAdd: 262_144),
        ["channelId": UInt32(7), "bytesToAdd": UInt64(262_144)],
    ),
    muxRecord(
        "windowAdjust",
        .windowAdjust(channelID: 1, bytesToAdd: UInt32.max),
        ["channelId": UInt32(1), "bytesToAdd": UInt64(UInt32.max)],
    ),
]

// MARK: emit

let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0A]))
