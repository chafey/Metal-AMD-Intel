import Foundation
import Metal
import IOSurface

// Measurement primitives shared by all if-bench directions: pipelined
// bandwidth (many copies committed together), dependent-chain latency
// (ping-pong copies), local VRAM, IOSurface staging hops (the only
// Apple-sanctioned cross-device buffer sharing on macOS), and host<->GPU
// approximations via shared (host-backed) buffers.

final class DeviceCtx {
    let index: Int
    let device: MTLDevice
    let queue: MTLCommandQueue
    let copyPipeline: MTLComputePipelineState?
    let fillPipeline: MTLComputePipelineState?
    let sumPipeline: MTLComputePipelineState?
    var info: [String: Any] = [:]

    init(index: Int, device: MTLDevice) {
        self.index = index
        self.device = device
        self.queue = device.makeCommandQueue()!

        // Kernel-driven copy paths, to compare against the blit/copy-engine
        // path (tools/if-bench/README.md: "distinguish copy-engine (blit)
        // vs. kernel-driven copy paths"). All sizes measured are multiples
        // of 16 bytes, so uint4 element granularity is exact.
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void copyu4(device const uint4 *src [[buffer(0)]],
                           device uint4 *dst [[buffer(1)]],
                           constant uint &n [[buffer(2)]],
                           uint i [[thread_position_in_grid]]) {
            if (i < n) dst[i] = src[i];
        }
        kernel void fillu4(device uint4 *dst [[buffer(0)]],
                           constant uint &n [[buffer(1)]],
                           uint i [[thread_position_in_grid]]) {
            if (i < n) dst[i] = uint4(i, i + 1u, i + 2u, i + 3u);
        }
        kernel void sumu4(device const uint4 *src [[buffer(0)]],
                          constant uint &n [[buffer(1)]],
                          device atomic_uint *out [[buffer(2)]],
                          uint i [[thread_position_in_grid]]) {
            if (i < n) {
                uint4 v = src[i];
                atomic_fetch_add_explicit(out, v.x + v.y + v.z + v.w, memory_order_relaxed);
            }
        }
        """
        func pipeline(_ function: String) -> MTLComputePipelineState? {
            guard let lib = try? device.makeLibrary(source: source, options: nil),
                  let fn = lib.makeFunction(name: function)
            else { return nil }
            return try? device.makeComputePipelineState(function: fn)
        }
        self.copyPipeline = pipeline("copyu4")
        self.fillPipeline = pipeline("fillu4")
        self.sumPipeline = pipeline("sumu4")
    }

    /// GPU-resident buffer. NB: never write through `contents()` on this
    /// driver for private storage — that hangs command submission on the
    /// W6800X Duo / macOS 26.6.2 (see docs/metal/gotchas.md).
    func buffer(_ bytes: Int) -> MTLBuffer? {
        device.makeBuffer(length: bytes, options: .storageModePrivate)
    }

    /// Dispatch a copy/fill/sum kernel over `count` uint4 elements. Buffer
    /// bindings are given explicitly because the kernels differ in where
    /// `n` lives; `count` is bound at `countIndex`.
    func dispatch(_ pipeline: MTLComputePipelineState, encoder: MTLComputeCommandEncoder,
                  bindings: [(index: Int, buffer: MTLBuffer)],
                  count: UInt32, countIndex: Int) {
        encoder.setComputePipelineState(pipeline)
        for binding in bindings {
            encoder.setBuffer(binding.buffer, offset: 0, index: binding.index)
        }
        var countVar = count
        withUnsafeBytes(of: countVar) { raw in
            encoder.setBytes(raw.baseAddress!, length: MemoryLayout<UInt32>.size,
                             index: countIndex)
        }
        let perGroup = pipeline.maxTotalThreadsPerThreadgroup
        let groups = (Int(count) + perGroup - 1) / perGroup
        encoder.dispatchThreads(
            MTLSize(width: groups * perGroup, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: perGroup, height: 1, depth: 1))
    }
}

// MARK: - Timing helpers

@inline(__always)
func measuredSeconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}

/// Iterations for a given size: enough traffic to be steady-state
/// (~64 MiB per timed batch) but bounded so tiny sizes don't dominate
/// total runtime.
func iterations(for size: Int) -> Int {
    max(8, min(2048, 67_108_864 / max(size, 1)))
}

// MARK: - Single-device (local VRAM) measurements

/// Pipelined copies committed as one command buffer. Alternates direction so
/// the same two buffers keep being touched (bounded working set).
/// Returns total seconds for `iters` copies of `size`.
func localBandwidth(_ ctx: DeviceCtx, size: Int, useKernel: Bool) -> Double? {
    guard let src = ctx.buffer(size), let dst = ctx.buffer(size) else { return nil }
    let n = iterations(for: size)

    func enqueue(_ cb: MTLCommandBuffer) {
        for i in 0..<n {
            let (from, to) = i % 2 == 0 ? (src, dst) : (dst, src)
            if useKernel, let pipeline = ctx.copyPipeline {
                let enc = cb.makeComputeCommandEncoder()!
                ctx.dispatch(pipeline, encoder: enc,
                             bindings: [(0, from), (1, to)],
                             count: UInt32(size / 16), countIndex: 2)
                enc.endEncoding()
            } else {
                let enc = cb.makeBlitCommandEncoder()!
                enc.copy(from: from, sourceOffset: 0, to: to, destinationOffset: 0, size: size)
                enc.endEncoding()
            }
        }
    }

    guard let warm = ctx.queue.makeCommandBuffer() else { return nil }
    enqueue(warm)
    warm.commit()
    warm.waitUntilCompleted()

    guard let cb = ctx.queue.makeCommandBuffer() else { return nil }
    return measuredSeconds {
        enqueue(cb)
        cb.commit()
        cb.waitUntilCompleted()
    }
}

/// Dependent ping-pong copies (each copy reads what the previous wrote)
/// within one command buffer: measures per-copy turnaround, not throughput.
/// Returns seconds per single copy.
func localLatency(_ ctx: DeviceCtx, size: Int, roundTrips: Int) -> Double? {
    guard let a = ctx.buffer(size), let b = ctx.buffer(size) else { return nil }
    guard let warm = ctx.queue.makeCommandBuffer(),
          let warmEnc = warm.makeBlitCommandEncoder()
    else { return nil }
    warmEnc.copy(from: a, sourceOffset: 0, to: b, destinationOffset: 0, size: size)
    warmEnc.endEncoding()
    warm.commit()
    warm.waitUntilCompleted()

    guard let cb = ctx.queue.makeCommandBuffer(),
          let enc = cb.makeBlitCommandEncoder()
    else { return nil }
    let seconds = measuredSeconds {
        for _ in 0..<roundTrips {
            enc.copy(from: a, sourceOffset: 0, to: b, destinationOffset: 0, size: size)
            enc.copy(from: b, sourceOffset: 0, to: a, destinationOffset: 0, size: size)
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
    return seconds / Double(2 * roundTrips)
}

// MARK: - IOSurface staging (cross-device sharing path)

/// A staging region backed by one IOSurface, with an `MTLTexture` view per
/// device. This is the only Apple-sanctioned way to make the same memory
/// visible to two `MTLDevice`s on macOS. Whether the surface pages are host-
/// resident or migrated by the driver is not observable from the API; peer
/// numbers must be interpreted accordingly (see tools/if-bench/README.md).
final class Staging {
    let surface: IOSurfaceRef
    let bytesPerRow: Int
    let rows: Int
    var views: [Int: MTLTexture] = [:]

    init?(size: Int) {
        // Keep both texture sides within the 16 384 px 2D-texture limit
        // (largest supportable region: 16 384 × 16 384 = 256 MiB).
        var width = min(max(size, 4096), 8192)
        while (size + width - 1) / width > 16_384, width < 16_384 { width *= 2 }
        guard (size + width - 1) / width <= 16_384 else { return nil }
        let dict: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: (size + width - 1) / width,
            kIOSurfaceBytesPerRow: width,
            kIOSurfaceBytesPerElement: 1,
        ]
        guard let surface = IOSurfaceCreate(dict as CFDictionary) else { return nil }
        self.surface = surface
        self.bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        self.rows = (size + self.bytesPerRow - 1) / self.bytesPerRow
        // The bytes-per-row the IOSurface picked must also fit the texture view.
        guard self.bytesPerRow <= 16_384, self.rows <= 16_384 else { return nil }
    }

    var stride: Int { bytesPerRow * rows }
    var region: MTLSize { MTLSize(width: bytesPerRow, height: rows, depth: 1) }

    func texture(on ctx: DeviceCtx) -> MTLTexture? {
        if let existing = views[ctx.index] { return existing }
        guard bytesPerRow <= 16_384, rows <= 16_384 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: bytesPerRow, height: rows, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        // The `try` is written for cross-SDK portability: some SDKs declare
        // this entry point `throws`, others do not.
        guard let tex = try? ctx.device.makeTexture(descriptor: desc, iosurface: surface, plane: 0)
        else { return nil }
        views[ctx.index] = tex
        return tex
    }
}

/// Enqueue one staging hop: device buffer -> staging (`write`) or
/// staging -> device buffer (`read`). Buffers must be at least
/// `staging.stride` bytes.
func enqueueHop(_ ctx: DeviceCtx, cb: MTLCommandBuffer, buffer: MTLBuffer,
                staging: Staging, texture: MTLTexture, write: Bool) {
    let enc = cb.makeBlitCommandEncoder()!
    let bpr = staging.bytesPerRow
    if write {
        enc.copy(from: buffer, sourceOffset: 0,
                 sourceBytesPerRow: bpr,
                 sourceBytesPerImage: bpr * staging.rows,
                 sourceSize: staging.region,
                 to: texture, destinationSlice: 0, destinationLevel: 0,
                 destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    } else {
        enc.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                 sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: staging.region,
                 to: buffer, destinationOffset: 0,
                 destinationBytesPerRow: bpr,
                 destinationBytesPerImage: bpr * staging.rows)
    }
    enc.endEncoding()
}

/// Bandwidth of one staging hop in isolation. Returns seconds per hop.
func stagingHopBandwidth(_ ctx: DeviceCtx, staging: Staging, write: Bool) -> Double? {
    guard let tex = staging.texture(on: ctx), let buf = ctx.buffer(staging.stride) else { return nil }
    let n = max(4, iterations(for: staging.stride) / 2)
    func pass() {
        guard let cb = ctx.queue.makeCommandBuffer() else { return }
        enqueueHop(ctx, cb: cb, buffer: buf, staging: staging, texture: tex, write: write)
        cb.commit()
        cb.waitUntilCompleted()
    }
    pass()  // warmup
    return measuredSeconds { for _ in 0..<n { pass() } } / Double(n)
}

/// Full A->B peer transfer: bufferA -> staging (on A's queue), then
/// staging -> bufferB (on B's queue), waited in dependency order.
/// Returns seconds per two-hop transfer.
func peerBandwidth(_ from: DeviceCtx, _ to: DeviceCtx, staging: Staging) -> Double? {
    guard let texA = staging.texture(on: from), let texB = staging.texture(on: to),
          let src = from.buffer(staging.stride), let dst = to.buffer(staging.stride)
    else { return nil }
    let n = max(4, iterations(for: staging.stride) / 2)

    func pass() {
        guard let cbA = from.queue.makeCommandBuffer(),
              let cbB = to.queue.makeCommandBuffer()
        else { return }
        enqueueHop(from, cb: cbA, buffer: src, staging: staging, texture: texA, write: true)
        cbA.commit()
        cbA.waitUntilCompleted()
        enqueueHop(to, cb: cbB, buffer: dst, staging: staging, texture: texB, write: false)
        cbB.commit()
        cbB.waitUntilCompleted()
    }
    pass()  // warmup
    return measuredSeconds { for _ in 0..<n { pass() } } / Double(n)
}

/// Cross-device round trip latency: four dependent hops per repetition
/// (A->staging, staging->B, B->staging, staging->A).
/// Returns seconds per single hop.
func peerRoundTripLatency(_ a: DeviceCtx, _ b: DeviceCtx, staging: Staging,
                          roundTrips: Int) -> Double? {
    guard let texA = staging.texture(on: a), let texB = staging.texture(on: b),
          let bufA = a.buffer(staging.stride), let bufB = b.buffer(staging.stride)
    else { return nil }

    func hop(_ ctx: DeviceCtx, _ tex: MTLTexture, _ buf: MTLBuffer, _ write: Bool) {
        guard let cb = ctx.queue.makeCommandBuffer() else { return }
        enqueueHop(ctx, cb: cb, buffer: buf, staging: staging, texture: tex, write: write)
        cb.commit()
        cb.waitUntilCompleted()
    }
    // Warmup round trip.
    hop(a, texA, bufA, true)
    hop(b, texB, bufB, false)
    hop(b, texB, bufB, true)
    hop(a, texA, bufA, false)

    let seconds = measuredSeconds {
        for _ in 0..<roundTrips {
            hop(a, texA, bufA, true)   // A -> staging
            hop(b, texB, bufB, false)  // staging -> B
            hop(b, texB, bufB, true)   // B -> staging
            hop(a, texA, bufA, false)  // staging -> A
        }
    }
    return seconds / Double(4 * roundTrips)
}

/// Correctness gate for peer results: write a pattern on A, read it back on
/// B. False means the staging route is not usable on this driver/OS and
/// peer rows must be dropped from the report.
func peerCoherenceCheck(_ a: DeviceCtx, _ b: DeviceCtx, staging: Staging) -> Bool {
    let size = min(65_536, staging.stride)
    guard let texA = staging.texture(on: a), let texB = staging.texture(on: b),
          // Shared (host-visible) storage: this check seeds and verifies
          // contents from the CPU, which private buffers do not allow on
          // this driver (see docs/metal/gotchas.md).
          let src = a.device.makeBuffer(length: staging.stride, options: .storageModeShared),
          let dst = b.device.makeBuffer(length: staging.stride, options: .storageModeShared)
    else { return false }
    let pattern = (0..<size).map { UInt8($0 % 251) }
    src.contents().copyMemory(from: pattern, byteCount: size)
    guard let cbA = a.queue.makeCommandBuffer() else { return false }
    enqueueHop(a, cb: cbA, buffer: src, staging: staging, texture: texA, write: true)
    cbA.commit()
    cbA.waitUntilCompleted()
    guard let cbB = b.queue.makeCommandBuffer() else { return false }
    enqueueHop(b, cb: cbB, buffer: dst, staging: staging, texture: texB, write: false)
    cbB.commit()
    cbB.waitUntilCompleted()
    let got = dst.contents().bindMemory(to: UInt8.self, capacity: size)
    return (0..<size).allSatisfy { got[$0] == pattern[$0] }
}

// MARK: - Host <-> GPU (PCIe path, approximations)

/// host -> GPU: CPU memsets a shared (host-backed) buffer, flushes with
/// didModifyRange, then a kernel reads all of it (forcing PCIe inbound
/// traffic). The separately measured CPU memset lets the report subtract
/// host-side cost. Returns (total, cpuMemset) seconds.
func hostUpBandwidth(_ ctx: DeviceCtx, size: Int) -> (total: Double, cpu: Double)? {
    guard let sum = ctx.sumPipeline,
          let buf = ctx.device.makeBuffer(length: size, options: .storageModeShared),
          let out = ctx.device.makeBuffer(length: 4, options: .storageModeShared)
    else { return nil }
    let ptr = buf.contents()

    let cpu = measuredSeconds { memset(ptr, 0x5a, size) }

    guard let warm = ctx.queue.makeCommandBuffer(),
          let warmEnc = warm.makeComputeCommandEncoder()
    else { return nil }
    ctx.dispatch(sum, encoder: warmEnc, bindings: [(0, buf), (2, out)],
                 count: UInt32(size / 16), countIndex: 1)
    warmEnc.endEncoding()
    warm.commit()
    warm.waitUntilCompleted()

    let total = measuredSeconds {
        memset(ptr, 0xa5, size)
        buf.didModifyRange(0..<size)
        guard let cb = ctx.queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder()
        else { return }
        ctx.dispatch(sum, encoder: enc, bindings: [(0, buf), (2, out)],
                     count: UInt32(size / 16), countIndex: 1)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
    return (total, cpu)
}

/// GPU -> host: kernel fills the shared buffer; after completion the CPU
/// reads all of it. On Intel hosts shared buffers are host RAM, so the GPU
/// write crosses PCIe and the CPU read does not; subtracting the
/// separately measured CPU pass isolates the GPU write + flush.
/// Returns (total, cpuRead) seconds.
func hostDownBandwidth(_ ctx: DeviceCtx, size: Int) -> (total: Double, cpu: Double)? {
    guard let fill = ctx.fillPipeline,
          let buf = ctx.device.makeBuffer(length: size, options: .storageModeShared)
    else { return nil }
    let ptr = buf.contents()

    guard let warm = ctx.queue.makeCommandBuffer(),
          let warmEnc = warm.makeComputeCommandEncoder()
    else { return nil }
    ctx.dispatch(fill, encoder: warmEnc, bindings: [(0, buf)],
                 count: UInt32(size / 16), countIndex: 1)
    warmEnc.endEncoding()
    warm.commit()
    warm.waitUntilCompleted()

    let cpu = measuredSeconds {
        var sink: Int = 0
        let bytes = ptr.bindMemory(to: UInt8.self, capacity: size)
        for i in stride(from: 0, to: size, by: 64) { sink &+= Int(bytes[i]) }
        _ = sink
    }
    let total = measuredSeconds {
        guard let cb = ctx.queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder()
        else { return }
        ctx.dispatch(fill, encoder: enc, bindings: [(0, buf)],
                     count: UInt32(size / 16), countIndex: 1)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var sink: Int = 0
        let bytes = ptr.bindMemory(to: UInt8.self, capacity: size)
        for i in stride(from: 0, to: size, by: 64) { sink &+= Int(bytes[i]) }
        _ = sink
    }
    return (total, cpu)
}
