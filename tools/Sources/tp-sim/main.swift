// tp-sim — simulate & measure llama.cpp/toshllm-style Metal tensor-parallel
// decode communication across a group of peer GPUs (e.g. the four dies of
// 2× W6800X Duo joined by an Infinity Fabric Link bridge).
//
// What it replicates (docs/benchmarks/ has the toshllm review): llama.cpp
// Metal tensor parallelism performs, per layer, 2 all-reduces (attention
// out-proj, FFN down-proj). Each all-reduce = every device PULLS each
// peer's fp32 partial tensor (destination-side, via Metal peer-group remote
// buffer views — toshllm's ggml_metal_cpy_xdev_peer()) into its own VRAM,
// then sums locally. Two synchronization styles are measured:
//   event : MTLSharedEvent chains, GPU-side waits (toshllm style) — the CPU
//           commits a whole token of work and is off the critical path; all
//           ranks' pulls run CONCURRENTLY.
//   chain : same event machinery, but each reduce chains the pull phase
//           across ranks (rank r waits for rank r-1's reduce to finish).
//           Measured on this driver: concurrent 4-way pulls cost ~500 us of
//           serialization per remote op, so sequential pulls win ~7x.
//   cpu   : every phase is committed and CPU-waited (upper bound; what a
//           naive implementation without events pays per reduce).
// Command buffers are encoded+committed per reduce (many uncommitted
// remote-view CBs wedge this driver), so the timed region per token covers
// encode + commit + GPU completion — the wall time a decode step actually
// pays for its communication. Reported: µs/token, µs/reduce,
// bytes/token/device, and the implied tokens/s communication ceiling
// (model compute time is NOT included).

import Foundation
import Metal

// MARK: - Arguments

var opts = (
    devices: [1, 2, 3, 4],
    hidden: 8192,            // fp32 elements per reduced tensor
    layers: 80,
    reduces: 2,              // all-reduces per layer
    tokens: 8,
    sync: "both",            // cpu | event | chain | both
    pull: "blit"             // blit | kernel | fused
)
var wantJSON = false
func printUsage() {
    print("""
    usage: tp-sim [options]

    Simulates llama.cpp Metal tensor-parallel decode all-reduces over
    peer-group remote buffer views (destination-side pulls + local sum),
    synchronized GPU-side with MTLSharedEvents (toshllm style) or with CPU
    barriers, and reports the communication cost per token. Model compute
    is NOT simulated; results are the communication-only bound.

      --devices 1,2,3,4   Metal device indices forming the TP group
                          (default 1,2,3,4; all must share one peer group)
      --hidden N          fp32 elements per all-reduced tensor (default
                          8192 = 70B hidden dim; 2048/4096 ≈ 7B/13B)
      --hidden-bytes N    same as --hidden but given in bytes (fp32)
      --layers L          layers per token (default 80)
      --reduces R         all-reduces per layer (default 2)
      --tokens T          timed tokens (default 8, plus one warmup token)
      --sync cpu|event|chain|both   synchronization style to measure
                          (default both = event, chain, cpu)
      --pull blit|kernel|fused
                          how the peer partials cross the fabric:
                          blit   = copy-engine pull into local VRAM,
                                   then sum (toshllm pattern, default)
                          kernel = compute-unit pull into local VRAM,
                                   then sum
                          fused  = one kernel reads the remote views
                                   directly and writes the sum (no local
                                   copy)
      --json              machine-readable output
    """)
}
func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("tp-sim: \(msg)\n".utf8)); exit(2)
}
let args = CommandLine.arguments
var ai = 1
while ai < args.count {
    switch args[ai] {
    case "--devices": ai += 1; guard ai < args.count else { break }
        opts.devices = args[ai].split(separator: ",").compactMap { Int($0) }
    case "--hidden":  ai += 1; guard ai < args.count else { break }; opts.hidden  = Int(args[ai]) ?? opts.hidden
    case "--hidden-bytes": ai += 1; guard ai < args.count else { break }
        if let b = Int(args[ai]) { opts.hidden = max(1, b / 4) }
    case "--layers":  ai += 1; guard ai < args.count else { break }; opts.layers  = Int(args[ai]) ?? opts.layers
    case "--reduces": ai += 1; guard ai < args.count else { break }; opts.reduces = Int(args[ai]) ?? opts.reduces
    case "--tokens":  ai += 1; guard ai < args.count else { break }; opts.tokens  = Int(args[ai]) ?? opts.tokens
    case "--sync":    ai += 1; guard ai < args.count else { break }; opts.sync    = args[ai]
    case "--pull":    ai += 1; guard ai < args.count else { break }; opts.pull    = args[ai]
    case "--json":    wantJSON = true
    case "-h", "--help": printUsage(); exit(0)
    default: die("unknown argument \(args[ai]) (see --help)")
    }
    ai += 1
}
guard ["cpu", "event", "chain", "both"].contains(opts.sync) else { die("--sync must be cpu|event|chain|both") }
guard ["blit", "kernel", "fused"].contains(opts.pull) else { die("--pull must be blit|kernel|fused") }
guard opts.hidden % 4 == 0 else { die("--hidden must be a multiple of 4 (16-byte pull slots)") }

