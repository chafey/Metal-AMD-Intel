// matvec-bench — the COMPUTE side of the batch-amortization argument.
//
// tp-sim measured the comm side of a tensor-parallel decode all-reduce as a
// function of batch size B (one all-reduce per layer carries B tokens' worth
// of activations). Larger B amortises the driver's fixed per-remote-op charge,
// but it also multiplies the local GEMM work per forward pass. This tool
// measures the second half of that trade: on ONE die, how long does it take to
// stream a transformer-weight matrix of given size, as a function of the number
// of tokens batched against it (the GEMV -> GEMM transition).
//
// Model: D[N,B] += sum_k W[K,N] * X[K,B]  with W the weight matrix read ONCE
// per forward regardless of B (the memory-bound regime the engine lives in at
// small B) and 2*K*N*B FLOPs of math (the compute-bound regime at large B).
// The B at which time stops tracking bytes and starts tracking FLOPs is where
// batching stops being free on the compute side.
//
// Two reference numbers anchor the curve:
//   BW    = pure weight-streaming read rate (the memory-bound asymptote)
//   FMA   = register-only FMA throughput (the compute-bound asymptote)
// so B* ~ FMA / BW is the predicted knee, and this tool shows where it really
// lands for a real dot-product kernel.
import Metal
import Foundation

func die(_ s: String) -> Never {
    FileHandle.standardError.write("matvec-bench: \(s)\n".data(using: .utf8)!)
    exit(1)
}
setbuf(stdout, nil)

var devIdx = 1
var weightGiB = 2.0
var batchList = [1, 2, 4, 8, 16, 32, 64]
var kSlices = 32
var json = false

let argv = CommandLine.arguments
var i = 1
func intArg(_ s: String) -> Int { guard let v = Int(s) else { die("needs int, got \(s)") }; return v }
while i < argv.count {
    switch argv[i] {
    case "--device":     i += 1; guard i < argv.count else { die("--device needs int") }; devIdx = intArg(argv[i])
    case "--gib":        i += 1; guard i < argv.count else { die("--gib needs number") }; guard let gv = Double(argv[i]) else { die("--gib needs number") }; weightGiB = gv
    case "--batches":    i += 1; guard i < argv.count else { die("--batches needs list") }
                         batchList = argv[i].split(separator: ",").map { intArg(String($0)) }
                         if batchList.contains(where: { $0 < 1 || $0 > 64 }) { die("--batches values must be 1..64") }
    case "--slices":     i += 1; guard i < argv.count else { die("--slices needs int") }; kSlices = max(1, intArg(argv[i]))
    case "--json":       json = true
    default:             die("unknown argument \(argv[i])")
    }
    i += 1
}
guard devIdx != 0 else { die("refusing device 0 (display GPU); use a peer-group die") }

let devs = MTLCopyAllDevices()
guard devIdx < devs.count else { die("no device index \(devIdx)") }
let dev = devs[devIdx]

let msl = """
#include <metal_stdlib>
using namespace metal;

kernel void streamRead(device const float4 *w [[buffer(0)]],
                       device float *out [[buffer(1)]],
                       constant uint &n4 [[buffer(2)]],
                       uint tid [[thread_position_in_grid]],
                       uint gt [[threads_per_grid]]) {
    float4 acc = {};
    for (uint i = tid; i < n4; i += gt) acc += w[i];
    if (acc.x + acc.y + acc.z + acc.w == 12345.678f) out[tid & 1023] = acc.x;
}

kernel void fmaPeak(device float *out [[buffer(0)]],
                    constant uint &iters [[buffer(1)]],
                    uint tid [[thread_position_in_grid]]) {
    float a = float(tid | 1) * 0.0001f, b = 1.0000001f, c = 1.0f, d = 0.9999f;
    float e = a * 0.5f + 1.0f, f = 1.1f, g = 0.9f, h = 1.2f;
    for (uint k = 0; k < iters; ++k) {
        a = fma(a, b, c); b = fma(b, d, a); c = fma(c, e, b); d = fma(d, f, c);
        e = fma(e, g, d); f = fma(f, h, e); g = fma(g, a, f); h = fma(h, b, g);
    }
    if (a + b + c + d + e + f + g + h == 12345.678f) out[tid & 1023] = a;
}

template <int B>
static void mv(uint2 gidx,
               constant uint &N,
               constant uint &KS,
               device const half *W,
               device const float *X,
               device atomic_float *D) {
    uint n = gidx.x;
    uint k0 = gidx.y * KS;
    float acc[B];
    for (int j = 0; j < B; ++j) acc[j] = 0.0f;
    device const half *wp = W + size_t(k0) * N + n;
    device const float *xp = X + size_t(k0) * B;
    for (uint k = 0; k < KS; ++k) {
        float wv = float(wp[k * N]);
        device const float *xk = xp + size_t(k) * B;
        for (int j = 0; j < B; ++j) acc[j] = fma(wv, xk[j], acc[j]);
    }
    device atomic_float *dp = D + size_t(n) * 64;
    for (int j = 0; j < B; ++j) atomic_fetch_add_explicit(dp + j, acc[j], memory_order_relaxed);
}

#define MVK(NAME, BB) \\
kernel void NAME(uint2 g [[thread_position_in_grid]], \\
                 constant uint &N [[buffer(0)]], \\
                 constant uint &KS [[buffer(1)]], \\
                 device const half *W [[buffer(2)]], \\
                 device const float *X [[buffer(3)]], \\
                 device atomic_float *D [[buffer(4)]]) { mv<BB>(g, N, KS, W, X, D); }
MVK(mvB1, 1)  MVK(mvB2, 2)  MVK(mvB4, 4)  MVK(mvB8, 8)
MVK(mvB16, 16) MVK(mvB32, 32) MVK(mvB64, 64)
"""

