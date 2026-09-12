// pull-contention — characterize the AMD xGMI-hive driver's behaviour for
// CONCURRENT destination-side pulls through Metal peer-group remote buffer
// views (the primitive llama.cpp/toshllm tensor parallelism is built on).
//
// Motivation: tp-sim showed a 4-rank all-reduce with all ranks pulling
// concurrently costs ~4 ms per reduce, while SEQUENTIAL pulls cost ~138 us
// each. This tool isolates why, case by case:
//   baseline   one rank, one remote copy, encode | commit+wait
//   multi-src  one rank, N-1 remote copies (different peers) in one CB
//   pair       two ranks pull each other (module pair, then cross pair)
//   a2a        all ranks pull all peers concurrently (1 or N-1 pulls each)
//   seq        all ranks pull all peers in sequence (no concurrency)
//   commitall  all ranks' a2a CBs committed up front, waited at the end
//   fanin      N consumers pull the SAME remote buffer concurrently
//              (KNOWN DRIVER HANG at 4 consumers on this hardware — only
//              run with --allow-fanin, and expect to have to kill the tool)
//
// All sizes are small (latency regime). Timings are medians over repeats.

import Foundation
import Metal

setbuf(stdout, nil)

var opts = (
    devices: [1, 2, 3, 4],
    bytes: 4096,
    iters: 11,
    allowFanin: false
)
var wantJSON = false
func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("pull-contention: \(msg)\n".utf8)); exit(2)
}
let args = CommandLine.arguments
var ai = 1
while ai < args.count {
    switch args[ai] {
    case "--devices":  ai += 1; guard ai < args.count else { break }
        opts.devices = args[ai].split(separator: ",").compactMap { Int($0) }
    case "--bytes":    ai += 1; guard ai < args.count else { break }
        opts.bytes = Int(args[ai]) ?? opts.bytes
    case "--iters":    ai += 1; guard ai < args.count else { break }
        opts.iters = Int(args[ai]) ?? opts.iters
    case "--allow-fanin": opts.allowFanin = true
    case "--json":    wantJSON = true
    case "-h", "--help":
        print("""
        usage: pull-contention [options]

        Measures concurrent remote-view pull contention on a peer group
        (see file header for cases). No arguments needed for the default
        4-device W6800X Duo setup.

          --devices 1,2,3,4   Metal device indices of the peer group
          --bytes N           copy size per remote op (default 4096)
          --iters N           iterations per case (default 11, median kept)
          --allow-fanin       also run the fan-in case (KNOWN DRIVER HANG
                              with >=4 consumers on AMDRadeonX6000 7.0.1)
          --json              machine-readable output
        """)
        exit(0)
    default: die("unknown argument \(args[ai]) (see --help)")
    }
    ai += 1
}
guard opts.devices.count >= 2 else { die("--devices needs at least 2 indices") }

let allDevices = MTLCopyAllDevices()
guard opts.devices.allSatisfy({ $0 < allDevices.count }) else { die("device index out of range") }
let groupIDs = Set(opts.devices.map { allDevices[$0].peerGroupID })
guard groupIDs.count == 1, let peerGroup = groupIDs.first, peerGroup != 0
else { die("all --devices must share one non-zero peerGroupID") }

let n = opts.devices.count
let dev = opts.devices.map { allDevices[$0] }
let q = dev.map { $0.makeCommandQueue()! }   // nil queue here is unrecoverable
let bytes = opts.bytes
let srcBufs = dev.map { $0.makeBuffer(length: max(bytes, 32768), options: .storageModePrivate)! }
let dstBufs = dev.map { $0.makeBuffer(length: max(bytes * 3, 32768), options: .storageModePrivate)! }

/// Views are created ONCE at startup, like tp-sim/if-bench (proven pattern).
/// One leaked +1 per view (a handful per run — acceptable).
func remoteView(_ buffer: MTLBuffer, on device: MTLDevice) -> MTLBuffer? {
    let sel = Selector(("newRemoteBufferViewForDevice:"))
    guard buffer.responds(to: sel),
          let raw = buffer.perform(sel, with: device),
          let view = raw.takeUnretainedValue() as? MTLBuffer
    else { return nil }
    return view
}
var views: [[MTLBuffer]] = Array(repeating: [], count: n)   // views[r][slot] of peers
var viewPeerIdx: [[Int]] = Array(repeating: [], count: n)   // which peer each slot is
for r in 0..<n {
    for p in 0..<n where p != r {
        guard let v = remoteView(srcBufs[p], on: dev[r])
        else { die("nil remote view of buf \(p) on device \(opts.devices[r])") }
        views[r].append(v)
        viewPeerIdx[r].append(p)
    }
}
func viewOf(_ r: Int, peer p: Int) -> MTLBuffer {
    views[r][viewPeerIdx[r].firstIndex(of: p)!]
}

func encodePulls(_ r: Int, _ srcs: [MTLBuffer]) -> MTLCommandBuffer {
    let cb = q[r].makeCommandBuffer()!
    let e = cb.makeBlitCommandEncoder()!
    for (s, v) in srcs.enumerated() {
        e.copy(from: v, sourceOffset: 0, to: dstBufs[r], destinationOffset: s * bytes, size: bytes)
    }
    e.endEncoding()
    return cb
}

