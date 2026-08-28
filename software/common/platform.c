#include "platform.h"

void uart_init(jyd_u32 baud)
{
    jyd_u32 divisor;

    divisor = (jyd_clock_hz() + (baud / 2u)) / baud;
    JYD_UART_CTRL = 0u;
    /* The UART register itself clamps values below two.  Writing the derived
     * value directly also keeps one unambiguous clock-to-divider path. */
    JYD_UART_BAUD_DIV = divisor;
}

void uart_putc(char value)
{
    while ((JYD_UART_STATUS & 1u) == 0u) {
    }
    JYD_UART_TXDATA = (jyd_u32)(unsigned char)value;
}

int uart_try_getc(char *value)
{
    if ((JYD_UART_STATUS & 2u) == 0u) {
        return 0;
    }
    *value = (char)(JYD_UART_RXDATA & 0xffu);
    return 1;
}

jyd_u32 jyd_clock_hz(void)
{
    return (jyd_u32)SOC_CLK_HZ;
}

void uart_puts(const char *value)
{
    while (*value != '\0') {
        uart_putc(*value++);
    }
}

jyd_u32 read_mcycle32(void)
{
    jyd_u32 value;
    __asm__ volatile("csrr %0, mcycle" : "=r"(value));
    return value;
}

jyd_u32 read_mcycle_shifted8(void)
{
    jyd_u32 high_before;
    jyd_u32 high_after;
    jyd_u32 low;

    do {
        __asm__ volatile("csrr %0, mcycleh" : "=r"(high_before));
        __asm__ volatile("csrr %0, mcycle" : "=r"(low));
        __asm__ volatile("csrr %0, mcycleh" : "=r"(high_after));
    } while (high_before != high_after);

    return (high_after << 24) | (low >> 8);
}
