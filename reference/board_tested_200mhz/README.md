# 200 MHz 实体板结果

- FPGA：`xc7k325tffg900-2`
- SoC：200 MHz
- CoreMark：18,000 iterations，`-O3`
- 实体板成绩：723 Iterations/Sec
- bit：`JYD2025_200MHz_CoreMark18000_BOARD_TESTED_723iters.bit`
- SHA-256：`5B498BEDF13F23DB230AA75D6D8DC45C72F33808972659AE06405D9B90C7C250`

该文件复用 150 MHz 已验收 post-route 物理布线，并将 PLL SoC 输出直接调整到
200 MHz。它是实体板超频产物，不是 200 MHz STA 收敛声明。
