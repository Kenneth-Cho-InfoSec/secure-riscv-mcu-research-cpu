# Secure RISC-V MCU Research CPU

This repository is a Verilog hardware project for experimenting with a cybersecurity-focused RISC-V CPU. It started as a small educational RV32I processor and was deliberately pushed toward a more realistic secure embedded processor: privilege separation, trap handling, CSR state, memory isolation, interrupt handling, and a second performance-oriented pipeline/cache/MMU prototype.

The current repository intentionally removes the original simple teaching CPU and keeps the new secured work only:

- `secure_riscv_mcu.v`: the main security-focused multi-cycle RV32I MCU core
- `pipelined_cached_mmu_cpu.v`: an experimental performance core with pipeline, cache counters, and MMU/TLB-style translation
- security and performance testbenches
- generated machine-code programs used by the simulations
- scripts for running the project through WSL Icarus Verilog
- VS Code waveform launchers for Surfer/VCD viewing

The goal is not to claim this is production silicon. The goal is to create a readable, hackable CPU research platform where security behavior is visible in the RTL and in simulation waveforms.

## Why This Exists

Modern cybersecurity does not stop at software. Firmware, boot ROM, MMU setup, privilege boundaries, traps, interrupt handlers, memory permissions, control-flow transfer, and hardware state all affect exploitability. A CPU can make whole classes of bugs easier or harder to exploit depending on how it handles memory access, privilege, and fault containment.

This project is meant to explore those ideas from the hardware side. It gives you a small RISC-V core where you can inspect every control signal and ask questions such as:

- What happens when user code writes to executable memory?
- Does a faulting store corrupt memory before the trap is raised?
- Can machine-mode firmware lock down memory permissions?
- Can user mode read or write machine-only data?
- Does `mret` return to the intended privilege level?
- Are traps precise enough for a secure recovery path?
- What debug signals are useful when validating a secure CPU?
- How much performance can a simple pipeline recover while still keeping memory translation visible?

The core is intentionally simple enough to read but complex enough to behave like more than a toy adder machine.

## Repository Layout

```text
rtl/
  secure_riscv_mcu.v             Main secure multi-cycle RV32I MCU core
  pipelined_cached_mmu_cpu.v     Experimental performance pipeline/cache/MMU core

tb/
  tb_secure_mcu.v                Security validation testbench
  tb_pipelined_cached_mmu.v      Pipeline/cache/MMU performance testbench

programs/
  secure.hex                     Generated secure MCU machine code
  secure.list                    Secure MCU listing
  perf.hex                       Generated performance benchmark machine code
  perf.list                      Performance benchmark listing

scripts/
  make_secure_program.js         Generates secure.hex and secure.list
  make_perf_program.js           Generates perf.hex and perf.list
  run_secure_wsl_iverilog.ps1    Runs secure MCU simulation through WSL Icarus
  run_pipeline_wsl_iverilog.ps1  Runs pipeline/cache/MMU simulation through WSL Icarus
  launch_secure_wave_vscode.ps1  Opens secure_cpu.vcd in VS Code
  launch_pipeline_wave_vscode.ps1 Opens pipelined_cached_mmu.vcd in VS Code

SECURE_MCU.md                    Secure MCU architecture notes
PIPELINE_CACHE_MMU.md            Pipeline/cache/MMU notes
DEBUGGING_NOTES.md               Bring-up and validation notes
```

Generated waveform and simulator output files go in `build/` and are ignored by Git.

## Main Core: Secure RV32I MCU

The main CPU is `rtl/secure_riscv_mcu.v`. It is a multi-cycle RV32I-style embedded core with explicit security behavior.

The core has these major states:

- fetch
- decode
- execute
- memory
- writeback
- trap

This was chosen instead of immediately jumping to a complicated superscalar pipeline because the security behavior needs to be understandable. A multi-cycle core makes it easier to reason about when an instruction commits, when a trap takes control, and whether memory side effects are contained.

### Implemented ISA and CPU Features

The secure MCU core implements a practical RV32I subset:

- arithmetic and logical operations
- immediate arithmetic
- loads and stores
- branches
- jumps
- `lui`
- `auipc`
- `ecall`
- `mret`
- `Zicsr` CSR operations:
  - `csrrw`
  - `csrrs`
  - `csrrc`
  - immediate CSR forms

The CPU has two privilege modes:

- machine mode
- user mode

Supervisor mode and virtual memory are intentionally not part of the secure MCU core yet. This keeps the first secure milestone focused on embedded isolation, PMP-style checks, and trap correctness.

### CSR Support

The secure MCU core includes the CSR state needed for an embedded security bring-up:

- `mstatus`
- `mtvec`
- `mepc`
- `mcause`
- `mtval`
- `mie`
- `mip`
- `mscratch`
- `mcycle`
- `minstret`
- `misa`
- `mhartid`

These CSRs are not merely decorative. The secure test program uses them to set the trap vector, enable interrupts, return from traps, read trap causes, check trap values, and transition into user mode.

