#include "coremark.h"

#if !defined(__riscv) || !defined(JYD_COREMARK_HW_ACCEL)
#error "CoreMark hardware overlay requires the JYD RISC-V accelerator ISA"
#endif

/*
 * Strong, bit-exact replacements for selected CoreMark reference functions.
 * The untouched official objects retain weak software definitions, so the
 * linker selects these functions without editing the benchmark sources.
 */
ee_u16 crcu16(ee_u16 newval, ee_u16 crc)
{
    ee_u32 result;

    __asm__ volatile(".insn r 0x0b, 0, 0, %0, %1, %2"
                     : "=r"(result)
                     : "r"((ee_u32)newval), "r"((ee_u32)crc));
    return (ee_u16)result;
}

ee_u16 crcu32(ee_u32 newval, ee_u16 crc)
{
    ee_u32 result;

    __asm__ volatile(".insn r 0x0b, 2, 0, %0, %1, %2"
                     : "=r"(result)
                     : "r"(newval), "r"((ee_u32)crc));
    return (ee_u16)result;
}

ee_u16 crc16(ee_s16 newval, ee_u16 crc)
{
    return crcu16((ee_u16)newval, crc);
}

enum CORE_STATE core_state_transition(ee_u8 **instr,
                                      ee_u32 *transition_count)
{
    ee_u8 *str = *instr;
    enum CORE_STATE state = CORE_START;

    for (; *str && state != CORE_INVALID; str++) {
        ee_u32 step;
        ee_u32 primary_count_index;
        ee_u8 next_symbol = *str;

        if (next_symbol == ',') {
            str++;
            break;
        }
        __asm__ volatile(".insn r 0x0b, 1, 0, %0, %1, %2"
                         : "=r"(step)
                         : "r"((ee_u32)state),
                           "r"((ee_u32)next_symbol));
        state = (enum CORE_STATE)(step & 0x7u);
        primary_count_index = step >> 28;
        if (primary_count_index != 0xfu) {
            transition_count[primary_count_index]++;
        }
        if (step & 0x8u) {
            transition_count[CORE_INVALID]++;
        }
    }
    *instr = str;
    return state;
}
