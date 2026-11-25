// TEST: a process that maps memory and then computes, for trigger.sh.
// spin <seconds of cpu time> <MiB to map> <MiB of them to write to> [none]
// With none the memory is mapped without access.
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>

static volatile unsigned long sum;

int main(int argc, char **argv) {
    if (argc < 4)
        return 2;
    double seconds = atof(argv[1]);
    size_t mapped = (size_t)atol(argv[2]) << 20, written = (size_t)atol(argv[3]) << 20;
    int none = argc > 4 && !strcmp(argv[4], "none");

    if (mapped) {
        // As mimalloc maps an arena
        char *mem = mmap(NULL, mapped, none ? PROT_NONE : PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
        if (mem == MAP_FAILED)
            return 1;
        for (size_t at = 0; at < written && !none; at += 4096)
            mem[at] = 1;
    }
    while (clock() < seconds * CLOCKS_PER_SEC)
        for (int i = 0; i < 1000000; i++)
            sum += i;
    return 0;
}
