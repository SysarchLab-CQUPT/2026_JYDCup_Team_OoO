#include <rtthread.h>
#include <finsh.h>

#include "platform.h"

int coremark_entry(void);

#define COREMARK_STACK_BYTES 8192u
#define TEAM_ID_BYTES        32u

#ifndef RTTHREAD_SIM_RUNS
#define RTTHREAD_SIM_RUNS    1u
#endif

static struct rt_thread coremark_thread;
ALIGN(16)
static rt_uint8_t coremark_stack[COREMARK_STACK_BYTES];
static struct rt_semaphore coremark_sem;
static volatile rt_uint32_t coremark_busy;
static volatile rt_uint32_t coremark_runs;
static char coremark_team_id[TEAM_ID_BYTES] = "DEFAULT_TEAM";

char rt_hw_console_getchar(void);

static void set_coremark_team_id(const char *value)
{
    const char *source = value;
    rt_size_t index = 0u;

    if (*source == '\0') {
        source = "NO_ID";
    }
    while ((*source != '\0') && (index < (sizeof(coremark_team_id) - 1u))) {
        coremark_team_id[index++] = *source++;
    }
    coremark_team_id[index] = '\0';
}

static void queue_coremark_with_team_id(const char *team_id)
{
    set_coremark_team_id(team_id);
    coremark_busy = 1u;
    rt_kprintf("Team ID locked: %s\n", coremark_team_id);
    rt_kprintf("Starting CoreMark, please wait...\n");
    rt_kprintf("========================================\n");
    rt_sem_release(&coremark_sem);
}

static void coremark_worker(void *parameter)
{
    int result;

    (void)parameter;
    for (;;) {
        rt_sem_take(&coremark_sem, RT_WAITING_FOREVER);
        rt_kprintf("\nCoreMark Team ID: %s\n", coremark_team_id);
        rt_kprintf("COREMARK BEGIN (RT-Thread worker, stack=%u)\n",
                   (unsigned int)sizeof(coremark_stack));
        result = coremark_entry();
        coremark_runs++;
        coremark_busy = 0u;
        rt_kprintf("CoreMark Team ID: %s\n", coremark_team_id);
        rt_kprintf("COREMARK DONE rc=%d runs=%u\n", result,
                   (unsigned int)coremark_runs);
#ifdef RTTHREAD_SIM_COMPLETION
        if (coremark_runs >= RTTHREAD_SIM_RUNS) {
            JYD_COMPLETION_ADDR = 0x600d0000u;
        }
#endif
    }
}

static void read_team_id(char *buffer, rt_size_t capacity)
{
    rt_size_t length = 0u;

    for (;;) {
        char value = rt_hw_console_getchar();

        if ((value == '\r') || (value == '\n')) {
            rt_kprintf("\n");
            buffer[length] = '\0';
            return;
        }
        if ((value == '\b') || ((unsigned char)value == 0x7fu)) {
            if (length != 0u) {
                length--;
                rt_kprintf("\b \b");
            }
            continue;
        }
        if ((value >= ' ') && (value <= '~') &&
            (length < (capacity - 1u))) {
            buffer[length++] = value;
            rt_kprintf("%c", value);
        }
    }
}

int status(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    rt_kprintf("STATUS RT-Thread=3.1.5 Nano CLK_HZ=%u TICK=%u COREMARK=%s RUNS=%u\n",
               (unsigned int)jyd_clock_hz(),
               (unsigned int)rt_tick_get(),
               coremark_busy ? "RUNNING" : "IDLE",
               (unsigned int)coremark_runs);
    return 0;
}
MSH_CMD_EXPORT(status, show JYD SoC and CoreMark status);

int ticks(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    rt_kprintf("TICK %u\n", (unsigned int)rt_tick_get());
    return 0;
}
MSH_CMD_EXPORT(ticks, show the RT-Thread tick counter);

int coremark(int argc, char **argv)
{
    char team_id[TEAM_ID_BYTES];

    if (coremark_busy) {
        rt_kprintf("COREMARK BUSY\n");
        return -RT_EBUSY;
    }
    if (argc > 2) {
        rt_kprintf("Usage: coremark [team_id]\n");
        return -RT_EINVAL;
    }

    if (argc == 2) {
        queue_coremark_with_team_id(argv[1]);
    } else {
        rt_kprintf("========================================\n");
        rt_kprintf("Please enter your Team ID and press Enter:\n");
        rt_kprintf("team id: ");
        read_team_id(team_id, sizeof(team_id));
        queue_coremark_with_team_id(team_id);
    }
    return 0;
}
MSH_CMD_EXPORT(coremark, run CoreMark in an RT-Thread worker);

int main(void)
{
    rt_err_t result;

    result = rt_sem_init(&coremark_sem, "cmsem", 0u, RT_IPC_FLAG_FIFO);
    RT_ASSERT(result == RT_EOK);
    result = rt_thread_init(&coremark_thread, "coremark", coremark_worker,
                            RT_NULL, coremark_stack, sizeof(coremark_stack),
                            5u, 10u);
    RT_ASSERT(result == RT_EOK);
    result = rt_thread_startup(&coremark_thread);
    RT_ASSERT(result == RT_EOK);

    rt_kprintf("JYD self-developed RV32IM SoC\n");
    rt_kprintf("RT-Thread Nano 3.1.5 ready; UART 115200 8N1\n");
    rt_kprintf("Official FinSH/MSH console ready; type help\n");
    return 0;
}
