#ifndef CFAST_H
#define CFAST_H
#include <stddef.h>
#include <stdint.h>

/* Cache-line maintenance for host-RAM staging shared between the CPU and a
   PCIe-attached GPU that does not snoop CPU caches (measured on MacPro7,1 +
   AMD MPX: a GPU spin-read of a flag the CPU had just written took ~9.6 ms,
   i.e. it waited for natural eviction of the dirty CPU cache line).

   - cfast_clflush_range(): write back + invalidate, so the GPU sees CPU
     stores immediately.
   - cfast_clinv_range():   invalidate without write back, so the CPU sees
     GPU DMA into host RAM immediately (avoids reading stale cached lines).

   Both target x86 (the Intel MPX Macs this project documents). On arm64
   they are no-ops: Apple Silicon GPU paths are HW coherent. */

#if defined(__x86_64__) || defined(__i386__)
static inline void cfast_clflush(void *p) { __builtin_ia32_clflush(p); }
static inline void cfast_clflush_range(void *p, size_t n) {
    uintptr_t c = (uintptr_t)p & ~(uintptr_t)63;
    for (; (void *)c < (char *)p + n; c += 64) __builtin_ia32_clflush((void *)c);
}
/* Invalidate = clflush: CLFLUSHOPT would SIGILL on CPUs without it, and a
   plain clflush is only unsafe when the line is DIRTY-STALE (its writeback
   would clobber newer GPU data) — a relay protocol must never leave such
   lines: CPU-written regions are flushed before the GPU reads them. */
static inline void cfast_clinv(void *p) { __builtin_ia32_clflush(p); }
static inline void cfast_clinv_range(void *p, size_t n) { cfast_clflush_range(p, n); }
#else
static inline void cfast_clflush(void *p) { (void)p; }
static inline void cfast_clflush_range(void *p, size_t n) { (void)p; (void)n; }
static inline void cfast_clinv(void *p) { (void)p; }
static inline void cfast_clinv_range(void *p, size_t n) { (void)p; (void)n; }
#endif

#endif
