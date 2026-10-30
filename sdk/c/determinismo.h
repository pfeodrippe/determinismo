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
 * timelines that reach new code: as the source line it is on ("line <file>:<n>", for targeted
 * runs) when the binary is in the image's /symbols with its debug information (as for
 * Antithesis), else as a number.
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
double det_random(void);                   /* In [0, 1), from 53 random bits. */

/* A generator the platform seeds once (SplitMix64): draws cost nothing, and replay with the
   seed. For hot loops; det_random_u64 is a platform decision a draw. */
struct det_prng {
  uint64_t state;
};
void det_prng_seed(struct det_prng *prng);
uint64_t det_prng_next(struct det_prng *prng);
uint64_t det_prng_below(struct det_prng *prng, uint64_t count);

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
void det_output(const char *json); /* Any JSON object as an event of its own (docs/SDKS.md). */

/* The assertion catalog: one announced before it runs (a message computed at run time); and
   the program's assertions (its DET_* call sites and those declared), one JSON object a line
   ({"kind","message"}) to `fd`, for review or CI. */
void det_declare(const char *kind, const char *message);
void det_catalog_write(int fd);

/* Faults from the scenario. A quiet period of `seconds` (0 ends it): faults stop, except clock
   skips. A fault now (`json` as det-faults inject takes it, e.g. {"kind": "pause", "node": "db",
   "duration_ms": 2000}): applied, logged and undone like a drawn one. Both only while the
   fault injector runs (the drivers); otherwise nothing happens. */
void det_stop_faults(double seconds);
void det_fault(const char *json);
/* Faults aimed at `node` from now on ("" for none): half the injector's then involve it. */
void det_fault_aim(const char *node);

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

/* An objective for exploration (Antithesis's "Optimizing our way through Metroid"): `bucket`, a
   JSON object or NULL, splits states by its strings and booleans (a leader, a phase); buckets
   are explored evenly, each keeping the state with the best `value` (`maximize` 1, or 0 to
   minimize), and the tree returns there and goes further from it. */
void det_optimize(const char *message, const char *bucket, double value, int maximize);

/* Labeled decisions, for strategies: the index of the option chosen (a platform decision),
   announced with the options' names; or a range, named. */
size_t det_decide(const char *name, const char *const *options, size_t count);
uint64_t det_random_below_named(const char *name, uint64_t count);

/* A buggify point (FoundationDB's BUGGIFY): inside determinismo, a point is active one stretch of
   two seconds (virtual time) in four, a named decision ("buggify <name>") at the stretch's first
   evaluation; while active, it is true one evaluation in four, drawn from its own generator
   seeded by the platform for the stretch. Outside determinismo, always false. `name` is a string
   that lives as long as the program (a literal); up to 256 points. Where it is true, take a rare
   path the real system can take too (a pause, a retry), never one it cannot. */
int det_buggify(const char *name);
/* At a buggify point, a pause of up to 9 ms one evaluation in 32 while the point is active
   (rarer than det_buggify: pause points sit on hot paths). */
void det_buggify_pause(const char *name);

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

#define DET_ALWAYS_GREATER_THAN_OR_EQUAL(left, right, message, details)                       \
  do {                                                                                         \
    DET_CATALOG_SITE("always", message);                                                       \
    det_compare(1, DET_GREATER_OR_EQUAL, (left), (right), (message), (details));               \
  } while (0)
#define DET_ALWAYS_LESS_THAN_OR_EQUAL(left, right, message, details)                          \
  do {                                                                                         \
    DET_CATALOG_SITE("always", message);                                                       \
    det_compare(1, DET_LESS_OR_EQUAL, (left), (right), (message), (details));                  \
  } while (0)
#define DET_SOMETIMES_GREATER_THAN(left, right, message, details)                             \
  do {                                                                                         \
    DET_CATALOG_SITE("sometimes", message);                                                    \
    det_compare(0, DET_GREATER, (left), (right), (message), (details));                        \
  } while (0)
