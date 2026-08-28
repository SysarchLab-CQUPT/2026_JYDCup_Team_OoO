param(
  [ValidateSet(50, 150, 200, 250, 270)]
  [int]$SocClockMHz = 50
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Vivado = 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
if (-not (Test-Path -LiteralPath $Vivado)) { throw "Vivado 2025.2 not found: $Vivado" }

$PreviousSocClockMHz = $env:JYD_SOC_CLK_MHZ
$env:JYD_SOC_CLK_MHZ = $SocClockMHz.ToString()

try {
  & (Join-Path $ProjectRoot 'software\build_firmware.ps1') `
    -Target rtthread_board -SocClockMHz $SocClockMHz
  if ($LASTEXITCODE -ne 0) { throw 'RT-Thread/CoreMark board firmware build failed' }

  & $Vivado -mode batch -source (Join-Path $PSScriptRoot 'run_synth.tcl') -notrace
  if ($LASTEXITCODE -ne 0) { throw 'Vivado synthesis failed' }

  & $Vivado -mode batch -source (Join-Path $PSScriptRoot 'run_impl.tcl') -notrace
  if ($LASTEXITCODE -ne 0) { throw 'Vivado implementation/sign-off failed; no bitstream was published' }

  $Bitstream = Join-Path $ProjectRoot "reports\impl\jyd_soc_top_rtthread_coremark_${SocClockMHz}mhz.bit"
  Write-Host "Board bitstream: $Bitstream"
} finally {
  $env:JYD_SOC_CLK_MHZ = $PreviousSocClockMHz
}
