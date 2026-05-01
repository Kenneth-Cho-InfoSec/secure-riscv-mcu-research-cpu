$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

node scripts/make_secure_program.js

$linuxRoot = "/mnt/c/Users/kenneth/Documents/riscv_cpu_verilog"
wsl -d Ubuntu -- bash -lc "cd '$linuxRoot' && mkdir -p build && iverilog -g2012 -Wall -o build/secure_cpu_tb.vvp rtl/secure_riscv_mcu.v tb/tb_secure_mcu.v && vvp build/secure_cpu_tb.vvp"
