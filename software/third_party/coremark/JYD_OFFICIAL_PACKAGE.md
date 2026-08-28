# 竞业达官方 CoreMark 包对接说明

本目录中的 CoreMark 1.0 算法源码已按竞业达提供的
`coremark（已解压版本）.zip` 对齐。

- 原始压缩包 SHA-256：`7EA87B722498DFA71CC24F09C51DF2BA21736265834D3C75760C203D749928FA`
- 实际参与构建的 `core_list_join.c`、`core_main.c`、`core_matrix.c`、
  `core_state.c`、`core_util.c`、`coremark.h` 均按压缩包原始字节覆盖，
  SHA-256 逐文件一致。
- 压缩包使用 LF。根目录 `.gitattributes` 对这些文件固定 `eol=lf`，避免
  Windows Git 的 `core.autocrlf=true` 再次改写字节。
- 压缩包中的五个移植层文件原样保存在 `jyd_supplied_port_20260819`，逐文件
  哈希见 `JYD_SOURCE_SHA256_20260819.txt`。

压缩包中的 `core_portme.c/.h` 包含面向另一套 RT-Thread BSP 的 CSR、stdio、
命令注册和 80 MHz 计时假设，不能直接替换本工程的板级移植层。因此计时、串口、
静态内存重复运行初始化及 LED 指示仍由 `software/coremark_port` 实现；Team ID
交互由 RT-Thread 3.1.5 官方 FinSH/MSH 的 `coremark` 导出命令实现。CoreMark
算法文件保持原样，UART 的 LF 到 CRLF 转换只在输出移植层完成。硬件加速由
`software/coremark_port/coremark_accel.c` 提供：
构建脚本把官方对象中的 CRC/状态转换参考实现降为弱符号，再由位精确的强符号覆盖，
因此官方文件保持不变，最终 CoreMark CRC 也必须与参考值完全一致。

当前 `rtthread_board` 目标默认编译为 18000 次迭代；若现场下发版本改变次数，
可用构建参数 `-CoreMarkIterations` 覆盖，而无需改动算法源码。板卡默认使用已有实体板
高于 600 Iterations/Sec 且等效 IPC 高于 1.20 的 `-O3`，硬件加速保持启用。
