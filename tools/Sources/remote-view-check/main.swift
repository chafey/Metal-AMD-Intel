// remote-view-check — ground-truth correctness + bandwidth test for
// compute-kernel reads of peer-group remote buffer views.
//
// Why this exists: on this driver, kernel reads of remote views are NOT
// uniformly coherent. Established contract (2026-09-12, dv series + this
// tool):
//   * Blit copies of remote views are always correct (not tested here).
//   * Loads from remote views must use NATURALLY ALIGNED types: uint, ulong,
//     uint4/ulong2/float4 (16 B, 16-byte aligned) are coherent at every size
//     and across producer rewrites. `uchar4` (16 B but only 4-byte aligned)
//     is NOT: reads are served from a non-snooped cache, returning stale
//     data at fake "local speed" (~113 GB/s) — even immediately after the
//     producer rewrote the source and its command buffer completed.
//   * Bandwidth when coherent: ~23–29 GB/s per stream — the same rate as
//     blit. Kernel reads are NOT a fast path beyond the copy engine.
//     This test always rewrites the source with a fresh fill before each
//     timed pull (dv5: repeated aligned loads of an unchanged source ran
//     at true speed, but rewrite-between-iterations is the safe
//     benchmarking discipline).
//
// Sections:
//   big:   1 GiB remote view, full-grid copy at several widths including
//          the intentionally-broken uchar4 demo row, 3 producer-rewrite
//          rounds each, head/mid/tail spot checks, timed.
//   small: 16 MiB, same matrix, FULL CPU verification of every word.
//
// Usage: remote-view-check [--small-only]
import Foundation
import Metal
setbuf(stdout, nil)

let src = """
#include <metal_stdlib>
using namespace metal;
kernel void fillGS(device uint *p [[buffer(0)]], constant uint &k [[buffer(1)]],
                   constant uint &n [[buffer(2)]], uint tid [[thread_position_in_grid]]) {
    if (tid < n) p[tid] = k;
}
kernel void cpU(device uint *dst [[buffer(0)]], const device uint *s [[buffer(1)]],
                constant uint &n [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i < n) dst[i] = s[i];
}
kernel void cpUL(device ulong *dst [[buffer(0)]], const device ulong *s [[buffer(1)]],
                 constant uint &n [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i < n) dst[i] = s[i];
}
kernel void cpUL2(device ulong2 *dst [[buffer(0)]], const device ulong2 *s [[buffer(1)]],
                  constant uint &n [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i < n) dst[i] = s[i];
}
// INTENTIONALLY BROKEN demo: uchar4 is 16 bytes but only 4-byte aligned;
// loads of remote views return stale cached data. Expected to FAIL here —
// that is the regression this tool guards against (see gotchas).
kernel void cpUC4(device uchar4 *dst [[buffer(0)]], const device uchar4 *s [[buffer(1)]],
                  constant uint &n [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i < n) dst[i] = s[i];
}
"""

let devs = MTLCopyAllDevices().enumerated().filter { $0.element.peerGroupID != 0 }
guard devs.count >= 2 else { fatalError("need >=2 peer-group devices") }
let prod = devs[0].element, cons = devs[1].element
print("producer=dev\(devs[0].offset) consumer=dev\(devs[1].offset)")
let qp = prod.makeCommandQueue()!, qc = cons.makeCommandQueue()!
func pipe(_ d: MTLDevice, _ fn: String) -> MTLComputePipelineState {
    let lib = try! d.makeLibrary(source: src, options: nil)
    return try! d.makeComputePipelineState(function: lib.makeFunction(name: fn)!)
}
let fillP = pipe(prod, "fillGS")
let cpU = pipe(cons, "cpU"), cpUL = pipe(cons, "cpUL"), cpUL2 = pipe(cons, "cpUL2")
let cpUC4 = pipe(cons, "cpUC4")
let sel = Selector(("newRemoteBufferViewForDevice:"))
func viewOf(_ b: MTLBuffer) -> MTLBuffer { b.perform(sel, with: cons)!.takeUnretainedValue() as! MTLBuffer }

// ---------- big-buffer (1 GiB) multi-round test ----------
let bigBytes = 1 << 30
let pBig = prod.makeBuffer(length: bigBytes, options: .storageModePrivate)!
let cBig = cons.makeBuffer(length: bigBytes, options: .storageModePrivate)!
let vBig = viewOf(pBig)
let probeBytes = 3 << 20
let hProbe = cons.makeBuffer(length: probeBytes, options: .storageModeShared)!

