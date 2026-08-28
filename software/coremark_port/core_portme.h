#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#ifdef COREMARK_HAS_FLOAT
#define HAS_FLOAT 1
#else
#define HAS_FLOAT 0
#endif
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0

#define COMPILER_VERSION "Clang " __clang_version__
#ifdef JYD_OPT_LEVEL_O2
#define JYD_COMPILER_OPT_FLAGS "-O2 "
#else
#define JYD_COMPILER_OPT_FLAGS "-O3 "
#endif
#ifdef JYD_COREMARK_HW_ACCEL
#define COMPILER_FLAGS JYD_COMPILER_OPT_FLAGS "-march=rv32im_zba_zicsr_zifencei -mabi=ilp32 -DJYD_COREMARK_HW_ACCEL=1"
#else
#define COMPILER_FLAGS JYD_COMPILER_OPT_FLAGS "-march=rv32im_zba_zicsr_zifencei -mabi=ilp32"
#endif
#define MEM_LOCATION "STATIC"

typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef float ee_f32;
typedef unsigned char ee_u8;
typedef unsigned int ee_u32;
typedef ee_u32 ee_ptr_int;
typedef __SIZE_TYPE__ ee_size_t;

#ifndef NULL
#define NULL ((void *)0)
#endif

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x) - 1) & ~3u))
#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;

#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK 0
#define USE_SOCKET 0
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);
int ee_printf(const char *fmt, ...);

#endif
