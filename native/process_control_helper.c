/* Process-Control's Unix target owner. Protocol 1; no Crystal runtime here. */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    return flags < 0 ? -1 : fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

/* This single-threaded helper has not opened its protocol resources yet.
 * Enumeration covers open FDs above a subsequently lowered soft limit too.
 * Refuse if enumeration is unavailable rather than guess an upper bound. */
static int close_foreign(void) {
#ifdef __linux__
    DIR *directory = opendir("/proc/self/fd");
#else
    DIR *directory = opendir("/dev/fd");
#endif
    if (!directory) return -1;
    int keep = dirfd(directory);
    struct dirent *entry;
    errno = 0;
    while ((entry = readdir(directory)) != NULL) {
        char *end = NULL;
        long fd = strtol(entry->d_name, &end, 10);
        if (end != entry->d_name && *end == '\0' && fd > 2 && fd <= INT_MAX && fd != keep)
            (void)close((int)fd);
        errno = 0;
    }
    int error = errno;
    closedir(directory);
    errno = error;
    return error ? -1 : 0;
}

static int send_line(int fd, const char *line) {
    size_t length = strlen(line);
    while (length) {
        ssize_t sent = write(fd, line, length);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return -1;
        line += sent;
        length -= (size_t)sent;
    }
    return 0;
}

static int read_line(int fd, char *line, size_t size) {
    size_t used = 0;
    while (used + 1 < size) {
        char byte;
        ssize_t got = read(fd, &byte, 1);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return -1;
        if (byte == '\n') {
            line[used] = '\0';
            return 0;
        }
        line[used++] = byte;
    }
    return -1;
}

static void child_failed(int fd, int error) {
    ssize_t ignored;
    do { ignored = write(fd, &error, sizeof(error)); } while (ignored < 0 && errno == EINTR);
    _exit(127);
}

static void child_notice(int signal_number) { (void)signal_number; }

static int reset_target_signals(void) {
    sigset_t mask;
    sigemptyset(&mask);
    if (sigprocmask(SIG_SETMASK, &mask, NULL) < 0) return -1;
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_handler = SIG_DFL;
    for (int number = 1; number < NSIG; ++number) {
        if (number == SIGKILL || number == SIGSTOP) continue;
        if (sigaction(number, &action, NULL) < 0 && errno != EINVAL) return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 5 || strcmp(argv[3], "--") != 0) return 64;
    if (close_foreign() < 0) return 65;
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (strlen(argv[1]) >= sizeof(address.sun_path)) return 66;
    memcpy(address.sun_path, argv[1], strlen(argv[1]) + 1);
    int connection = socket(AF_UNIX, SOCK_STREAM, 0);
    if (connection < 0 || cloexec(connection) < 0) return 67;
    if (connect(connection, (struct sockaddr *)&address, sizeof(address)) < 0) return 68;
    (void)signal(SIGPIPE, SIG_IGN);
    char line[192];
    if (snprintf(line, sizeof(line), "HELLO 1 %s %d %d\n", argv[2], NSIG, F_DUPFD_CLOEXEC) >= (int)sizeof(line)) return 69;
    if (send_line(connection, line) < 0) return 70;
    char expected[96];
    snprintf(expected, sizeof(expected), "START %s", argv[2]);
    if (read_line(connection, line, sizeof(line)) < 0 || strcmp(line, expected) != 0) return 0;

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_handler = child_notice;
    if (sigaction(SIGCHLD, &action, NULL) < 0) return 71;
    sigset_t empty;
    sigemptyset(&empty);
    if (sigprocmask(SIG_SETMASK, &empty, NULL) < 0) return 72;

    int error_pipe[2];
    if (pipe(error_pipe) < 0) return 73;
    if (cloexec(error_pipe[0]) < 0 || cloexec(error_pipe[1]) < 0) return 74;
    pid_t target = fork();
    if (target < 0) {
        int error = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
        snprintf(line, sizeof(line), "REJECTED %s %d\n", argv[2], error);
        (void)send_line(connection, line);
        return 0;
    }
    if (target == 0) {
        close(error_pipe[0]);
        if (reset_target_signals() < 0) child_failed(error_pipe[1], errno);
        execv(argv[4], &argv[4]);
        child_failed(error_pipe[1], errno);
    }

    close(error_pipe[1]);
    int exec_error = 0;
    ssize_t received;
    do { received = read(error_pipe[0], &exec_error, sizeof(exec_error)); } while (received < 0 && errno == EINTR);
    close(error_pipe[0]);
    /* Only the target retains its stdio. The persistent helper must not keep
     * output writers or stdin readers open. The protocol may occupy 0..2. */
    for (int fd = 0; fd <= 2; ++fd) if (fd != connection) close(fd);
    if (received != 0) {
        int status;
        while (waitpid(target, &status, 0) < 0 && errno == EINTR) {}
        snprintf(line, sizeof(line), "REJECTED %s %d\n", argv[2], received > 0 ? exec_error : EIO);
        (void)send_line(connection, line);
        return 0;
    }

    snprintf(line, sizeof(line), "STARTED %s %ld\n", argv[2], (long)target);
    int connected = send_line(connection, line) == 0;
    for (;;) {
        int status = 0;
        pid_t collected = waitpid(target, &status, connected ? WNOHANG : 0);
        if (collected < 0 && errno == EINTR) continue;
        if (collected == target) {
            snprintf(line, sizeof(line), "EXIT %s %u\n", argv[2], (unsigned int)status);
            if (connected) (void)send_line(connection, line);
            return 0;
        }
        if (collected < 0) {
            snprintf(line, sizeof(line), "FAILED %s %d\n", argv[2], errno);
            if (connected) (void)send_line(connection, line);
            return 75;
        }
        if (!connected) continue;
        struct pollfd event = {connection, POLLIN, 0};
        int ready = poll(&event, 1, 20);
        if (ready < 0 && errno == EINTR) continue;
        if (ready == 0) continue;
        if (ready < 0 || read_line(connection, line, sizeof(line)) < 0) {
            close(connection);
            connected = 0;
            continue;
        }
        unsigned long long sequence;
        int signal_number;
        char token[65];
        char trailing;
        if (sscanf(line, "SIGNAL %64s %llu %d %c", token, &sequence, &signal_number, &trailing) != 3 ||
            signal_number <= 0 || signal_number >= NSIG) {
            close(connection);
            connected = 0;
            continue;
        }
        if (strcmp(token, argv[2]) != 0) continue;
        /* No other thread/reaper exists. If exit races this call, the target
         * remains our unreaped child and its PID cannot have been reused.
         * After waitpid reports it above, this loop returns without signaling. */
        int error = kill(target, signal_number) == 0 ? 0 : errno;
        snprintf(line, sizeof(line), "ACK %s %llu %d\n", argv[2], sequence, error);
        if (send_line(connection, line) < 0) {
            close(connection);
            connected = 0;
        }
    }
}
