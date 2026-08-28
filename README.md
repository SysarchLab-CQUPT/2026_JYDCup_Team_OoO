# 蓝桥杯大于 CCPC

本仓库是 CICC1004534 团队面向竞业达 Kintex-7 板卡实现的自研 RV32IM
乱序双发射 SoC。CPU、缓存、存储系统、互连、外设和验证环境均为自研；官方包
仅用于目标器件、板级 XDC 和 PLL/XCI。系统运行 RT-Thread Nano 3.1.5、
FinSH/MSH 和官方 CoreMark 1.0，板卡目标使用 18,000 次迭代、`-O3` 与
位精确硬件加速。

## 实体板结果

- SoC 时钟：**200 MHz**。
- CoreMark：**723 Iterations/Sec**（实体板实测）。
- 板测 bit：`reference/board_tested_200mhz/JYD2025_200MHz_CoreMark18000_BOARD_TESTED_723iters.bit`。
- 板测 bit SHA-256：`5B498BEDF13F23DB230AA75D6D8DC45C72F33808972659AE06405D9B90C7C250`。
- 50 MHz 的 DS18B20 测温与数码管扫描时钟保持独立，不随 SoC 超频改变。

200 MHz 文件是基于已验收 150 MHz 物理布线的实体板超频版本；它通过板卡运行
验证，但不表述为 200 MHz STA 收敛。150 MHz 版本保留完整 routed STA/DRC
签核与精确 post-route DCP。

## 处理器与 SoC

- RV32IM + Zicsr + Zifencei，双取指、双译码、双重命名、双发射、双提交。
- 32 项 ROB、64 个物理寄存器、精确异常和按序提交。
- 双 bank 整数发射队列，8 项 LQ、8 项 SQ，支持存储转发和分支精确恢复。
- 2-way ICache/DCache、64 KiB 双口片上 BRAM。
- UART、tick timer、IRQ/debug MMIO、CoreMark LED。
- 独立 50 MHz DS18B20 主机与八位数码管实时温度显示。

## 目录

- `rtl/`：全部 SystemVerilog 源码。
- `constraints/board.xdc`：完整板级管脚和时序约束。
- `ip/pll/pll.xci`：官方 PLL 配置。
- `flow/`：建工程、综合、实现、时序报告、签核和 bit 复现脚本。
- `software/`：启动代码、RT-Thread 3.1.5、FinSH/MSH、CoreMark 与移植层。
- `sim/`：XSim 独立模块测试和 Verilator 整机测试。
- `reference/`：150 MHz 签核 bit/DCP、固件、报告和 200 MHz 板测 bit。
- `docs/`：完整技术报告（Word 与 PDF）。

## 环境

1. Windows PowerShell 5.1 或 PowerShell 7。
2. AMD Vivado 2025.2。
3. MSYS2 UCRT64 Clang/LLVM。
4. Python 3。

## 复现 150 MHz 签核 bit

```powershell
powershell -ExecutionPolicy Bypass -File .\CHECK_PACKAGE.ps1
powershell -ExecutionPolicy Bypass -File .\BUILD_150MHZ.ps1
```

输出：

```text
output/jyd_soc_top_rtthread_coremark_150mhz.bit
```

脚本重新编译固件、更新 16 个 RAMB36 的 INIT/INITP、执行 routed sign-off，
最终配置负载与参考 bit 一致。参考文件：

- bit：`reference/current_bit/jyd_soc_top_rtthread_coremark_150mhz.bit`
- bit SHA-256：`D415F26FA8B279847A77464727A233978E8837DE69B3435953C7F1881AC38969`
- DCP：`reference/accepted_route/jyd_soc_top_150mhz_accepted_route.dcp`
- DCP SHA-256：`FB7C6E9BD75E175B4E6D59FE3B043EF951474DB99761F30A7A1BF941650F414B`

## 生成直接超频 bit

```powershell
powershell -ExecutionPolicy Bypass -File .\BUILD_DIRECT_OVERCLOCK.ps1 -SocClockMHz 200
```

也支持 `250`。该流程保留 150 MHz 的已验收布局布线，只替换目标频率固件和
PLL 参数，不执行目标频率 STA。正式频率签核仍应使用
`flow/build_coremark_bitstream.ps1` 完成全量综合、实现和时序门禁。

## 仿真

```powershell
powershell -ExecutionPolicy Bypass -File .\sim\run_xsim_unit_tests.ps1
powershell -ExecutionPolicy Bypass -File .\sim\run_verilator_firmware_tests.ps1 -SocClockMHz 150
```

串口参数：`115200 8N1`，无流控。MSH 中使用 `coremark` 启动测试。
