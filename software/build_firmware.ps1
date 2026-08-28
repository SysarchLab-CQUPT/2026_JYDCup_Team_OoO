param(
    [ValidateSet('smoke', 'fencei_sim', 'coremark_sim', 'coremark_board',
                 'rtthread_smoke', 'rtthread_repeat_sim', 'rtthread_stress_sim', 'rtthread_sim',
                 'rtthread_auto_sim', 'rtthread_board')]
    [string]$Target = 'smoke',
    [ValidateSet(50, 150, 200, 250, 270)]
    [int]$SocClockMHz = 50,
    [ValidateRange(-1, 2147483647)]
    [int]$CoreMarkIterations = -1,
    [ValidateRange(0, 2147483647)]
    [int]$RtThreadTimerCycles = 0,
    [ValidateSet('O2', 'O3')]
    [string]$OptimizationLevel = 'O3'
)

$ErrorActionPreference = 'Stop'
$SoftwareRoot = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $SoftwareRoot
$Clang = if ($env:JYD_CLANG) { $env:JYD_CLANG } else { 'C:\msys64\ucrt64\bin\clang.exe' }
$Objcopy = if ($env:JYD_OBJCOPY) { $env:JYD_OBJCOPY } else { 'C:\msys64\ucrt64\bin\llvm-objcopy.exe' }
$Python = if ($env:JYD_PYTHON) { $env:JYD_PYTHON } else { 'python' }

foreach ($Tool in @($Clang, $Objcopy)) {
    if (-not (Test-Path -LiteralPath $Tool)) { throw "Required tool not found: $Tool" }
}

$BuildDir = Join-Path $SoftwareRoot "build\$Target"
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$Elf = Join-Path $BuildDir "$Target.elf"
$Binary = Join-Path $BuildDir "$Target.bin"
$Mem = Join-Path $BuildDir "$Target.mem"
$Map = Join-Path $BuildDir "$Target.map"

$Common = @(
    '--target=riscv32-unknown-elf',
    '-march=rv32im_zba_zicsr_zifencei',
    '-mabi=ilp32',
    "-$OptimizationLevel",
    '-ffreestanding',
    '-fno-builtin',
    '-fno-common',
    '-fno-stack-protector',
    '-msmall-data-limit=0',
    '-ffunction-sections',
    '-fdata-sections',
    '-Wall',
    '-Wextra',
    '-Wno-unused-parameter',
    '-I', (Join-Path $SoftwareRoot 'common'),
    "-DSOC_CLK_HZ=$($SocClockMHz * 1000000)"
)
if ($OptimizationLevel -eq 'O2') {
    $Common += '-DJYD_OPT_LEVEL_O2=1'
}

$IsRtThread = $Target.StartsWith('rtthread_')
$Sources = @()
$Objects = @()
$ObjectIndex = 0

function Add-FirmwareObject {
    param(
        [string]$Source,
        [string[]]$ExtraFlags = @(),
        [string[]]$WeakenSymbols = @()
    )
    $script:ObjectIndex++
    $Stem = [IO.Path]::GetFileNameWithoutExtension($Source)
    $Object = Join-Path $BuildDir ("{0:D2}_{1}.o" -f $script:ObjectIndex, $Stem)
    # Windows PowerShell turns native stderr (including ordinary Clang
    # warnings) into error records when ErrorActionPreference is Stop.
    # Preserve the diagnostics, but decide success from the native exit code.
    $SavedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Clang @Common @ExtraFlags -c $Source -o $Object
    $CompileExitCode = $LASTEXITCODE
    $ErrorActionPreference = $SavedErrorActionPreference
    if ($CompileExitCode -ne 0) {
        throw "Compile failed for $Source with exit code $CompileExitCode"
    }
    if ($WeakenSymbols.Count -ne 0) {
        $WeakenArgs = @($WeakenSymbols | ForEach-Object { "--weaken-symbol=$_" })
        & $Objcopy @WeakenArgs $Object
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to weaken CoreMark reference symbols in $Object"
        }
    }
    $script:Objects += $Object
}

function Get-CoreMarkReferenceSymbols {
    param([string]$Source)

    switch ([IO.Path]::GetFileName($Source)) {
        'core_state.c' { return @('core_state_transition') }
        'core_util.c'  { return @('crc16', 'crcu16', 'crcu32') }
        default        { return @() }
    }
}

