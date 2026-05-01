# Secure RISC-V MCU Core

`rtl/secure_riscv_mcu.v` is the main security-focused RV32I MCU core in this repository. It uses a simple multi-cycle FSM so privilege checks, traps, and memory-protection behavior remain easy to inspect.

## Architecture

Implemented states:

- fetch
- decode
- execute
- memory
- writeback
- trap

Implemented execution features:

- RV32I arithmetic, branches, jumps, loads, stores, `lui`, `auipc`
- `Zicsr` CSR operations: `csrrw`, `csrrs`, `csrrc`, and immediate forms
- machine and user privilege modes
- `ecall` and `mret`
- machine timer, software, and external interrupt inputs
- trap CSRs: `mstatus`, `mtvec`, `mepc`, `mcause`, `mtval`, `mie`, `mip`, `mscratch`, `mcycle`, `minstret`, `misa`, `mhartid`

## PMP-Style Memory Protection

The core has eight PMP-style regions. Each region has:

- base address
- limit address
- `R/W/X` permissions
- user-access bit
- lock bit

The first four regions are initialized and locked at reset:

- `0x00000000..0x000000ff`: machine boot/trap code, read/execute
- `0x00000100..0x0000017f`: user text, read/execute/user
- `0x00000200..0x000002ff`: user data, read/write/user
- `0x00000300..0x0000037f`: machine result data, read/write

PMP checks are applied to instruction fetches, loads, and stores. Faulting loads/stores do not commit register or memory side effects.

Custom PMP CSRs used by this research core:

- `pmpcfg0`: `0x3a0`, four 8-bit config entries
- `pmpbase0..7`: `0x7c0..0x7c7`
- `pmplimit0..7`: `0x7d0..0x7d7`

## Secure Test Program

`programs/secure.hex` is generated from `scripts/make_secure_program.js`.

The test program:

1. boots in machine mode
2. installs `mtvec`
3. enables a timer interrupt
4. verifies the interrupt handler runs
5. verifies a locked PMP entry cannot be modified
6. enters user mode using `mret`
7. performs allowed user RAM store/load
8. attempts a forbidden user write into executable ROM
9. verifies the store fault trap and `mtval`
10. resumes user mode and exits via user `ecall`

Pass criteria:

- `mem32[0x300] = 1`
- `mem32[0x304] = 1`
- `mem32[0x200] = 7`
- `mem32[0x000] = 0`
- final `mcause = 8`
- final privilege is machine mode

## Run

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_secure_wsl_iverilog.ps1
powershell -ExecutionPolicy Bypass -File scripts/launch_secure_wave_vscode.ps1
```

Expected simulation result:

```text
PASS: secure MCU interrupt, CSR, privilege, PMP, trap, and containment checks passed
```
