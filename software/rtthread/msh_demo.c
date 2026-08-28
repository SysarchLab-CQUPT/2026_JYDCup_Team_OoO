#include <rtthread.h>
#include <finsh.h>

int simple_add(int argc, char **argv)
{
    rt_uint32_t upper;

    (void)argv;
    if (argc != 1) {
        rt_kprintf("Usage: simple_add\n");
        return -RT_EINVAL;
    }

    for (upper = 99u; upper <= 999u; upper += 100u) {
        rt_uint32_t sum = (upper * (upper + 1u)) / 2u;
        rt_kprintf("add 1 to %u, sum=%u\n",
                   (unsigned int)upper, (unsigned int)sum);
    }
    return 0;
}
MSH_CMD_EXPORT(simple_add, demonstrate an RT-Thread MSH application command);
