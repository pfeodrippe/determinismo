// SPDX-License-Identifier: MIT
// The callbacks of trace-pc-guard instrumentation (the C SDK's, sdk/c/determinismo.h): guards hold
// an edge's number, 0 once reported, so each edge costs one event, the first time it runs. Inside
// determinismo only; compiled without the instrumentation (build.rs).
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 02000000
#endif

static int determinismo_coverage_device = -2;

void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
  static uint32_t next = 1;
  if (start == stop || *start) return; /* Already numbered. */
  for (uint32_t *guard = start; guard < stop; guard++) *guard = next++;
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
  if (!*guard) return;
  if (determinismo_coverage_device == -2) {
    determinismo_coverage_device = open("/dev/determinismo", O_RDWR | O_CLOEXEC);
  }
  uint32_t edge = *guard;
  *guard = 0;
  if (determinismo_coverage_device < 0) return; /* Outside determinismo: nothing to report. */
  char line[80];
  int length = snprintf(line, sizeof line, "{\"event\":\"coverage\",\"details\":{\"name\":\"edge %u\"}}", edge);
  if (length > 0) (void)!write(determinismo_coverage_device, line, (size_t)length);
}
