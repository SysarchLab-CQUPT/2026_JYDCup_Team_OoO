#ifndef JYD_PLATFORM_H
#define JYD_PLATFORM_H

typedef unsigned int jyd_u32;

#define JYD_UART_BASE       0x10000000u
#define JYD_UART_TXDATA     (*(volatile jyd_u32 *)(JYD_UART_BASE + 0x00u))
#define JYD_UART_RXDATA     (*(volatile jyd_u32 *)(JYD_UART_BASE + 0x04u))
#define JYD_UART_STATUS     (*(volatile jyd_u32 *)(JYD_UART_BASE + 0x08u))
#define JYD_UART_CTRL       (*(volatile jyd_u32 *)(JYD_UART_BASE + 0x0cu))
#define JYD_UART_BAUD_DIV   (*(volatile jyd_u32 *)(JYD_UART_BASE + 0x10u))

#define JYD_TIMER_BASE      0x10001000u
#define JYD_TIMER_COUNT     (*(volatile jyd_u32 *)(JYD_TIMER_BASE + 0x00u))
#define JYD_TIMER_RELOAD    (*(volatile jyd_u32 *)(JYD_TIMER_BASE + 0x04u))
#define JYD_TIMER_CTRL      (*(volatile jyd_u32 *)(JYD_TIMER_BASE + 0x08u))
#define JYD_TIMER_PENDING   (*(volatile jyd_u32 *)(JYD_TIMER_BASE + 0x0cu))
#define JYD_TIMER_ACK       (*(volatile jyd_u32 *)(JYD_TIMER_BASE + 0x10u))

#define JYD_IRQ_BASE        0x10002000u
#define JYD_IRQ_PENDING     (*(volatile jyd_u32 *)(JYD_IRQ_BASE + 0x00u))
#define JYD_IRQ_ENABLE      (*(volatile jyd_u32 *)(JYD_IRQ_BASE + 0x04u))
#define JYD_IRQ_ACK         (*(volatile jyd_u32 *)(JYD_IRQ_BASE + 0x08u))
#define JYD_BUILD_ID        (*(volatile jyd_u32 *)(JYD_IRQ_BASE + 0x0cu))
#define JYD_CLK_HZ          (*(volatile jyd_u32 *)(JYD_IRQ_BASE + 0x10u))
#define JYD_COREMARK_LED    (*(volatile jyd_u32 *)(JYD_IRQ_BASE + 0x14u))

#define JYD_COMPLETION_ADDR (*(volatile jyd_u32 *)0x0000fff0u)

void uart_init(jyd_u32 baud);
void uart_putc(char value);
void uart_puts(const char *value);
int uart_try_getc(char *value);
jyd_u32 jyd_clock_hz(void);
jyd_u32 read_mcycle32(void);
jyd_u32 read_mcycle_shifted8(void);

#endif
