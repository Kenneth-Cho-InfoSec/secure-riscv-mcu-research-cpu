$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$vcd = Join-Path $root "build\pipelined_cached_mmu.vcd"

if (!(Test-Path $vcd)) {
    throw "Waveform not found: $vcd. Run scripts\run_pipeline_wsl_iverilog.ps1 first."
}

code --reuse-window $root $vcd
