/* MS6.4 (plan :1610, :1576-1583) — the sandbox's network endpoint enforcement. One connect attempt to
 * argv[1]:argv[2], over argv[4] ∈ {tcp,udp} (default tcp); the address family is AF_INET6 when argv[1] holds a
 * ':' else AF_INET, so IPv6 loopback / IPv4-mapped / UDP can be probed at the SAME numeric port the renderer
 * permits. Reports exactly one verdict, and a Seatbelt POLICY denial is distinguished from every other outcome:
 *   - CONNECT-OK                     the attempt was permitted (TCP connected; UDP datagram sent)
 *   - CONNECT-DENIED errno=<e> <s>   ONLY EPERM/EACCES — a Seatbelt policy denial
 *   - CONNECT-REFUSED errno=<e> <s>  ECONNREFUSED/EHOSTUNREACH/ENETDOWN/ENETUNREACH — host reachability, NOT policy
 *   - CONNECT-ERROR errno=<e> <where> any other syscall/observation failure (socket/fcntl/select/getsockopt/…)
 *   - CONNECT-TIMEOUT                neither completed nor failed within the deadline
 * CONNECT-ERROR and CONNECT-REFUSED are never conflated with DENIED or OK, so a false "denied"/"ok" cannot pass
 * a gate: the caller asserts an exact tag. Build: xcrun clang -std=c11 -Wall -Wextra -Werror -o <out> <this>.
 * Usage: ms6_4_connect_probe <ip> <port> [timeout_ms] [tcp|udp] */
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

static int verdict_ok(void)             { printf("CONNECT-OK\n"); return 0; }
static int verdict(const char *tag, int e) { printf("%s errno=%d %s\n", tag, e, strerror(e)); return 1; }
/* EPERM/EACCES ONLY -> DENIED; the common unreachable errnos -> REFUSED; anything else -> ERROR (a distinct,
 * failing verdict, never DENIED/OK). `where` names the failing call for an ERROR so a mutant is diagnosable. */
static int classify(int e, const char *where) {
  if (e == EPERM || e == EACCES) return verdict("CONNECT-DENIED", e);
  if (e == ECONNREFUSED || e == EHOSTUNREACH || e == ENETDOWN || e == ENETUNREACH || e == EHOSTDOWN)
    return verdict("CONNECT-REFUSED", e);
  printf("CONNECT-ERROR errno=%d %s (%s)\n", e, strerror(e), where);
  return 1;
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: %s <ip> <port> [timeout_ms] [tcp|udp]\n", argv[0]); return 2; }
  const char *ip = argv[1];
  int port = atoi(argv[2]);
  int timeout_ms = (argc > 3) ? atoi(argv[3]) : 1500;
  int udp = (argc > 4 && strcmp(argv[4], "udp") == 0);
  int family = (strchr(ip, ':') != NULL) ? AF_INET6 : AF_INET;

  struct sockaddr_storage ss;
  socklen_t slen;
  memset(&ss, 0, sizeof ss);
  if (family == AF_INET6) {
    struct sockaddr_in6 *a6 = (struct sockaddr_in6 *)&ss;
    a6->sin6_family = AF_INET6;
    a6->sin6_port = htons((unsigned short)port);
    if (inet_pton(AF_INET6, ip, &a6->sin6_addr) != 1) { fprintf(stderr, "bad ipv6 %s\n", ip); return 2; }
    slen = sizeof *a6;
  } else {
    struct sockaddr_in *a4 = (struct sockaddr_in *)&ss;
    a4->sin_family = AF_INET;
    a4->sin_port = htons((unsigned short)port);
    if (inet_pton(AF_INET, ip, &a4->sin_addr) != 1) { fprintf(stderr, "bad ipv4 %s\n", ip); return 2; }
    slen = sizeof *a4;
  }

  int fd = socket(family, udp ? SOCK_DGRAM : SOCK_STREAM, 0);
  if (fd < 0) return classify(errno, "socket");  /* EPERM here is still a real policy denial of the socket */

  if (udp) {
    /* UDP: a connect() sets the default peer and a send() is where egress policy bites; no listener is needed
     * (a permitted datagram "sends" regardless), so OK here means the profile ALLOWED egress at this endpoint. */
    if (connect(fd, (struct sockaddr *)&ss, slen) != 0) { int e = errno; close(fd); return classify(e, "connect"); }
    char b = 'x';
    ssize_t s = send(fd, &b, 1, 0);
    int e = errno;
    close(fd);
    if (s == 1) return verdict_ok();
    return classify(e, "send");
  }

  int fl = fcntl(fd, F_GETFL, 0);
  if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) { int e = errno; close(fd); return classify(e, "fcntl"); }

  int rc = connect(fd, (struct sockaddr *)&ss, slen);
  if (rc == 0) { close(fd); return verdict_ok(); }
  if (errno != EINPROGRESS) { int e = errno; close(fd); return classify(e, "connect"); }

  double deadline_ms = (double)timeout_ms;
  for (;;) {
    fd_set wset;
    FD_ZERO(&wset);
    FD_SET(fd, &wset);
    struct timeval tv = { (int)(deadline_ms / 1000), (int)((long)deadline_ms % 1000) * 1000 };
    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    rc = select(fd + 1, NULL, &wset, NULL, &tv);
    if (rc < 0) {
      if (errno == EINTR) {  /* a signal, not a denial: subtract elapsed and retry */
        gettimeofday(&t1, NULL);
        deadline_ms -= (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_usec - t0.tv_usec) / 1000.0;
        if (deadline_ms <= 0) { close(fd); printf("CONNECT-TIMEOUT\n"); return 1; }
        continue;
      }
      int e = errno; close(fd); return classify(e, "select");
    }
    break;
  }
  if (rc == 0) { close(fd); printf("CONNECT-TIMEOUT\n"); return 1; }

  int soerr = 0;
  socklen_t len = sizeof soerr;
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len) != 0) { int e = errno; close(fd); return classify(e, "getsockopt"); }
  close(fd);
  if (soerr == 0) return verdict_ok();
  return classify(soerr, "connect");
}
