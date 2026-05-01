# Pipelined Cached MMU CPU

`rtl/pipelined_cached_mmu_cpu.v` is an experimental performance-focused RV32I core added beside the secure MCU core.

## Implemented Features

- 5-stage pipeline: fetch, decode, execute, memory, writeback
- ALU forwarding from later pipeline stages into execute
- Load-use stall detection
- Branch/jump flush handling
- Direct-mapped 8-entry instruction cache tag array
- Direct-mapped 8-entry data cache tag array
- 4-entry page-translation table used as a tiny MMU/TLB model
- Execute/read/write permission checks in the MMU translation path
- Debug counters for cycles, retired instructions, cache hits/misses, MMU hits/faults, stalls, and flushes

This is a performance research core, not a full privileged RISC-V implementation. It does not replace the secure MCU core's trap/CSR/PMP validation.

## Performance Goal

The benchmark in `programs/perf.hex` performs a dependency-heavy arithmetic chain, store, load, and halt. The testbench compares the pipelined run against a modeled multi-cycle baseline of 400 cycles for the same instruction stream.

Observed passing run:

```text
PASS: pipelined cached MMU CPU completed benchmark with >=3x modeled speedup
PERF: baseline_cycles=400 pipeline_cycles=106 speedup_x100=377
```

That is a measured/modelled speedup of 3.77x.

## Run

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_pipeline_wsl_iverilog.ps1
powershell -ExecutionPolicy Bypass -File scripts/launch_pipeline_wave_vscode.ps1
```

Generated artifacts:

- `programs/perf.hex`
- `programs/perf.list`
- `build/pipelined_cached_mmu.vcd`

## Current Limitations

- Caches currently model tag lookup and hit/miss accounting, not multi-cycle refill latency.
- The MMU is a tiny fixed TLB-style translator, not Sv32.
- The benchmark targets ALU throughput and simple memory operations.
- The secure MCU core remains the reference for CSRs, traps, interrupts, and PMP-style isolation.