struct CaseResult { var caseName: String; var us: Double; var note: String = "" }
var results: [CaseResult] = []
func emit(_ name: String, _ us: Double, _ note: String = "") {
    results.append(CaseResult(caseName: name, us: (us * 10).rounded() / 10, note: note))
    if !wantJSON { print(String(format: "%-56@ %9.1f us  %@", name, us, note)) }
}
func runCase(_ name: String, _ note: String = "", _ body: () -> Void) {
    body()  // warmup
    var ts: [Double] = []
    for _ in 0..<opts.iters {
        let t = DispatchTime.now().uptimeNanoseconds
        body()
        ts.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1000.0)
    }
    ts.sort()
    emit(name, ts[ts.count / 2], note)
}

// baseline: encode cost and commit+wait cost, single rank single pull
do {
    var enc: [Double] = [], cw: [Double] = []
    for _ in 0..<opts.iters * 3 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let cb = encodePulls(0, [views[0][0]])
        let t1 = DispatchTime.now().uptimeNanoseconds
        cb.commit(); cb.waitUntilCompleted()
        enc.append(Double(t1 - t0) / 1000.0)
        cw.append(Double(DispatchTime.now().uptimeNanoseconds - t1) / 1000.0)
    }
    enc.sort(); cw.sort()
    emit("baseline encode (1 pull CB)", enc[enc.count / 2])
    emit("baseline commit+wait (1 pull CB)", cw[cw.count / 2])
}

// multi-src: 1 rank pulls all its peers' buffers in one CB (others idle)
runCase("1 puller, \(n - 1) remote copies, 1 CB") {
    let cb = encodePulls(0, views[0])
    cb.commit(); cb.waitUntilCompleted()
}

// pair: two ranks pull each other (same-module pair on Duo layouts)
if n >= 2 {
    runCase("pair exchange rank0<->rank1") {
        DispatchQueue.concurrentPerform(iterations: 2) { k in
            let r = k, p = 1 - k
            let cb = encodePulls(r, [viewOf(r, peer: p)])
            cb.commit(); cb.waitUntilCompleted()
        }
    }
}
// cross pair: rank 0 and rank 2 (different module on Duo layouts)
if n >= 3 {
    runCase("pair exchange rank0<->rank2 (cross module)") {
        DispatchQueue.concurrentPerform(iterations: 2) { k in
            let r = k == 0 ? 0 : 2, p = k == 0 ? 2 : 0
            let cb = encodePulls(r, [viewOf(r, peer: p)])
            cb.commit(); cb.waitUntilCompleted()
        }
    }
}

// a2a: every rank pulls its peers — concurrent vs sequential
if n >= 3 {
    runCase("all-to-all concurrent, 1 pull/rank") {
        DispatchQueue.concurrentPerform(iterations: n) { r in
            let cb = encodePulls(r, [views[r][0]])
            cb.commit(); cb.waitUntilCompleted()
        }
    }
    runCase("all-to-all concurrent, \(n - 1) pulls/rank") {
        DispatchQueue.concurrentPerform(iterations: n) { r in
            let cb = encodePulls(r, views[r])
            cb.commit(); cb.waitUntilCompleted()
        }
    }
    runCase("all-to-all SEQUENTIAL (per-rank CBs one at a time)") {
        for r in 0..<n {
            let cb = encodePulls(r, views[r])
            cb.commit(); cb.waitUntilCompleted()
        }
    }
    runCase("all-to-all concurrent, commit-all then wait-all") {
        var cbs: [MTLCommandBuffer] = []
        for r in 0..<n { let cb = encodePulls(r, views[r]); cb.commit(); cbs.append(cb) }
        cbs.forEach { $0.waitUntilCompleted() }
    }
}

// fanin: every rank pulls the SAME remote buffer — KNOWN HANG at >= 4
if opts.allowFanin {
    // Exactly reproduces the hang case: every consumer (including the
    // buffer's owner device, via a self-view) pulls srcBufs[1] at once.
    let target = 1
    var fanViews: [MTLBuffer] = []
    for r in 0..<n {
        guard let v = remoteView(srcBufs[target], on: dev[r])
        else { die("nil fan-in view on device \(opts.devices[r])") }
        fanViews.append(v)
    }
    runCase("fan-in: \(n) ranks pull SAME remote buffer", "KNOWN HANG RISK >=4 consumers") {
        DispatchQueue.concurrentPerform(iterations: n) { r in
            let cb = encodePulls(r, [fanViews[r]])
            cb.commit(); cb.waitUntilCompleted()
        }
    }
} else if n >= 4 {
    emit("fan-in skipped", -1,
         "4 consumers of one remote buffer HARD-HANG the driver (AMDRadeonX6000 7.0.1); use --allow-fanin to reproduce")
}

if wantJSON {
    var out: [[String: Any]] = []
    for r in results { out.append(["case": r.caseName, "medianUs": r.us, "note": r.note]) }
    let report: [String: Any] = [
        "tool": "pull-contention", "version": 1,
        "devices": opts.devices.map { ["index": $0, "name": allDevices[$0].name] as [String: Any] },
        "peerGroupIDHex": String(format: "0x%016llx", peerGroup),
        "bytesPerRemoteOp": bytes, "iterations": opts.iters,
        "results": out,
    ]
    let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
