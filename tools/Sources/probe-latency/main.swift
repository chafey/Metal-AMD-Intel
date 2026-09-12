// probe-latency v2: per-op cost breakdown for a host-RAM relay all-reduce
// (GPU writes own partial to its host buffer + signals an event -> CPU
// observes event cheaply, clflush-invalidates, reads/sums, writes each
// consumer's host buffer + clflush + CPU event signal -> consumer GPU
// (already waiting on that event) copies host->priv and signals done).
// Incumbent: direct remote-view pull (tp-sim naive ~600 us/reduce, 32 KiB).
//
// v1 findings baked into this design (MacPro7,1 + AMD MPX, 2026-09-12):
//  - GPU DMA -> CPU reads: flag was seen by CPU spin, but payload read
//    immediately after the flag was STALE in 60/60 iters (GPU-side posted
//    writes not release-ordered vs the flag) -> use CB event signaling,
//    which implies full memory flush, + invalidate CPU lines before reading.
//  - CPU stores -> GPU spin: 9.6 ms (GPU waited for natural eviction of
//    the dirty CPU cache line) -> CPU must clflush its staging lines.
//
// Probes:
//   P1  trivial CB: commit->waitUntilCompleted wall (driver floor)
//   P2  GPU->host: [parallel copy 32 KiB priv->shared] + event; CPU polls
//       signaledValue; verify payload fresh after invalidate
//   P3  host->GPU: consumer CB pre-committed waiting on CPU-signaled event,
//       copies shared->priv, signals done; measures signal->done-observed
//       (the CPU->GPU coherence fix) + clflush cost separately
//   P4  full relay e2e for ONE producer->ONE consumer hop (cross-card)
//   P5  remote-view read of 4 KiB/32 KiB/1 MiB (streaming copy kernel):
//       wall + GPU busy; the incumbent path
import Metal
import Foundation
import CFast

func die(_ s: String) -> Never { FileHandle.standardError.write("probe-latency: \(s)\n".data(using: .utf8)!); exit(1) }
setbuf(stdout, nil)

var devIdx = 1, remoteIdx = 3, iters = 100, sizeKiB = 32
var relay4 = false, crossbuf = false, crossview = false, noclinv = false
let argv = CommandLine.arguments
var i = 1
func intArg(_ s: String) -> Int { guard let v = Int(s) else { die("needs int, got \(s)") }; return v }
while i < argv.count {
    switch argv[i] {
    case "--device":  i += 1; guard i < argv.count else { die("--device needs int") }; devIdx = intArg(argv[i])
    case "--remote":  i += 1; guard i < argv.count else { die("--remote needs int") }; remoteIdx = intArg(argv[i])
    case "--iters":   i += 1; guard i < argv.count else { die("--iters needs int") }; iters = intArg(argv[i])
    case "--size-kib": i += 1; guard i < argv.count else { die("--size-kib needs int") }; sizeKiB = intArg(argv[i])
    case "--relay4": relay4 = true
    case "--crossbuf": crossbuf = true
    case "--crossview": crossview = true
    case "--noclinv": noclinv = true
    default: die("unknown argument \(argv[i]) (bare '--' args are not accepted)")
    }
    i += 1
}

let devs = MTLCopyAllDevices()
guard devIdx < devs.count, remoteIdx < devs.count else { die("bad device index") }
let D = devs[devIdx]
let C = devs[remoteIdx]
print("D=\(devIdx) \(D.name)  remote=\(remoteIdx) \(C.name)  iters=\(iters)")
func remoteView(_ b: MTLBuffer, on d: MTLDevice) -> MTLBuffer? {
    let sel = Selector(("newRemoteBufferViewForDevice:"))
    guard b.responds(to: sel), let raw = b.perform(sel, with: d),
          let v = raw.takeUnretainedValue() as? MTLBuffer else { return nil }
    return v
}

