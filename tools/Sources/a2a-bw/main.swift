// a2a-bw — is the Infinity Fabric Link bridge's capacity shared when all
// hive members transfer simultaneously, or does each GPU pair get its own
// share? Apple rates the W6x-series IF link at 84 GB/s per direction but
// publishes no figure for the external bridge connection, and every
// previous measurement in this repo ran one flow at a time.
//
// Method: bulk (64 MiB) destination-side pulls through peer-group remote
// views — the same primitive as if-bench p2p, sized into the bandwidth
// regime so driver fixed-costs are amortised. Each stream = rounds copies
// in one command buffer on the CONSUMER's queue (pulls; remote views are
// read-only). Phases:
//   A isolated      every stream alone, one at a time (baseline per pair)
//   B jumper-ctrl   same-module pairs run simultaneously (physically
//                   independent links — control for "sharing" detection)
//   C cross-card    cross-module pairs only, all simultaneously
//                   (directly answers the bridge-sharing question)
//   D all-to-all    every ordered pair simultaneously (max hive stress;
//                   every buffer has n-1 consumers — 4+ would hang the
//                   driver, 3 is measured-safe)
// Reports per-stream GB/s (median over repeats) and phase aggregate GB/s.

import Foundation
import Metal

setbuf(stdout, nil)

