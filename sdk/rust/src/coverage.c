// SPDX-License-Identifier: MIT
// The callbacks of trace-pc-guard instrumentation (the C SDK's, sdk/c/determinismo.h): guards hold
// an edge's number, 0 once reported, so each edge costs one event, the first time it runs, as the
// source line it is on when the binary is in the image's /symbols with its debug information (as
// for Antithesis), else as its number. Inside determinismo only; compiled without the
// instrumentation (build.rs). The line lookup is the C SDK's, copied: a packaged crate cannot
// include sdk/c (keep the two the same).
#include <elf.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 02000000
#endif

static int determinismo_coverage_device = -2;

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

/* JSON's escapes for a name in an event. */
static size_t det_json_escaped(char *out, size_t used, size_t size, const char *text) {
  for (; *text && used + 7 < size; text++) {
    unsigned char c = (unsigned char)*text;
    if (c == '"' || c == '\\') {
      out[used++] = '\\';
      out[used++] = (char)c;
    } else if (c < 0x20) {
      used += (size_t)snprintf(out + used, size - used, "\\u%04x", c);
    } else {
      out[used++] = (char)c;
    }
  }
  return used;
}

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
  char name[448], line[600];
  int length;
  if (det_line_of((uintptr_t)__builtin_return_address(0), name, sizeof name)) {
    size_t used = (size_t)snprintf(line, sizeof line, "{\"event\":\"coverage\",\"details\":{\"name\":\"");
    used = det_json_escaped(line, used, sizeof line, name);
    if (used + 4 > sizeof line) return;
    memcpy(line + used, "\"}}", 4);
    length = (int)(used + 3);
  } else {
    length = snprintf(line, sizeof line, "{\"event\":\"coverage\",\"details\":{\"name\":\"edge %u\"}}", edge);
  }
  if (length > 0) (void)!write(determinismo_coverage_device, line, (size_t)length);
}
