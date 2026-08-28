param(
    [switch]$FullRtThread,
    [switch]$RtThreadOnly,
    [switch]$BoardExact,
    [switch]$StressRtThread,
    [switch]$RepeatOnly,
    [switch]$LongOnly,
    [switch]$CoreMarkOnly,
    [switch]$CorrectnessOnly,
    [ValidateSet(50, 150)]
    [int]$SocClockMHz = 50
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Bash = 'C:\msys64\usr\bin\bash.exe'
if (-not (Test-Path -LiteralPath $Bash)) { throw "MSYS2 bash not found: $Bash" }

$Sources = @(
    'rtl/pkg/soc_cfg_pkg.sv',
    'rtl/pkg/rv32_pkg.sv',
    'rtl/pkg/core_types_pkg.sv',
    'rtl/pkg/backend_types_pkg.sv',
    'rtl/pkg/mmio_pkg.sv',
    'rtl/core/frontend/rv32_decode.sv',
    'rtl/core/frontend/branch_predictor.sv',
    'rtl/core/frontend/fetch_bundle_queue.sv',
    'rtl/core/rename/free_bitmap.sv',
    'rtl/core/rename/rename_map.sv',
    'rtl/core/rename/physical_regfile_lane.sv',
    'rtl/core/rename/physical_regfile.sv',
    'rtl/core/rename/branch_checkpoints.sv',
    'rtl/core/backend/rob.sv',
    'rtl/core/backend/issue_queue.sv',
    'rtl/core/lsu/load_queue.sv',
    'rtl/core/lsu/store_queue.sv',
    'rtl/core/execute/rv32_alu.sv',
    'rtl/core/execute/rv32_agu_add_imm.sv',
    'rtl/core/execute/crc16_accelerator.sv',
    'rtl/core/execute/crc32_word_accelerator.sv',
    'rtl/core/execute/state_transition_accelerator.sv',
    'rtl/core/execute/rv32_mul_partial_products.sv',
    'rtl/core/execute/muldiv_unit.sv',
    'rtl/core/execute/csr_execute.sv',
    'rtl/core/commit/csr_file.sv',
    'rtl/core/ooo_core.sv',
    'rtl/cache/instruction_cache.sv',
    'rtl/cache/cache_data_ram.sv',
    'rtl/cache/data_cache.sv',
    'rtl/soc/mmio_decode.sv',
    'rtl/periph/uart.sv',
    'rtl/periph/tick_timer.sv',
    'rtl/soc/irq_debug.sv',
    'rtl/soc/soc_peripherals.sv',
    'rtl/soc/unified_bram.sv',
    'rtl/soc/dmem_request_fifo.sv',
    'rtl/soc/ooo_soc_system.sv',
    'sim/verilator/tb_soc_firmware.sv'
)
$SourceArgs = $Sources -join ' '
$ProjectRootMsys = (& $Bash -lc "cygpath -u '$ProjectRoot'").Trim()
if ($LASTEXITCODE -ne 0 -or -not $ProjectRootMsys) { throw 'Failed to convert project path for MSYS2' }

$SocClockHz = $SocClockMHz * 1000000
$CycleScale = $SocClockMHz / 50.0
$CommandWaitCycles = [int][math]::Ceiling(5000000 * $CycleScale)
$RtThreadMinIterationsPerSec = 600.0
# Effective IPC is measured against the fixed pre-acceleration CoreMark work
# count in tb_soc_firmware.  The requested death line is effective IPC 1.20:
# floor(2,976,237 / 1.20) = 2,480,197 active cycles.
$CoreMarkMaxActiveCyclesForEffectiveIpc1p20 = if ($CorrectnessOnly) {
    0
} else {
    2480197
}
$Mdir = "build/verilator/firmware_${SocClockMHz}mhz"
New-Item -ItemType Directory -Force -Path (Join-Path $ProjectRoot 'build/verilator') |
    Out-Null
$BuildCommand = @"
cd '$ProjectRootMsys'
export PATH=/ucrt64/bin:/usr/bin:`$PATH
verilator --binary --timing --assert -Wall -Wno-fatal -Wno-PINCONNECTEMPTY --top-module tb_soc_firmware \
  -GSOC_CLK_HZ=$SocClockHz \
  --Mdir '$Mdir' -MAKEFLAGS 'OPT_GLOBAL=-O2 OPT_FAST=-O2' \
  $SourceArgs
"@
$SavedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$BuildOutput = & $Bash -lc $BuildCommand 2>&1
$BuildExitCode = $LASTEXITCODE
$ErrorActionPreference = $SavedErrorActionPreference
$BuildOutput | ForEach-Object { Write-Host $_ }
if ($BuildExitCode -ne 0) { throw 'Verilator firmware model build failed' }
$Executable = Join-Path $ProjectRoot "$Mdir\Vtb_soc_firmware.exe"

function Invoke-FirmwareTest {
    param(
        [string]$Target,
        [string[]]$ExpectedText,
        [int]$MaxCycles,
        [string[]]$RuntimeArgs = @(),
        [long]$MaxActiveCycles = 0,
        [double]$MinIterationsPerSec = 0.0
    )

    & (Join-Path $ProjectRoot 'software\build_firmware.ps1') `
      -Target $Target -SocClockMHz $SocClockMHz
    $Mem = "software/build/$Target/$Target.mem"
    $Log = Join-Path $ProjectRoot "$Mdir\run_$Target.log"
    & $Executable "+MEM_FILE=$Mem" "+MAX_CYCLES=$MaxCycles" @RuntimeArgs 2>&1 |
        Tee-Object -FilePath $Log
    if ($LASTEXITCODE -ne 0) { throw "Verilator firmware test failed for $Target" }
    $LogText = Get-Content -LiteralPath $Log -Raw
    foreach ($Expected in $ExpectedText) {
        if ($LogText -notmatch [regex]::Escape($Expected)) {
            throw "Expected firmware output '$Expected' not found for $Target"
        }
    }
    foreach ($Forbidden in @('[0]ERROR! list crc', '[0]ERROR! matrix crc',
                             '[0]ERROR! state crc', 'FATAL TRAP', 'jyd>',
                             'Unknown command:')) {
        if ($LogText.Contains($Forbidden)) {
            throw "Forbidden firmware output '$Forbidden' found for $Target"
        }
    }
    if ($MaxActiveCycles -gt 0) {
        $PerfMatches = [regex]::Matches(
            $LogText,
            'PERF coremark_run=\d+ active_cycles=(\d+)'
        )
        if ($PerfMatches.Count -eq 0) {
            throw "CoreMark performance counters not found for $Target"
        }
        foreach ($PerfMatch in $PerfMatches) {
            $ActiveCycles = [long]$PerfMatch.Groups[1].Value
            if ($ActiveCycles -gt $MaxActiveCycles) {
                throw "CoreMark active cycles $ActiveCycles exceed IPC limit $MaxActiveCycles for $Target"
            }
        }
    }
    if ($MinIterationsPerSec -gt 0.0) {
        $ScoreMatches = [regex]::Matches(
            $LogText,
            'Iterations/Sec\s*:\s*([0-9]+(?:\.[0-9]+)?)'
        )
        if ($ScoreMatches.Count -eq 0) {
            throw "CoreMark Iterations/Sec not found for $Target"
        }
        foreach ($ScoreMatch in $ScoreMatches) {
            $Score = [double]::Parse(
                $ScoreMatch.Groups[1].Value,
                [Globalization.CultureInfo]::InvariantCulture
            )
            if ($Score -lt $MinIterationsPerSec) {
                throw "CoreMark score $Score is below $MinIterationsPerSec Iterations/Sec for $Target"
            }
        }
    }
    if ($LogText -notmatch 'PASS tb_soc_firmware') {
        throw "Completion signature not observed for $Target"
    }
}

