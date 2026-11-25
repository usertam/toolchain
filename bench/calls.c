// TEST: one kind of system call, many times, for trigger.sh.
// calls <mmap | madvise | mprotect | open | fcntl> <times>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv) {
    long times = argc > 2 ? atol(argv[2]) : 0, size = 1 << 16;
    char *mem = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    int fd = open("/dev/null", O_RDONLY);

    if (argc < 3 || mem == MAP_FAILED || fd < 0)
        return 2;
    for (long i = 0; i < times; i++) {
        if (!strcmp(argv[1], "mmap")) {
            char *more = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (more == MAP_FAILED)
                return 1;
            more[0] = 1;
            munmap(more, size);
        } else if (!strcmp(argv[1], "madvise")) {
            mem[0] = 1;
            madvise(mem, size, MADV_DONTNEED);
        } else if (!strcmp(argv[1], "mprotect")) {
            mprotect(mem, size, i & 1 ? PROT_READ | PROT_WRITE : PROT_NONE);
        } else if (!strcmp(argv[1], "open")) {
            close(open(argv[0], O_RDONLY | O_CLOEXEC));
        } else if (!strcmp(argv[1], "fcntl")) {
            fcntl(fd, F_SETFD, FD_CLOEXEC);
        } else {
            return 2;
        }
    }
    return 0;
}
