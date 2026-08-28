param(
    [string[]] $Only = @()
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$VivadoBin = 'C:\AMDDesignTools\2025.2\Vivado\bin'
$Xvlog = Join-Path $VivadoBin 'xvlog.bat'
$Xelab = Join-Path $VivadoBin 'xelab.bat'
$Xsim = Join-Path $VivadoBin 'xsim.bat'
$RunId = Get-Date -Format 'yyyyMMdd-HHmmss-ffff'

foreach ($Tool in @($Xvlog, $Xelab, $Xsim)) {
    if (-not (Test-Path -LiteralPath $Tool)) {
        throw "Required Vivado 2025.2 tool not found: $Tool"
    }
}

function Invoke-XsimTest {
    param(
        [Parameter(Mandatory)] [string] $Top,
        [Parameter(Mandatory)] [string[]] $Sources
    )

    if ($Only.Count -gt 0 -and $Only -notcontains $Top) {
        return
    }

    # XSim leaves native snapshot executables behind and Windows may keep them
    # locked briefly after exit.  Isolate each regression run so a stale lock
    # cannot turn a passing RTL test into an elaboration failure.
    $BuildDir = Join-Path $ProjectRoot "build\xsim\runs\$RunId\$Top"
    New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
    Push-Location $BuildDir
    try {
        & $Xvlog -sv --work xil_defaultlib @Sources
        if ($LASTEXITCODE -ne 0) {
            throw "xvlog failed for $Top with exit code $LASTEXITCODE"
        }

        $Snapshot = "${Top}_snapshot"
        & $Xelab "xil_defaultlib.$Top" -s $Snapshot -debug typical -timescale 1ns/1ps
        if ($LASTEXITCODE -ne 0) {
            throw "xelab failed for $Top with exit code $LASTEXITCODE"
        }

        $Output = & $Xsim $Snapshot -runall 2>&1
        $XsimExitCode = $LASTEXITCODE
        $LogPath = Join-Path $BuildDir "$Top.console.log"
        $Output | Tee-Object -FilePath $LogPath
        $OutputText = $Output -join "`n"
        if ($XsimExitCode -ne 0) {
            throw "xsim failed for $Top with exit code $XsimExitCode"
        }
        if ($OutputText -match '(?im)^Fatal:|^ERROR:') {
            throw "xsim reported a fatal/error for $Top; see $LogPath"
        }
        if ($OutputText -notmatch "PASS $Top") {
            throw "xsim did not report PASS for $Top; see $LogPath"
        }
    }
    finally {
        Pop-Location
    }
}

$Cfg = Join-Path $ProjectRoot 'rtl\pkg\soc_cfg_pkg.sv'
$Types = Join-Path $ProjectRoot 'rtl\pkg\core_types_pkg.sv'

Invoke-XsimTest -Top 'tb_rv32_agu_add_imm' -Sources @(
    (Join-Path $ProjectRoot 'rtl\core\execute\rv32_agu_add_imm.sv'),
    (Join-Path $ProjectRoot 'sim\tb_rv32_agu_add_imm.sv')
)

Invoke-XsimTest -Top 'tb_free_bitmap' -Sources @(
    $Cfg,
    $Types,
    (Join-Path $ProjectRoot 'rtl\core\rename\free_bitmap.sv'),
    (Join-Path $ProjectRoot 'sim\tb_free_bitmap.sv')
)

Invoke-XsimTest -Top 'tb_rob' -Sources @(
    $Cfg,
    $Types,
    (Join-Path $ProjectRoot 'rtl\core\backend\rob.sv'),
    (Join-Path $ProjectRoot 'sim\tb_rob.sv')
)

Invoke-XsimTest -Top 'tb_mmio_decode' -Sources @(
    (Join-Path $ProjectRoot 'rtl\pkg\mmio_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\soc\mmio_decode.sv'),
    (Join-Path $ProjectRoot 'sim\tb_mmio_decode.sv')
)

Invoke-XsimTest -Top 'tb_uart' -Sources @(
    (Join-Path $ProjectRoot 'rtl\pkg\mmio_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\periph\uart.sv'),
    (Join-Path $ProjectRoot 'sim\tb_uart.sv')
)

Invoke-XsimTest -Top 'tb_tick_timer' -Sources @(
    (Join-Path $ProjectRoot 'rtl\pkg\mmio_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\periph\tick_timer.sv'),
    (Join-Path $ProjectRoot 'sim\tb_tick_timer.sv')
)

Invoke-XsimTest -Top 'tb_ds18b20_master' -Sources @(
    (Join-Path $ProjectRoot 'rtl\periph\ds18b20_master.sv'),
    (Join-Path $ProjectRoot 'sim\tb_ds18b20_master.sv')
)

Invoke-XsimTest -Top 'tb_temperature_seg_display' -Sources @(
    (Join-Path $ProjectRoot 'rtl\periph\temperature_seg_display.sv'),
    (Join-Path $ProjectRoot 'sim\tb_temperature_seg_display.sv')
)

Invoke-XsimTest -Top 'tb_rv32_decode' -Sources @(
    (Join-Path $ProjectRoot 'rtl\pkg\rv32_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\rv32_decode.sv'),
    (Join-Path $ProjectRoot 'sim\tb_rv32_decode.sv')
)

Invoke-XsimTest -Top 'tb_branch_predictor' -Sources @(
    (Join-Path $ProjectRoot 'rtl\core\frontend\branch_predictor.sv'),
    (Join-Path $ProjectRoot 'sim\tb_branch_predictor.sv')
)

Invoke-XsimTest -Top 'tb_fetch_bundle_queue' -Sources @(
    (Join-Path $ProjectRoot 'rtl\pkg\rv32_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\fetch_bundle_queue.sv'),
    (Join-Path $ProjectRoot 'sim\tb_fetch_bundle_queue.sv')
)

Invoke-XsimTest -Top 'tb_rv32_alu' -Sources @(
    (Join-Path $ProjectRoot 'rtl\pkg\rv32_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\core\execute\rv32_alu.sv'),
    (Join-Path $ProjectRoot 'sim\tb_rv32_alu.sv')
)

Invoke-XsimTest -Top 'tb_crc16_accelerator' -Sources @(
    (Join-Path $ProjectRoot 'rtl\core\execute\crc16_accelerator.sv'),
    (Join-Path $ProjectRoot 'rtl\core\execute\crc32_word_accelerator.sv'),
    (Join-Path $ProjectRoot 'rtl\core\execute\state_transition_accelerator.sv'),
    (Join-Path $ProjectRoot 'sim\tb_crc16_accelerator.sv')
)

Invoke-XsimTest -Top 'tb_crc32_word_accelerator' -Sources @(
    (Join-Path $ProjectRoot 'rtl\core\execute\crc32_word_accelerator.sv'),
    (Join-Path $ProjectRoot 'sim\tb_crc32_word_accelerator.sv')
)

Invoke-XsimTest -Top 'tb_state_transition_accelerator' -Sources @(
    (Join-Path $ProjectRoot 'rtl\core\execute\state_transition_accelerator.sv'),
    (Join-Path $ProjectRoot 'sim\tb_state_transition_accelerator.sv')
)

Invoke-XsimTest -Top 'tb_muldiv_unit' -Sources @(
    $Cfg,
    $Types,
    (Join-Path $ProjectRoot 'rtl\pkg\rv32_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\core\execute\muldiv_unit.sv'),
    (Join-Path $ProjectRoot 'sim\tb_muldiv_unit.sv')
)

Invoke-XsimTest -Top 'tb_rv32_mul_partial_products' -Sources @(
    (Join-Path $ProjectRoot 'rtl\core\execute\rv32_mul_partial_products.sv'),
    (Join-Path $ProjectRoot 'sim\tb_rv32_mul_partial_products.sv')
)

Invoke-XsimTest -Top 'tb_rename_map' -Sources @(
    $Cfg,
    $Types,
    (Join-Path $ProjectRoot 'rtl\core\rename\rename_map.sv'),
    (Join-Path $ProjectRoot 'sim\tb_rename_map.sv')
)

Invoke-XsimTest -Top 'tb_physical_regfile' -Sources @(
    $Cfg,
    $Types,
    (Join-Path $ProjectRoot 'rtl\core\rename\physical_regfile_lane.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\physical_regfile.sv'),
    (Join-Path $ProjectRoot 'sim\tb_physical_regfile.sv')
)

Invoke-XsimTest -Top 'tb_issue_queue' -Sources @(
    $Cfg,
    $Types,
    (Join-Path $ProjectRoot 'rtl\pkg\rv32_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\pkg\backend_types_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\core\backend\issue_queue.sv'),
    (Join-Path $ProjectRoot 'sim\tb_issue_queue.sv')
)

Invoke-XsimTest -Top 'tb_csr_file' -Sources @(
    (Join-Path $ProjectRoot 'rtl\core\commit\csr_file.sv'),
    (Join-Path $ProjectRoot 'sim\tb_csr_file.sv')
)

Invoke-XsimTest -Top 'tb_csr_execute' -Sources @(
    (Join-Path $ProjectRoot 'rtl\pkg\rv32_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\core\execute\csr_execute.sv'),
    (Join-Path $ProjectRoot 'sim\tb_csr_execute.sv')
)

Invoke-XsimTest -Top 'tb_branch_checkpoints' -Sources @(
    $Cfg,
    $Types,
    (Join-Path $ProjectRoot 'rtl\core\rename\branch_checkpoints.sv'),
    (Join-Path $ProjectRoot 'sim\tb_branch_checkpoints.sv')
)

Invoke-XsimTest -Top 'tb_load_queue' -Sources @(
    $Cfg,
    $Types,
    (Join-Path $ProjectRoot 'rtl\pkg\rv32_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\core\lsu\load_queue.sv'),
    (Join-Path $ProjectRoot 'sim\tb_load_queue.sv')
)

Invoke-XsimTest -Top 'tb_store_queue' -Sources @(
    $Cfg,
    $Types,
    (Join-Path $ProjectRoot 'rtl\core\lsu\store_queue.sv'),
    (Join-Path $ProjectRoot 'sim\tb_store_queue.sv')
)

Invoke-XsimTest -Top 'tb_instruction_cache' -Sources @(
    (Join-Path $ProjectRoot 'rtl\cache\cache_data_ram.sv'),
    (Join-Path $ProjectRoot 'rtl\cache\instruction_cache.sv'),
    (Join-Path $ProjectRoot 'sim\tb_instruction_cache.sv')
)

Invoke-XsimTest -Top 'tb_data_cache' -Sources @(
    (Join-Path $ProjectRoot 'rtl\cache\cache_data_ram.sv'),
    (Join-Path $ProjectRoot 'rtl\cache\data_cache.sv'),
    (Join-Path $ProjectRoot 'sim\tb_data_cache.sv')
)

Invoke-XsimTest -Top 'tb_dmem_request_fifo' -Sources @(
    $Cfg,
    $Types,
    (Join-Path $ProjectRoot 'rtl\soc\dmem_request_fifo.sv'),
    (Join-Path $ProjectRoot 'sim\tb_dmem_request_fifo.sv')
)

Invoke-XsimTest -Top 'tb_mret_interrupt_boundary' -Sources @(
    $Cfg,
    $Types,
    (Join-Path $ProjectRoot 'rtl\pkg\rv32_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\pkg\backend_types_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\pkg\mmio_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\free_bitmap.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\rename_map.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\physical_regfile_lane.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\physical_regfile.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\branch_checkpoints.sv'),
    (Join-Path $ProjectRoot 'rtl\core\backend\rob.sv'),
    (Join-Path $ProjectRoot 'rtl\core\backend\issue_queue.sv'),
    (Join-Path $ProjectRoot 'rtl\core\lsu\load_queue.sv'),
    (Join-Path $ProjectRoot 'rtl\core\lsu\store_queue.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\rv32_decode.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\branch_predictor.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\fetch_bundle_queue.sv'),
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
    (Join-Path $ProjectRoot 'sim\tb_mret_interrupt_boundary.sv')
)

Invoke-XsimTest -Top 'tb_fetch_redirect_stale_response' -Sources @(
    $Cfg,
    $Types,
    (Join-Path $ProjectRoot 'rtl\pkg\rv32_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\pkg\backend_types_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\pkg\mmio_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\free_bitmap.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\rename_map.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\physical_regfile_lane.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\physical_regfile.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\branch_checkpoints.sv'),
    (Join-Path $ProjectRoot 'rtl\core\backend\rob.sv'),
    (Join-Path $ProjectRoot 'rtl\core\backend\issue_queue.sv'),
    (Join-Path $ProjectRoot 'rtl\core\lsu\load_queue.sv'),
    (Join-Path $ProjectRoot 'rtl\core\lsu\store_queue.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\rv32_decode.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\branch_predictor.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\fetch_bundle_queue.sv'),
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
    (Join-Path $ProjectRoot 'sim\tb_fetch_redirect_stale_response.sv')
)

Invoke-XsimTest -Top 'tb_dmem_response_collision' -Sources @(
    (Join-Path $ProjectRoot 'rtl\pkg\soc_cfg_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\pkg\core_types_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\pkg\rv32_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\pkg\backend_types_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\pkg\mmio_pkg.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\free_bitmap.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\rename_map.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\physical_regfile_lane.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\physical_regfile.sv'),
    (Join-Path $ProjectRoot 'rtl\core\rename\branch_checkpoints.sv'),
    (Join-Path $ProjectRoot 'rtl\core\backend\rob.sv'),
    (Join-Path $ProjectRoot 'rtl\core\backend\issue_queue.sv'),
    (Join-Path $ProjectRoot 'rtl\core\lsu\load_queue.sv'),
    (Join-Path $ProjectRoot 'rtl\core\lsu\store_queue.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\rv32_decode.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\branch_predictor.sv'),
    (Join-Path $ProjectRoot 'rtl\core\frontend\fetch_bundle_queue.sv'),
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
    (Join-Path $ProjectRoot 'rtl\cache\cache_data_ram.sv'),
    (Join-Path $ProjectRoot 'rtl\cache\instruction_cache.sv'),
    (Join-Path $ProjectRoot 'rtl\cache\data_cache.sv'),
    (Join-Path $ProjectRoot 'rtl\soc\mmio_decode.sv'),
    (Join-Path $ProjectRoot 'rtl\periph\uart.sv'),
    (Join-Path $ProjectRoot 'rtl\periph\tick_timer.sv'),
    (Join-Path $ProjectRoot 'rtl\soc\irq_debug.sv'),
    (Join-Path $ProjectRoot 'rtl\soc\soc_peripherals.sv'),
    (Join-Path $ProjectRoot 'rtl\soc\unified_bram.sv'),
    (Join-Path $ProjectRoot 'rtl\soc\dmem_request_fifo.sv'),
    (Join-Path $ProjectRoot 'rtl\soc\ooo_soc_system.sv'),
    (Join-Path $ProjectRoot 'sim\tb_dmem_response_collision.sv')
)

Write-Host 'All XSim unit tests passed.'