if (-not $RtThreadOnly -and -not $RepeatOnly -and -not $LongOnly) {
    Invoke-FirmwareTest -Target 'smoke' -ExpectedText @('SELFTEST PASS') -MaxCycles 2000000
    Invoke-FirmwareTest -Target 'fencei_sim' -ExpectedText @() -MaxCycles 2000000
    Invoke-FirmwareTest -Target 'coremark_sim' -ExpectedText @(
        '2K performance run parameters for coremark.',
        'seedcrc          : 0xe9f5',
        '[0]crclist       : 0xe714',
        '[0]crcmatrix     : 0x1fd7',
        '[0]crcstate      : 0x8e3a',
        'ERROR! Must execute for at least 10 secs for a valid result!'
    ) -MaxCycles 20000000 -RuntimeArgs @('+EXPECT_COREMARK_LED') `
       -MaxActiveCycles $CoreMarkMaxActiveCyclesForEffectiveIpc1p20
}

if (-not $LongOnly -and -not $CoreMarkOnly) {
if (-not $RepeatOnly) {
Invoke-FirmwareTest -Target 'rtthread_smoke' -ExpectedText @(
    'RT-Thread Nano 3.1.5 ready; UART 115200 8N1',
    'Official FinSH/MSH console ready; type help',
    'msh >',
    'RT-Thread shell commands:',
    'ps               - List threads in the system.',
    'list_sem         - list semaphore in system',
    'status           - show JYD SoC and CoreMark status',
    'coremark         - run CoreMark in an RT-Thread worker',
    'simple_add',
    'add 1 to 99, sum=4950',
    'add 1 to 999, sum=499500',
    'tshell',
    'cmsem',
    "STATUS RT-Thread=3.1.5 Nano CLK_HZ=$SocClockHz",
    'Team ID locked: JYD_SIM',
    'CoreMark Team ID: JYD_SIM',
    'COREMARK BEGIN (RT-Thread worker, stack=8192)',
    'seedcrc          : 0xe9f5',
    '[0]crclist       : 0xe714',
    '[0]crcmatrix     : 0x1fd7',
    '[0]crcstate      : 0x8e3a',
    'COREMARK DONE rc=0 runs=1'
) -MaxCycles ([int][math]::Ceiling(100000000 * $CycleScale)) `
  -RuntimeArgs @('+UART_COMMANDS', '+EXPECT_COREMARK_LED',
                 "+COMMAND_WAIT_CYCLES=$CommandWaitCycles") `
  -MaxActiveCycles $CoreMarkMaxActiveCyclesForEffectiveIpc1p20 `
  -MinIterationsPerSec $RtThreadMinIterationsPerSec
}