guard let lib = try? dev.makeLibrary(source: msl, options: nil) else { die("shader compile failed") }
func pipe(_ name: String) -> MTLComputePipelineState {
    guard let f = lib.makeFunction(name: name),
          let p = try? dev.makeComputePipelineState(function: f) else { die("pipeline \(name)") }
    return p
}
let q = dev.makeCommandQueue()!
let pStream = pipe("streamRead"), pFma = pipe("fmaPeak")
let mvPipes: [Int: MTLComputePipelineState] = [
    1: pipe("mvB1"), 2: pipe("mvB2"), 4: pipe("mvB4"), 8: pipe("mvB8"),
    16: pipe("mvB16"), 32: pipe("mvB32"), 64: pipe("mvB64"),
]

func median(_ xs: [Double]) -> Double { var s = xs; s.sort(); return s[s.count / 2] }
var progressLines: [String] = []
func say(_ s: String) { progressLines.append(s); if !json { print(s) } }
func timed(_ work: () -> MTLCommandBuffer?) -> (Double, Double) {
    var walls: [Double] = [], busys: [Double] = []
    for _ in 0..<3 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let cb = work() else { return (-1, -1) }
        cb.commit(); cb.waitUntilCompleted()
        walls.append(Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1000)
        if cb.gpuEndTime > cb.gpuStartTime { busys.append((cb.gpuEndTime - cb.gpuStartTime) * 1e6) }
    }
    return (median(walls), busys.isEmpty ? -1 : median(busys))
}

// ---- weight matrix + input -------------------------------------------------
let N = 16384
let totalWBytes = UInt64(weightGiB * Double(1 << 30))
let K = Int(totalWBytes / (2 * UInt64(N)))          // fp16 weights
guard K % kSlices == 0 else { die("K=\(K) not divisible by --slices \(kSlices)") }
let KS = K / kSlices
let maxB = 64
let wCount = UInt64(K) * UInt64(N)
let wBytes = wCount * 2

guard let W = dev.makeBuffer(length: Int(wBytes), options: .storageModePrivate),
      let X = dev.makeBuffer(length: K * maxB * 4, options: .storageModePrivate),
      let Dout = dev.makeBuffer(length: N * 64 * 4, options: .storageModePrivate),
      let scratch = dev.makeBuffer(length: 4096, options: .storageModePrivate)
else { die("buffer alloc (\(Double(wBytes) / 1e9) GB) failed") }

// deterministic patterns via blits from small CPU-filled pattern buffers
// (avoids the renamed/unavailable fill(buffer:range:value:) API entirely)
func patternBuf(_ byte: Int32, _ len: Int) -> MTLBuffer {
    let b = dev.makeBuffer(length: len, options: .storageModeShared)!
    memset(b.contents(), byte, len)
    return b
}
func blitFill(_ dst: MTLBuffer, from pat: MTLBuffer, length: Int, offset: Int = 0) {
    let cb = q.makeCommandBuffer()!, e = cb.makeBlitCommandEncoder()!
    var done = 0
    while done < length {
        let n = min(pat.length, length - done)
        e.copy(from: pat, sourceOffset: 0, to: dst, destinationOffset: offset + done, size: n)
        done += n
    }
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
}
let patW = patternBuf(0x3C, 1 << 20)   // half 0x3C3C ~ 0.0146
let patX = patternBuf(0x3E, 1 << 20)   // float ~0.093-ish, fine for timing
let pat0 = patternBuf(0x00, N * 64 * 4)
blitFill(W, from: patW, length: Int(wBytes))
blitFill(X, from: patX, length: K * maxB * 4)
blitFill(Dout, from: pat0, length: N * 64 * 4)
say("device \(devIdx) \(dev.name): W=[\(K) x \(N)] fp16 = \(String(format: "%.2f", Double(wBytes)/1e9)) GB, K-slab \(KS) x \(kSlices)")