// MARK: - Metal setup

let allDevices = MTLCopyAllDevices()
guard opts.devices.count >= 2, opts.devices.count <= 4,
      opts.devices.allSatisfy({ $0 < allDevices.count })
else { die("--devices must list 2..4 valid Metal device indices") }
let groupIDs = Set(opts.devices.map { allDevices[$0].peerGroupID })
guard groupIDs.count == 1, let peerGroup = groupIDs.first, peerGroup != 0
else { die("all --devices must share one non-zero peerGroupID (got \(groupIDs.sorted().map { String($0, radix: 16) }))") }

/// `newRemoteBufferViewForDevice:` is public in the SDK but imported
/// awkwardly; call through the selector (pattern proven in if-bench).
/// One leaked +1 per view (a handful per run — acceptable).
func remoteBufferView(_ buffer: MTLBuffer, on device: MTLDevice) -> MTLBuffer? {
    let sel = Selector(("newRemoteBufferViewForDevice:"))
    guard buffer.responds(to: sel),
          let raw = buffer.perform(sel, with: device),
          let view = raw.takeUnretainedValue() as? MTLBuffer
    else { return nil }
    return view
}

let kernelSource = """
#include <metal_stdlib>
using namespace metal;
// Emulates the local "compute" that produces this rank's partial tensor.
kernel void produce(device float *out [[buffer(0)]],
                    constant float &value [[buffer(1)]],
                    constant uint &n [[buffer(2)]],
                    uint idx [[thread_position_in_grid]]) {
    if (idx < n) out[idx] = value;
}
// Pulls of peer partials across the fabric run as blit copies, compute
// copies, or are fused into the sum (see --pull). sumN runs locally.
kernel void sumN(device const float *own [[buffer(0)]],
                 device const float *pulls [[buffer(1)]],
                 device float *out [[buffer(2)]],
                 constant uint &np [[buffer(3)]],
                 constant uint &n [[buffer(4)]],
                 uint idx [[thread_position_in_grid]]) {
    if (idx < n) {
        float s = own[idx];
        for (uint k = 0; k < np; ++k) s += pulls[k * n + idx];
        out[idx] = s;
    }
}
// Compute-engine pull of one remote view. IMPORTANT (2026-09-12): do NOT
// use 16-byte but 4-byte-aligned vector types (uchar4) for remote-view
// loads — they are served from a non-snooped cache and return STALE data at
// fake "local speed" rates, even after the producer rewrote the source.
// Naturally aligned types (uint, uint4, ulong2, float) are coherent
// (remote-view-check tool + docs/metal/gotchas.md). 4-byte scalar is used
// here because decode-size tensors are latency-bound anyway. Grid must be
// dispatched at exactly bytes/4 threads (no bounds constant: on this driver
// the constant binding misbehaves across a pipeline-switch loop).
kernel void pullCopy(const device uint *src [[buffer(0)]],
                     device uint *dst [[buffer(1)]],
                     uint idx [[thread_position_in_grid]]) {
    dst[idx] = src[idx];
}
// Fused reduce: reads the remote views directly (read-only) and writes
// only the sum — skips the local VRAM copy entirely.
kernel void fusedSum(device const float *own [[buffer(0)]],
                     device const float *v0 [[buffer(1)]],
                     device const float *v1 [[buffer(2)]],
                     device const float *v2 [[buffer(3)]],
                     device float *out [[buffer(4)]],
                     constant uint &np [[buffer(5)]],
                     constant uint &n [[buffer(6)]],
                     uint idx [[thread_position_in_grid]]) {
    if (idx < n) {
        float s = own[idx] + v0[idx];
        if (np > 1) s += v1[idx];
        if (np > 2) s += v2[idx];
        out[idx] = s;
    }
}
"""