let src = """
#include <metal_stdlib>
using namespace metal;
kernel void trivial(device float *out [[buffer(0)]]) { out[0] = 1.0f; }
kernel void fcopy(device const float *s [[buffer(0)]],
                  device float *d [[buffer(1)]],
                  constant uint &n [[buffer(2)]],
                  uint idx [[thread_position_in_grid]]) {
    if (idx < n) d[idx] = s[idx];
}
"""
let lib = try! D.makeLibrary(source: src, options: nil)
let libC = try! C.makeLibrary(source: src, options: nil)
func pl(_ name: String, on dev: MTLDevice) -> MTLComputePipelineState {
    let l = dev === D ? lib : libC
    return try! dev.makeComputePipelineState(function: l.makeFunction(name: name)!)
}
let qD = D.makeCommandQueue()!, qC = C.makeCommandQueue()!
var psCache: [Int: [String: MTLComputePipelineState]] = [:]
func psc(_ name: String, on dev: MTLDevice) -> MTLComputePipelineState {
    let key = Int(dev.registryID)
    if let p = psCache[key]?[name] { return p }
    let p = pl(name, on: dev)
    psCache[key, default: [:]][name] = p
    return p
}
let N: UInt32 = UInt32(sizeKiB * 256)           // fp32 elements
guard let privD = D.makeBuffer(length: 4 << 20, options: .storageModePrivate),
      let privC = C.makeBuffer(length: 4 << 20, options: .storageModePrivate),
      let shD = D.makeBuffer(length: 4 << 20, options: .storageModeShared),
      let shC = C.makeBuffer(length: 4 << 20, options: .storageModeShared)
else { die("alloc failed") }

