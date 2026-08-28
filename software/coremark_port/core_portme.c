#include "coremark.h"
#include "platform.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#elif PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#else
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif

volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;

#if (MEM_METHOD == MEM_STATIC)
extern ee_u8 static_memblk[TOTAL_DATA_SIZE];
#endif

static CORETIMETYPE start_time_value;
static CORETIMETYPE stop_time_value;

void start_time(void)
{
    JYD_COREMARK_LED = 1u;
    __asm__ volatile("fence iorw, iorw" ::: "memory");
    start_time_value = read_mcycle_shifted8();
}

void stop_time(void)
{
    stop_time_value = read_mcycle_shifted8();
    JYD_COREMARK_LED = 0u;
    __asm__ volatile("fence iorw, iorw" ::: "memory");
}

CORE_TICKS get_time(void)
{
    return stop_time_value - start_time_value;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
#if HAS_FLOAT
    return ((secs_ret)ticks * 256.0) / (secs_ret)jyd_clock_hz();
#else
    return (ticks * 256u) / jyd_clock_hz();
#endif
}

void portable_init(core_portable *p, int *argc, char *argv[])
{
    ee_u32 i;

    (void)argc;
    (void)argv;
#if (MEM_METHOD == MEM_STATIC)
    // The UART command can invoke CoreMark more than once in the same RT-Thread
    // worker.  The upstream executable normally receives a zeroed static arena
    // exactly once from C startup; recreate that contract for every command.
    for (i = 0; i < TOTAL_DATA_SIZE; i++) {
        static_memblk[i] = 0u;
    }
    __asm__ volatile("fence rw, rw" ::: "memory");
#endif
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *) || sizeof(ee_u32) != 4u) {
        ee_printf("CoreMark port type error\n");
    }
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
}