final class RankCtx {
    let index: Int          // Metal device index
    let rank: Int           // position in TP group
    let device: MTLDevice
    let queue: MTLCommandQueue
    let producePL: MTLComputePipelineState
    let sumPL: MTLComputePipelineState
    let pullPL: MTLComputePipelineState
    let fusedPL: MTLComputePipelineState
    let partial: MTLBuffer      // this rank's partial tensor (private VRAM)
    let pulls: MTLBuffer        // peerCount slots of hidden floats
    let sumOut: MTLBuffer       // private VRAM (verify copies out to shared)
    var views: [MTLBuffer] = [] // remote views of peers' partials (peer order)

    init?(metalIndex: Int, rank: Int, bytes: Int, peerCount: Int) {
        let dev = allDevices[metalIndex]
        guard let q = dev.makeCommandQueue(),
              let lib = try? dev.makeLibrary(source: kernelSource, options: nil),
              let pf = lib.makeFunction(name: "produce"),
              let sf = lib.makeFunction(name: "sumN"),
              let pp = try? dev.makeComputePipelineState(function: pf),
              let sp = try? dev.makeComputePipelineState(function: sf),
              let cf = lib.makeFunction(name: "pullCopy"),
              let cp = try? dev.makeComputePipelineState(function: cf),
              let fsf = lib.makeFunction(name: "fusedSum"),
              let fp = try? dev.makeComputePipelineState(function: fsf),
              let partial = dev.makeBuffer(length: bytes, options: .storageModePrivate),
              let pulls = dev.makeBuffer(length: bytes * peerCount, options: .storageModePrivate),
              let sumOut = dev.makeBuffer(length: bytes, options: .storageModePrivate)
        else { return nil }
        self.index = metalIndex; self.rank = rank
        self.device = dev; self.queue = q
        self.producePL = pp; self.sumPL = sp
        self.pullPL = cp; self.fusedPL = fp
        self.partial = partial; self.pulls = pulls; self.sumOut = sumOut
    }

    func grid(_ pl: MTLComputePipelineState, encoder: MTLComputeCommandEncoder, count: Int) {
        let perGroup = pl.maxTotalThreadsPerThreadgroup
        let groups = ((count + perGroup - 1) / perGroup) * perGroup
        encoder.dispatchThreads(MTLSize(width: groups, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: perGroup, height: 1, depth: 1))
    }
}

let tensorBytes = opts.hidden * 4
let peerCount = opts.devices.count - 1
var ranks: [RankCtx] = []
for (slot, devIdx) in opts.devices.enumerated() {
    guard let rc = RankCtx(metalIndex: devIdx, rank: slot, bytes: tensorBytes, peerCount: peerCount)
    else { die("failed to set up rank context on device \(devIdx)") }
    ranks.append(rc)
}
func peerOrder(of selfRank: Int) -> [Int] { (0..<ranks.count).filter { $0 != selfRank } }

// Remote views of each peer's partial buffer (read-only on the consumer).
for r in 0..<ranks.count {
    for p in peerOrder(of: r) {
        guard let v = remoteBufferView(ranks[p].partial, on: ranks[r].device)
        else { die("nil remote view of rank \(p) partial on rank \(r)") }
        ranks[r].views.append(v)
    }
}

// One shared event per writer rank; value = global reduce index, monotonic
// across tokens and shared by all ranks (same reduce -> same value).
var events: [MTLSharedEvent] = []
for rc in ranks {
    guard let e = rc.device.makeSharedEvent() else { die("makeSharedEvent failed on device \(rc.index)") }
    events.append(e)
}
// Second event set: "rank r's reduce u is done" (used by chain mode).
var reduceDone: [MTLSharedEvent] = []
for rc in ranks {
    guard let e = rc.device.makeSharedEvent() else { die("makeSharedEvent failed on device \(rc.index)") }
    reduceDone.append(e)
}

// MARK: - Command buffer construction (all pre-encoded; timed region
// covers commit + completion only)

func encodeProduceCB(_ rc: RankCtx) -> MTLCommandBuffer? {
    guard let cb = rc.queue.makeCommandBuffer(),
          let enc = cb.makeComputeCommandEncoder() else { return nil }
    enc.setComputePipelineState(rc.producePL)
    enc.setBuffer(rc.partial, offset: 0, index: 0)
    var value = Float(rc.rank + 1)
    var n = UInt32(opts.hidden)
    withUnsafeBytes(of: value) { enc.setBytes($0.baseAddress!, length: 4, index: 1) }
    withUnsafeBytes(of: n) { enc.setBytes($0.baseAddress!, length: 4, index: 2) }
    rc.grid(rc.producePL, encoder: enc, count: opts.hidden)
    enc.endEncoding()
    return cb
}