// ---- BW asymptote ----------------------------------------------------------
let n4 = UInt32(wBytes / 16)
let (bwWall, bwBusy) = timed {
    guard let cb = q.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { return nil }
    e.setComputePipelineState(pStream)
    e.setBuffer(W, offset: 0, index: 0); e.setBuffer(scratch, offset: 0, index: 1)
    withUnsafeBytes(of: n4) { e.setBytes($0.baseAddress!, length: 4, index: 2) }
    e.dispatchThreads(MTLSize(width: 1 << 17, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    e.endEncoding(); return cb
}
let bwGBs = Double(wBytes) / (bwBusy / 1e6) / 1e9
say(String(format: "stream BW          : %.1f GB/s  (kernel busy %.2f ms for %.2f GB)", bwGBs, bwBusy / 1000, Double(wBytes)/1e9))

// ---- FMA asymptote (calibrate iters at the runtime launch config) ----------
func fmaCB(_ iters: UInt32) -> MTLCommandBuffer? {
    guard let cb = q.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { return nil }
    e.setComputePipelineState(pFma)
    e.setBuffer(scratch, offset: 0, index: 0)
    withUnsafeBytes(of: iters) { e.setBytes($0.baseAddress!, length: 4, index: 1) }
    e.dispatchThreads(MTLSize(width: 1 << 17, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    e.endEncoding(); return cb
}
var fmaIters: UInt32 = 2000
for _ in 0..<4 {
    guard let cb = fmaCB(fmaIters) else { die("fma cb") }
    let t0 = DispatchTime.now().uptimeNanoseconds
    cb.commit(); cb.waitUntilCompleted()
    let us = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1000
    if us > 40_000 { break }
    fmaIters = UInt32(max(100, Double(fmaIters) * 60_000.0 / max(us, 1)))
}
guard let fcb = fmaCB(fmaIters) else { die("fma") }
fcb.commit(); fcb.waitUntilCompleted()
let fmaSec = fcb.gpuEndTime - fcb.gpuStartTime
let fmaBusyUs = fmaSec > 0 ? fmaSec * 1e6 : -1
let fmaFlops = Double(1 << 17) * Double(fmaIters) * 8.0 * 2.0
let fmaTF = fmaBusyUs > 0 ? fmaFlops / (fmaBusyUs * 1e-6) / 1e12 : -1
say(String(format: "FMA ceiling        : %.2f TFLOPS (fp32, register-only, %u iters, gpu busy %.1f ms)",
             fmaTF, fmaIters, fmaBusyUs / 1000))
if fmaTF > 0 {
    say(String(format: "predicted knee B*  : %.0f  (FMA %.1f TFLOPS / BW %.0f GB/s)", fmaTF * 1e3 / bwGBs, fmaTF, bwGBs))
}

// ---- the curve -------------------------------------------------------------
var rows: [(Int, Double, Double, Double)] = []
for B in batchList where B <= maxB {
    let ps = mvPipes[B]!
    func run() -> MTLCommandBuffer? {
        guard let cb = q.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { return nil }
        e.setComputePipelineState(ps)
        var nN = UInt32(N), nKS = UInt32(KS)
        withUnsafeBytes(of: nN)  { e.setBytes($0.baseAddress!, length: 4, index: 0) }
        withUnsafeBytes(of: nKS) { e.setBytes($0.baseAddress!, length: 4, index: 1) }
        e.setBuffer(W, offset: 0, index: 2)
        e.setBuffer(X, offset: 0, index: 3)
        e.setBuffer(Dout, offset: 0, index: 4)
        e.dispatchThreads(MTLSize(width: N, height: kSlices, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        e.endEncoding(); return cb
    }
    // zero D then run
    func zeroAndRun() -> MTLCommandBuffer? {
        blitFill(Dout, from: pat0, length: N * 64 * 4)   // untimed
        return run()
    }
    let (wall, busy) = timed { zeroAndRun() }
    let msPerGB = (busy / 1000) / (Double(wBytes) / 1e9)
    let effGBs = Double(wBytes) / (busy / 1e6) / 1e9
    let tflops = (2.0 * Double(K) * Double(N) * Double(B)) / (busy / 1e6) / 1e12
    rows.append((B, msPerGB, effGBs, tflops))
}

if json {
    var out: [String: Any] = [
        "tool": "matvec-bench",
        "device": ["index": devIdx, "name": dev.name],
        "matrix": ["N": N, "K": K, "kSlices": kSlices, "weightBytes": wBytes],
        "streamGBs": bwGBs, "fmaTFLOPS": fmaTF, "fmaIters": Int(fmaIters),
        "progress": progressLines,
        "rows": rows.map { ["B": $0.0, "msPerGB": $0.1, "effGBs": $0.2, "tflops": $0.3] },
    ]
    let d = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    print(String(data: d, encoding: .utf8)!)
} else {
    print("   B    ms/GB    eff GB/s   TFLOPS")
    for r in rows {
        print(String(format: "%4d   %6.2f   %7.0f   %6.2f", r.0, r.1, r.2, r.3))
    }
}