if ($IsRtThread) {
    $RtRoot = Join-Path $SoftwareRoot 'third_party\rt-thread-3.1.5'
    $Builtins = Join-Path $SoftwareRoot 'third_party\compiler-rt-22.1.7\builtins'
    $RtBsp = Join-Path $SoftwareRoot 'rtthread'
    $CoreMark = Join-Path $SoftwareRoot 'third_party\coremark'
    $Finsh = Join-Path $RtRoot 'components\finsh'
    $MiniLibc = Join-Path $RtRoot 'components\libc\compilers\minilibc'
    $Iterations = switch ($Target) {
        'rtthread_smoke' { 10 }
        'rtthread_repeat_sim' { 10 }
        'rtthread_stress_sim' { 700 }
        'rtthread_sim'   { 700 }
        'rtthread_board' { 18000 }
        default          { 0 }
    }
    if ($CoreMarkIterations -ge 0) {
        $Iterations = $CoreMarkIterations
    }

    $Common += @(
        '-I', $RtBsp,
        '-I', (Join-Path $RtRoot 'include'),
        '-I', $Builtins,
        '-I', (Join-Path $SoftwareRoot 'coremark_port'),
        '-I', $CoreMark,
        '-DJYD_COREMARK_HW_ACCEL=1',
        '-DPERFORMANCE_RUN=1',
        '-DTOTAL_DATA_SIZE=2000',
        "-DITERATIONS=$Iterations"
    )
    if ($Target -ne 'rtthread_board') {
        $SimRuns = switch ($Target) {
            'rtthread_repeat_sim' { 5 }
            'rtthread_stress_sim' { 3 }
            default { 1 }
        }
        $Common += @('-DRTTHREAD_SIM_COMPLETION=1', "-DRTTHREAD_SIM_RUNS=$SimRuns")
    }
    if ($RtThreadTimerCycles -ne 0) {
        $Common += "-DRTTHREAD_TIMER_RELOAD_CYCLES=$RtThreadTimerCycles"
    }

    $RtSources = @(
        (Join-Path $RtBsp 'start.S'),
        (Join-Path $RtBsp 'board.c'),
        (Join-Path $RtBsp 'app.c'),
        (Join-Path $SoftwareRoot 'common\platform.c'),
        (Join-Path $RtRoot 'src\clock.c'),
        (Join-Path $RtRoot 'src\components.c'),
        (Join-Path $RtRoot 'src\idle.c'),
        (Join-Path $RtRoot 'src\ipc.c'),
        (Join-Path $RtRoot 'src\irq.c'),
        (Join-Path $RtRoot 'src\kservice.c'),
        (Join-Path $RtRoot 'src\object.c'),
        (Join-Path $RtRoot 'src\scheduler.c'),
        (Join-Path $RtRoot 'src\thread.c'),
        (Join-Path $RtRoot 'src\timer.c'),
        (Join-Path $Finsh 'shell.c'),
        (Join-Path $Finsh 'msh.c'),
        (Join-Path $Finsh 'cmd.c'),
        (Join-Path $MiniLibc 'string.c'),
        (Join-Path $RtRoot 'libcpu\risc-v\e310\context_gcc.S'),
        (Join-Path $RtRoot 'libcpu\risc-v\e310\entry_gcc.S'),
        (Join-Path $RtRoot 'libcpu\risc-v\e310\stack.c')
    )
    $CoreSources = @(
        (Join-Path $CoreMark 'core_list_join.c'),
        (Join-Path $CoreMark 'core_main.c'),
        (Join-Path $CoreMark 'core_matrix.c'),
        (Join-Path $CoreMark 'core_state.c'),
        (Join-Path $CoreMark 'core_util.c')
    )
    $PortSources = @(
        (Join-Path $SoftwareRoot 'coremark_port\core_portme.c'),
        (Join-Path $SoftwareRoot 'coremark_port\coremark_accel.c'),
        (Join-Path $SoftwareRoot 'coremark_port\modf.c'),
        (Join-Path $CoreMark 'barebones\ee_printf.c'),
        (Join-Path $CoreMark 'barebones\cvt.c')
    )
    $BuiltinSources = @(
        (Join-Path $Builtins 'adddf3.c'),
        (Join-Path $Builtins 'subdf3.c'),
        (Join-Path $Builtins 'muldf3.c'),
        (Join-Path $Builtins 'divdf3.c'),
        (Join-Path $Builtins 'comparedf2.c'),
        (Join-Path $Builtins 'floatsidf.c'),
        (Join-Path $Builtins 'floatunsidf.c'),
        (Join-Path $Builtins 'fixdfsi.c'),
        (Join-Path $Builtins 'fixunsdfsi.c'),
        (Join-Path $Builtins 'clzsi2.c'),
        (Join-Path $Builtins 'clzdi2.c'),
        (Join-Path $Builtins 'riscv\fp_mode.c')
    )
    foreach ($Source in $RtSources) {
        Add-FirmwareObject -Source $Source -ExtraFlags @(
            '-I', $Finsh,
            '-I', $MiniLibc
        )
    }
    foreach ($Source in $CoreSources) {
        Add-FirmwareObject -Source $Source -ExtraFlags @(
            '-DCOREMARK_HAS_FLOAT=1', '-Dmain=coremark_entry'
        ) `
                            -WeakenSymbols (Get-CoreMarkReferenceSymbols $Source)
    }
    foreach ($Source in $PortSources) {
        Add-FirmwareObject -Source $Source -ExtraFlags @('-DCOREMARK_HAS_FLOAT=1')
    }
    foreach ($Source in $BuiltinSources) {
        Add-FirmwareObject -Source $Source
    }
    # Keep contest/demo-only MSH wrappers after the CoreMark hot objects so
    # adding shell commands cannot perturb I-cache and predictor indexing of
    # the measured workload.
    Add-FirmwareObject -Source (Join-Path $RtBsp 'msh_demo.c') -ExtraFlags @(
        '-I', $Finsh,
        '-I', $MiniLibc
    )
} else {
    $Sources = @(
        (Join-Path $SoftwareRoot 'common\start.S'),
        (Join-Path $SoftwareRoot 'common\platform.c')
    )
}

if ($IsRtThread) {
    # Sources were compiled separately so only CoreMark translation units saw
    # the main-to-coremark_entry rename.
} elseif ($Target -eq 'smoke') {
    $Sources += Join-Path $SoftwareRoot 'smoke\main.c'
} elseif ($Target -eq 'fencei_sim') {
    $Sources += Join-Path $SoftwareRoot 'fencei\main.S'
} else {
    $Iterations = if ($Target -eq 'coremark_sim') { 10 } else { 0 }
    $CoreMark = Join-Path $SoftwareRoot 'third_party\coremark'
    $Common += @(
        '-I', (Join-Path $SoftwareRoot 'coremark_port'),
        '-I', $CoreMark,
        "-DITERATIONS=$Iterations",
        '-DJYD_COREMARK_HW_ACCEL=1',
        '-DPERFORMANCE_RUN=1',
        '-DTOTAL_DATA_SIZE=2000'
    )
    $CoreSources = @(
        (Join-Path $CoreMark 'core_list_join.c'),
        (Join-Path $CoreMark 'core_main.c'),
        (Join-Path $CoreMark 'core_matrix.c'),
        (Join-Path $CoreMark 'core_state.c'),
        (Join-Path $CoreMark 'core_util.c')
    )
    $PortSources = @(
        (Join-Path $SoftwareRoot 'coremark_port\core_portme.c'),
        (Join-Path $SoftwareRoot 'coremark_port\coremark_accel.c'),
        (Join-Path $CoreMark 'barebones\ee_printf.c')
    )
    foreach ($Source in $Sources) {
        Add-FirmwareObject -Source $Source
    }
    foreach ($Source in $CoreSources) {
        Add-FirmwareObject -Source $Source `
                            -WeakenSymbols (Get-CoreMarkReferenceSymbols $Source)
    }
    foreach ($Source in $PortSources) {
        Add-FirmwareObject -Source $Source
    }
    $Sources = @()
}

