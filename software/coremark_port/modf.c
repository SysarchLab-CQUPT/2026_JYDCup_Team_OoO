#include "math.h"

double modf(double value, double *integer_part)
{
    union {
        double floating;
        unsigned long long bits;
    } input, integral, zero;
    unsigned int exponent_bits;
    int exponent;
    unsigned long long fraction_mask;

    input.floating = value;
    exponent_bits = (unsigned int)((input.bits >> 52) & 0x7ffu);
    exponent = (int)exponent_bits - 1023;

    zero.bits = input.bits & (1ull << 63);
    if (exponent < 0) {
        *integer_part = zero.floating;
        return value;
    }
    if (exponent >= 52) {
        *integer_part = value;
        if (exponent_bits == 0x7ffu && (input.bits & 0x000fffffffffffffull)) {
            return value;
        }
        return zero.floating;
    }

    fraction_mask = (1ull << (52 - (unsigned int)exponent)) - 1ull;
    if ((input.bits & fraction_mask) == 0ull) {
        *integer_part = value;
        return zero.floating;
    }

    integral.bits = input.bits & ~fraction_mask;
    *integer_part = integral.floating;
    return value - integral.floating;
}