var opts = (
    devices: [1, 2, 3, 4],
    moduleA: [Int](),
    moduleB: [Int](),
    bytes: 64 * 1024 * 1024,
    rounds: 8,
    iters: 3,
    engine: "blit",
    maxConcurrent: 0
)
var wantJSON = false
var phaseFilter: [String] = []   // empty = all; else keep phases whose name contains any entry
func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("a2a-bw: \(msg)\n".utf8)); exit(2)
}
func progress(_ line: String) {
    FileHandle.standardError.write(Data("a2a-bw: \(line)\n".utf8))
}
let args = CommandLine.arguments
var ai = 1
while ai < args.count {
    switch args[ai] {
    case "--devices":  ai += 1; guard ai < args.count else { break }
        opts.devices = args[ai].split(separator: ",").compactMap { Int($0) }
    case "--modules":  ai += 1; guard ai < args.count else { break }
        let halves = args[ai].split(separator: "|").map { $0.split(separator: ",").compactMap { Int($0) } }
        guard halves.count == 2 else { die("--modules wants '<idx,idx>|<idx,idx>'") }
        opts.moduleA = halves[0]; opts.moduleB = halves[1]
    case "--bytes":    ai += 1; guard ai < args.count else { break }
        opts.bytes = Int(args[ai]) ?? opts.bytes
    case "--rounds":   ai += 1; guard ai < args.count else { break }
        opts.rounds = Int(args[ai]) ?? opts.rounds
    case "--iters":    ai += 1; guard ai < args.count else { break }
        opts.iters = Int(args[ai]) ?? opts.iters
    case "--engine":   ai += 1; guard ai < args.count else { break }
        guard args[ai] == "blit" || args[ai] == "kernel" else { die("--engine is blit|kernel") }
        opts.engine = args[ai]
    case "--max-concurrent": ai += 1; guard ai < args.count else { break }
        opts.maxConcurrent = Int(args[ai]) ?? 0
    case "--phases":   ai += 1; guard ai < args.count else { break }
        phaseFilter = args[ai].split(separator: ",").map(String.init)
    case "--json":     wantJSON = true
    case "-h", "--help":
        print("""
        usage: a2a-bw [options]

        Measures simultaneous bulk remote-view pull bandwidth across an xGMI
        hive to determine whether the Infinity Fabric Link bridge capacity is
        shared across flows. Default setup: 2x W6800X Duo, modules (1,2)|(3,4).

          --devices 1,2,3,4      Metal device indices (one peer group)
          --modules 1,2|3,4      which devices share a physical module
                                 (default: first half / second half of
                                 --devices when exactly 4 are given)
          --bytes N              buffer size per stream (default 64 MiB)
          --rounds N             copies per stream per CB (default 8)
          --iters N              timed repeats per phase, median kept
                                 (default 3, plus one warmup)
          --engine blit|kernel   pull with blit copies (default) or with a
                                 compute kernel reading the remote view
                                 (different driver submission path)
          --max-concurrent N     cap simultaneously-in-flight streams with
                                 a semaphore (default 0 = uncapped)
          --phases A,B3,E8       only run phases whose name contains one of
                                 these comma-separated substrings
          --json                 machine-readable output
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

// Module membership: needed to label streams cross-module vs same-module.
if opts.moduleA.isEmpty {
    guard opts.devices.count == 4 else { die("--modules required unless exactly 4 devices (assumed first2|last2)") }
    opts.moduleA = [opts.devices[0], opts.devices[1]]
    opts.moduleB = [opts.devices[2], opts.devices[3]]
    progress("assuming modules \(opts.moduleA)|\(opts.moduleB) (pass --modules to override)")
}
guard Set(opts.moduleA + opts.moduleB) == Set(opts.devices),
      !opts.moduleA.isEmpty, !opts.moduleB.isEmpty
else { die("--modules must partition --devices") }
func moduleOf(_ metalIdx: Int) -> String {
    opts.moduleA.contains(metalIdx) ? "A" : (opts.moduleB.contains(metalIdx) ? "B" : "?")
}

let n = opts.devices.count
let dev = opts.devices.map { allDevices[$0] }
let q = dev.map { $0.makeCommandQueue()! }
let bytes = opts.bytes, rounds = opts.rounds
// Source per device; one destination per ordered (consumer, producer) pair.
let src = dev.map { $0.makeBuffer(length: bytes, options: .storageModePrivate)! }
var dst = [[MTLBuffer]](repeating: [], count: n)   // dst[c][p] used when p != c
for c in 0..<n {
    for p in 0..<n {
        if p == c { dst[c].append(src[c]); continue }
        dst[c].append(dev[c].makeBuffer(length: bytes, options: .storageModePrivate)!)
    }
}
// Fill sources once (never touched again — consumers read "clean" VRAM).
for i in 0..<n {
    let cb = q[i].makeCommandBuffer()!, e = cb.makeBlitCommandEncoder()!
    e.fill(buffer: src[i], range: 0..<bytes, value: UInt8(0x5A &+ i))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
}

/// Views created once (proven pattern); one leaked +1 per view — fine.
func remoteView(_ buffer: MTLBuffer, on device: MTLDevice) -> MTLBuffer? {
    let sel = Selector(("newRemoteBufferViewForDevice:"))
    guard buffer.responds(to: sel),
          let raw = buffer.perform(sel, with: device),
          let view = raw.takeUnretainedValue() as? MTLBuffer
    else { return nil }
    return view
}
// views[c][p] = consumer c's read-only view of producer p's source.
var views = [[MTLBuffer]](repeating: [], count: n)
for c in 0..<n {
    for p in 0..<n {
        if p == c { views[c].append(src[c]); continue }
        guard let v = remoteView(src[p], on: dev[c])
        else { die("nil remote view: consumer \(opts.devices[c]) of source \(opts.devices[p])") }
        views[c].append(v)
    }
}

struct Spec { let c: Int, p: Int }
var phaseReports: [[String: Any]] = []

// Kernel engine: one trivially compiling pull kernel per consumer device
// (kernel-driven remote reads are a different driver submission path than
// the blit engine; used to tell fabric limits from blit-path scheduling).
let pullSource = """
kernel void pull(const device uchar4 *src [[buffer(0)]],
                 device uchar4 *dst [[buffer(1)]],
                 uint tid [[thread_position_in_grid]]) {
    dst[tid] = src[tid];
}
"""
var pullPipes: [Int: MTLComputePipelineState] = [:]
if opts.engine == "kernel" {
    guard opts.bytes % (16 * 256) == 0 else { die("--engine kernel needs --bytes multiple of 4096") }
    for c in 0..<n {
        guard let lib = try? dev[c].makeLibrary(source: pullSource, options: nil),
              let fn = lib.makeFunction(name: "pull"),
              let pso = try? dev[c].makeComputePipelineState(function: fn)
        else { die("kernel engine: pipeline compile failed on device \(opts.devices[c])") }
        pullPipes[c] = pso
    }
}
let pullThreads = opts.bytes / 16

/// One timed iteration: run all specs (concurrently or one at a time).
/// Returns (wall ms, per-stream GB/s in spec order).
func runStreams(_ specs: [Spec], concurrent: Bool, maxConcurrent: Int = 0) -> (Double, [Double]) {
    var gbps = [Double](repeating: 0, count: specs.count)
    let lock = NSLock()
    let sem = maxConcurrent > 0 ? DispatchSemaphore(value: maxConcurrent) : nil
    let startAll = DispatchTime.now().uptimeNanoseconds
    func one(_ i: Int) {
        sem?.wait()
        defer { sem?.signal() }
        let s = specs[i]
        let cb = q[s.c].makeCommandBuffer()!
        if opts.engine == "kernel", let pso = pullPipes[s.c] {
            guard let e = cb.makeComputeCommandEncoder() else {
                lock.lock(); gbps[i] = 0; lock.unlock(); return
            }
            e.setComputePipelineState(pso)
            e.setBuffer(views[s.c][s.p], offset: 0, index: 0)
            e.setBuffer(dst[s.c][s.p], offset: 0, index: 1)
            let grid = MTLSize(width: pullThreads, height: 1, depth: 1)
            let tg = MTLSize(width: 256, height: 1, depth: 1)
            for _ in 0..<rounds { e.dispatchThreads(grid, threadsPerThreadgroup: tg) }
            e.endEncoding()
        } else {
            let e = cb.makeBlitCommandEncoder()!
            for _ in 0..<rounds {
                e.copy(from: views[s.c][s.p], sourceOffset: 0, to: dst[s.c][s.p], destinationOffset: 0, size: bytes)
            }
            e.endEncoding()
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        cb.commit(); cb.waitUntilCompleted()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let gb = Double(bytes * rounds) / (ms / 1e3) / 1e9
        lock.lock(); gbps[i] = gb; lock.unlock()
    }
    if concurrent {
        DispatchQueue.concurrentPerform(iterations: specs.count, execute: one)
    } else {
        for i in 0..<specs.count { one(i) }
    }
    return (Double(DispatchTime.now().uptimeNanoseconds - startAll) / 1e6, gbps)
}

func phase(_ name: String, _ specs: [Spec], concurrent: Bool, maxConcurrent: Int = 0) {
    guard !specs.isEmpty else { return }
    guard phaseFilter.isEmpty || phaseFilter.contains(where: { name.contains($0) }) else { return }
    let cap = maxConcurrent > 0 ? maxConcurrent : opts.maxConcurrent
    _ = runStreams(specs, concurrent: concurrent, maxConcurrent: cap)  // warmup
    var walls: [Double] = []
    var perStream: [[Double]] = (0..<specs.count).map { _ in [] }
    for _ in 0..<opts.iters {
        let (wall, gb) = runStreams(specs, concurrent: concurrent, maxConcurrent: cap)
        walls.append(wall)
        for i in 0..<specs.count { perStream[i].append(gb[i]) }
    }
    walls.sort()
    let totalBytes = Double(bytes * rounds * specs.count)
    let medianWall = walls[walls.count / 2]
    var streamRows: [[String: Any]] = []
    for (i, s) in specs.enumerated() {
        let xs = perStream[i].sorted(), m = xs[xs.count / 2]
        streamRows.append([
            "consumerIdx": opts.devices[s.c], "producerIdx": opts.devices[s.p],
            "consumerModule": moduleOf(opts.devices[s.c]), "producerModule": moduleOf(opts.devices[s.p]),
            "crossModule": moduleOf(opts.devices[s.c]) != moduleOf(opts.devices[s.p]),
            "gbps": (m * 10).rounded() / 10,
        ])
        if !wantJSON {
            print(String(format: "  dev%@→dev%@ [%@→%@] %7.1f GB/s",
                         "\(opts.devices[s.c])", "\(opts.devices[s.p])",
                         moduleOf(opts.devices[s.c]), moduleOf(opts.devices[s.p]), m))
        }
    }
    let aggregate = totalBytes / (medianWall / 1e3) / 1e9
    phaseReports.append([
        "phase": name, "streams": specs.count, "concurrent": concurrent,
        "maxConcurrent": cap,
        "medianWallMs": (medianWall * 10).rounded() / 10,
        "aggregateGbps": (aggregate * 10).rounded() / 10,
        "perStream": streamRows,
    ])
    if !wantJSON {
        print(String(format: "  == phase %@: %d stream(s), wall %.1f ms, aggregate %.1f GB/s\n",
                     name, specs.count, medianWall, aggregate))
    }
}

var allSpecs: [Spec] = []
for c in 0..<n { for p in 0..<n where p != c { allSpecs.append(Spec(c: c, p: p)) } }
let sameSpecs = allSpecs.filter { moduleOf(opts.devices[$0.c]) == moduleOf(opts.devices[$0.p]) }
let crossSpecs = allSpecs.filter { moduleOf(opts.devices[$0.c]) != moduleOf(opts.devices[$0.p]) }

// Concurrency-controlled cross-card subsets. Same stream COUNT as the B
// control, so if B totals ~2x these, the cross-card aggregate is a physical
// medium limit (or a count-independent penalty), not merely a side effect
// of running more streams at once.
var cross1Pair: [Spec] = []   // 2 streams: moduleA[0] <-> moduleB[0]
if n >= 2 && opts.moduleA.count >= 1 && opts.moduleB.count >= 1 {
    let a = opts.devices.firstIndex(of: opts.moduleA[0])!, b = opts.devices.firstIndex(of: opts.moduleB[0])!
    cross1Pair = [Spec(c: a, p: b), Spec(c: b, p: a)]
}
var cross2Pairs: [Spec] = []  // 4 streams: two disjoint cross-card pairs
if opts.moduleA.count >= 2 && opts.moduleB.count >= 2 {
    let a = opts.moduleA.map { opts.devices.firstIndex(of: $0)! }
    let b = opts.moduleB.map { opts.devices.firstIndex(of: $0)! }
    cross2Pairs = [Spec(c: a[0], p: b[0]), Spec(c: b[0], p: a[0]),
                   Spec(c: a[1], p: b[1]), Spec(c: b[1], p: a[1])]
}

// Fixed cross-card ordering interleaving both directions and both module
// pairs, so every N-prefix is balanced: per producer fan-in <= 2 for N <= 7
// (<= 3 at N = 8) — under the 4-consumer driver hang limit. First 8 = all
// cross streams (= phase C).
var crossOrdered: [Spec] = []
if opts.moduleA.count == 2 && opts.moduleB.count == 2 {
    let a = opts.moduleA.map { opts.devices.firstIndex(of: $0)! }
    let b = opts.moduleB.map { opts.devices.firstIndex(of: $0)! }
    crossOrdered = [
        Spec(c: a[0], p: b[0]), Spec(c: b[0], p: a[0]),
        Spec(c: a[1], p: b[1]), Spec(c: b[1], p: a[1]),
        Spec(c: a[0], p: b[1]), Spec(c: b[1], p: a[0]),
        Spec(c: a[1], p: b[0]), Spec(c: b[0], p: a[1]),
    ]
}

progress("phase A: isolated (one stream at a time)")
phase("A_isolated", allSpecs, concurrent: false)
progress("phase B: same-module pairs simultaneous (control)")
phase("B_jumper_control", sameSpecs, concurrent: true)
progress("phase B2: ONE cross-card pair, both directions (2 streams)")
phase("B2_crosscard_2streams", cross1Pair, concurrent: true)
progress("phase B3: TWO cross-card pairs, both directions (4 streams)")
phase("B3_crosscard_4streams", cross2Pairs, concurrent: true)
progress("phase C: cross-card streams simultaneous")
phase("C_cross_card", crossSpecs, concurrent: true)
// Ceiling discrimination (engine-agnostic where specs allow):
if !crossOrdered.isEmpty {
    for k in [3, 5, 6] {
        progress("phase E: cross-card sweep, \(k) streams")
        phase("E_cross_\(k)streams", Array(crossOrdered.prefix(k)), concurrent: true)
    }
    progress("phase E8cap4: 8 cross-card streams, semaphore cap 4")
    phase("E8_cross_8streams_cap4", Array(crossOrdered.prefix(8)), concurrent: true, maxConcurrent: 4)
}
progress("phase D: full all-to-all simultaneous")
phase("D_all_to_all", allSpecs, concurrent: true)

if wantJSON {
    let report: [String: Any] = [
        "tool": "a2a-bw", "version": 2,
        "engine": opts.engine, "maxConcurrentDefault": opts.maxConcurrent,
        "devices": opts.devices.map { ["index": $0, "name": allDevices[$0].name,
                                       "module": moduleOf($0)] as [String: Any] },
        "peerGroupIDHex": String(format: "0x%016llx", peerGroup),
        "bytesPerStream": bytes, "roundsPerStream": rounds, "iterations": opts.iters,
        "phases": phaseReports,
    ]
    let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
