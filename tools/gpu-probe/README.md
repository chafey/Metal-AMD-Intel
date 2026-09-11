# gpu-probe

Enumerates every `MTLDevice` and its backing IOKit registry properties, plus
machine/OS/driver environment, in a form that can be pasted directly into a
benchmark report (see `docs/benchmarks/TEMPLATE.md`).

**Status:** scaffolded (Phase 2 will implement). Currently prints a stub.

Planned output:

- Machine model, CPU, RAM, macOS + IOAccelerator versions
- Per `MTLDevice`: name, `registryID`, `location`/`entryPoint`,
  `recommendedMaxWorkingSetSize`, family/feature-set support
- Per backing `IOPCIDevice`: `device-id`, `revision-id`, `subsystem-vendor-id`,
  `AAPL,slot-name`, negotiated link width/speed
- Duo-partition correlation hints (which devices share a physical module)
