[CmdletBinding()]
param(
    [string]$AuditTag = 'banked_storage_20260814',
    [string[]]$Stages = @()
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputDir = Join-Path $projectRoot "reports\audit\$AuditTag"
$outputFile = Join-Path $outputDir 'all_stage_timing_bank_classification.txt'
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

$groupPatterns = [ordered]@{
    IQ0_BANK0        = 'u_iq0/.*bank0'
    IQ0_BANK1        = 'u_iq0/.*bank1'
    IQ1_BANK0        = 'u_iq1/.*bank0'
    IQ1_BANK1        = 'u_iq1/.*bank1'
    CHECKPOINT_BANK0 = 'u_checkpoints/.*bank0'
    CHECKPOINT_BANK1 = 'u_checkpoints/.*bank1'
    BP_BANK0         = 'u_branch_predictor/.*bank0'
    BP_BANK1         = 'u_branch_predictor/.*bank1'
    PRF_BANK0        = 'u_prf/.*bank0'
    PRF_BANK1        = 'u_prf/.*bank1'
    DCACHE_WAY0      = 'u_dcache/.*way0'
    DCACHE_WAY1      = 'u_dcache/.*way1'
    ICACHE_WAY0      = 'u_icache/.*way0'
    ICACHE_WAY1      = 'u_icache/.*way1'
}

function Get-BankGroups([string]$Text) {
    $groups = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $groupPatterns.GetEnumerator()) {
        if ($Text -match $entry.Value) { $groups.Add($entry.Key) }
    }
    return $groups
}

function Test-SiblingPair([System.Collections.Generic.HashSet[string]]$Groups) {
    foreach ($base in @('IQ0_BANK','IQ1_BANK','CHECKPOINT_BANK','BP_BANK','PRF_BANK','DCACHE_WAY','ICACHE_WAY')) {
        if ($Groups.Contains("${base}0") -and $Groups.Contains("${base}1")) { return $true }
    }
    return $false
}

$writer = [System.IO.StreamWriter]::new($outputFile, $false)
try {
    $writer.WriteLine("NOTE=Streaming classification of every violation emitted by each current-stage setup/hold report.")
    foreach ($reportName in $reports.Keys) {
        $path = Join-Path $projectRoot $reports[$reportName]
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing timing report: $path" }

        $total = 0
        $bankEndpoint = 0
        $directSibling = 0
        $touchesBank = 0
        $touchesSiblingPair = 0
        $sourceCounts = @{}
        $destinationCounts = @{}
        $source = ''
        $destination = ''
        $insidePath = $false
        $seenGroups = [System.Collections.Generic.HashSet[string]]::new()

        $flushPath = {
            if ($insidePath) {
                $sourceGroups = @(Get-BankGroups $source)
                $destinationGroups = @(Get-BankGroups $destination)
                if (($sourceGroups.Count + $destinationGroups.Count) -gt 0) { $bankEndpoint++ }
                foreach ($g in $sourceGroups) {
                    if (-not $sourceCounts.ContainsKey($g)) { $sourceCounts[$g] = 0 }
                    $sourceCounts[$g]++
                }
                foreach ($g in $destinationGroups) {
                    if (-not $destinationCounts.ContainsKey($g)) { $destinationCounts[$g] = 0 }
                    $destinationCounts[$g]++
                }
                $endpointSet = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($g in $sourceGroups) { [void]$endpointSet.Add($g) }
                foreach ($g in $destinationGroups) { [void]$endpointSet.Add($g) }
                if (Test-SiblingPair $endpointSet) { $directSibling++ }
                if ($seenGroups.Count -gt 0) { $touchesBank++ }
                if (Test-SiblingPair $seenGroups) { $touchesSiblingPair++ }
            }
        }

        $reader = [System.IO.StreamReader]::new($path)
        try {
            while (($line = $reader.ReadLine()) -ne $null) {
                if ($line -match '^Slack \(VIOLATED\)') {
                    . $flushPath
                    $total++
                    $insidePath = $true
                    $source = ''
                    $destination = ''
                    $seenGroups.Clear()
                    continue
                }
                if (-not $insidePath) { continue }
                if ($line -match '^\s*Source:\s+(\S+)') { $source = $Matches[1] }
                if ($line -match '^\s*Destination:\s+(\S+)') { $destination = $Matches[1] }
                foreach ($g in (Get-BankGroups $line)) { [void]$seenGroups.Add($g) }
            }
            . $flushPath
        }
        finally {
            $reader.Dispose()
        }

        $writer.WriteLine("REPORT=$reportName FILE=$path")
        $writer.WriteLine("  VIOLATION_PATHS=$total BANK_ENDPOINT_PATHS=$bankEndpoint DIRECT_SIBLING_BANK_ENDPOINT_PATHS=$directSibling BANK_TOUCHED_PATHS=$touchesBank SIBLING_BANKS_TOUCHED_PATHS=$touchesSiblingPair")
        foreach ($g in $groupPatterns.Keys) {
            $src = if ($sourceCounts.ContainsKey($g)) { $sourceCounts[$g] } else { 0 }
            $dst = if ($destinationCounts.ContainsKey($g)) { $destinationCounts[$g] } else { 0 }
            if (($src + $dst) -gt 0) {
                $writer.WriteLine("  GROUP=$g SOURCE_PATHS=$src DESTINATION_PATHS=$dst")
            }
        }
    }
}
finally {
    $writer.Dispose()
}

Write-Output "ALL_STAGE_TIMING_BANK_CLASSIFICATION=$outputFile"