#define DET_SOMETIMES_LESS_THAN(left, right, message, details)                                \
  do {                                                                                         \
    DET_CATALOG_SITE("sometimes", message);                                                    \
    det_compare(0, DET_LESS, (left), (right), (message), (details));                           \
  } while (0)
#define DET_ALWAYS_SOME(names, values, count, message, details)                                \
  do {                                                                                         \
    DET_CATALOG_SITE("always", message);                                                       \
    det_always_some((names), (values), (count), (message), (details));                         \
  } while (0)
#define DET_SOMETIMES_ALL(names, values, count, message, details)                              \
  do {                                                                                         \
    DET_CATALOG_SITE("sometimes", message);                                                    \
    det_sometimes_all((names), (values), (count), (message), (details));                       \
  } while (0)

#define DET_UNREACHABLE(message, details)                                                      \
  do {                                                                                         \
    DET_CATALOG_SITE("unreachable", message);                                                  \
    det_assert_at("unreachable", 1, (message), (details), __FILE__, __LINE__, __func__);       \
  } while (0)

#ifdef __cplusplus
}

namespace determinismo {
/* A UniformRandomBitGenerator (std::shuffle, std::uniform_int_distribution, ...) whose every draw
   is a platform decision. */
struct random_engine {
  typedef uint64_t result_type;
  static constexpr result_type min() { return 0; }
  static constexpr result_type max() { return UINT64_MAX; }
  result_type operator()() { return det_random_u64(); }
};
/* One the platform seeds once (det_prng): draws cost nothing. */
struct prng_engine {
  typedef uint64_t result_type;
  det_prng prng;
  prng_engine() { det_prng_seed(&prng); }
  static constexpr result_type min() { return 0; }
  static constexpr result_type max() { return UINT64_MAX; }
  result_type operator()() { return det_prng_next(&prng); }
};
} /* namespace determinismo */
#endif

#ifdef DETERMINISMO_IMPLEMENTATION

/* The SDK itself is never instrumented for coverage: only the program's own edges count. */
#if defined(__clang__)
#pragma clang attribute push(__attribute__((no_sanitize("coverage"))), apply_to = function)
#endif

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* Strict C (-std=c11 with glibc) hides O_CLOEXEC: Linux's value (the guests are Linux). */
#ifndef O_CLOEXEC
#define O_CLOEXEC 02000000
#endif

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

/* Outside determinismo: the file DETERMINISMO_SDK_LOCAL_OUTPUT (or Antithesis's
   ANTITHESIS_SDK_LOCAL_OUTPUT) names, one JSON object a line, else stderr. */
static int det_local_output_fd(void) {
  static int fd = -2;
  if (fd == -2) {
    const char *path = getenv("DETERMINISMO_SDK_LOCAL_OUTPUT");
    if (!path || !*path) path = getenv("ANTITHESIS_SDK_LOCAL_OUTPUT");
    fd = path && *path ? open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644) : -1;
    if (fd < 0) fd = 2;
  }
  return fd;
}

static void det_emit(const char *line, size_t length) {
  int fd = det_device_fd();
  if (fd >= 0) {
    (void)!write(fd, line, length); /* One write, one event. */
  } else {
    int local = det_local_output_fd();
    (void)!write(local, line, length);
    (void)!write(local, "\n", 1);
  }
}

void det_output(const char *json) { det_emit(json, strlen(json)); }

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