/// One all-reduce for one rank. When `eventSync`, waits on every peer's
/// produce event for `reduceSeq`; when `chainWait >= 0`, additionally waits
/// on that rank's reduce-done event (serializes the pull phase across
/// ranks); when `signalDone`, signals this rank's reduce-done event.
/// (Produce+its signal live in their own CB so peers see data early.)
func encodeReduceCB(_ rc: RankCtx, eventSync: Bool, chainWait: Int, signalDone: Bool,
                    reduceSeq: UInt64) -> MTLCommandBuffer? {
    guard let cb = rc.queue.makeCommandBuffer() else { return nil }
    if eventSync {
        for p in peerOrder(of: rc.rank) {
            cb.encodeWaitForEvent(events[p], value: reduceSeq)
        }
        if chainWait >= 0 {
            cb.encodeWaitForEvent(reduceDone[chainWait], value: reduceSeq)
        }
    }
    // Pull each peer partial into local VRAM (remote views are read-only,
    // so the pull direction is mandatory).
    if opts.pull == "fused" {
        // Single kernel: reads remote views directly, writes the sum.
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(rc.fusedPL)
            enc.setBuffer(rc.partial, offset: 0, index: 0)
            enc.setBuffer(rc.views[0], offset: 0, index: 1)
            enc.setBuffer(peerCount > 1 ? rc.views[1] : rc.partial, offset: 0, index: 2)
            enc.setBuffer(peerCount > 2 ? rc.views[2] : rc.partial, offset: 0, index: 3)
            enc.setBuffer(rc.sumOut, offset: 0, index: 4)
            let np = UInt32(peerCount)
            let n = UInt32(opts.hidden)
            withUnsafeBytes(of: np) { enc.setBytes($0.baseAddress!, length: 4, index: 5) }
            withUnsafeBytes(of: n) { enc.setBytes($0.baseAddress!, length: 4, index: 6) }
            rc.grid(rc.fusedPL, encoder: enc, count: opts.hidden)
            enc.endEncoding()
        }
        if signalDone {
            cb.encodeSignalEvent(reduceDone[rc.rank], value: reduceSeq)
        }
        return cb
    }
    if opts.pull == "kernel" {
        let n4 = tensorBytes / 4
        for slot in 0..<peerCount {
            guard let enc = cb.makeComputeCommandEncoder() else { break }
            enc.setComputePipelineState(rc.pullPL)
            enc.setBuffer(rc.views[slot], offset: 0, index: 0)
            enc.setBuffer(rc.pulls, offset: tensorBytes * slot, index: 1)
            enc.dispatchThreads(MTLSize(width: n4, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            enc.endEncoding()
        }
    } else if let enc = cb.makeBlitCommandEncoder() {
        for slot in 0..<peerCount {
            enc.copy(from: rc.views[slot], sourceOffset: 0,
                     to: rc.pulls, destinationOffset: tensorBytes * slot,
                     size: tensorBytes)
        }
        enc.endEncoding()
    }
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(rc.sumPL)
        enc.setBuffer(rc.partial, offset: 0, index: 0)
        enc.setBuffer(rc.pulls, offset: 0, index: 1)
        enc.setBuffer(rc.sumOut, offset: 0, index: 2)
        let np = UInt32(peerCount)
        let n = UInt32(opts.hidden)
        withUnsafeBytes(of: np) { enc.setBytes($0.baseAddress!, length: 4, index: 3) }
        withUnsafeBytes(of: n) { enc.setBytes($0.baseAddress!, length: 4, index: 4) }
        rc.grid(rc.sumPL, encoder: enc, count: opts.hidden)
        enc.endEncoding()
    }
    if signalDone {
        cb.encodeSignalEvent(reduceDone[rc.rank], value: reduceSeq)
    }
    return cb
}

// MARK: - Correctness gate (event path): produce writes rank+1, sum must
// equal Σ(1…N) on every rank. Catches event paths that "work" but do not
// actually make peer writes visible.

var notes: [String] = []
var verifyPassed = false
// Single monotonically increasing signal-value source shared by the gate and
// all event-chained runs (event values must never go backwards).
var seqCounter: UInt64 = 0

