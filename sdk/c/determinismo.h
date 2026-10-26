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

/* Which evaluations become events: every one (0, the default: queries see each), or, as
   Antithesis's SDKs do, each assertion's first pass and first failure in this process (1: for
   hot paths, the same verdict with far fewer events). Set it once, at the start. */
extern int det_first_pass_first_failure;

/* An assertion with its place in the code (what the DET_* macros call). */
void det_assert_at(const char *kind, int condition, const char *message, const char *details,
                   const char *file, int line, const char *function);
void det_always(int condition, const char *message, const char *details);
void det_always_or_unreachable(int condition, const char *message, const char *details);
void det_sometimes(int condition, const char *message, const char *details);
void det_reachable(const char *message, const char *details);
void det_unreachable(const char *message, const char *details);

void det_setup_complete(const char *details); /* The platform snapshots here. */
void det_event(const char *name, const char *details);

/* Faults from the scenario. A quiet period of `seconds` (0 ends it): faults stop, except clock
   skips. A fault now (`json` as det-faults inject takes it, e.g. {"kind": "pause", "node": "db",
   "duration_ms": 2000}): applied, logged and undone like a drawn one. Both only while the
   fault injector runs (the drivers); otherwise nothing happens. */
void det_stop_faults(double seconds);
void det_fault(const char *json);

/* Guidance assertions: the compared values in the details, and a guidance event telling
   strategies how far the timeline is from the interesting outcome (lower is closer). `always`
   is 1 for an always, 0 for a sometimes; `relation` is one of DET_GREATER, ... */
enum det_relation { DET_GREATER, DET_GREATER_OR_EQUAL, DET_LESS, DET_LESS_OR_EQUAL };
void det_compare(int always, enum det_relation relation, double left, double right,
                 const char *message, const char *details);
/* Named conditions (all evaluated): at least one holds every time, or all hold at least once. */
void det_always_some(const char *const *names, const int *values, size_t count,
                     const char *message, const char *details);
void det_sometimes_all(const char *const *names, const int *values, size_t count,
                       const char *message, const char *details);

/* Labeled decisions, for strategies: the index of the option chosen (a platform decision),
   announced with the options' names; or a range, named. */
size_t det_decide(const char *name, const char *const *options, size_t count);
uint64_t det_random_below_named(const char *name, uint64_t count);

/* A buggify point (FoundationDB's BUGGIFY): inside determinismo true one time in four, a named
   decision; outside always false. Where it is true, take a rare path the real system can take
   too (a pause, a retry), never one it cannot. */
int det_buggify(const char *name);

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
    det_assert_at("always", (condition), (message), (details), __FILE__, __LINE__, __func__);  \
  } while (0)
#define DET_ALWAYS_OR_UNREACHABLE(condition, message, details)                                 \
  do {                                                                                         \
    DET_CATALOG_SITE("always_or_unreachable", message);                                        \
    det_assert_at("always_or_unreachable", (condition), (message), (details), __FILE__,          \
                  __LINE__, __func__);                                                         \
  } while (0)
#define DET_SOMETIMES(condition, message, details)                                             \
  do {                                                                                         \
    DET_CATALOG_SITE("sometimes", message);                                                    \
    det_assert_at("sometimes", (condition), (message), (details), __FILE__, __LINE__,          \
                  __func__);                                                                   \
  } while (0)
#define DET_REACHABLE(message, details)                                                        \
  do {                                                                                         \
    DET_CATALOG_SITE("reachable", message);                                                    \
    det_assert_at("reachable", 1, (message), (details), __FILE__, __LINE__, __func__);         \
  } while (0)
#define DET_ALWAYS_GREATER_THAN(left, right, message, details)                                \
  do {                                                                                         \
    DET_CATALOG_SITE("always", message);                                                       \
    det_compare(1, DET_GREATER, (left), (right), (message), (details));                        \
  } while (0)
#define DET_ALWAYS_LESS_THAN(left, right, message, details)                                   \
  do {                                                                                         \
    DET_CATALOG_SITE("always", message);                                                       \
    det_compare(1, DET_LESS, (left), (right), (message), (details));                           \
  } while (0)
#define DET_SOMETIMES_GREATER_THAN_OR_EQUAL(left, right, message, details)                     \
  do {                                                                                         \
    DET_CATALOG_SITE("sometimes", message);                                                    \
    det_compare(0, DET_GREATER_OR_EQUAL, (left), (right), (message), (details));               \
  } while (0)
#define DET_SOMETIMES_LESS_THAN_OR_EQUAL(left, right, message, details)                        \
  do {                                                                                         \
    DET_CATALOG_SITE("sometimes", message);                                                    \
    det_compare(0, DET_LESS_OR_EQUAL, (left), (right), (message), (details));                  \
  } while (0)

