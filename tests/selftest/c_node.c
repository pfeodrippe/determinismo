/* SPDX-License-Identifier: MIT */
/* det-selftest-c: a node written in C, reporting through the C SDK (sdk/c/determinismo.h). */
#define DETERMINISMO_IMPLEMENTATION
#include "determinismo.h"

#include <unistd.h>

int main(void) {
  uint64_t value = det_random_below(1000);
  DET_REACHABLE("the C node started", NULL);
  DET_ALWAYS(value < 1000, "the C SDK's randomness stays below its bound", NULL);
  det_event("c_node", "{\"started\":true}");
  for (;;) pause(); /* A service: it runs until the timeline ends. */
}
