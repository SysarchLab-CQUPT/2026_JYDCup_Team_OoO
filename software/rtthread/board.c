#include <rthw.h>
#include <rtthread.h>

#include "platform.h"

#define MCAUSE_INTERRUPT_FLAG 0x80000000u
#define MCAUSE_MACHINE_TIMER  (MCAUSE_INTERRUPT_FLAG | 7u)
#define MCAUSE_MACHINE_EXT    (MCAUSE_INTERRUPT_FLAG | 11u)
#define MIE_MTIE              (1u << 7)

static void write_hex32(jyd_u32 value)
{
    static const char digits[] = "0123456789abcdef";
    int shift;

    for (shift = 28; shift >= 0; shift -= 4) {
        uart_putc(digits[(value >> (unsigned int)shift) & 0xfu]);
    }
}

void rt_hw_console_output(const char *str)
{
    while (*str != '\0') {
        if (*str == '\n') {
            uart_putc('\r');
        }
        uart_putc(*str++);
    }
}

char rt_hw_console_getchar(void)
{
    char value;

    /* The UART has a one-byte receive register, so sleeping for a 100 Hz
     * system tick here would drop characters at 115200 baud.  The official
     * FinSH thread blocks in this BSP hook; higher-priority RT-Thread work
     * still preempts it normally. */
    while (!uart_try_getc(&value)) {
    }
    return value;
}

void rt_hw_interrupt_init(void)
{
    jyd_u32 trap_address;

    __asm__ volatile("la %0, trap_entry" : "=r"(trap_address));
    __asm__ volatile("csrw mtvec, %0" : : "r"(trap_address));
    __asm__ volatile("csrs mie, %0" : : "r"(MIE_MTIE));
}

static void rt_hw_timer_init(void)
{
#ifdef RTTHREAD_TIMER_RELOAD_CYCLES
    jyd_u32 reload = RTTHREAD_TIMER_RELOAD_CYCLES - 1u;
#else
    jyd_u32 reload = (jyd_clock_hz() / RT_TICK_PER_SECOND) - 1u;
#endif

    JYD_TIMER_CTRL = 0u;
    JYD_TIMER_ACK = 1u;
    JYD_TIMER_RELOAD = reload;
    JYD_TIMER_COUNT = reload;
    JYD_TIMER_CTRL = 3u;
}

void rt_hw_board_init(void)
{
    uart_init(115200u);
    rt_hw_interrupt_init();
    rt_hw_timer_init();
}

void handle_trap(jyd_u32 mcause, jyd_u32 epc, void *irq_stack)
{
    jyd_u32 mtval;

    (void)irq_stack;

    if (mcause == MCAUSE_MACHINE_TIMER) {
        JYD_TIMER_ACK = 1u;
        rt_tick_increase();
        return;
    }

    if (mcause == MCAUSE_MACHINE_EXT) {
        JYD_IRQ_ACK = JYD_IRQ_PENDING;
        return;
    }

    __asm__ volatile("csrr %0, mtval" : "=r"(mtval));
    uart_puts("\r\nFATAL TRAP mcause=0x");
    write_hex32(mcause);
    uart_puts(" mepc=0x");
    write_hex32(epc);
    uart_puts(" mtval=0x");
    write_hex32(mtval);
    uart_puts("\r\n");
    JYD_COMPLETION_ADDR = 0xdead0000u | (mcause & 0xffffu);
    for (;;) {
    }
}

void rt_hw_cpu_shutdown(void)
{
    for (;;) {
    }
}
