// TEST: a process that maps memory and then computes, for trigger.sh.
// spin <seconds of cpu time> <MiB to map> <MiB of them to write to> [none|churn]
// With none the memory is mapped without access. With churn the written part
// is given back and written to again while it computes, 1 MiB at a time.
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>

#define MIB ((size_t)1 << 20)

static volatile unsigned long sum;

int main(int argc, char **argv) {
    if (argc < 4)
        return 2;
    double seconds = atof(argv[1]);
    size_t mapped = atol(argv[2]) * MIB, written = atol(argv[3]) * MIB;
    int none = argc > 4 && !strcmp(argv[4], "none");
    int churn = argc > 4 && !strcmp(argv[4], "churn");
    char *mem = NULL;

    if (written > mapped || (churn && !written))
        return 2;
    if (mapped) {
        // As mimalloc maps an arena
        mem = mmap(NULL, mapped, none ? PROT_NONE : PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
        if (mem == MAP_FAILED)
            return 1;
        for (size_t at = 0; at < written && !none; at += 4096)
            mem[at] = 1;
    }
    for (size_t block = 0; clock() < seconds * CLOCKS_PER_SEC; block = (block + MIB) % (written ? written : MIB)) {
        for (int i = 0; i < 1000000; i++)
            sum += i;
        if (churn) {
            // As mimalloc purges a part of a segment that is used again later
            madvise(mem + block, MIB, MADV_DONTNEED);
            for (size_t at = 0; at < MIB; at += 4096)
                mem[block + at] = 1;
        }
    }
    return 0;
}
