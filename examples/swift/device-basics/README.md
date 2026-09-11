# device-basics

Swift example: enumerate `MTLDevice`s, select one by policy (family support,
working-set size), and print a capability report. On Duo cards it should
identify which devices share a physical module (using the same registry
correlations as `gpu-probe`).

**Status:** scaffolded (Phase 4 will implement). Currently prints a stub.
