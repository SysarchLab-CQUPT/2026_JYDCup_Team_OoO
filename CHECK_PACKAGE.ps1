$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Required = @(
    'README.md', 'BUILD_150MHZ.ps1', 'CHECK_PACKAGE.ps1', 'SHA256SUMS.txt',
    'constraints\board.xdc', 'ip\pll\pll.xci',
    'flow\create_project.tcl', 'flow\rebuild_current_150mhz_bit.tcl',
    'flow\rebuild_direct_overclock_bit.tcl',
    'rtl\soc\jyd_soc_top.sv', 'software\build_firmware.ps1',
    'reference\accepted_route\jyd_soc_top_150mhz_accepted_route.dcp',
    'reference\current_bit\jyd_soc_top_rtthread_coremark_150mhz.bit',
    'reference\board_tested_200mhz\JYD2025_200MHz_CoreMark18000_BOARD_TESTED_723iters.bit'
)
foreach ($Relative in $Required) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $Relative))) {
        throw "Missing package file: $Relative"
    }
}

$Manifest = Join-Path $Root 'SHA256SUMS.txt'
foreach ($Line in Get-Content -LiteralPath $Manifest) {
    if ([string]::IsNullOrWhiteSpace($Line)) { continue }
    $Parts = $Line -split '  ', 2
    if ($Parts.Count -ne 2) { throw "Invalid manifest line: $Line" }
    $Path = Join-Path $Root ($Parts[1] -replace '/', '\')
    if (-not (Test-Path -LiteralPath $Path)) { throw "Manifest file missing: $($Parts[1])" }
    $Actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    if ($Actual -ne $Parts[0]) { throw "Hash mismatch: $($Parts[1])" }
}
Write-Host 'PACKAGE_CHECK=PASS'