### Trap and Interrupt Behavior

The core supports:

- illegal instruction traps
- instruction access faults
- load access faults
- store access faults
- user and machine `ecall`
- machine timer interrupt input
- machine software interrupt input
- machine external interrupt input
- `mret`

The important security property tested here is fault containment. A denied user store must not modify memory before the trap handler runs. The testbench checks that behavior directly.

## PMP-Style Memory Isolation

The secure MCU includes eight PMP-style protection regions. Each region has:

- base address
- limit address
- read permission
- write permission
- execute permission
- user-access permission
- lock bit

The reset configuration creates a small secure memory map:

```text
0x00000000..0x000000ff  machine boot/trap code, read/execute, locked
0x00000100..0x0000017f  user text, read/execute/user, locked
0x00000200..0x000002ff  user data, read/write/user, locked
0x00000300..0x0000037f  machine result data, read/write, locked
```

The secure test program validates that:

- machine-mode firmware starts first
- `mtvec` can be installed
- interrupts can be enabled
- locked PMP entries cannot be modified
- `mret` can enter user mode
- user mode can access user RAM
- user mode cannot write to protected executable memory
- a failed store traps cleanly
- the failed store does not modify memory
- the trap handler can recover and continue
- user `ecall` returns control to machine mode

Custom research CSRs are used for the simplified PMP model:

```text
pmpcfg0      0x3a0
pmpbase0..7 0x7c0..0x7c7
pmplimit0..7 0x7d0..0x7d7
```

This is not a complete implementation of the official RISC-V PMP encoding. It is a readable PMP-style model designed to make the memory-isolation mechanism explicit and easy to test.

## Performance Prototype: Pipeline, Cache, and MMU

The second core is `rtl/pipelined_cached_mmu_cpu.v`. It is an experimental performance core built to explore the next step after a secure multi-cycle CPU.

It includes:

- 5-stage pipeline:
  - fetch
  - decode
  - execute
  - memory
  - writeback
- ALU forwarding
- load-use stall detection
- branch/jump flush handling
- direct-mapped instruction cache tag array
- direct-mapped data cache tag array
- a tiny four-entry MMU/TLB-style translator
- read/write/execute permission checks in the translation path
- debug counters for:
  - cycles
  - retired instructions
  - instruction-cache hits/misses
  - data-cache hits/misses
  - MMU hits/faults
  - stalls
  - flushes

The performance prototype is not the main security reference. It exists to explore how much complexity is needed before performance improves meaningfully, and to establish the next direction for a higher-frequency or higher-throughput CPU.

The current benchmark passes with a modeled speedup greater than 3x:

```text
PASS: pipelined cached MMU CPU completed benchmark with >=3x modeled speedup
PERF: baseline_cycles=400 pipeline_cycles=106 speedup_x100=377
```

That means the benchmark measured a modeled 3.77x improvement over the simple multi-cycle baseline assumption used in the testbench.

## How to Run

This project was developed on Windows with WSL Ubuntu because local Windows application control blocked some standalone HDL tools. The simulations use Icarus Verilog installed inside WSL.

### Run the Secure MCU Test

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_secure_wsl_iverilog.ps1
```

Expected output:

```text
PASS: secure MCU interrupt, CSR, privilege, PMP, trap, and containment checks passed
```

This creates:

```text
build/secure_cpu.vcd
```

Open the waveform:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/launch_secure_wave_vscode.ps1
```

### Run the Pipeline/Cache/MMU Test

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_pipeline_wsl_iverilog.ps1
```

Expected output:

```text
PASS: pipelined cached MMU CPU completed benchmark with >=3x modeled speedup
```

This creates:

```text
build/pipelined_cached_mmu.vcd
```

Open the waveform:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/launch_pipeline_wave_vscode.ps1
```

## Waveform Viewing

The easiest viewer path on this machine is VS Code plus the Surfer waveform extension.

Install Surfer:

```powershell
code --install-extension surfer-project.surfer --force
```

Then run one of the waveform launcher scripts.

Standalone GTKWave and OSS CAD Suite were also explored, but Windows Device Guard blocked some binaries and DLLs. VS Code with Surfer was the most reliable path in this environment.

## Validation Status

Current passing checks:

```text
PASS: secure MCU interrupt, CSR, privilege, PMP, trap, and containment checks passed
PASS: pipelined cached MMU CPU completed benchmark with >=3x modeled speedup
```

The secure MCU test validates the actual security path:

- machine-mode boot
- trap-vector setup
- timer interrupt entry
- CSR read/write/set/clear behavior
- PMP lock behavior
- user-mode entry
- allowed user memory access
- forbidden user write into protected executable memory
- store-fault trap
- `mtval` reporting
- recovery through `mret`
- final user `ecall`

The pipeline/cache/MMU test validates the performance path:

