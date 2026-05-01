$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

node scripts/make_perf_program.js

$linuxRoot = "/mnt/c/Users/kenneth/Documents/riscv_cpu_verilog"
wsl -d Ubuntu -- bash -lc "cd '$linuxRoot' && mkdir -p build && iverilog -g2012 -Wall -o build/pipelined_cached_mmu_tb.vvp rtl/pipelined_cached_mmu_cpu.v tb/tb_pipelined_cached_mmu.v && vvp build/pipelined_cached_mmu_tb.vvp"
