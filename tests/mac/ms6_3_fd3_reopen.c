/* MS6.3 (plan :1608): the macOS CLI receives its OAuth token on fd 3 and reads it by REOPENING the path
 * "/dev/fd/3" (CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3), not by read(3) on the inherited descriptor. The
 * reopen is an open() that must pass the Seatbelt profile's file-read check — so this is the exact operation
 * the hard gate pins. This stand-in does only that reopen+read and reports the outcome; the real CLI is not
 * run (it needs network/auth). Build: xcrun clang -o ms6_3_fd3_reopen ms6_3_fd3_reopen.c
 *
 * Reads the descriptor number from argv[1] (defaults to 3), opens "/dev/fd/<n>", reads up to 4 KiB, and:
 *   - on success prints exactly  FD3-REOPEN-OK <bytes-read> <content>\n   and exits 0;
 *   - on any failure prints      FD3-REOPEN-FAILED errno=<e> <strerror>\n  and exits 1.
 * A denied reopen (the mutant profile with no file-read*) is EACCES/EPERM here, never a false OK. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int n = (argc > 1) ? atoi(argv[1]) : 3;
    char path[32];
    snprintf(path, sizeof(path), "/dev/fd/%d", n);

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        printf("FD3-REOPEN-FAILED errno=%d %s\n", errno, strerror(errno));
        return 1;
    }
    char buf[4096];
    ssize_t got = read(fd, buf, sizeof(buf) - 1);
    if (got < 0) {
        printf("FD3-REOPEN-FAILED errno=%d %s\n", errno, strerror(errno));
        close(fd);
        return 1;
    }
    buf[got] = '\0';
    /* trim one trailing newline so the token compares cleanly */
    if (got > 0 && buf[got - 1] == '\n') buf[got - 1] = '\0';
    printf("FD3-REOPEN-OK %zd %s\n", got, buf);
    close(fd);
    return 0;
}