Invoke-FirmwareTest -Target 'rtthread_repeat_sim' -ExpectedText @(
    'RT-Thread shell commands:',
    'msh >',
    'simple_add',
    'add 1 to 999, sum=499500',
    'tshell',
    'cmsem',
    "STATUS RT-Thread=3.1.5 Nano CLK_HZ=$SocClockHz",
    'Team ID locked: JYD_SIM',
    'CoreMark Team ID: JYD_SIM',
    'COREMARK DONE rc=0 runs=1',
    'COREMARK DONE rc=0 runs=5',
    '[0]crclist       : 0xe714',
    '[0]crcmatrix     : 0x1fd7',
    '[0]crcstate      : 0x8e3a'
) -MaxCycles ([int][math]::Ceiling(250000000 * $CycleScale)) -RuntimeArgs @(
    '+UART_COMMANDS', '+EXPECT_COREMARK_LED', '+COREMARK_RUNS=5',
    "+COMMAND_WAIT_CYCLES=$CommandWaitCycles",
    "+COREMARK_GAP_CYCLES=$([int][math]::Ceiling(2000000 * $CycleScale))") `
  -MaxActiveCycles $CoreMarkMaxActiveCyclesForEffectiveIpc1p20 `
  -MinIterationsPerSec $RtThreadMinIterationsPerSec
}

if ($StressRtThread) {
    Invoke-FirmwareTest -Target 'rtthread_stress_sim' -ExpectedText @(
        'CoreMark Team ID: JYD_SIM',
        'COREMARK DONE rc=0 runs=1',
        'COREMARK DONE rc=0 runs=3',
        '[0]crclist       : 0xe714',
        '[0]crcmatrix     : 0x1fd7',
        '[0]crcstate      : 0x8e3a'
    ) -MaxCycles 1850000000 -RuntimeArgs @(
        '+UART_COMMANDS', '+EXPECT_COREMARK_LED', '+COREMARK_RUNS=3',
        '+COREMARK_GAP_CYCLES=560000000')
}

if ($FullRtThread) {
    Invoke-FirmwareTest -Target 'rtthread_sim' -ExpectedText @(
        'RT-Thread Nano 3.1.5 ready; UART 115200 8N1',
        'RT-Thread shell commands:',
        'msh >',
        'simple_add',
        'add 1 to 999, sum=499500',
        "STATUS RT-Thread=3.1.5 Nano CLK_HZ=$SocClockHz",
        'CoreMark Team ID: JYD_SIM',
        'COREMARK BEGIN (RT-Thread worker, stack=8192)',
        '[0]crclist       : 0xe714',
        '[0]crcmatrix     : 0x1fd7',
        '[0]crcstate      : 0x8e3a',
        'COREMARK DONE rc=0 runs=1'
    ) -MaxCycles 650000000 -RuntimeArgs @(
        '+UART_COMMANDS', '+EXPECT_COREMARK_LED',
        "+COMMAND_WAIT_CYCLES=$CommandWaitCycles") `
      -MinIterationsPerSec $RtThreadMinIterationsPerSec
}
if ($BoardExact) {
    Invoke-FirmwareTest -Target 'rtthread_auto_sim' -ExpectedText @(
        'RT-Thread Nano 3.1.5 ready; UART 115200 8N1',
        'RT-Thread shell commands:',
        'msh >',
        'simple_add',
        'add 1 to 999, sum=499500',
        'CoreMark Team ID: JYD_SIM',
        '[0]crclist       : 0xe714',
        '[0]crcmatrix     : 0x1fd7',
        '[0]crcstate      : 0x8e3a',
        'COREMARK DONE rc=0 runs=1'
    ) -MaxCycles 1300000000 -RuntimeArgs @(
        '+UART_COMMANDS', '+EXPECT_COREMARK_LED',
        "+COMMAND_WAIT_CYCLES=$CommandWaitCycles") `
      -MinIterationsPerSec $RtThreadMinIterationsPerSec
}
Write-Host 'PASS Verilator firmware regression'