func correctnessGate() {
    seqCounter += 1
    let seq = seqCounter  // far ahead of the timed run's counter
    var cbs: [MTLCommandBuffer] = []
    for rc in ranks {
        guard let produce = encodeProduceCB(rc),
              let reduce = encodeReduceCB(rc, eventSync: true, chainWait: -1, signalDone: false, reduceSeq: seq)
        else { return }
        // NB: encodeWait values must be <= what we signal; signal here at CB
        // level on the produce CB.
        produce.encodeSignalEvent(events[rc.rank], value: seq)
        cbs.append(produce); cbs.append(reduce)
    }
    // Produce CBs must commit before reduce CBs see the signal; events make
    // the GPU-side order legal, commit order only matters for not-deadlock:
    for rc in ranks { cbs[rc.rank * 2].commit() }
    for rc in ranks { cbs[rc.rank * 2 + 1].commit() }
    for cb in cbs { cb.waitUntilCompleted() }
    let expect = Float((1...ranks.count).reduce(0, +))
    var observed: [String] = []
    for rc in ranks {
        guard let shared = rc.device.makeBuffer(length: tensorBytes, options: .storageModeShared),
              let cb = rc.queue.makeCommandBuffer(),
              let enc = cb.makeBlitCommandEncoder()
        else { return }
        enc.copy(from: rc.sumOut, sourceOffset: 0, to: shared, destinationOffset: 0, size: tensorBytes)
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let p = shared.contents().bindMemory(to: Float.self, capacity: opts.hidden)
        var ok = true
        for k in stride(from: 0, to: opts.hidden, by: 251) where p[k] != expect { ok = false; break }
        if !ok { observed.append("rank\(rc.rank) saw \(p[0])/\(p[opts.hidden / 2])/\(p[opts.hidden - 1])") }
    }
    if observed.isEmpty { verifyPassed = true }
    else { notes.append("gate observed (expect \(expect)): \(observed.joined(separator: "; "))") }
}

// MARK: - Runs

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2]
}
func progress(_ line: String) {
    FileHandle.standardError.write(Data("tp-sim: \(line)\n".utf8))
}

let reducesPerToken = opts.layers * opts.reduces
let bytesPerTokenPerDevice = Double(reducesPerToken * peerCount * tensorBytes)

/// Event/chain sync: encode+commit per reduce (a real engine's cadence —
/// many uncommitted remote-view CBs wedge this driver, so in-flight depth
/// stays at 2 CBs per rank), then ONE CPU wait for the whole token at the
/// end. With `chain`, the pull phase is additionally serialized across
/// ranks via reduceDone events. Timed region: encode + commit + GPU
/// completion (what a decode step actually pays per token).
func runEventSync(tokens: Int, chain: Bool) -> [Double]? {
    progress("running \(tokens) tokens × \(reducesPerToken) reduces × \(ranks.count) ranks (\(chain ? "chain" : "event"))")
    var perToken: [Double] = []
    for t in 0..<tokens {
        let start = DispatchTime.now().uptimeNanoseconds
        var last: [MTLCommandBuffer] = []
        for _ in 0..<reducesPerToken {
            seqCounter += 1
            let v = seqCounter
            for rc in ranks {
                guard let produce = encodeProduceCB(rc) else { return nil }
                produce.encodeSignalEvent(events[rc.rank], value: v)
                produce.commit()
            }
            for rc in ranks {
                let chainWait = chain ? rc.rank - 1 : -1
                guard let reduce = encodeReduceCB(rc, eventSync: true, chainWait: chainWait,
                                                 signalDone: chain, reduceSeq: v) else { return nil }
                reduce.commit()
                last.append(reduce)
            }
        }
        // Queue order means each rank's last reduce CB implies all its
        // earlier CBs completed; waiting the 4 tails covers the token.
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            for cb in last { cb.waitUntilCompleted() }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 60) == .timedOut { return nil }
        let us = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000.0
        if t >= 1 { perToken.append(us) }
    }
    return perToken
}

