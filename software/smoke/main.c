#include "platform.h"

static volatile jyd_u32 runtime_seed = 7u;
static volatile jyd_u32 scratch[16];

int main(void)
{
    jyd_u32 seed = runtime_seed;
    jyd_u32 checksum = 0u;

    uart_puts("JYD OOO RV32IM boot\r\n");
    for (jyd_u32 i = 0u; i < 16u; ++i) {
        jyd_u32 value = (seed * (i + 3u)) ^ (0x13579bdfu >> (i & 7u));
        scratch[i] = value;
        checksum += scratch[i] / (i + 1u);
    }

    if (checksum != 0x1eb8c38au) {
        uart_puts("SELFTEST FAIL\r\n");
        return 1;
    }

    uart_puts("SELFTEST PASS\r\n");
    return 0;
}