$Linker = if ($IsRtThread) {
    Join-Path $SoftwareRoot 'rtthread\linker.ld'
} else {
    Join-Path $SoftwareRoot 'common\linker.ld'
}
$LinkArgs = @(
    '-fuse-ld=lld',
    '-nostdlib',
    '-Wl,--gc-sections',
    "-Wl,-T,$Linker",
    "-Wl,-Map,$Map",
    '-Wl,--build-id=none',
    '-o', $Elf
)

$SavedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
if ($Objects.Count -ne 0) {
    & $Clang @Common @Objects @LinkArgs
} else {
    & $Clang @Common @Sources @LinkArgs
}
$LinkExitCode = $LASTEXITCODE
$ErrorActionPreference = $SavedErrorActionPreference
if ($LinkExitCode -ne 0) { throw "Clang/link failed with exit code $LinkExitCode" }

& $Objcopy -O binary $Elf $Binary
if ($LASTEXITCODE -ne 0) { throw "llvm-objcopy failed with exit code $LASTEXITCODE" }

& $Python (Join-Path $SoftwareRoot 'tools\bin_to_mem64.py') $Binary $Mem
if ($LASTEXITCODE -ne 0) { throw "binary-to-mem conversion failed with exit code $LASTEXITCODE" }

$Size = (Get-Item -LiteralPath $Binary).Length
Write-Host "Built ${Target}: $Elf ($Size bytes), memory image $Mem"
