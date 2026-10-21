/* MS6.4 (plan :1610) — the sandbox's network endpoint enforcement. Attempts a single non-blocking TCP connect
 * to argv[1]:argv[2] and reports which of three distinct outcomes occurred, so a Seatbelt DENIAL is never
 * confused with "nothing listening":
 *   - CONNECT-OK                     the connect completed (the profile permits this endpoint, a listener answered)
 *   - CONNECT-DENIED errno=<e> <s>   the connect was refused by policy (EPERM/EACCES — the Seatbelt profile)
 *   - CONNECT-REFUSED errno=<e> <s>  the host refused/unreachable (ECONNREFUSED/ENETDOWN/…): NOT a policy denial
 *   - CONNECT-TIMEOUT                the connect neither completed nor failed within the deadline
 * Build: xcrun clang -o ms6_4_connect_probe ms6_4_connect_probe.c
 * Usage: ms6_4_connect_probe <ipv4> <port> [timeout_ms]   (default 1500 ms)
 *
 * A sandbox network denial on macOS surfaces as EPERM at connect() before any SYN; a live-but-forbidden port
 * must therefore give CONNECT-DENIED, while an allowed port with a listener gives CONNECT-OK. The caller keeps
 * a real listener on every "must be denied" loopback target so a denial can never be a false "refused". */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static int say(const char *tag, int e) {
    if (e) printf("%s errno=%d %s\n", tag, e, strerror(e));
    else   printf("%s\n", tag);
    return (strcmp(tag, "CONNECT-OK") == 0) ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <ipv4> <port> [timeout_ms]\n", argv[0]); return 2; }
    const char *ip = argv[1];
    int port = atoi(argv[2]);
    int timeout_ms = (argc > 3) ? atoi(argv[3]) : 1500;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return say("CONNECT-DENIED", errno);  /* socket() itself blocked by the profile */

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    if (inet_pton(AF_INET, ip, &a.sin_addr) != 1) { fprintf(stderr, "bad ip %s\n", ip); return 2; }

    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);

    int rc = connect(fd, (struct sockaddr *)&a, sizeof(a));
    if (rc == 0) { close(fd); return say("CONNECT-OK", 0); }
    if (errno != EINPROGRESS) {
        int e = errno;
        close(fd);
        if (e == EPERM || e == EACCES) return say("CONNECT-DENIED", e);
        return say("CONNECT-REFUSED", e);  /* ECONNREFUSED, ENETDOWN, EHOSTUNREACH, … — not a policy denial */
    }

    fd_set wset;
    FD_ZERO(&wset);
    FD_SET(fd, &wset);
    struct timeval tv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
    rc = select(fd + 1, NULL, &wset, NULL, &tv);
    if (rc == 0) { close(fd); return say("CONNECT-TIMEOUT", 0); }
    if (rc < 0)  { int e = errno; close(fd); return say("CONNECT-DENIED", e); }

    int soerr = 0;
    socklen_t len = sizeof(soerr);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len);
    close(fd);
    if (soerr == 0) return say("CONNECT-OK", 0);
    if (soerr == EPERM || soerr == EACCES) return say("CONNECT-DENIED", soerr);
    return say("CONNECT-REFUSED", soerr);
}
