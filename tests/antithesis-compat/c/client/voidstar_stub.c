// SPDX-License-Identifier: MIT
// What the program links against at build time; in a node, determinismo's libvoidstar.so is
// at /usr/lib/libvoidstar.so instead (as Antithesis's is).
void __sanitizer_cov_trace_pc_guard_init(unsigned *start, unsigned *stop) {}
void __sanitizer_cov_trace_pc_guard(unsigned *guard) {}
unsigned long fuzz_get_random(void) { return 0; }