- register forwarding
- pipeline progression
- memory store/load
- cache hit/miss counters
- MMU translation counters
- halt handling after pipeline drain
- 3x-plus modeled performance target

## Challenges Faced

This project had several real hardware-development problems rather than just coding problems.

### Moving from a Toy CPU to a Security CPU

The first challenge was architectural. A small one-cycle CPU can execute instructions, but it has no meaningful security story. There is no privilege boundary, no trap entry, no machine state, no memory policy, and no way to explain what happens when software misbehaves.

To make the CPU cybersecurity-focused, the design had to gain control state:

- privilege mode
- trap cause
- exception PC
- trap value
- interrupt enable state
- memory permissions
- locked configuration
- fault containment

That changed the design from “execute an instruction” to “execute an instruction only if the current privilege and memory policy allow it, and otherwise trap without committing unsafe side effects.”

### Getting Fault Containment Right

The most important security behavior was making sure a faulting memory operation does not partially succeed. A denied store should not write memory and then report a trap. It should report a trap instead of writing memory.

The testbench checks this directly by having user-mode code try to write to address `0x00000000`, which belongs to the locked machine boot/trap region. The final pass condition confirms that memory at address zero is still unchanged.

### CSR Semantics

CSRs look simple until they interact with privilege transitions. The core had to support enough CSR behavior to make real trap flow possible:

- `mtvec` for trap entry
- `mepc` for return address
- `mcause` for why the trap happened
- `mtval` for the faulting address or value
- `mstatus` for interrupt enable and previous privilege
- `mie` and `mip` for interrupt behavior

The secure program uses these features instead of relying on testbench magic.

### Timer Interrupt Timing

During bring-up, the timer interrupt initially fired too early. The pulse happened before the firmware had fully enabled `mie` and `mstatus.MIE`, so the program sat in its wait loop forever.

The fix was not to fake the result, but to move the interrupt pulse later in the testbench so the CPU had actually enabled interrupts before the event arrived. This is exactly the kind of timing bug that real firmware and hardware teams hit.

### Locked PMP Behavior

The secure program reads a locked PMP base register, tries to overwrite it, reads it again, and branches to failure if it changed. That forced the RTL to enforce lock semantics on configuration writes.

This matters because memory protection is not useful if compromised code can simply rewrite the protection map.

### Windows Tooling Problems

The development environment also fought back. Native Windows `iverilog` was not available at first, so simulation moved to WSL Ubuntu. Then waveform viewers had their own problems:

- OSS CAD Suite downloaded correctly
- `iverilog.exe` was blocked by Windows Application Control
- GTKWave initially failed with a missing `libbz2-1.dll`
- after fixing PATH, GTKWave hit a GTK DLL bad-image error
- standalone GTKWave was blocked by Device Guard
- Surfer inside VS Code became the reliable waveform path

This is why the scripts use WSL for simulation and VS Code for waveform viewing.

### Pipeline Halt and Drain

The performance core exposed a classic pipeline issue: a halt self-loop can be detected in execute, but younger and older instructions may still be in flight. The first halt detector stopped too early, before the final load had written back.

The fix was to add a short halt-drain counter so the last memory/writeback stages can complete before the testbench checks final architectural state.

### Performance vs. Honesty

The 3x benchmark is modeled and simulation-based. It is useful, but it is not the same as claiming a real chip frequency. A real 1 GHz goal requires synthesis, timing constraints, a technology library, and static timing analysis.

This repository now has the structure needed to move in that direction, but timing closure is future work.

## Current Limitations

The project is intentionally not pretending to be finished silicon.

Known limitations:

- no full official PMP encoding
- no supervisor mode
- no Sv32 page tables
- no atomics
- no caches with realistic refill latency
- no branch prediction
- no synthesis timing signoff yet
- no formal verification yet
- no external bus protocol such as AXI or Wishbone yet
- no real firmware toolchain integration yet

Those limitations are also the roadmap.

## Roadmap

The next milestones are:

1. Replace the simplified PMP CSRs with a more spec-like PMP model.
2. Add an external memory bus interface.
3. Add real cache refill/miss FSMs.
4. Expand the MMU from a fixed TLB model toward Sv32-style translation.
5. Add more security tests for illegal CSR access and instruction-fetch faults.
6. Add formal assertions for fault containment and privilege rules.
7. Add synthesis scripts and timing reports.
8. Build a deeper timing-oriented pipeline for a credible high-frequency target.
9. Explore control-flow integrity features such as shadow stack or branch target policy.
10. Add optional crypto helper instructions after the privilege/memory model is stronger.

## Project Purpose

This project is for learning, research, and experimentation. It is meant to be a hands-on place to study the intersection of:

- CPU architecture
- RISC-V
- embedded security
- privilege isolation
- memory protection
- trap handling
- hardware verification
- pipeline performance
- practical HDL toolchains

It is not meant to be dropped into a product. It is meant to be read, simulated, broken, improved, and used as a stepping stone toward more serious secure CPU design.