func copyCB(_ q: MTLCommandQueue, on dev: MTLDevice, from s: MTLBuffer, to d: MTLBuffer,
            n: UInt32, wait: (MTLSharedEvent, UInt64)? = nil,
            signal: (MTLSharedEvent, UInt64)? = nil) -> MTLCommandBuffer {
    let cb = q.makeCommandBuffer()!
    if let (e, v) = wait { cb.encodeWaitForEvent(e, value: v) }
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(psc("fcopy", on: dev))
    enc.setBuffer(s, offset: 0, index: 0)
    enc.setBuffer(d, offset: 0, index: 1)
    withUnsafeBytes(of: n) { enc.setBytes($0.baseAddress!, length: 4, index: 2) }
    enc.dispatchThreads(MTLSize(width: Int(n), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    enc.endEncoding()
    if let (e, v) = signal { cb.encodeSignalEvent(e, value: v) }
    return cb
}
func trivialCB() -> MTLCommandBuffer {
    let cb = qD.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(psc("trivial", on: D))
    enc.setBuffer(privD, offset: 0, index: 0)
    enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    enc.endEncoding()
    return cb
}
func us(_ t0: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1000 }
func busy(_ cb: MTLCommandBuffer) -> Double { cb.gpuEndTime > cb.gpuStartTime ? (cb.gpuEndTime - cb.gpuStartTime) * 1e6 : -1 }
func median(_ xs: [Double]) -> Double { var s = xs; s.sort(); return s[s.count / 2] }
/// CPU spin on an event value; sched_yield forces a fresh property read and
/// bounds damage on failure. Returns after observing v.
func waitEvent(_ e: MTLSharedEvent, _ v: UInt64) {
    let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
    while e.signaledValue < v {
        if DispatchTime.now().uptimeNanoseconds > deadline { die("timeout waiting event value \(v) (have \(e.signaledValue))") }
        sched_yield()
    }
}

// seed privD = 0x41414141 pattern (float 3.0195...) for payload verification
do { let tmp = D.makeBuffer(length: Int(N) * 4, options: .storageModeShared)!
     memset(tmp.contents(), 0x41, Int(N) * 4)
     let cb = qD.makeCommandBuffer()!; let e = cb.makeBlitCommandEncoder()!
     e.copy(from: tmp, sourceOffset: 0, to: privD, destinationOffset: 0, size: Int(N) * 4)
     e.endEncoding(); cb.commit(); cb.waitUntilCompleted() }

// ---- P6 / --relay4: full 4-rank host-relay all-reduce loop ---------------
if relay4 {
    let ranks = [devIdx, 2, 3, remoteIdx].sorted()
    guard Set(ranks).count == 4 else { die("--relay4 needs --device and --remote to be the same-module/cross pair endpoints beyond 2,3; got \(ranks)") }
    struct Rk { var dev: MTLDevice; var q: MTLCommandQueue; var qc: MTLCommandQueue
                var priv: MTLBuffer; var outPriv: MTLBuffer; var sh: MTLBuffer
                var ep: MTLSharedEvent; var ec: MTLSharedEvent; var ed: MTLSharedEvent }
    var rk: [Rk] = []
    for d in ranks {
        let dv = devs[d]
        guard let pr = dv.makeBuffer(length: 4 << 20, options: .storageModePrivate),
              let op = dv.makeBuffer(length: 4 << 20, options: .storageModePrivate),
              let sh = dv.makeBuffer(length: 4 << 20, options: .storageModeShared)
        else { die("alloc") }
        // TWO queues per rank: consumer CBs block on events and must not
        // sit on the same queue as the producer CBs (would deadlock).
        // priv = input partial (seeded once), outPriv = consumer landing
        // spot; they must be DISTINCT or iteration it+1 reduces old sums.
        rk.append(Rk(dev: dv, q: dv.makeCommandQueue()!, qc: dv.makeCommandQueue()!,
                     priv: pr, outPriv: op, sh: sh,
                     ep: dv.makeSharedEvent()!, ec: dv.makeSharedEvent()!, ed: dv.makeSharedEvent()!))
    }
    // --crossbuf: ONE broadcast shared buffer (allocated on rank 0) that
    // every consumer GPU reads directly; CPU writes+flushes once instead of
    // per-rank. LEGALITY TEST: Metal forbids encoding a buffer created on
    // device A into a kernel on device B without a remote view — whether
    // this driver tolerates it (all these buffers ARE host RAM) is the
    // question. Run in its own process; validation may abort().
    let bcast: MTLBuffer? = (crossbuf || crossview) ? rk[0].dev.makeBuffer(length: 4 << 20, options: .storageModeShared) : nil
    // --crossview: same broadcast buffer, but each consumer reads a REMOTE
    // VIEW of it on its own device (the legal way to reference a buffer
    // owned by another device).
    var bcastViews: [MTLBuffer] = []
    if crossview, let b = bcast {
        for k in rk {
            guard let v = remoteView(b, on: k.dev) else { die("no remote view of bcast on \(k.dev.name)") }
            bcastViews.append(v)
        }
    }
    // seed priv[r] = float(r+1)
    for (r, k) in rk.enumerated() {
        let tmp = k.dev.makeBuffer(length: Int(N) * 4, options: .storageModeShared)!
        let p = tmp.contents().bindMemory(to: Float.self, capacity: Int(N))
        for j in 0..<Int(N) { p[j] = Float(r + 1) }
        let cb = k.q.makeCommandBuffer()!; let e = cb.makeBlitCommandEncoder()!
        e.copy(from: tmp, sourceOffset: 0, to: k.priv, destinationOffset: 0, size: Int(N) * 4)
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    }
    let expected = Float((1...rk.count).reduce(0, +))   // Σ(r+1)
    var w: [Double] = [], wSum: [Double] = []
    var seq4: UInt64 = 0
    let np = Int(N)
    var sums = [Float](repeating: 0, count: np)
    for it in 0..<iters {
        seq4 += 1
        // consumers first: wait ec, copy host->outPriv, signal done
        var cbsC: [MTLCommandBuffer] = []
        for (r, k) in rk.enumerated() {
            let src = !bcastViews.isEmpty ? bcastViews[r] : (bcast ?? k.sh)
            let cb = copyCB(k.qc, on: k.dev, from: src, to: k.outPriv, n: N, wait: (k.ec, seq4), signal: (k.ed, seq4))
            cb.commit(); cbsC.append(cb)
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        // producers
        for (r, k) in rk.enumerated() {
            let cb = copyCB(k.q, on: k.dev, from: k.priv, to: k.sh, n: N, signal: (k.ep, seq4))
            cb.commit()
        }
        var payPtrs: [UnsafeMutablePointer<Float>] = []
        for (r, k) in rk.enumerated() {
            waitEvent(k.ep, seq4)
            if !noclinv { cfast_clinv_range(k.sh.contents(), np * 4) }
            payPtrs.append(k.sh.contents().bindMemory(to: Float.self, capacity: np))
        }
        let ts0 = DispatchTime.now().uptimeNanoseconds
        for j in 0..<np { sums[j] = payPtrs[0][j] + payPtrs[1][j] + payPtrs[2][j] + payPtrs[3][j] }
        if let b = bcast {
            let dst = b.contents().bindMemory(to: Float.self, capacity: np)
            for j in 0..<np { dst[j] = sums[j] }
            cfast_clflush_range(b.contents(), np * 4)
        } else {
            for (r, k) in rk.enumerated() {
                let dst = payPtrs[r]
                for j in 0..<np { dst[j] = sums[j] }
                cfast_clflush_range(k.sh.contents(), np * 4)
            }
        }
        wSum.append(us(ts0))
        for k in rk { k.ec.signaledValue = seq4 }
        for k in rk { waitEvent(k.ed, seq4) }
        w.append(us(t0))
        if it == iters - 1 { for cb in cbsC { cb.waitUntilCompleted() } }
    }
    print(String(format: "P6 relay4 all-reduce (%d KiB, %d ranks, crossbuf=%d, crossview=%d, noclinv=%d): %.0f us/reduce (med)  [CPU sum+write+flush stage %.0f us]",
                 sizeKiB, rk.count, crossbuf ? 1 : 0, crossview ? 1 : 0, noclinv ? 1 : 0, median(w), median(wSum)))
    // verify last iteration landed everywhere
    var badTotal = 0
    for (r, k) in rk.enumerated() {
        let back = k.dev.makeBuffer(length: np * 4, options: .storageModeShared)!
        let cb = k.q.makeCommandBuffer()!; let e = cb.makeBlitCommandEncoder()!
        e.copy(from: k.outPriv, sourceOffset: 0, to: back, destinationOffset: 0, size: np * 4)
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let p = back.contents().bindMemory(to: Float.self, capacity: np)
        var bad = 0; for j in stride(from: 0, to: np, by: 97) where abs(p[j] - expected) > 0.01 { bad += 1 }
        if bad != 0 { badTotal += 1 }
    }
    print("   P6 relay4 verify (all ranks, expected=\(expected)): \(badTotal == 0 ? "PASS" : "FAIL \(badTotal) ranks")")
    exit(0)
}

// ---- P1: trivial CB floor -----------------------------------------------
var w1: [Double] = []
for _ in 0..<iters {
    let cb = trivialCB()
    let t0 = DispatchTime.now().uptimeNanoseconds
    cb.commit(); cb.waitUntilCompleted()
    w1.append(us(t0))
}
print(String(format: "P1 trivial CB            : commit->completed %.0f us (med)", median(w1)))

// ---- P2: GPU->host with event signal + CPU invalidate --------------------
let ep = D.makeSharedEvent()!
var w2s: [Double] = [], w2c: [Double] = [], bad2 = 0, b2: [Double] = []
var seq: UInt64 = 0
let payD = shD.contents().bindMemory(to: Float.self, capacity: Int(N))
for it in 0..<iters {
    seq += 1
    let cb = copyCB(qD, on: D, from: privD, to: shD, n: N, signal: (ep, seq))
    let t0 = DispatchTime.now().uptimeNanoseconds
    cb.commit()
    waitEvent(ep, seq)
    let tsig = us(t0)
    if !noclinv { cfast_clinv_range(shD.contents(), Int(N) * 4) }   // drop possibly-stale CPU lines
    let v = payD[Int(N) - 1]
    // expected: fill 0x41 -> float bits 0x41414141 = 12.078
    if !(v > 12.0 && v < 12.2) { bad2 += 1 }
    cb.waitUntilCompleted()
    if it % 4 == 0 { b2.append(busy(cb)) }
    w2s.append(tsig); w2c.append(us(t0))
}
print(String(format: "P2 GPU->host + event     : commit->CPU-saw-event %.0f us, commit->completed %.0f us (med)  copy busy %.1f us  stale-payload %d/%d",
              median(w2s), median(w2c), median(b2), bad2, iters))

// ---- P3: host->GPU with clflush + CPU-signaled event ---------------------
let ec = C.makeSharedEvent()!
let ed = C.makeSharedEvent()!
let payC = shC.contents().bindMemory(to: Float.self, capacity: Int(N))
var tFlush: [Double] = [], w3: [Double] = []
seq = 0
for it in 0..<iters {
    seq += 1
    // consumer CB waits on ec, copies host->priv, signals ed; committed FIRST
    let cb = copyCB(qC, on: C, from: shC, to: privC, n: N, wait: (ec, seq), signal: (ed, seq))
    cb.commit()
    // CPU payload write (cached), then flush so the GPU's PCIe reads see it
    let tf0 = DispatchTime.now().uptimeNanoseconds
    for k in 0..<Int(N) { payC[k] = Float(7) }
    cfast_clflush_range(shC.contents(), Int(N) * 4)
    tFlush.append(us(tf0))
    let t0 = DispatchTime.now().uptimeNanoseconds
    ec.signaledValue = seq          // CPU-side signal via readwrite property
    waitEvent(ed, seq)
    w3.append(us(t0))
    if it == iters - 1 { cb.waitUntilCompleted() }
}
print(String(format: "P3 host->GPU clflush fix : CPU-signal->GPU-done %.0f us (med)   [CPU write+clflush of 32 KiB: %.0f us (med)]",
              median(w3), median(tFlush)))
// stale-read check on consumer side: read back privC via blit
do { let back = C.makeBuffer(length: Int(N) * 4, options: .storageModeShared)!
     let cb = qC.makeCommandBuffer()!; let e = cb.makeBlitCommandEncoder()!
     e.copy(from: privC, sourceOffset: 0, to: back, destinationOffset: 0, size: Int(N) * 4)
     e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
     let p = back.contents().bindMemory(to: Float.self, capacity: Int(N))
     var bad = 0; for k in stride(from: 0, to: Int(N), by: 97) where p[k] != 7 { bad += 1 }
     let verdict = bad == 0 ? "PASS" : "FAIL \(bad) slots"
     print("   P3 consumer verify: \(verdict)") }

// ---- P4: full one-hop relay e2e (cross-card unless --remote says same) ---
var w4: [Double] = [], w4p: [Double] = []
seq = 0
for it in 0..<iters {
    seq += 1
    let cbC = copyCB(qC, on: C, from: shC, to: privC, n: N, wait: (ec, seq), signal: (ed, seq))
    cbC.commit()
    let t0 = DispatchTime.now().uptimeNanoseconds
    let cbD = copyCB(qD, on: D, from: privD, to: shD, n: N, signal: (ep, seq))
    cbD.commit()
    waitEvent(ep, seq)
    let tpro = us(t0)
    if !noclinv { cfast_clinv_range(shD.contents(), Int(N) * 4) }
    let s = payD[Int(N) - 1] + 4.0                       // "sum" (one peer here)
    for k in 0..<Int(N) { payC[k] = s }
    cfast_clflush_range(shC.contents(), Int(N) * 4)
    ec.signaledValue = seq          // CPU-side signal
    waitEvent(ed, seq)
    w4.append(us(t0)); w4p.append(tpro)
    if it == iters - 1 { cbD.waitUntilCompleted(); cbC.waitUntilCompleted() }
}
print(String(format: "P4 relay e2e (GPU->host->GPU, %d KiB): %.0f us (med)  [stage1 producer-commit->CPU %.0f us]",
              sizeKiB, median(w4), median(w4p)))
// P4 freshness verify: privC must hold payD-value + 4 = 16.078
do { let back = C.makeBuffer(length: Int(N) * 4, options: .storageModeShared)!
     let cb = qC.makeCommandBuffer()!; let e = cb.makeBlitCommandEncoder()!
     e.copy(from: privC, sourceOffset: 0, to: back, destinationOffset: 0, size: Int(N) * 4)
     e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
     let p = back.contents().bindMemory(to: Float.self, capacity: Int(N))
     var bad = 0; for k in stride(from: 0, to: Int(N), by: 97) where !(p[k] > 16.0 && p[k] < 16.2) { bad += 1 }
     let verdict = bad == 0 ? "PASS" : "FAIL \(bad) slots"
     print("   P4 relay verify (full path freshness): \(verdict)") }

// ---- P5: remote-view streaming read (incumbent) ---------------------------
for kb in [4, 32, 1024] {
    let n = UInt32(kb * 1024 / 4)
    let tmp = C.makeBuffer(length: Int(n) * 4, options: .storageModeShared)!
    memset(tmp.contents(), 0x41, Int(n) * 4)
    do { let cb = qC.makeCommandBuffer()!; let e = cb.makeBlitCommandEncoder()!
         e.copy(from: tmp, sourceOffset: 0, to: privC, destinationOffset: 0, size: Int(n) * 4)
         e.endEncoding(); cb.commit(); cb.waitUntilCompleted() }
    guard let view = remoteView(privC, on: D) else { die("no remote view") }
    var w5: [Double] = [], b5: [Double] = []
    for it in 0..<max(10, iters / 3) {
        let cb = copyCB(qD, on: D, from: view, to: privD, n: n)   // dst reuse ok (unused)
        let t0 = DispatchTime.now().uptimeNanoseconds
        cb.commit(); cb.waitUntilCompleted()
        w5.append(us(t0))
        if it % 4 == 0 { b5.append(busy(cb)) }
    }
    print(String(format: "P5 remote read %5d KiB : wall %.0f us (med)  gpu busy %.0f us", kb, median(w5), median(b5)))
}
