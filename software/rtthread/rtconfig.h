#ifndef RT_CONFIG_H__
#define RT_CONFIG_H__

/* RT-Thread Nano 3.1.5 configuration for the JYD RV32IM SoC. */
#define RT_NAME_MAX                    16
#define RT_ALIGN_SIZE                  16
#define RT_THREAD_PRIORITY_32
#define RT_THREAD_PRIORITY_MAX         32
#define RT_TICK_PER_SECOND             100
#define RT_USING_OVERFLOW_CHECK
#define RT_DEBUG

#define IDLE_THREAD_STACK_SIZE         512

#define RT_USING_SEMAPHORE

#define RT_USING_CONSOLE
#define RT_CONSOLEBUF_SIZE             256

/* Official RT-Thread v3.1.5 FinSH module shell, trimmed to MSH-only mode. */
#define RT_USING_COMPONENTS_INIT
#define RT_USING_MINILIBC
#define RT_USING_FINSH
#define FINSH_USING_MSH
#define FINSH_USING_MSH_ONLY
#define FINSH_USING_SYMTAB
#define FINSH_USING_DESCRIPTION
#define FINSH_THREAD_NAME               "tshell"
#define FINSH_THREAD_PRIORITY           20
#define FINSH_THREAD_STACK_SIZE         2048
#define FINSH_CMD_SIZE                  80
#define FINSH_ARG_MAX                   8

#define RT_USING_USER_MAIN
#define RT_MAIN_THREAD_STACK_SIZE      2048
#define RT_MAIN_THREAD_PRIORITY        10

#endif
