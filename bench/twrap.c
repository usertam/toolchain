// TEST: the timing of single tools for idle.sh.
// Run the tool of this name in $TWRAP_BIN and add a line to $TWRAP_LOG: when it
// started, its wall, user and system time in seconds, its name and its output.
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double seconds(struct timeval t) { return t.tv_sec + t.tv_usec / 1e6; }

int main(int argc, char **argv) {
    const char *bin = getenv("TWRAP_BIN"), *log = getenv("TWRAP_LOG"), *out = "-";
    const char *name = strrchr(argv[0], '/');
    char path[4096], line[8192];
    struct timespec start, end;
    struct rusage usage;
    int status, fd, len;

    name = name ? name + 1 : argv[0];
    if (!bin || !log) {
        fputs("twrap: TWRAP_BIN and TWRAP_LOG are not set\n", stderr);
        return 127;
    }
    snprintf(path, sizeof path, "%s/%s", bin, name);
    for (int i = 1; i + 1 < argc; i++)
        if (!strcmp(argv[i], "-o"))
            out = argv[i + 1];
    clock_gettime(CLOCK_REALTIME, &start);
    pid_t pid = fork();
    if (pid == 0) {
        argv[0] = path;
        execv(path, argv);
        perror(path);
        _exit(127);
    }
    if (pid < 0 || wait4(pid, &status, 0, &usage) < 0) {
        perror("twrap");
        return 127;
    }
    clock_gettime(CLOCK_REALTIME, &end);
    len = snprintf(line, sizeof line, "%.6f\t%.6f\t%.6f\t%.6f\t%s\t%s\n",
                   start.tv_sec + start.tv_nsec / 1e9,
                   (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9,
                   seconds(usage.ru_utime), seconds(usage.ru_stime), name, out);
    if (len >= (int)sizeof line)
        len = sizeof line - 1;
    fd = open(log, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        if (write(fd, line, len) < 0)
            perror(log);
        close(fd);
    }
    return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : WEXITSTATUS(status);
}