#define DET_UNREACHABLE(message, details)                                                      \
  do {                                                                                         \
    DET_CATALOG_SITE("unreachable", message);                                                  \
    det_assert_at("unreachable", 1, (message), (details), __FILE__, __LINE__, __func__);       \
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

static int det_repeated(const char *message, int condition);

static void det_assert_located(const char *kind, int condition, const char *message,
                               const char *details, const char *file, int line_number,
                               const char *function) {
  if (det_repeated(message, condition)) return;
  char line[DET_MESSAGE_SIZE_MAX];
  size_t used = (size_t)snprintf(line, sizeof line, "{\"assert\":{\"type\":\"%s\",\"message\":", kind);
  used = det_json_string(line, used, sizeof line, message);
  if (used >= sizeof line) return;
  if (file) {
    used += (size_t)snprintf(line + used, sizeof line - used, ",\"location\":{\"file\":");
    if (used >= sizeof line) return;
    used = det_json_string(line, used, sizeof line, file);
    if (used >= sizeof line) return;
    used += (size_t)snprintf(line + used, sizeof line - used, ",\"line\":%d,\"function\":",
                             line_number);
    if (used >= sizeof line) return;
    used = det_json_string(line, used, sizeof line, function ? function : "");
    if (used + 1 >= sizeof line) return;
    line[used++] = '}';
  }
  int written = snprintf(line + used, sizeof line - used, ",\"condition\":%s,\"details\":%s}}",
                         condition ? "true" : "false", details ? details : "{}");
  if (written < 0 || used + (size_t)written >= sizeof line) {
    /* Details too large: the assertion itself must not be lost. */
    written = snprintf(line + used, sizeof line - used, ",\"condition\":%s,\"details\":{}}}",
                       condition ? "true" : "false");
  }
  det_emit(line, used + (size_t)written);
}

static void det_assert(const char *kind, int condition, const char *message, const char *details) {
  det_assert_located(kind, condition, message, details, NULL, 0, NULL);
}

void det_assert_at(const char *kind, int condition, const char *message, const char *details,
                   const char *file, int line, const char *function) {
  det_assert_located(kind, condition, message, details, file, line, function);
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

int det_first_pass_first_failure = 0;

/* Small open-addressing tables keyed by a message's hash: what this process already sent. */
#define DET_SEEN_SIZE 4096
static uint64_t det_seen[DET_SEEN_SIZE];      /* hash | 1, with the condition in bit 1 */
static uint64_t det_best_keys[DET_SEEN_SIZE];  /* hash | 1 */
static double det_best_values[DET_SEEN_SIZE];

static uint64_t det_hash(const char *text) {
  uint64_t hash = 1469598103934665603ull; /* FNV-1a */
  for (const char *c = text; *c; c++) hash = (hash ^ (uint8_t)*c) * 1099511628211ull;
  return hash;
}

/* Whether (message, condition) was sent already (and marks it); full tables send everything. */
static int det_repeated(const char *message, int condition) {
  if (!det_first_pass_first_failure) return 0;
  uint64_t key = ((det_hash(message) << 2) | ((uint64_t)(condition != 0) << 1)) | 1;
  for (size_t probe = 0; probe < DET_SEEN_SIZE; probe++) {
    uint64_t *slot = &det_seen[(key + probe) % DET_SEEN_SIZE];
    if (*slot == key) return 1;
    if (*slot == 0) {
      *slot = key;
      return 0;
    }
  }
  return 0;
}

static void det_guidance(const char *message, double distance) {
  /* Only improvements: all a strategy needs. */
  uint64_t key = det_hash(message) | 1;
  for (size_t probe = 0; probe < DET_SEEN_SIZE; probe++) {
    size_t at = (key + probe) % DET_SEEN_SIZE;
    if (det_best_keys[at] == key) {
      if (!(distance < det_best_values[at])) return;
      det_best_values[at] = distance;
      break;
    }
    if (det_best_keys[at] == 0) {
      det_best_keys[at] = key;
      det_best_values[at] = distance;
      break;
    }
  }
  char line[DET_MESSAGE_SIZE_MAX];
  size_t used = (size_t)snprintf(line, sizeof line, "{\"guidance\":{\"message\":");
  used = det_json_string(line, used, sizeof line, message);
  if (used >= sizeof line) return;
  int written = snprintf(line + used, sizeof line - used, ",\"distance\":%.17g}}", distance);
  if (written > 0 && used + (size_t)written < sizeof line) det_emit(line, used + (size_t)written);
}

void det_compare(int always, enum det_relation relation, double left, double right,
                 const char *message, const char *details) {
  int holds = relation == DET_GREATER ? left > right
              : relation == DET_GREATER_OR_EQUAL ? left >= right
              : relation == DET_LESS ? left < right
              : left <= right;
  double margin = relation <= DET_GREATER_OR_EQUAL ? left - right : right - left;
  char merged[DET_MESSAGE_SIZE_MAX];
  snprintf(merged, sizeof merged, "{\"left\":%.17g,\"right\":%.17g,\"details\":%s}", left,
           right, details ? details : "{}");
  det_assert(always ? "always" : "sometimes", holds, message, merged);
  det_guidance(message, always ? margin : -margin);
}

static void det_conditions(int always, const char *const *names, const int *values, size_t count,
                           const char *message, const char *details) {
  char merged[DET_MESSAGE_SIZE_MAX];
  size_t used = (size_t)snprintf(merged, sizeof merged, "{\"conditions\":{");
  size_t held = 0;
  for (size_t index = 0; index < count && used < sizeof merged; index++) {
    held += values[index] != 0;
    if (index > 0) merged[used++] = ',';
    used = det_json_string(merged, used, sizeof merged, names[index]);
    if (used >= sizeof merged) break;
    used += (size_t)snprintf(merged + used, sizeof merged - used, ":%s",
                             values[index] ? "true" : "false");
  }
  if (used < sizeof merged) {
    snprintf(merged + used, sizeof merged - used, "},\"details\":%s}", details ? details : "{}");
  }
  if (always) {
    det_assert("always", held > 0, message, merged);
    det_guidance(message, (double)held);
  } else {
    det_assert("sometimes", held == count, message, merged);
    det_guidance(message, (double)(count - held));
  }
}

void det_always_some(const char *const *names, const int *values, size_t count,
                     const char *message, const char *details) {
  det_conditions(1, names, values, count, message, details);
}

void det_sometimes_all(const char *const *names, const int *values, size_t count,
                       const char *message, const char *details) {
  det_conditions(0, names, values, count, message, details);
}

size_t det_decide(const char *name, const char *const *options, size_t count) {
  if (det_device_fd() >= 0) {
    char line[DET_MESSAGE_SIZE_MAX];
    size_t used = (size_t)snprintf(line, sizeof line, "{\"decision\":{\"name\":");
    used = det_json_string(line, used, sizeof line, name);
    if (used + 12 < sizeof line) {
      used += (size_t)snprintf(line + used, sizeof line - used, ",\"options\":[");
      for (size_t index = 0; index < count && used < sizeof line; index++) {
        if (index > 0) line[used++] = ',';
        used = det_json_string(line, used, sizeof line, options[index]);
      }
      if (used + 3 < sizeof line) {
        memcpy(line + used, "]}}", 3);
        det_emit(line, used + 3);
      }
    }
  }
  return (size_t)det_random_below(count);
}

int det_buggify(const char *name) {
  return det_device_fd() >= 0 && det_random_below_named(name, 4) == 0;
}

uint64_t det_random_below_named(const char *name, uint64_t count) {
  if (det_device_fd() >= 0) {
    char line[DET_MESSAGE_SIZE_MAX];
    size_t used = (size_t)snprintf(line, sizeof line, "{\"decision\":{\"name\":");
    used = det_json_string(line, used, sizeof line, name);
    int written = snprintf(line + used, sizeof line - used, ",\"range\":%llu}}",
                           (unsigned long long)count);
    if (written > 0 && used + (size_t)written < sizeof line) det_emit(line, used + (size_t)written);
  }
  return det_random_below(count);
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

#define DET_FAULTS_CONTROL "/opt/determinismo/faults-control" /* faults.zig's control_path */

static void det_faults_control(const void *message, size_t size) {
  int fd = open(DET_FAULTS_CONTROL, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return; /* No injector running. */
  ssize_t written = write(fd, message, size); /* Atomic: under PIPE_BUF. */
  (void)written;
  close(fd);
}

static void det_u64_le(unsigned char *out, uint64_t value) {
  for (int i = 0; i < 8; i++) out[i] = (unsigned char)(value >> (8 * i));
}

void det_stop_faults(double seconds) {
  unsigned char message[8];
  det_u64_le(message, seconds > 0 ? (uint64_t)(seconds * 1e9) : 0);
  det_faults_control(message, sizeof message);
}

void det_fault(const char *json) {
  unsigned char message[4096];
  size_t length = strlen(json);
  if (length + 8 > sizeof message) return;
  det_u64_le(message, ((uint64_t)1 << 63) | length);
  memcpy(message + 8, json, length);
  det_faults_control(message, length + 8);
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
