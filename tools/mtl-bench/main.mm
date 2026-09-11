// mtl-bench: Metal API-overhead microbenchmarks on MPX GPUs.
//
// Written in Objective-C++ against the *system* Metal headers rather than
// metal-cpp: metal-cpp ships only through an Apple-ID-gated download, which
// a documentation-first CI cannot depend on, while <Metal/Metal.h> is in the
// Command Line Tools SDK. The API surface measured here is identical.
//
// Emits one JSON document (stdout) with ns/op per benchmark, matching the
// environment-block discipline of the Swift tools (machine block suitable
// for docs/benchmarks/TEMPLATE.md).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <sys/sysctl.h>
#include <ctime>
#include <cstdio>
#include <string>
#include <vector>

static double nowNs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return double(ts.tv_sec) * 1e9 + double(ts.tv_nsec);
}

static std::string sysctlString(const char *name) {
    size_t size = 0;
    if (sysctlbyname(name, nullptr, &size, nullptr, 0) != 0 || size == 0) return "unknown";
    std::string value(size, '\0');
    if (sysctlbyname(name, value.data(), &size, nullptr, 0) != 0) return "unknown";
    value.resize(size - 1);
    return value;
}

// Minimal JSON string escaping (only what device names can contain).
static std::string jsonEscape(NSString *s) {
    std::string out;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            default: out += char(c);
        }
    }
    return out;
}

static void phase(const char *what) {
    std::fprintf(stderr, "mtl-bench: %s\n", what);
    std::fflush(stderr);
}

struct Row {
    std::string name;
    long iters;
    double nsPerOp;
    double bytesPerSecond;  // 0 when not a throughput benchmark
    std::string note;
};

static std::vector<Row> rows;
static bool quietRows = false;

