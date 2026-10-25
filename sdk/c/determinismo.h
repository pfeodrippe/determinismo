/* SPDX-License-Identifier: MIT */
/*
 * determinismo SDK for C and C++ (and anything with a C FFI): assertions, events and platform
 * randomness. Header-only: in exactly one file,
 *
 *     #define DETERMINISMO_IMPLEMENTATION
 *     #include "determinismo.h"
 *
 * Inside determinismo everything goes through /dev/determinismo (events are recorded with
 * their moment; random values are platform decisions, steerable and replayable). Outside it,
 * randomness comes from the OS and events go to stderr, so the same binary runs everywhere.
 * `details` arguments are JSON objects as strings ("{}" or NULL for none).
 *
 * Assertions: DET_ALWAYS, DET_ALWAYS_OR_UNREACHABLE, DET_SOMETIMES, DET_REACHABLE and
 * DET_UNREACHABLE take literal messages and put each call site in the program's assertion
 * catalog, announced as the program starts, before any assertion runs (Antithesis's catalog):
 * one no timeline reaches is judged too. The det_* functions take messages computed at run time,
 * known only once they run.
 *
 * Code coverage for strategies: build with `-fsanitize-coverage=trace-pc-guard` and define
 * DETERMINISMO_COVERAGE next to DETERMINISMO_IMPLEMENTATION. Each edge reports itself the first
 * time it runs (a "coverage" event), which strategies such as det-strategy-mutate use to keep
 * timelines that reach new code.
 */
#ifndef DETERMINISMO_H
#define DETERMINISMO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void det_random_bytes(void *target, size_t count);
uint64_t det_random_u64(void);
uint64_t det_random_below(uint64_t count); /* Uniform in [0, count). */

void det_always(int condition, const char *message, const char *details);
void det_always_or_unreachable(int condition, const char *message, const char *details);
void det_sometimes(int condition, const char *message, const char *details);
void det_reachable(const char *message, const char *details);
void det_unreachable(const char *message, const char *details);

void det_setup_complete(const char *details); /* The platform snapshots here. */
void det_event(const char *name, const char *details);

/* The assertion catalog: one entry per call site, in the det_catalog section (the layout the Zig
   SDK uses too); the magic tells entries from the linker's padding. */
struct det_catalog_entry {
  uint64_t magic;
  const char *kind;
  const char *message;
  uint64_t message_size;
};
#define DET_CATALOG_MAGIC 0x676f6c6174616364ull

#if defined(__has_attribute)
#if __has_attribute(retain)
#define DET_RETAIN __attribute__((retain))
#endif
#endif
#ifndef DET_RETAIN
#define DET_RETAIN
#endif

/* "" message "": a literal, or this does not compile. */
#define DET_CATALOG_SITE(kind, message)                                                        \
  do {                                                                                         \
    static const struct det_catalog_entry det_catalog_site_                                    \
        __attribute__((used, section("det_catalog"), aligned(8))) DET_RETAIN = {               \
            DET_CATALOG_MAGIC, kind, "" message "", sizeof(message) - 1};                      \
    (void)det_catalog_site_;                                                                   \
  } while (0)

#define DET_ALWAYS(condition, message, details)                                                \
  do {                                                                                         \
    DET_CATALOG_SITE("always", message);                                                       \
    det_always((condition), (message), (details));                                             \
  } while (0)
#define DET_ALWAYS_OR_UNREACHABLE(condition, message, details)                                 \
  do {                                                                                         \
    DET_CATALOG_SITE("always_or_unreachable", message);                                        \
    det_always_or_unreachable((condition), (message), (details));                              \
  } while (0)
#define DET_SOMETIMES(condition, message, details)                                             \
  do {                                                                                         \
    DET_CATALOG_SITE("sometimes", message);                                                    \
    det_sometimes((condition), (message), (details));                                          \
  } while (0)
#define DET_REACHABLE(message, details)                                                        \
  do {                                                                                         \
    DET_CATALOG_SITE("reachable", message);                                                    \
    det_reachable((message), (details));                                                       \
  } while (0)