static void det_declare_sized(const char *kind, const char *message, size_t message_size) {
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

void det_optimize(const char *message, const char *bucket, double value, int maximize) {
  if (!isfinite(value)) return;
  char line[DET_MESSAGE_SIZE_MAX];
  size_t used = (size_t)snprintf(line, sizeof line, "{\"optimize\":{\"message\":");
  used = det_json_string(line, used, sizeof line, message);
  if (used >= sizeof line) return;
  int written = snprintf(line + used, sizeof line - used,
                         ",\"bucket\":%s,\"value\":%.17g,\"goal\":\"%s\"}}", bucket ? bucket : "{}",
                         value, maximize ? "maximize" : "minimize");
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

struct det_buggify_point {
  const char *name;
  uint64_t until_ns;
  uint64_t state; /* xorshift64* while active, 0 when not */
};
static struct det_buggify_point det_buggify_points[256];
static size_t det_buggify_point_count;
static int det_buggify_lock; /* A spinlock (__atomic builtins): taken briefly, rarely contended. */

/* The next draw of `name`'s generator into *value, while the point is active (1), else 0. */
static int det_buggify_draw(const char *name, uint64_t *value) {
  if (det_device_fd() < 0) return 0;
  /* Virtual time inside determinismo, in whole seconds (standard C's time(): no feature macros
     needed, and enough for stretches of two seconds). */
  uint64_t now = (uint64_t)time(0) * 1000000000u;
  while (__atomic_test_and_set(&det_buggify_lock, __ATOMIC_ACQUIRE)) {
  }
  struct det_buggify_point *point = 0;
  for (size_t index = 0; index < det_buggify_point_count && !point; index++) {
    if (strcmp(det_buggify_points[index].name, name) == 0) point = &det_buggify_points[index];
  }
  if (!point && det_buggify_point_count < sizeof det_buggify_points / sizeof *point) {
    point = &det_buggify_points[det_buggify_point_count++];
    *point = (struct det_buggify_point){name, 0, 0};
  }
  int fires = 0;
  if (point) {
    if (now >= point->until_ns) {
      char label[DET_MESSAGE_SIZE_MAX];
      snprintf(label, sizeof label, "buggify %s", name);
      point->state = det_random_below_named(label, 4) == 0 ? (det_random_u64() | 1) : 0;
      point->until_ns = now + 2000000000u;
    }
    if (point->state) {
      point->state ^= point->state >> 12;
      point->state ^= point->state << 25;
      point->state ^= point->state >> 27;
      *value = point->state * 0x2545F4914F6CDD1Dull;
      fires = 1;
    }
  }
  __atomic_clear(&det_buggify_lock, __ATOMIC_RELEASE);
  return fires;
}

int det_buggify(const char *name) {
  uint64_t value;
  return det_buggify_draw(name, &value) && value % 4 == 0;
}

void det_buggify_pause(const char *name) {
  uint64_t value;
  if (!det_buggify_draw(name, &value) || value % 32 != 0) return;
  uint64_t ms = (value >> 8) % 10;
  if (ms == 0) return;
  (void)poll(0, 0, (int)ms); /* A pause: no file to wait for, only the timeout. */
}

double det_random(void) { return (double)(det_random_u64() >> 11) / 9007199254740992.0; }

void det_prng_seed(struct det_prng *prng) { prng->state = det_random_u64(); }

uint64_t det_prng_next(struct det_prng *prng) {
  uint64_t z = (prng->state += 0x9e3779b97f4a7c15ull);
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
  z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
  return z ^ (z >> 31);
}

uint64_t det_prng_below(struct det_prng *prng, uint64_t count) {
  return count ? det_prng_next(prng) % count : 0;
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
    det_declare_sized(entry->kind, entry->message, (size_t)entry->message_size);
    at += sizeof(struct det_catalog_entry);
  }
}

/* Assertions declared at run time, for det_catalog_write (up to 256). */
static struct {
  const char *kind;
  char *message;
} det_declared[256];
static size_t det_declared_count;

void det_declare(const char *kind, const char *message) {
  for (size_t index = 0; index < det_declared_count; index++) {
    if (strcmp(det_declared[index].kind, kind) == 0 && strcmp(det_declared[index].message, message) == 0) return;
  }
  if (det_declared_count < sizeof det_declared / sizeof *det_declared) {
    det_declared[det_declared_count].kind = kind;
    size_t size = strlen(message) + 1;
    char *copy = (char *)malloc(size);
    if (!copy) return;
    memcpy(copy, message, size);
    det_declared[det_declared_count].message = copy;
    det_declared_count++;
  }
  if (det_device_fd() >= 0) det_declare_sized(kind, message, strlen(message));
}

static void det_catalog_line(int fd, const char *kind, const char *message, size_t size) {
  char text[DET_MESSAGE_SIZE_MAX];
  if (size >= sizeof text) return;
  memcpy(text, message, size);
  text[size] = 0;
  char line[DET_MESSAGE_SIZE_MAX];
  size_t used = (size_t)snprintf(line, sizeof line, "{\"kind\":\"%s\",\"message\":", kind);
  used = det_json_string(line, used, sizeof line, text);
  if (used + 2 >= sizeof line) return;
  line[used++] = '}';
  line[used++] = '\n';
  (void)!write(fd, line, used);
}

void det_catalog_write(int fd) {
  if (__start_det_catalog && __stop_det_catalog) {
    for (const char *at = __start_det_catalog;
         at + sizeof(struct det_catalog_entry) <= __stop_det_catalog;) {
      const struct det_catalog_entry *entry = (const struct det_catalog_entry *)(const void *)at;
      if (entry->magic != DET_CATALOG_MAGIC) {
        at += 8;
        continue;
      }
      det_catalog_line(fd, entry->kind, entry->message, (size_t)entry->message_size);
      at += sizeof(struct det_catalog_entry);
    }
  }
  for (size_t index = 0; index < det_declared_count; index++) {
    det_catalog_line(fd, det_declared[index].kind, det_declared[index].message,
                     strlen(det_declared[index].message));
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

/* Aims the fault injector at `node` from now on, until another call ("" for none): half its
 * faults involve it, each a decision strategies see and replays repeat (a primary, a leader). */
void det_fault_aim(const char *node) {
  unsigned char message[8 + 32];
  size_t length = strlen(node);
  if (length > 32) length = 32;
  det_u64_le(message, ((uint64_t)1 << 61) | length);
  memcpy(message + 8, node, length);
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
#include <elf.h>
#include <sys/mman.h>

/* An edge's source line: the module holding its call (/proc/self/maps, once per module), its
   GNU build ID (its ELF header in memory), and the table of its lines the host made from the
   image's /symbols when it prepared the image (src/lines.zig's format, as libvoidstar reads it:
   "DETLINES", a count, rows by address {address, line, file offset}, then the file names). */
struct det_lines_row {
  uint64_t address;
  uint32_t line;
  uint32_t file;
};

struct det_native {
  uintptr_t low, high, bias;
  const struct det_lines_row *rows;
  uint64_t count;
  const char *strings;
  size_t strings_size;
};

#define DET_NATIVES_MAX 64
static struct det_native det_natives[DET_NATIVES_MAX];
static int det_native_count;
static int det_natives_lock;

/* The process's maps, read whole (a JVM's run to hundreds of kilobytes). */
static char *det_maps_read(size_t *size) {
  int fd = open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return NULL;
  size_t capacity = 1 << 16, used = 0;
  char *text = (char *)malloc(capacity);
  while (text) {
    if (used + 4096 > capacity) {
      char *grown = (char *)realloc(text, capacity * 2);
      if (!grown) { free(text); text = NULL; break; }
      text = grown;
      capacity *= 2;
    }
    ssize_t got = read(fd, text + used, capacity - used - 1);
    if (got <= 0) break;
    used += (size_t)got;
  }
  close(fd);
  if (text) text[used] = 0;
  *size = used;
  return text;
}

/* A maps line: "start-end perms offset device inode   path". */
static int det_maps_line(const char *line, uintptr_t *start, uintptr_t *end, unsigned long *offset,
                         char *path, size_t path_size) {
  unsigned long a, b, c;
  int consumed = 0;
  if (sscanf(line, "%lx-%lx %*s %lx %*s %*s%n", &a, &b, &c, &consumed) < 3) return 0;
  const char *rest = line + consumed;
  while (*rest == ' ') rest++;
  size_t length = 0;
  while (rest[length] && rest[length] != '\n') length++;
  if (length >= path_size) length = path_size - 1;
  memcpy(path, rest, length);
  path[length] = 0;
  *start = a;
  *end = b;
  *offset = c;
  return 1;
}

/* The module holding pc: its range, load bias and key (build ID, or name-<file name>). */
static int det_native_find(uintptr_t pc, struct det_native *found, char *key, size_t key_size) {
  size_t size;
  char *maps = det_maps_read(&size);
  if (!maps) return 0;
  char path[256] = "", each[256];
  uintptr_t start, end, header = 0;
  unsigned long offset;
  found->low = found->high = 0;
  for (char *line = maps; line && *line; line = strchr(line, '\n') ? strchr(line, '\n') + 1 : NULL) {
    if (!det_maps_line(line, &start, &end, &offset, each, sizeof each)) continue;
    if (pc >= start && pc < end) {
      memcpy(path, each, sizeof path);
      found->low = start;
      found->high = end;
      break;
    }
  }
  if (!found->high) { free(maps); return 0; }
  if (path[0] != '/') { free(maps); key[0] = 0; return 1; } /* Anonymous (JIT) code. */
  for (char *line = maps; line && *line; line = strchr(line, '\n') ? strchr(line, '\n') + 1 : NULL) {
    if (!det_maps_line(line, &start, &end, &offset, each, sizeof each) || strcmp(each, path) != 0) continue;
    if (start < found->low) found->low = start;
    if (end > found->high) found->high = end;
    if (offset == 0 && !header) header = start;
  }
  free(maps);
  found->bias = 0;
  const char *base = strrchr(path, '/');
  snprintf(key, key_size, "name-%s", base ? base + 1 : path);
  if (!header) return 1;
  const Elf64_Ehdr *elf = (const Elf64_Ehdr *)header;
  if (memcmp(elf->e_ident, ELFMAG, SELFMAG) != 0 || elf->e_ident[EI_CLASS] != ELFCLASS64) return 1;
  const Elf64_Phdr *segments = (const Elf64_Phdr *)(header + elf->e_phoff);
  if (elf->e_type == ET_DYN) { /* Position-independent: where its first segment's page landed. */
    uint64_t lowest = UINT64_MAX;
    for (int i = 0; i < elf->e_phnum; i++)
      if (segments[i].p_type == PT_LOAD && segments[i].p_vaddr < lowest) lowest = segments[i].p_vaddr;
    if (lowest == UINT64_MAX) return 1;
    found->bias = header - (uintptr_t)(lowest & ~(uint64_t)4095);
  }
  for (int i = 0; i < elf->e_phnum; i++) {
    if (segments[i].p_type != PT_NOTE) continue;
    uintptr_t notes_at = found->bias + segments[i].p_vaddr;
    if (notes_at < found->low || notes_at + segments[i].p_filesz > found->high) continue;
    const unsigned char *notes = (const unsigned char *)notes_at;
    size_t at = 0;
    while (at + 12 <= segments[i].p_filesz) {
      uint32_t name_size, description_size, kind;
      memcpy(&name_size, notes + at, 4);
      memcpy(&description_size, notes + at + 4, 4);
      memcpy(&kind, notes + at + 8, 4);
      size_t name_at = at + 12, description_at = name_at + ((name_size + 3) & ~3u);
      if (description_at + description_size > segments[i].p_filesz) break;
      if (kind == NT_GNU_BUILD_ID && name_size == 4 && memcmp(notes + name_at, "GNU", 4) == 0 &&
          description_size * 2 < key_size) {
        for (uint32_t j = 0; j < description_size; j++)
          snprintf(key + 2 * j, 3, "%02x", notes[description_at + j]);
        return 1;
      }
      at = description_at + ((description_size + 3) & ~3u);
    }
  }
  return 1;
}

static void det_lines_load(struct det_native *native, const char *key) {
  char path[160];
  snprintf(path, sizeof path, "/symbols/.determinismo/%s", key);
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return;
  off_t size = lseek(fd, 0, SEEK_END);
  if (size < 16) { close(fd); return; }
  const unsigned char *table = (const unsigned char *)mmap(NULL, (size_t)size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (table == MAP_FAILED) return;
  uint64_t count;
  memcpy(&count, table + 8, 8);
  if (memcmp(table, "DETLINES", 8) != 0 || count > ((uint64_t)size - 16) / sizeof(struct det_lines_row)) return;
  native->rows = (const struct det_lines_row *)(table + 16);
  native->count = count;
  native->strings = (const char *)(table + 16 + count * sizeof(struct det_lines_row));
  native->strings_size = (size_t)size - 16 - count * sizeof(struct det_lines_row);
}

/* The module of a code address, found once (a lock held too long, by a thread a fork left
   behind, is not waited for: the edge stays a number). */
static const struct det_native *det_native_at(uintptr_t pc) {
  int count = __atomic_load_n(&det_native_count, __ATOMIC_ACQUIRE);
  for (int i = 0; i < count; i++)
    if (pc >= det_natives[i].low && pc < det_natives[i].high) return &det_natives[i];
  for (long spins = 0; __atomic_exchange_n(&det_natives_lock, 1, __ATOMIC_ACQUIRE); spins++)
    if (spins > (1L << 22)) return NULL;
  const struct det_native *result = NULL;
  count = __atomic_load_n(&det_native_count, __ATOMIC_ACQUIRE);
  for (int i = 0; i < count && !result; i++)
    if (pc >= det_natives[i].low && pc < det_natives[i].high) result = &det_natives[i];
  if (!result && count < DET_NATIVES_MAX) {
    struct det_native found = {0};
    char key[96];
    if (det_native_find(pc, &found, key, sizeof key)) {
      det_natives[count] = found;
      if (key[0]) det_lines_load(&det_natives[count], key);
      __atomic_store_n(&det_native_count, count + 1, __ATOMIC_RELEASE);
      result = &det_natives[count];
    }
  }
  __atomic_store_n(&det_natives_lock, 0, __ATOMIC_RELEASE);
  return result;
}

/* "line <file>:<n>" for a code address, or 0 (no table, no line there). */
static int det_line_of(uintptr_t pc, char *out, size_t size) {
  const struct det_native *native = det_native_at(pc);
  if (!native || !native->count || pc <= native->bias) return 0;
  uint64_t address = pc - native->bias - 1; /* The call, not the return address. */
  uint64_t low = 0, high = native->count;
  while (low < high) { /* The last row at or before the address. */
    uint64_t middle = low + (high - low) / 2;
    if (native->rows[middle].address <= address) low = middle + 1; else high = middle;
  }
  if (low == 0) return 0;
  const struct det_lines_row *row = &native->rows[low - 1];
  if (row->line == 0 || row->file >= native->strings_size) return 0;
  const char *file = native->strings + row->file;
  size_t length = 0;
  while (row->file + length < native->strings_size && file[length]) length++;
  int written = snprintf(out, size, "line %.*s:%u", (int)length, file, row->line);
  return written > 0 && (size_t)written < size;
}

/* The callbacks clang's trace-pc-guard instrumentation calls. Guards hold an edge's number,
   0 once reported (so each edge costs one event, the first time). */
void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
  static uint32_t next = 1;
  if (start == stop || *start) return; /* Already numbered. */
  for (uint32_t *guard = start; guard < stop; guard++) *guard = next++;
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
  if (!*guard) return;
  char name[448], details[512];
  if (det_line_of((uintptr_t)__builtin_return_address(0), name, sizeof name)) {
    size_t used = (size_t)snprintf(details, sizeof details, "{\"name\":");
    used = det_json_string(details, used, sizeof details, name);
    if (used + 2 > sizeof details) return;
    details[used] = '}';
    details[used + 1] = 0;
  } else {
    snprintf(details, sizeof details, "{\"name\":\"edge %u\"}", *guard);
  }
  *guard = 0;
  det_event("coverage", details);
}
#endif /* DETERMINISMO_COVERAGE */

#if defined(__clang__)
#pragma clang attribute pop
#endif

#endif /* DETERMINISMO_IMPLEMENTATION */
#endif /* DETERMINISMO_H */
