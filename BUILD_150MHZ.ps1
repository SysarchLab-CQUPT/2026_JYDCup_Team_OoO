[CmdletBinding()]
param(
    [string]$VivadoBat = 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat',
    [string]$LlvmBin = 'C:\msys64\ucrt64\bin',
    [string]$PythonExe = 'python'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Clang = Join-Path $LlvmBin 'clang.exe'
$Objcopy = Join-Path $LlvmBin 'llvm-objcopy.exe'
$BaseDcp = Join-Path $Root 'reference\accepted_route\jyd_soc_top_150mhz_accepted_route.dcp'
$ReferenceBit = Join-Path $Root 'reference\current_bit\jyd_soc_top_rtthread_coremark_150mhz.bit'
$OutputDir = Join-Path $Root 'output'
$RawBit = Join-Path $OutputDir 'jyd_soc_top_rtthread_coremark_150mhz_raw.bit'
$ExactBit = Join-Path $OutputDir 'jyd_soc_top_rtthread_coremark_150mhz.bit'
$OutputDcp = Join-Path $OutputDir 'jyd_soc_top_rtthread_coremark_150mhz.dcp'

$ExpectedFirmware = @{
    'rtthread_board.mem' = 'C4F21D05A034E39DF87CB9610657FD4E0C3FD8822873F073276BF30F4A6C5A85'
    'rtthread_board.bin' = '122F0F1D098F92CAF580FEEEC999BC87A980FBB8524DE2A29867A7E12B3021DA'
    'rtthread_board.elf' = '999AB2CA569A8BC056354D58217DF1836EBBC7763343DCF49ECFAEC1F7A7D079'
}
$ExpectedDcp = 'FB7C6E9BD75E175B4E6D59FE3B043EF951474DB99761F30A7A1BF941650F414B'
$ExpectedBit = 'D415F26FA8B279847A77464727A233978E8837DE69B3435953C7F1881AC38969'
$ExpectedPayload = 'DE2906072CA43CD12F898772C7B0DF3E4B34036CAB0347A8F86EA73E33F02EF8'

foreach ($Path in @($VivadoBat, $Clang, $Objcopy, $BaseDcp, $ReferenceBit)) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing required file: $Path" }
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $BaseDcp).Hash -ne $ExpectedDcp) {
    throw 'Accepted physical DCP hash mismatch'
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $ReferenceBit).Hash -ne $ExpectedBit) {
    throw 'Reference bit hash mismatch'
}

function Get-BitLayout([string]$Path) {
    $Bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path))
    $Index = 0
    $MagicLength = 256 * $Bytes[$Index] + $Bytes[$Index + 1]
    $Index += 2 + $MagicLength
    $Index += 2
    while ($true) {
        $Key = [char]$Bytes[$Index]
        $Index++
        if ($Key -eq 'e') {
            $Length = 16777216L * $Bytes[$Index] + 65536L * $Bytes[$Index + 1] +
                      256L * $Bytes[$Index + 2] + $Bytes[$Index + 3]
            $Index += 4
            break
        }
        $FieldLength = 256 * $Bytes[$Index] + $Bytes[$Index + 1]
        $Index += 2 + $FieldLength
    }
    [pscustomobject]@{ Bytes = $Bytes; Offset = $Index; Length = [int]$Length }
}

function Get-PayloadHash([string]$Path) {
    $Layout = Get-BitLayout $Path
    $Sha = [Security.Cryptography.SHA256]::Create()
    try {
        (($Sha.ComputeHash($Layout.Bytes, $Layout.Offset, $Layout.Length) |
          ForEach-Object { $_.ToString('x2') }) -join '').ToUpperInvariant()
    }
    finally { $Sha.Dispose() }
}

$OldSourceDate = $env:SOURCE_DATE_EPOCH
$OldClang = $env:JYD_CLANG
$OldObjcopy = $env:JYD_OBJCOPY
$OldPython = $env:JYD_PYTHON
try {
    $env:SOURCE_DATE_EPOCH = ([DateTimeOffset]::Parse('2026-08-19T00:00:00Z')).ToUnixTimeSeconds().ToString()
    $env:JYD_CLANG = $Clang
    $env:JYD_OBJCOPY = $Objcopy
    $env:JYD_PYTHON = $PythonExe

    & (Join-Path $Root 'software\build_firmware.ps1') -Target rtthread_board `
        -SocClockMHz 150 -CoreMarkIterations 18000 -OptimizationLevel O3
    if ($LASTEXITCODE -ne 0) { throw 'Firmware build failed' }

    foreach ($Name in $ExpectedFirmware.Keys) {
        $Path = Join-Path $Root "software\build\rtthread_board\$Name"
        $Actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
        if ($Actual -ne $ExpectedFirmware[$Name]) {
            throw "Firmware mismatch: $Name expected $($ExpectedFirmware[$Name]) actual $Actual"
        }
        Write-Host "FIRMWARE_MATCH $Name $Actual"
    }

    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $Mem = Join-Path $Root 'software\build\rtthread_board\rtthread_board.mem'
    & $VivadoBat -mode batch -notrace `
        -source (Join-Path $Root 'flow\rebuild_current_150mhz_bit.tcl') `
        -tclargs $Root $BaseDcp $Mem $OutputDir $OutputDcp $RawBit
    if ($LASTEXITCODE -ne 0) { throw 'Vivado bit reproduction failed' }

    $Payload = Get-PayloadHash $RawBit
    if ($Payload -ne $ExpectedPayload) {
        throw "Bit payload mismatch: expected $ExpectedPayload actual $Payload"
    }

    $ReferenceLayout = Get-BitLayout $ReferenceBit
    $RawLayout = Get-BitLayout $RawBit
    if ($ReferenceLayout.Length -ne $RawLayout.Length) { throw 'Bit payload length mismatch' }
    $ExactBytes = New-Object byte[] ($ReferenceLayout.Offset + $RawLayout.Length)
    [Array]::Copy($ReferenceLayout.Bytes, 0, $ExactBytes, 0, $ReferenceLayout.Offset)
    [Array]::Copy($RawLayout.Bytes, $RawLayout.Offset, $ExactBytes,
                  $ReferenceLayout.Offset, $RawLayout.Length)
    [IO.File]::WriteAllBytes($ExactBit, $ExactBytes)
    $ExactHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ExactBit).Hash
    if ($ExactHash -ne $ExpectedBit) { throw "Exact bit hash mismatch: $ExactHash" }

    Write-Host "BITSTREAM_MATCH $ExactHash"
    Write-Host "BITSTREAM=$ExactBit"
    Write-Host 'REPRODUCTION=PASS'
}
finally {
    $env:SOURCE_DATE_EPOCH = $OldSourceDate
    $env:JYD_CLANG = $OldClang
    $env:JYD_OBJCOPY = $OldObjcopy
    $env:JYD_PYTHON = $OldPython
}