#define DET_UNREACHABLE(message, details)                                                      \
  do {                                                                                         \
    DET_CATALOG_SITE("unreachable", message);                                                  \
    det_unreachable((message), (details));                                                     \
  } while (0)

#ifdef __cplusplus
}
#endif

#ifdef DETERMINISMO_IMPLEMENTATION

/* The SDK itself is never instrumented for coverage: only the program's own edges count. */
#if defined(__clang__)
#pragma clang attribute push(__attribute__((no_sanitize("coverage"))), apply_to = function)
#endif

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <unistd.h>

#define DET_DEVICE_PATH "/dev/determinismo"
#define DET_MESSAGE_SIZE_MAX (4096 - 16) /* One event or one pull per device call. */

static int det_device = -2; /* -2: not opened yet; -1: not inside determinismo. */

static int det_device_fd(void) {
  if (det_device == -2) det_device = open(DET_DEVICE_PATH, O_RDWR | O_CLOEXEC);
  return det_device;
}

void det_random_bytes(void *target, size_t count) {
  unsigned char *bytes = (unsigned char *)target;
  while (count > 0) {
    size_t chunk = count < 256 ? count : 256;
    int fd = det_device_fd();
    ssize_t got = fd >= 0 ? read(fd, bytes, chunk) : getrandom(bytes, chunk, 0);
    if (got <= 0) continue;
    bytes += got;
    count -= (size_t)got;
  }
}

uint64_t det_random_u64(void) {
  uint64_t value;
  det_random_bytes(&value, sizeof value);
  return value;
}

uint64_t det_random_below(uint64_t count) { return count == 0 ? 0 : det_random_u64() % count; }

/* Appends `text` as a JSON string; returns the new length (or `size` if it did not fit). */
static size_t det_json_string(char *out, size_t used, size_t size, const char *text) {
  if (used + 1 >= size) return size;
  out[used++] = '"';
  for (const char *c = text ? text : ""; *c; c++) {
    char escape[8];
    size_t length = 1;
    if (*c == '"' || *c == '\\') {
      escape[0] = '\\', escape[1] = *c, length = 2;
    } else if ((unsigned char)*c < 0x20) {
      length = (size_t)snprintf(escape, sizeof escape, "\\u%04x", (unsigned char)*c);
    } else {
      escape[0] = *c;
    }
    if (used + length + 1 >= size) return size;
    memcpy(out + used, escape, length);
    used += length;
  }
  out[used++] = '"';
  return used;
}

static void det_emit(const char *line, size_t length) {
  int fd = det_device_fd();
  if (fd >= 0) {
    (void)!write(fd, line, length); /* One write, one event. */
  } else {
    (void)!write(2, line, length);
    (void)!write(2, "\n", 1);
  }
}

static void det_assert(const char *kind, int condition, const char *message, const char *details) {
  char line[DET_MESSAGE_SIZE_MAX];
  size_t used = (size_t)snprintf(line, sizeof line, "{\"assert\":{\"type\":\"%s\",\"message\":", kind);
  used = det_json_string(line, used, sizeof line, message);
  if (used >= sizeof line) return;
  int written = snprintf(line + used, sizeof line - used, ",\"condition\":%s,\"details\":%s}}",
                         condition ? "true" : "false", details ? details : "{}");
  if (written < 0 || used + (size_t)written >= sizeof line) {
    /* Details too large: the assertion itself must not be lost. */
    written = snprintf(line + used, sizeof line - used, ",\"condition\":%s,\"details\":{}}}",
                       condition ? "true" : "false");
  }
  det_emit(line, used + (size_t)written);
}

void det_always(int condition, const char *message, const char *details) {
  det_assert("always", condition, message, details);
}
void det_always_or_unreachable(int condition, const char *message, const char *details) {
  det_assert("always_or_unreachable", condition, message, details);
}
void det_sometimes(int condition, const char *message, const char *details) {
  det_assert("sometimes", condition, message, details);
}
void det_reachable(const char *message, const char *details) {
  det_assert("reachable", 1, message, details);
}
void det_unreachable(const char *message, const char *details) {
  det_assert("unreachable", 1, message, details);
}

