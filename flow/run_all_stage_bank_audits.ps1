[CmdletBinding()]
param(
    [string]$AuditTag = 'banked_storage_20260814'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$vivado = 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
$auditTcl = Join-Path $PSScriptRoot 'audit_banked_storage_placement.tcl'
$auditRoot = Join-Path $projectRoot "reports\audit\$AuditTag"

$stages = [ordered]@{
    synth             = 'reports\synth\jyd_soc_top_synth.dcp'
    opt               = 'reports\impl\pre_route\jyd_soc_top_opt.dcp'
    place             = 'reports\impl\pre_route\jyd_soc_top_placed.dcp'
    physopt           = 'reports\impl\pre_route\jyd_soc_top_physopt.dcp'
    route             = 'reports\impl\jyd_soc_top_route.dcp'
    postroute_physopt = 'reports\impl\jyd_soc_top_postroute_physopt.dcp'
    reroute           = 'reports\impl\jyd_soc_top_reroute.dcp'
    final_route       = 'reports\impl\jyd_soc_top_final_route.dcp'
}

foreach ($stage in $stages.Keys) {
    $dcp = Join-Path $projectRoot $stages[$stage]
    if (-not (Test-Path -LiteralPath $dcp)) {
        throw "Missing $stage checkpoint: $dcp"
    }
    $stageDir = Join-Path $auditRoot $stage
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
    $env:JYD_AUDIT_DCP = $dcp
    $env:JYD_AUDIT_STAGE = $stage
    $env:JYD_AUDIT_SKIP_TIMING = '1'
    & $vivado -mode batch -source $auditTcl -notrace `
        -log (Join-Path $stageDir 'vivado.log') `
        -journal (Join-Path $stageDir 'vivado.jou')
    if ($LASTEXITCODE -ne 0) {
        throw "Vivado bank audit failed at stage $stage (exit $LASTEXITCODE)"
    }
}

Remove-Item Env:JYD_AUDIT_DCP -ErrorAction SilentlyContinue
Remove-Item Env:JYD_AUDIT_STAGE -ErrorAction SilentlyContinue
Remove-Item Env:JYD_AUDIT_SKIP_TIMING -ErrorAction SilentlyContinue
Write-Output "ALL_STAGE_BANK_AUDITS=$auditRoot"
