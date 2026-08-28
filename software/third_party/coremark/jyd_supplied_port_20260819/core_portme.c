/*
Copyright 2018 Embedded Microprocessor Benchmark Consortium (EEMBC)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Original Author: Shay Gal-on
*/

#include "coremark.h"
#include "core_portme.h"
#include <rtthread.h>   /* RT-Thread 标准头文件 */

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* ========== 计时部分 ========== */

/* 选手必须实现此函数 */
CORETIMETYPE barebones_clock()
{
 // 读取 mcycle 或 mtime CSR
    return (CORETIMETYPE)read_csr(mcycle);  
}

#define GETMYTIME(_t)              (*_t = barebones_clock())
#define MYTIMEDIFF(fin, ini)       ((fin) - (ini))
#define TIMER_RES_DIVIDER          1
#define SAMPLE_TIME_IMPLEMENTATION 1

/* 选手根据 barebones_clock() 的单位配置 */
#ifndef EE_TICKS_PER_SEC
#define EE_TICKS_PER_SEC  80000000  // 你的 CPU 频率
#endif

static CORETIMETYPE start_time_val, stop_time_val;

void start_time(void)
{
    GETMYTIME(&start_time_val);
}

void stop_time(void)
{
    GETMYTIME(&stop_time_val);
}

CORE_TICKS get_time(void)
{
    CORE_TICKS elapsed = (CORE_TICKS)(MYTIMEDIFF(stop_time_val, start_time_val));
    return elapsed;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    secs_ret retval = ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
    return retval;
}

/* ========== 结束计时部分 ========== */

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    /* 选手在此添加板级初始化（串口、时钟等） */
    (void)argc;
    (void)argv;

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
    {
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
    }
    if (sizeof(ee_u32) != 4)
    {
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    }
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
}

/* ===== Team ID 交互 + msh 命令 ===== */

extern char rt_hw_console_getchar(void);

static char g_team_id[32] = "DEFAULT_TEAM";

static void get_team_id_interactive(void)
{
    int i = 0;
    int c;
    int pending = -1;

    g_team_id[0] = '\0';

    rt_thread_mdelay(20);
    while ((c = (int)rt_hw_console_getchar()) >= 0)
    {
        if (c == '\r' || c == '\n')
            continue;
        pending = c;
        break;
    }

    rt_kprintf("\r\n");
    rt_kprintf("========================================\r\n");
    rt_kprintf("Please enter your Team ID and press Enter:\r\n");
    rt_kprintf("team id: ");

    if (pending >= 32 && pending <= 126)
    {
        g_team_id[i++] = (char)pending;
        g_team_id[i] = '\0';
        rt_kprintf("%c", pending);
    }

    while (i < (int)sizeof(g_team_id) - 1)
    {
        c = (int)rt_hw_console_getchar();

        if (c < 0)
            continue;

        if (c == '\r' || c == '\n')
        {
            rt_kprintf("\r\n");
            break;
        }

        if (c == '\b' || c == 127)
        {
            if (i > 0)
            {
                i--;
                g_team_id[i] = '\0';
                rt_kprintf("\b \b");
            }
            continue;
        }

        if (c >= 32 && c <= 126)
        {
            g_team_id[i++] = (char)c;
            g_team_id[i] = '\0';
            rt_kprintf("%c", c);
        }
    }

    if (i == 0)
    {
        const char default_id[] = "NO_ID";
        int j;
        for (j = 0; default_id[j] != '\0'; j++)
            g_team_id[j] = default_id[j];
        g_team_id[j] = '\0';
    }

    rt_kprintf("Team ID locked: %s\r\n", g_team_id);
    rt_kprintf("Starting CoreMark, please wait...\r\n");
    rt_kprintf("========================================\r\n\r\n");
}

extern MAIN_RETURN_TYPE coremark_main(void);

static void coremark(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    get_team_id_interactive();

    rt_kprintf("CoreMark Team ID: %s\r\n", g_team_id);

    coremark_main();

    rt_kprintf("CoreMark Team ID: %s\r\n", g_team_id);
}

/* 导出 msh 命令（需要启用 FinSH 组件） */
#ifdef RT_USING_FINSH
#include <finsh.h>
MSH_CMD_EXPORT(coremark, run EEMBC CoreMark);
#endif

/* ===== 新增结束 ===== */
