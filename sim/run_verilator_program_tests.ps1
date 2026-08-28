$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Bash = 'C:\msys64\usr\bin\bash.exe'
if (-not (Test-Path -LiteralPath $Bash)) { throw "MSYS2 bash not found: $Bash" }

$BuildDir = Join-Path $ProjectRoot 'build\verilator\ooo_program'
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$Sources = @(
    (Join-Path $ProjectRoot 'rtl\pkg\soc_cfg_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\pkg\rv32_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\pkg\core_types_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\pkg\backend_types_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\rv32_decode.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\branch_predictor.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\fetch_bundle_queue.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\free_bitmap.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\rename_map.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\physical_regfile_lane.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\physical_regfile.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\branch_checkpoints.sv'),
    (Join-Path $ProjectRoot 'rtl\core\backend\rob.sv'),
    (Join-Path $ProjectRoot 'rtl\core\backend\issue_queue.sv'),
    (Join-Path $ProjectRoot 'rtl\core\lsu\load_queue.sv'),
    (Join-Path $ProjectRoot 'rtl\core\lsu\store_queue.sv'),
    (Join-Path $ProjectRoot 'rtl\core\execute\rv32_alu.sv'),
    (Join-Path $ProjectRoot 'rtl\core\execute\rv32_agu_add_imm.sv'),
    (Join-Path $ProjectRoot 'rtl\core\execute\crc16_accelerator.sv'),
    (Join-Path $ProjectRoot 'rtl\core\execute\crc32_word_accelerator.sv'),
    (Join-Path $ProjectRoot 'rtl\core\execute\state_transition_accelerator.sv'),
    (Join-Path $ProjectRoot 'rtl\core\execute\rv32_mul_partial_products.sv'),
    (Join-Path $ProjectRoot 'rtl\core\execute\muldiv_unit.sv'),
    (Join-Path $ProjectRoot 'rtl\core\execute\csr_execute.sv'),
    (Join-Path $ProjectRoot 'rtl\core\commit\csr_file.sv'),
    (Join-Path $ProjectRoot 'rtl\core\ooo_core.sv'),
    (Join-Path $ProjectRoot 'sim\verilator\tb_ooo_program.sv')
)

$RelativeSources = $Sources | ForEach-Object {
    $_.Substring($ProjectRoot.Length + 1).Replace('\', '/')
}
$SourceArgs = $RelativeSources -join ' '
$ProjectRootMsys = (& $Bash -lc "cygpath -u '$ProjectRoot'").Trim()
if ($LASTEXITCODE -ne 0 -or -not $ProjectRootMsys) { throw 'Failed to convert project path for MSYS2' }
$BuildCommand = @"
cd '$ProjectRootMsys'
export PATH=/ucrt64/bin:/usr/bin:`$PATH
verilator --binary --timing --assert -Wall -Wno-fatal --top-module tb_ooo_program \
  --Mdir build/verilator/ooo_program -MAKEFLAGS 'OPT_GLOBAL=-O2 OPT_FAST=-O2' $SourceArgs
"@
& $Bash -lc $BuildCommand
if ($LASTEXITCODE -ne 0) { throw "Verilator build failed with exit code $LASTEXITCODE" }

$Executable = Join-Path $BuildDir 'Vtb_ooo_program.exe'
& $Executable
if ($LASTEXITCODE -ne 0) { throw "Verilator program test failed with exit code $LASTEXITCODE" }