func fill(_ buf: MTLBuffer, bytes: Int, _ k: UInt32) {
    var kk = k, n = UInt32(bytes / 4)
    let cb = qp.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(fillP); e.setBuffer(buf, offset: 0, index: 0)
    withUnsafeBytes(of: &kk) { e.setBytes($0.baseAddress!, length: 4, index: 1) }
    withUnsafeBytes(of: &n) { e.setBytes($0.baseAddress!, length: 4, index: 2) }
    e.dispatchThreads(MTLSize(width: bytes / 4, height: 1, depth: 1),
                      threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
}
func copy1G(_ p: MTLComputePipelineState, elems: Int) -> Double {
    // private-storage dst cannot be CPU-poisoned; rely on round-to-round distinct k
    var n = UInt32(elems)
    let cb = qc.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(p); e.setBuffer(cBig, offset: 0, index: 0); e.setBuffer(vBig, offset: 0, index: 1)
    withUnsafeBytes(of: &n) { e.setBytes($0.baseAddress!, length: 4, index: 2) }
    e.dispatchThreads(MTLSize(width: elems, height: 1, depth: 1),
                      threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    e.endEncoding()
    let t0 = DispatchTime.now().uptimeNanoseconds
    cb.commit(); cb.waitUntilCompleted()
    return Double(bigBytes) / (Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9) / 1e9
}
// check head / mid / tail (each 1 MiB into its own probe slot), report per-region
func checkBig(_ k: UInt32) -> String {
    let cb = qc.makeCommandBuffer()!, e = cb.makeBlitCommandEncoder()!
    e.copy(from: cBig, sourceOffset: 0, to: hProbe, destinationOffset: 0, size: 1 << 20)
    e.copy(from: cBig, sourceOffset: bigBytes / 2, to: hProbe, destinationOffset: 1 << 20, size: 1 << 20)
    e.copy(from: cBig, sourceOffset: bigBytes - (1 << 20), to: hProbe, destinationOffset: 2 << 20, size: 1 << 20)
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    let base = hProbe.contents().bindMemory(to: UInt32.self, capacity: probeBytes / 4)
    var out: [String] = []
    for (name, off) in [("head", 0), ("mid", 1 << 18), ("tail", 2 << 18)] {
        var bad = 0
        for i in stride(from: off, to: off + (1 << 18), by: 251) where base[i] != k { bad += 1 }
        out.append("\(name):\(bad)")
    }
    return out.joined(separator: " ")
}

let rounds = 3
let widths: [(String, MTLComputePipelineState, Int)] = [
    ("uint   4B", cpU, bigBytes / 4),
    ("ulong  8B", cpUL, bigBytes / 8),
    ("ulong2 16B", cpUL2, bigBytes / 16),
    ("uchar4 16B*", cpUC4, bigBytes / 16),   // expected FAIL (alignment bug)
]
if !CommandLine.arguments.contains("--small-only") {
    for (name, p, elems) in widths {
        let h = UInt32(truncatingIfNeeded: name.hashValue)
        for r in 1...rounds {
            let k: UInt32 = 0xAB000000 | ((UInt32(r) << 16) | (h & 0xFFFF)) & 0x00FFFFFF
            fill(pBig, bytes: bigBytes, k)
            let gbps = copy1G(p, elems: elems)
            print(String(format: "%@ r%d: %.1f GB/s  bad(head/mid/tail) %@", name, r, gbps, checkBig(k)))
        }
    }
}

// ---------- small-buffer (16 MiB) FULL CPU verification, scalar & vector ----------
let smBytes = 16 << 20
let pS = prod.makeBuffer(length: smBytes, options: .storageModePrivate)!
let cS = cons.makeBuffer(length: smBytes, options: .storageModePrivate)!
let vS = viewOf(pS)
let hS = cons.makeBuffer(length: smBytes, options: .storageModeShared)!
print("--- 16 MiB full-buffer verification ---")
for (name, p, elems) in widths {
    let h = UInt32(truncatingIfNeeded: name.hashValue)
    for r in 1...rounds {
        let k: UInt32 = 0xCD000000 | ((UInt32(r) << 12) | (h & 0xFFF)) & 0x00FFFFFF
        fill(pS, bytes: smBytes, k)
        var n = UInt32(elems)
        let cb = qc.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(p); e.setBuffer(cS, offset: 0, index: 0); e.setBuffer(vS, offset: 0, index: 1)
        withUnsafeBytes(of: &n) { e.setBytes($0.baseAddress!, length: 4, index: 2) }
        e.dispatchThreads(MTLSize(width: elems, height: 1, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let eb = qc.makeCommandBuffer()!, ee = eb.makeBlitCommandEncoder()!
        ee.copy(from: cS, sourceOffset: 0, to: hS, destinationOffset: 0, size: smBytes)
        ee.endEncoding(); eb.commit(); eb.waitUntilCompleted()
        let w = hS.contents().bindMemory(to: UInt32.self, capacity: smBytes / 4)
        var bad = 0, first = -1
        for i in 0..<(smBytes / 4) where w[i] != k { bad += 1; if first < 0 { first = i } }
        let verdict = bad == 0 ? "OK" : String(format: "FAIL, first at %.2f MiB", Double(first) * 4 / 1048576)
        print("\(name) r\(r): \(verdict) (\(bad) bad words)")
    }
}
print("done")
