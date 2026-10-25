/* SPDX-License-Identifier: MIT */
/* det-maze: a deep path guarded by input values, for coverage-guided exploration (a node in the
   self-test system). `det-maze idle` keeps the node alive; `det-maze solve` is one attempt: four
   digits from platform randomness, each checked before the next is drawn. Solving it takes
   1 in 10000 attempts by chance; a strategy that keeps timelines reaching new edges climbs it
   one digit at a time. Built with -fsanitize-coverage=trace-pc-guard. */
#define DETERMINISMO_IMPLEMENTATION
#define DETERMINISMO_COVERAGE
#include "determinismo.h"

#include <string.h>
#include <unistd.h>

static int digit(void) { return (int)det_random_below(10); }

int main(int argc, char **argv) {
  if (argc < 2 || strcmp(argv[1], "solve") != 0) {
    for (;;) pause(); /* The node: an attempt is a command run inside it. */
  }
  int solved = 0;
  if (digit() == 7) {
    det_reachable("maze: first digit", NULL);
    if (digit() == 3) {
      det_reachable("maze: second digit", NULL);
      if (digit() == 9) {
        det_reachable("maze: third digit", NULL);
        if (digit() == 1) solved = 1;
      }
    }
  }
  det_always(!solved, "the maze is never solved", NULL);
  return 0;
}
