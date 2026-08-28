param(
    [string]$AuditTag = 'uart_physical_20260814'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Vivado = 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
$AuditRoot = Join-Path $ProjectRoot "reports\audit\$AuditTag"

$Stages = [ordered]@{
    synth = 'reports\synth\jyd_soc_top_synth.dcp'
    opt = 'reports\impl\pre_route\jyd_soc_top_opt.dcp'
    place = 'reports\impl\pre_route\jyd_soc_top_placed.dcp'
    physopt = 'reports\impl\pre_route\jyd_soc_top_physopt.dcp'
    route = 'reports\impl\jyd_soc_top_route.dcp'
    postroute_physopt = 'reports\impl\jyd_soc_top_postroute_physopt.dcp'
    reroute = 'reports\impl\jyd_soc_top_reroute.dcp'
    final_route = 'reports\impl\jyd_soc_top_final_route.dcp'
}

New-Item -ItemType Directory -Force -Path $AuditRoot | Out-Null
foreach ($entry in $Stages.GetEnumerator()) {
    $Dcp = Join-Path $ProjectRoot $entry.Value
    if (-not (Test-Path -LiteralPath $Dcp)) {
        throw "Missing checkpoint for $($entry.Key): $Dcp"
    }
    $StageDir = Join-Path $AuditRoot $entry.Key
    New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
    $env:JYD_UART_AUDIT_DCP = $Dcp
    $env:JYD_UART_AUDIT_STAGE = $entry.Key
    $env:JYD_UART_AUDIT_OUT = Join-Path $StageDir 'uart_physical_audit.txt'
    & $Vivado -mode batch -notrace -source (Join-Path $PSScriptRoot 'audit_uart_physical_path.tcl') `
      -log (Join-Path $StageDir 'vivado.log') -journal (Join-Path $StageDir 'vivado.jou')
    if ($LASTEXITCODE -ne 0) {
        throw "UART physical audit failed at $($entry.Key)"
    }
}

Remove-Item Env:JYD_UART_AUDIT_DCP -ErrorAction SilentlyContinue
Remove-Item Env:JYD_UART_AUDIT_STAGE -ErrorAction SilentlyContinue
Remove-Item Env:JYD_UART_AUDIT_OUT -ErrorAction SilentlyContinue
Write-Host "PASS all-stage UART physical audit: $AuditRoot"
