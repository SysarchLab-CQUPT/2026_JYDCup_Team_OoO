[CmdletBinding()]
param(
    [string]$AuditTag = 'banked_storage_20260814',
    [string[]]$Stages = @()
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputDir = Join-Path $projectRoot "reports\audit\$AuditTag"
$outputFile = Join-Path $outputDir 'all_stage_timing_path_families.txt'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$reports = [ordered]@{
    synth_setup             = 'reports\synth\synth_all_setup_violations.rpt'
    synth_hold              = 'reports\synth\synth_all_hold_violations.rpt'
    opt_setup               = 'reports\impl\pre_route\opt_all_setup_violations.rpt'
    opt_hold                = 'reports\impl\pre_route\opt_all_hold_violations.rpt'
    place_setup             = 'reports\impl\pre_route\place_all_setup_violations.rpt'
    place_hold              = 'reports\impl\pre_route\place_all_hold_violations.rpt'
    physopt_setup           = 'reports\impl\pre_route\physopt_all_setup_violations.rpt'
    physopt_hold            = 'reports\impl\pre_route\physopt_all_hold_violations.rpt'
    route_setup             = 'reports\impl\route_all_setup_violations.rpt'
    route_hold              = 'reports\impl\route_all_hold_violations.rpt'
    postroute_physopt_setup = 'reports\impl\postroute_physopt_all_setup_violations.rpt'
    postroute_physopt_hold  = 'reports\impl\postroute_physopt_all_hold_violations.rpt'
    reroute_setup           = 'reports\impl\reroute_all_setup_violations.rpt'
    reroute_hold            = 'reports\impl\reroute_all_hold_violations.rpt'
    final_route_setup       = 'reports\impl\final_route_all_setup_violations.rpt'
    final_route_hold        = 'reports\impl\final_route_all_hold_violations.rpt'
}

if ($Stages.Count -gt 0) {
    $unknownStages = @($Stages | Where-Object { -not $reports.Contains($_) })
    if ($unknownStages.Count -gt 0) {
        throw "Unknown timing report stage(s): $($unknownStages -join ', ')"
    }
    $selectedReports = [ordered]@{}
    foreach ($stage in $Stages) { $selectedReports[$stage] = $reports[$stage] }
    $reports = $selectedReports
}

function Get-Block([string]$Endpoint) {
    switch -Regex ($Endpoint) {
        '/u_rob/'              { return 'ROB' }
        '/u_iq0/'              { return 'IQ0' }
        '/u_iq1/'              { return 'IQ1' }
        '/u_lq/'               { return 'LQ' }
        '/u_sq/'               { return 'SQ' }
        '/u_prf/'              { return 'PRF' }
        '/u_checkpoints/'      { return 'CHECKPOINT' }
        '/u_branch_predictor/' { return 'BRANCH_PREDICTOR' }
        '/u_dcache/'           { return 'DCACHE' }
        '/u_icache/'           { return 'ICACHE' }
        '/u_dmem_request_fifo/' { return 'DMEM_FIFO' }
        '/u_memory/'           { return 'MEMORY' }
        '/u_core/'             { return 'CORE_OTHER' }
        default                { return 'SOC_OTHER' }
    }
}

function Get-NormalizedEndpoint([string]$Endpoint) {
    $normalized = $Endpoint -replace '\[[^\]]+\]', '[*]'
    $normalized = $normalized -replace '_replica(?:_[0-9]+)*', '_replica*'
    $normalized = $normalized -replace '_rep(?:_[0-9]+)+', '_rep*'
    $normalized = $normalized -replace '_reg_[0-9]+(?:_[0-9]+)+', '_reg_*'
    return $normalized
}

$writer = [System.IO.StreamWriter]::new($outputFile, $false)
try {
    $writer.WriteLine('NOTE=Every emitted timing violation is included; endpoint indices and replica suffixes are normalized only for family grouping.')
    foreach ($reportName in $reports.Keys) {
        $path = Join-Path $projectRoot $reports[$reportName]
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing timing report: $path" }
        $families = @{}
        $modulePairs = @{}
        $total = 0
        $tns = 0.0
        $wns = [double]::PositiveInfinity
        $insidePath = $false
        $slack = 0.0
        $source = ''
        $destination = ''

        $flushPath = {
            if ($insidePath -and $source -and $destination) {
                $sourceBlock = Get-Block $source
                $destinationBlock = Get-Block $destination
                $sourceNorm = Get-NormalizedEndpoint $source
                $destinationNorm = Get-NormalizedEndpoint $destination
                $familyKey = "$sourceNorm -> $destinationNorm"
                $pairKey = "$sourceBlock->$destinationBlock"
                if (-not $families.ContainsKey($familyKey)) {
                    $families[$familyKey] = [ordered]@{ Count = 0; Worst = [double]::PositiveInfinity; Tns = 0.0 }
                }
                $families[$familyKey].Count++
                if ($slack -lt $families[$familyKey].Worst) { $families[$familyKey].Worst = $slack }
                $families[$familyKey].Tns += $slack
                if (-not $modulePairs.ContainsKey($pairKey)) {
                    $modulePairs[$pairKey] = [ordered]@{ Count = 0; Worst = [double]::PositiveInfinity; Tns = 0.0 }
                }
                $modulePairs[$pairKey].Count++
                if ($slack -lt $modulePairs[$pairKey].Worst) { $modulePairs[$pairKey].Worst = $slack }
                $modulePairs[$pairKey].Tns += $slack
            }
        }

        $reader = [System.IO.StreamReader]::new($path)
        try {
            while (($line = $reader.ReadLine()) -ne $null) {
                if ($line -match '^Slack \(VIOLATED\) :\s+([-0-9.]+)ns') {
                    . $flushPath
                    $insidePath = $true
                    $slack = [double]$Matches[1]
                    $source = ''
                    $destination = ''
                    $total++
                    $tns += $slack
                    if ($slack -lt $wns) { $wns = $slack }
                }
                elseif ($insidePath -and $line -match '^\s*Source:\s+(\S+)') {
                    $source = $Matches[1]
                }
                elseif ($insidePath -and $line -match '^\s*Destination:\s+(\S+)') {
                    $destination = $Matches[1]
                }
            }
            . $flushPath
        }
        finally {
            $reader.Dispose()
        }

        $wnsText = if ($total -eq 0) { 'NONE' } else { '{0:F3}' -f $wns }
        $writer.WriteLine("REPORT=$reportName PATHS=$total WNS=$wnsText TNS=$('{0:F3}' -f $tns) FILE=$path")
        foreach ($entry in ($modulePairs.GetEnumerator() | Sort-Object { $_.Value.Worst }, { -$_.Value.Count })) {
            $writer.WriteLine("  MODULE_PAIR=$($entry.Key) COUNT=$($entry.Value.Count) WORST=$('{0:F3}' -f $entry.Value.Worst) TNS=$('{0:F3}' -f $entry.Value.Tns)")
        }
        foreach ($entry in ($families.GetEnumerator() | Sort-Object { $_.Value.Worst }, { -$_.Value.Count })) {
            $writer.WriteLine("  FAMILY_COUNT=$($entry.Value.Count) WORST=$('{0:F3}' -f $entry.Value.Worst) TNS=$('{0:F3}' -f $entry.Value.Tns) PATH=$($entry.Key)")
        }
    }
}
finally {
    $writer.Dispose()
}

Write-Output "ALL_STAGE_TIMING_PATH_FAMILIES=$outputFile"