static void addRow(const std::string &name, long iters, double nsPerOp,
                   double bytesPerSecond = 0.0, const std::string &note = "") {
    rows.push_back({name, iters, nsPerOp, bytesPerSecond, note});
    if (quietRows) return;  // --json: stdout carries only the JSON document
    std::printf("mtl-bench: %-28s %10.1f ns/op", name.c_str(), nsPerOp);
    if (bytesPerSecond > 0) std::printf("  %8.2f GB/s", bytesPerSecond / 1e9);
    std::printf("\n");
    std::fflush(stdout);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        bool asJSON = false;
        for (int i = 1; i < argc; i++) {
            std::string arg = argv[i];
            if (arg == "--json") { asJSON = true; quietRows = true; }
            if (arg == "--help" || arg == "-h") {
                std::printf(
                    "usage: mtl-bench [--json]\n\n"
                    "Metal API-overhead microbenchmarks (command buffer,\n"
                    "encoder, small-blit, render-pass setup, dispatch).\n"
                    "Requires a Metal device; emits JSON on --json.\n");
                return 0;
            }
        }

        NSProcessInfo *info = [NSProcessInfo processInfo];
        NSOperatingSystemVersion os = info.operatingSystemVersion;
        NSString *osString = [NSString stringWithFormat:@"%ld.%ld.%ld",
                              (long)os.majorVersion, (long)os.minorVersion,
                              (long)os.patchVersion];
        std::string build = sysctlString("kern.osversion");
        std::string model = sysctlString("hw.model");

        id<MTLDevice> device = MTLCopyAllDevices().firstObject;
        if (device == nil) {
            if (asJSON) {
                std::printf("{\"tool\":\"mtl-bench\",\"version\":\"1\","
                            "\"machine\":{\"model\":\"%s\",\"macOS\":\"%s\","
                            "\"osBuild\":\"%s\"},\"results\":[],"
                            "\"notes\":[\"no Metal device visible\"]}\n",
                            model.c_str(), [osString UTF8String], build.c_str());
            } else {
                std::printf("mtl-bench: no Metal device visible; nothing to measure\n");
            }
            return 0;
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];

        // --- Command buffer allocation --------------------------------------
        phase("commandBuffer.alloc");
        {
            const long N = 20000;
            double t0 = nowNs();
            for (long i = 0; i < N; i++) {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                (void)cb;
            }
            addRow("commandBuffer.alloc", N, (nowNs() - t0) / N);
        }

        // --- Commit of empty command buffers (pipelined) ---------------------
        phase("commandBuffer.commit.empty");
        {
            const long N = 5000;
            double t0 = nowNs();
            id<MTLCommandBuffer> last = nil;
            for (long i = 0; i < N; i++) {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                [cb commit];
                last = cb;
            }
            [last waitUntilCompleted];
            addRow("commandBuffer.commit.empty", N, (nowNs() - t0) / N, 0.0,
                   "pipelined; includes GPU retirement");
        }

        // --- Blit encoder create/end (no work) --------------------------------
        phase("blitEncoder.create.end");
        {
            const long N = 20000;
            double t0 = nowNs();
            for (long i = 0; i < N; i++) {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
                [enc endEncoding];
            }
            addRow("blitEncoder.create.end", N, (nowNs() - t0) / N, 0.0,
                   "includes CB allocation; subtract commandBuffer.alloc");
        }

        // --- Small blit copies (one copy per command buffer) ------------------
        phase("blit.copy");
        {
            // NB: the `options:` parameter takes shifted MTLResourceOptions,
            // not the bare MTLStorageMode* value — MTLResourceStorageModePrivate
            // (== MTLStorageModePrivate << 1). Passing the unshifted constant
            // trips a driver assertion ("Invalid cacheMode 2").
            const MTLResourceOptions priv =
                (MTLResourceOptions)MTLStorageModePrivate << MTLResourceStorageModeShift;
            const size_t sizes[] = {64, 1024, 65536, 1u << 20};
            for (size_t size : sizes) {
                id<MTLBuffer> src = [device newBufferWithLength:size options:priv];
                id<MTLBuffer> dst = [device newBufferWithLength:size options:priv];
                const long N = 2000;
                id<MTLCommandBuffer> last = nil;
                double t0 = nowNs();
                for (long i = 0; i < N; i++) {
                    id<MTLCommandBuffer> cb = [queue commandBuffer];
                    id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
                    [enc copyFromBuffer:src sourceOffset:0
                               toBuffer:dst destinationOffset:0 size:size];
                    [enc endEncoding];
                    [cb commit];
                    last = cb;
                }
                [last waitUntilCompleted];
                double ns = (nowNs() - t0) / N;
                char name[64];
                std::snprintf(name, sizeof name, "blit.copy.%zuB", size);
                addRow(name, N, ns, double(size) / ns * 1e9,
                       "pipelined commits, one copy each");
            }
        }

        // --- Render pass setup (clear attachment, no draws) -------------------
        phase("renderPass.setup");
        {
            MTLTextureDescriptor *texDesc =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                   width:64 height:64
                                                               mipmapped:NO];
            texDesc.usage = MTLTextureUsageRenderTarget;
            id<MTLTexture> target = [device newTextureWithDescriptor:texDesc];
            const long N = 5000;
            double t0 = nowNs();
            for (long i = 0; i < N; i++) {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
                rp.colorAttachments[0].texture = target;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
                id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                [enc endEncoding];
            }
            addRow("renderPass.setup.clear64x64", N, (nowNs() - t0) / N, 0.0,
                   "encoder create+end, no draws, no commits");
        }

        // --- Kernel dispatch overhead -----------------------------------------
        phase("kernel.dispatch");
        {
            NSString *msl = @"#include <metal_stdlib>\n"
                             "using namespace metal;\n"
                             "kernel void nop() {}";
            NSError *error = nil;
            id<MTLLibrary> lib = [device newLibraryWithSource:msl options:nil error:&error];
            id<MTLFunction> fn = lib ? [lib newFunctionWithName:@"nop"] : nil;
            id<MTLComputePipelineState> pipeline =
                fn ? [device newComputePipelineStateWithFunction:fn error:&error] : nil;
            if (pipeline == nil) {
                rows.push_back({"kernel.dispatch", 0, 0.0, 0.0,
                                "compute pipeline unavailable: " +
                                    std::string(error ? [error localizedDescription].UTF8String
                                                      : "unknown")});
            } else {
                // Pipelined dispatches inside one command buffer: pure encoder
                // dispatch cost.
                const long N = 100000;
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                [enc setComputePipelineState:pipeline];
                double t0 = nowNs();
                for (long i = 0; i < N; i++) {
                    [enc dispatchThreads:MTLSizeMake(1, 1, 1)
                   threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                }
                [enc endEncoding];
                double nsEncode = (nowNs() - t0) / N;
                [cb commit];
                [cb waitUntilCompleted];
                addRow("kernel.dispatch.encode", N, nsEncode, 0.0,
                       "1x1 dispatches encoded into one CB");

                // One dispatch committed per command buffer: full submit cost.
                const long M = 5000;
                id<MTLCommandBuffer> last = nil;
                t0 = nowNs();
                for (long i = 0; i < M; i++) {
                    id<MTLCommandBuffer> cb1 = [queue commandBuffer];
                    id<MTLComputeCommandEncoder> e = [cb1 computeCommandEncoder];
                    [e setComputePipelineState:pipeline];
                    [e dispatchThreads:MTLSizeMake(1, 1, 1)
                 threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                    [e endEncoding];
                    [cb1 commit];
                    last = cb1;
                }
                [last waitUntilCompleted];
                addRow("kernel.dispatch.commit", M, (nowNs() - t0) / M, 0.0,
                       "pipelined commits, one 1x1 dispatch each");
            }
        }

        // --- Output -------------------------------------------------------------
        if (!asJSON) return 0;
        std::printf("{\n  \"tool\": \"mtl-bench\",\n  \"version\": \"1\",\n");
        std::printf("  \"machine\": {\"model\": \"%s\", \"macOS\": \"%s\", \"osBuild\": \"%s\"},\n",
                    model.c_str(), [osString UTF8String], build.c_str());
        std::printf("  \"device\": \"%s\",\n  \"results\": [\n",
                    jsonEscape(device.name).c_str());
        for (size_t i = 0; i < rows.size(); i++) {
            const Row &r = rows[i];
            std::printf("    {\"benchmark\": \"%s\", \"iterations\": %ld, \"nsPerOp\": %.1f",
                        r.name.c_str(), r.iters, r.nsPerOp);
            if (r.bytesPerSecond > 0) std::printf(", \"bytesPerSecond\": %.0f", r.bytesPerSecond);
            if (!r.note.empty()) std::printf(", \"note\": \"%s\"", r.note.c_str());
            std::printf("}%s\n", i + 1 < rows.size() ? "," : "");
        }
        std::printf("  ]\n}\n");
    }
    return 0;
}
