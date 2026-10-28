// SPDX-License-Identifier: MIT
// The maze in C, instrumented as for Antithesis (clang's trace-pc-guard, linked against
// libvoidstar): four digits from the platform's randomness, 1 in 10000 attempts solves it. Its
// symbols are in /symbols, so its coverage edges are reported as the source lines they are on.
#include <stdio.h>

unsigned long fuzz_get_random(void);

static unsigned digit(void) {
    return (unsigned)(fuzz_get_random() % 10);
}

int main(void) {
    unsigned found = 0;
    if (digit() == 7) {
        found = 1;
        if (digit() == 3) {
            found = 2;
            if (digit() == 9) {
                found = 3;
                if (digit() == 1) {
                    puts("maze: solved");
                    return 1;
                }
            }
        }
    }
    printf("maze: %u digits\n", found);
    return 0;
}
