// TEST: a process that maps memory and then computes, for trigger.sh.
// spin <seconds of cpu time> <MiB to map> <MiB of them to write to> [mode]
// The modes: none maps the memory without access. split puts a page without
// access in the middle, which makes two mappings of it. grow writes to the
// memory bit by bit over the seconds, not all at the start. calls maps and
// unmaps 64 KiB 20000 times after the writing.
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>

#define MIB ((size_t)1 << 20)

static volatile unsigned long sum;

static void write_to(char *mem, size_t from, size_t to) {
    for (size_t at = from; at < to; at += 4096)
        mem[at] = 1;
}

int main(int argc, char **argv) {
    if (argc < 4)
        return 2;
    double seconds = atof(argv[1]);
    size_t mapped = atol(argv[2]) * MIB, written = atol(argv[3]) * MIB, done = 0;
    const char *mode = argc > 4 ? argv[4] : "";
    int none = !strcmp(mode, "none"), split = !strcmp(mode, "split");
    char *mem = NULL;

    if (written > (split ? mapped / 2 : mapped))
        return 2;
    if (mapped) {
        // As mimalloc maps an arena
        mem = mmap(NULL, mapped, none ? PROT_NONE : PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
        if (mem == MAP_FAILED)
            return 1;
        if (split && mprotect(mem + mapped / 2, 4096, PROT_NONE))
            return 1;
    }
    if (none)
        written = 0;
    if (strcmp(mode, "grow")) {
        write_to(mem, 0, written);
        done = written;
    }
    if (!strcmp(mode, "calls"))
        for (int i = 0; i < 20000; i++) {
            void *more = mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (more == MAP_FAILED || munmap(more, 65536))
                return 1;
        }
    for (double now; (now = (double)clock() / CLOCKS_PER_SEC) < seconds;) {
        for (int i = 0; i < 1000000; i++)
            sum += i;
        // With grow: as much as is due by now
        size_t due = (size_t)(written * (now / seconds)) & ~(size_t)4095;
        if (due > done) {
            write_to(mem, done, due);
            done = due;
        }
    }
    return 0;
}
