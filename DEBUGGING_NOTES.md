# Debugging Notes

## Secure MCU Bring-Up

The secure MCU core was added as `rtl/secure_riscv_mcu.v` and tested with `tb/tb_secure_mcu.v`.

Validation command:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_secure_wsl_iverilog.ps1
```

Observed result:

```text
PASS: secure MCU interrupt, CSR, privilege, PMP, trap, and containment checks passed
```

Important fixes during bring-up:

1. Replaced indexed expression alignment checks with explicit address masks so Icarus Verilog accepts the code.
2. Moved the timer IRQ pulse later in the testbench so it occurs after `mie` and `mstatus.MIE` are enabled.
3. Corrected the testbench halt detector to the generated secure program's `<halt>` label at `0x000000a4`.

## Pipelined Cached MMU Bring-Up

The performance core was added as `rtl/pipelined_cached_mmu_cpu.v` and tested with `tb/tb_pipelined_cached_mmu.v`.

Validation command:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_pipeline_wsl_iverilog.ps1
```

Observed result:

```text
PASS: pipelined cached MMU CPU completed benchmark with >=3x modeled speedup
PERF: baseline_cycles=400 pipeline_cycles=106 speedup_x100=377
```

Important fixes during bring-up:

1. Added execute-stage recognition of the halt self-loop because branch/jump flush prevents the jump from reaching later pipeline stages.
2. Added a short halt-drain counter so the final load can write back before the simulation stops.

## Tooling Notes

Native Windows HDL tooling was blocked or incomplete on this machine. WSL Ubuntu with Icarus Verilog is the reliable simulation path.

Waveform viewing through standalone GTKWave and OSS CAD Suite was blocked by Windows Device Guard/Application Control. VS Code with the Surfer extension is the reliable waveform path.
