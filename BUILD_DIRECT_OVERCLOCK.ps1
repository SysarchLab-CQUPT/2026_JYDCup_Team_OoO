param(
    [ValidateSet(200, 250)]
    [int]$SocClockMHz = 200,
    [string]$VivadoBat = 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$AcceptedDcp = Join-Path $Root 'reference\accepted_route\jyd_soc_top_150mhz_accepted_route.dcp'
$FirmwareMem = Join-Path $Root 'software\build\rtthread_board\rtthread_board.mem'
$OutputDir = Join-Path $Root "output\direct_${SocClockMHz}mhz"
$OutputDcp = Join-Path $OutputDir "jyd_soc_top_${SocClockMHz}mhz_direct.dcp"
$OutputBit = Join-Path $OutputDir "jyd_soc_top_rtthread_coremark_${SocClockMHz}mhz_direct.bit"

if (-not (Test-Path -LiteralPath $VivadoBat)) {
    throw "Vivado 2025.2 not found: $VivadoBat"
}

& (Join-Path $Root 'software\build_firmware.ps1') `
    -Target rtthread_board -SocClockMHz $SocClockMHz -OptimizationLevel O3
if ($LASTEXITCODE -ne 0) { throw 'Firmware build failed' }

& $VivadoBat -mode batch -notrace `
    -source (Join-Path $Root 'flow\rebuild_direct_overclock_bit.tcl') `
    -tclargs $Root $AcceptedDcp $FirmwareMem $OutputDir $OutputDcp $OutputBit $SocClockMHz
if ($LASTEXITCODE -ne 0) { throw 'Direct overclock bit generation failed' }

Write-Host "Direct-overclock bit: $OutputBit"
