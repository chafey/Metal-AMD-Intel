# Metal Gotchas on MPX / Intel Hosts

A running log of driver, IOAccelerator, and OS-level surprises. Each entry:
symptom, affected configuration, workaround, and OS/driver version observed.

## Template for new entries

```md
### <short title>
- **Affects:** <card(s)>, macOS x.y, IOAccelerator kext version
- **Symptom:** what you see
- **Repro:** minimal case or tool invocation
- **Workaround:** what works
- **Status:** workaround-only / fixed in x.y / filed with Apple
```

## Known issues

### (placeholder) Duo partition co-scheduling stalls
- **Affects:** W6800X Duo, macOS 14.x — TODO: confirm
- **Symptom:** TODO: describe observed stalls when both partitions run heavy
  concurrent workloads
- **Repro:** `tools/if-bench --mode concurrent-load`
- **Workaround:** TODO
- **Status:** investigating

> Replace this placeholder with verified findings only; each entry must be
> reproducible with a checked-in tool or example.
