# RT-Thread 3.1.5 provenance

This directory contains the `include`, `src`, `libcpu/risc-v/e310`,
`components/finsh`, and `components/libc/compilers/minilibc` subtrees from the
official RT-Thread `v3.1.5` tag, commit
`92beddf3bccf6346e26aa097f82464456fb8e6bd`.

The JYD port changes the E310 initial thread stack alignment from 8 bytes to
the required RV32 16-byte alignment. It also guards the legacy newlib
compatibility includes when the Nano configuration is deliberately libc-free.
Board startup, memory layout, trap handling, timer, UART, and application code
live outside this upstream tree.
