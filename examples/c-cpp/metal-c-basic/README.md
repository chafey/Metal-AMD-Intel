# metal-c-basic

Minimal compute pipeline written against **Metal-c** (objc-free C API, macOS
13.3+; our minimum target is macOS 14) with a Metal-cpp shim where the C API
is too thin. Demonstrates device/library/buffer/queue setup and a dispatch
with no Objective-C or Swift in sight.

**Status:** planned (Phase 4). Builds via CMake from the root `Makefile`.
