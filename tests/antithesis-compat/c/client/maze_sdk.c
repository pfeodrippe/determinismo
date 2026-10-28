// SPDX-License-Identifier: MIT
// The maze with determinismo's C SDK (sdk/c) instead of libvoidstar: its coverage edges, from
// clang's trace-pc-guard, are reported as the source lines they are on (its binary is in
// /symbols), as code built for Antithesis.
#define DETERMINISMO_IMPLEMENTATION
#define DETERMINISMO_COVERAGE
#include "determinismo.h"

static unsigned digit(void) {
    return (unsigned)det_random_below(10);
}

int main(void) {
    unsigned found = 0;
    if (digit() == 7) {
        found = 1;
        if (digit() == 3) {
            found = 2;
            if (digit() == 9) {
                found = 3;
            }
        }
    }
    printf("maze (sdk): %u digits\n", found);
    return 0;
}