static void det_declare(const char *kind, const char *message, size_t message_size) {
  char text[DET_MESSAGE_SIZE_MAX];
  if (message_size >= sizeof text) return;
  memcpy(text, message, message_size);
  text[message_size] = 0;
  char line[DET_MESSAGE_SIZE_MAX];
  size_t used = (size_t)snprintf(line, sizeof line, "{\"assert\":{\"type\":\"%s\",\"message\":", kind);
  used = det_json_string(line, used, sizeof line, text);
  if (used + sizeof(",\"hit\":false}}") > sizeof line) return;
  memcpy(line + used, ",\"hit\":false}}", sizeof(",\"hit\":false}}") - 1);
  det_emit(line, used + sizeof(",\"hit\":false}}") - 1);
}

/* Present only when the program has catalogued assertions (weak: no section, no symbols). */
extern const char __start_det_catalog[] __attribute__((weak));
extern const char __stop_det_catalog[] __attribute__((weak));

/* Announces the catalog as the program starts: inside determinismo only, and once per program
   file on each machine or node (a marker named after the file). */
__attribute__((constructor)) static void det_catalog_announce(void) {
  if (!__start_det_catalog || !__stop_det_catalog) return;
  int probe = open(DET_DEVICE_PATH, O_RDWR | O_CLOEXEC);
  if (probe < 0) return;
  close(probe);
  struct stat status;
  if (stat("/proc/self/exe", &status) == 0) {
    char marker[96];
    snprintf(marker, sizeof marker, "/tmp/.determinismo-catalog-c-%llx-%llx",
             (unsigned long long)status.st_dev, (unsigned long long)status.st_ino);
    int fd = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0444);
    if (fd < 0 && errno == EEXIST) return;
    if (fd >= 0) close(fd);
  }
  for (const char *at = __start_det_catalog;
       at + sizeof(struct det_catalog_entry) <= __stop_det_catalog;) {
    const struct det_catalog_entry *entry = (const struct det_catalog_entry *)(const void *)at;
    if (entry->magic != DET_CATALOG_MAGIC) {
      at += 8;
      continue;
    }
    det_declare(entry->kind, entry->message, (size_t)entry->message_size);
    at += sizeof(struct det_catalog_entry);
  }
}

void det_setup_complete(const char *details) {
  char line[DET_MESSAGE_SIZE_MAX];
  int length = snprintf(line, sizeof line, "{\"lifecycle\":\"setup_complete\",\"details\":%s}",
                        details ? details : "{}");
  if (length > 0 && (size_t)length < sizeof line) det_emit(line, (size_t)length);
}

void det_event(const char *name, const char *details) {
  char line[DET_MESSAGE_SIZE_MAX];
  size_t used = (size_t)snprintf(line, sizeof line, "{\"event\":");
  used = det_json_string(line, used, sizeof line, name);
  if (used >= sizeof line) return;
  int written = snprintf(line + used, sizeof line - used, ",\"details\":%s}", details ? details : "{}");
  if (written > 0 && used + (size_t)written < sizeof line) det_emit(line, used + (size_t)written);
}

#ifdef DETERMINISMO_COVERAGE
/* The callbacks clang's trace-pc-guard instrumentation calls. Guards hold an edge's number,
   0 once reported (so each edge costs one event, the first time). */
void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
  static uint32_t next = 1;
  if (start == stop || *start) return; /* Already numbered. */
  for (uint32_t *guard = start; guard < stop; guard++) *guard = next++;
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
  if (!*guard) return;
  char details[48];
  snprintf(details, sizeof details, "{\"name\":\"edge %u\"}", *guard);
  *guard = 0;
  det_event("coverage", details);
}
#endif /* DETERMINISMO_COVERAGE */

#if defined(__clang__)
#pragma clang attribute pop
#endif

#endif /* DETERMINISMO_IMPLEMENTATION */
#endif /* DETERMINISMO_H */
