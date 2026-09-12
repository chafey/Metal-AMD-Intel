// Control v2: can a SECOND command queue overlap work with the first on ONE
// local device? Fixes v1 bugs: non-overlapping separate src/dst blit buffers,
// per-CB GPU timestamps, 5 passes (report min), overlap-interval check.
import Metal
import Foundation
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void spinK(device float *out [[buffer(0)]],
                  device float *scratch [[buffer(1)]],
                  constant float &value [[buffer(2)]],
                  constant uint &iters [[buffer(3)]],
                  uint idx [[thread_position_in_grid]]) {
    float x = float(idx | 1);
    for (uint i = 0; i < iters; ++i) { x = fma(x, 1.0000001f, 1.0f); }
    scratch[idx] = x;
    out[idx] = value;
}
"""
let dev = MTLCopyAllDevices()[1]
let lib = try! dev.makeLibrary(source: src, options: nil)
let pl = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "spinK")!)
let q1 = dev.makeCommandQueue()!
let q2 = dev.makeCommandQueue()!
let sbuf = dev.makeBuffer(length: 8192*8, options: .storageModePrivate)!
let srcBuf = dev.makeBuffer(length: 1 << 24, options: .storageModePrivate)!   // 16 MiB
let dstBuf = dev.makeBuffer(length: 1 << 24, options: .storageModePrivate)!
// calibrate spin at the RUNTIME dispatch config (tg=64): target ~480 µs busy
func spinCB(_ q: MTLCommandQueue, iters: UInt32) -> MTLCommandBuffer {
    let cb = q.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pl)
    enc.setBuffer(sbuf, offset: 0, index: 0)
    enc.setBuffer(sbuf, offset: 0, index: 1)
    var v: Float = 0; var it = iters
    withUnsafeBytes(of: &v) { enc.setBytes($0.baseAddress!, length: 4, index: 2) }
    withUnsafeBytes(of: &it) { enc.setBytes($0.baseAddress!, length: 4, index: 3) }
    enc.dispatchThreads(MTLSize(width: 8192, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    enc.endEncoding()
    return cb
}
func blitCB(_ q: MTLCommandQueue, bytes: Int) -> MTLCommandBuffer {
    let cb = q.makeCommandBuffer()!
    let enc = cb.makeBlitCommandEncoder()!
    enc.copy(from: srcBuf, sourceOffset: 0, to: dstBuf, destinationOffset: 0, size: bytes)
    enc.endEncoding()
    return cb
}
func calibrate() -> UInt32 {
    var iters: UInt32 = 48000
    for _ in 0..<4 {
        let cb = spinCB(q1, iters: iters); let t0 = DispatchTime.now().uptimeNanoseconds
        cb.commit(); cb.waitUntilCompleted()
        let us = Double(DispatchTime.now().uptimeNanoseconds - t0)/1000
        let target = 480.0
        if us > 300 && us < 700 { break }
        iters = UInt32(max(1000, Double(iters) * target / max(us, 1)))
    }
    return iters
}
let iters = calibrate()
FileHandle.standardError.write("calibrated iters=\(iters)\n".data(using: .utf8)!)
let B = 1 << 24
func bench(_ name: String, _ work: () -> [MTLCommandBuffer], showIntervals: Bool = false) {
    var best = Double.infinity
    var last: [MTLCommandBuffer] = []
    for pass in 0..<5 {
        let cbs = work()
        let t0 = DispatchTime.now().uptimeNanoseconds
        for cb in cbs { cb.commit() }
        for cb in cbs { cb.waitUntilCompleted() }
        let us = Double(DispatchTime.now().uptimeNanoseconds - t0)/1000
        if us < best { best = us }
        last = cbs
    }
    var line = String(format: "%@: %6.0f µs (min of 5)", name, best)
    // GPU busy intervals
    var intervals: [(Double, Double)] = []
    var gpuOK = true
    for cb in last {
        let s = cb.gpuStartTime, e = cb.gpuEndTime
        if e <= s { gpuOK = false; break }
        intervals.append((s, e))
    }
    if gpuOK {
        line += "  | gpu busy:"
        for (s, e) in intervals { line += String(format: " [%.0f..%.0f]", s*1e6, (e-s)*1e6) }
        // overlap between first CB and any later CB (parallel configs)
        if intervals.count > 1 {
            let (s0, e0) = intervals[0]
            let overlapped = intervals.dropFirst().contains { $0.0 < e0 && $0.1 > s0 }
            line += overlapped ? "  OVERLAP=yes" : "  OVERLAP=no"
        }
    } else {
        line += "  | GPUStartTime unavailable"
    }
    print(line)
}
bench("spin alone            ") { [spinCB(q1, iters: iters)] }
bench("blit alone x1         ") { [blitCB(q2, bytes: B)] }
bench("blit serial x2 q2     ") { [blitCB(q2, bytes: B), blitCB(q2, bytes: B)] }
bench("serial spin+2blit q1  ") { [spinCB(q1, iters: iters), blitCB(q1, bytes: B), blitCB(q1, bytes: B)] }
bench("q1 spin || q2 2blit   ") { [spinCB(q1, iters: iters), blitCB(q2, bytes: B), blitCB(q2, bytes: B)] }
bench("q1 spin || q2 4blit   ") { [spinCB(q1, iters: iters)] + (0..<4).map { _ in blitCB(q2, bytes: B) } }
