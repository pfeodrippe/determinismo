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

#ifdef __cplusplus
}
#endif

#ifdef DETERMINISMO_IMPLEMENTATION

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/random.h>
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

#endif /* DETERMINISMO_IMPLEMENTATION */
#endif /* DETERMINISMO_H */