/// CPU sync: per reduce, encode+commit the produce CBs on every rank and
/// CPU-barrier, then encode+commit the reduce CBs and CPU-barrier (what a
/// naive implementation without events pays: two CPU round-trips per
/// reduce). Timed region per token = encode + commit + waits.
func runCPUSync(tokens: Int) -> [Double]? {
    progress("running \(tokens) tokens × \(reducesPerToken) reduces × \(ranks.count) ranks (cpu)")
    var perToken: [Double] = []
    for t in 0..<tokens {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<reducesPerToken {
            var cbs: [MTLCommandBuffer] = []
            for rc in ranks {
                guard let produce = encodeProduceCB(rc) else { return nil }
                produce.commit(); cbs.append(produce)
            }
            for cb in cbs { cb.waitUntilCompleted() }
            cbs.removeAll(keepingCapacity: true)
            for rc in ranks {
                guard let reduce = encodeReduceCB(rc, eventSync: false, chainWait: -1, signalDone: false, reduceSeq: 0) else { return nil }
                reduce.commit(); cbs.append(reduce)
            }
            for cb in cbs { cb.waitUntilCompleted() }
        }
        let us = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000.0
        if t >= 1 { perToken.append(us) }
    }
    return perToken
}

var results: [[String: Any]] = []
func record(_ mode: String, perToken: [Double]) {
    let med = median(perToken)
    guard med > 0 else { return }
    let usPerReduce = med / Double(reducesPerToken)
    let gbps = bytesPerTokenPerDevice / (med / 1e6) / 1e9
    results.append([
        "kind": "tp-sim", "sync": mode, "pull": opts.pull, "hidden": opts.hidden,
        "layers": opts.layers, "reducesPerLayer": opts.reduces,
        "medianUsPerToken": (med * 100).rounded() / 100,
        "usPerReduce": (usPerReduce * 100).rounded() / 100,
        "bytesPerTokenPerDevice": Int(bytesPerTokenPerDevice),
        "gbytesPerSecond": (gbps * 100).rounded() / 100,
        "commBoundTokensPerSecond": ((1e6 / med) * 10).rounded() / 10,
        "samples": perToken.count,
    ])
}

if opts.sync != "cpu" {
    progress("correctness gate (event-chained all-reduce, verifiable values)")
    correctnessGate()
    if !verifyPassed {
        notes.append("event-sync correctness gate FAILED: event-chained pulls did not observe peers' produces (sums wrong) — event/chain modes skipped")
    }
}
if opts.sync == "event" || opts.sync == "both", verifyPassed {
    if let s = runEventSync(tokens: opts.tokens + 1, chain: false) {
        record("event", perToken: s)
    } else {
        notes.append("event-sync run stalled >30 s (possible driver event issue): event mode skipped")
    }
}
if opts.sync == "chain" || opts.sync == "both", verifyPassed {
    if let s = runEventSync(tokens: opts.tokens + 1, chain: true) {
        record("chain", perToken: s)
    } else {
        notes.append("chain run stalled >30 s: chain mode skipped")
    }
}
if opts.sync != "event" {
    if let s = runCPUSync(tokens: opts.tokens + 1) { record("cpu", perToken: s) }
}

// MARK: - Report

if wantJSON {
    let report: [String: Any] = [
        "tool": "tp-sim", "version": 2,
        "devices": zip(opts.devices, ranks).map { [
            "index": $0.0, "name": allDevices[$0.0].name,
            "peerGroupIDHex": String(format: "0x%016llx", peerGroup),
        ] as [String: Any] },
        "options": ["hidden": opts.hidden, "layers": opts.layers,
                    "reducesPerLayer": opts.reduces, "tokens": opts.tokens,
                    "sync": opts.sync, "pull": opts.pull],
        "verifyPassed": verifyPassed,
        "results": results, "notes": notes,
    ]
    let data = try! JSONSerialization.data(withJSONObject: report,
                                           options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} else {
    print("== tp-sim (llama.cpp-style TP decode all-reduce simulation) ==")
    print("note: communication only; model compute time NOT included")
    for n in notes { print("note: \(n)") }
    print("verify(event pulls observe peer data): \(verifyPassed ? "PASS" : "FAIL/skipped")")
    for r in results {
        print(String(format: "%-5@ hidden=%-6@ %@ µs/token  %@ µs/reduce  %@ B/token/dev  %@ GB/s  comm-ceiling %@ tok/s",
                     r["sync"] as? String ?? "?",
                     "\(r["hidden"] ?? "?")",
                     String(format: "%.0f", r["medianUsPerToken"] as? Double ?? 0),
                     String(format: "%.2f", r["usPerReduce"] as? Double ?? 0),
                     "\(r["bytesPerTokenPerDevice"] ?? "?")",
                     String(format: "%.2f", r["gbytesPerSecond"] as? Double ?? 0),
                     String(format: "%.1f", r["commBoundTokensPerSecond"] as? Double ?? 0)))
    }
}
