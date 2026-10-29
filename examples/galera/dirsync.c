// SPDX-License-Identifier: MIT
// Loaded with LD_PRELOAD (the jepsen-dirsync profile): after a rename onto a file named
// gvwstate.dat, its directory is synced. Galera's ViewState::write_file syncs the new file and
// renames it into place, but never syncs the directory, so a power loss can undo the rename and
// a restart reuse its UUID's incarnation (README). This makes the rename durable, as the fix
// would: a hunt with it tells whether that rename is the cause.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <libgen.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int rename(const char *from, const char *to) {
    static int (*real)(const char *, const char *);
    static int said;
    if (!real) real = (int (*)(const char *, const char *))dlsym(RTLD_NEXT, "rename");
    int result = real(from, to);
    const char *name = "gvwstate.dat";
    size_t to_size = strlen(to);
    size_t name_size = strlen(name);
    if (result != 0 || to_size < name_size || strcmp(to + to_size - name_size, name) != 0) {
        return result;
    }
    char directory[4096];
    snprintf(directory, sizeof directory, "%s", to);
    int fd = open(dirname(directory), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd >= 0) {
        fsync(fd);
        close(fd);
    }
    if (!said) {
        said = 1;
        fprintf(stderr, "dirsync: %s renamed into place and its directory synced\n", to);
    }
    return result;
}
