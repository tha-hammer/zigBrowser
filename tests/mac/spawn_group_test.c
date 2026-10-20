/* macOS plan rev 14 item 5, the chain without the browser: zb_agent_spawn_group starts setup as the leader
 * of a new process group; setup arms zb_agent_host.parent_watch (real kqueue DarwinOps) and starts a
 * descendant; when the "browser" is SIGKILLed (it runs no exit path), the watcher SIGKILLs the whole group.
 * Run by tests/mac/ms5_spawn_gate.sh on both Macs. argv: <watch_stub.py> <python3>
 *
 * Cases:
 *  1. armed: the setup child leads its own group (getpgid == pid) and its descendant is in that group;
 *     SIGKILL the browser; within 2 s no member of the group is alive (zombies count as dead).
 *  2. barrier: the browser is SIGKILLed while setup waits between its parent check and the kqueue
 *     registration; the registration then fails (the pid is gone) and the group still dies within 2 s.
 * Any survivor is reported and then killed, so a failing run leaves nothing behind. */
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Weak, so the red fails by behaviour ("missing"), not at link time. */
extern int zb_agent_spawn_group(const char *const *argv, const char *const *envp, pid_t *out_pid)
    __attribute__((weak_import));

static int failures = 0;
static void fail(const char *msg) { printf("  FAIL %s\n", msg); failures++; }

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

/* Alive and not a zombie. */
static int alive(pid_t pid) {
  if (kill(pid, 0) != 0) return 0;
  char cmd[64], buf[16] = {0};
  snprintf(cmd, sizeof cmd, "/bin/ps -o stat= -p %d", (int)pid);
  FILE *p = popen(cmd, "r");
  if (p == NULL) return 1;
  size_t n = fread(buf, 1, sizeof buf - 1, p);
  pclose(p);
  return n > 0 && buf[0] != 'Z';
}

static int group_alive(pid_t pgid) {
  char cmd[64], line[64];
  snprintf(cmd, sizeof cmd, "/bin/ps -o stat= -g %d", (int)pgid);
  FILE *p = popen(cmd, "r");
  if (p == NULL) return 1;
  int live = 0;
  while (fgets(line, sizeof line, p) != NULL) {
    char *s = line;
    while (*s == ' ') s++;
    if (*s != 0 && *s != '\n' && *s != 'Z') live++;
  }
  pclose(p);
  return live;
}

static int read_file(const char *path, char *buf, size_t cap) {
  FILE *f = fopen(path, "r");
  if (f == NULL) return 0;
  size_t n = fread(buf, 1, cap - 1, f);
  fclose(f);
  buf[n] = 0;
  return (int)n;
}

/* Starts the browser stand-in; returns its pid and the setup child's pid. */
static pid_t start_browser(const char *python, const char *stub, const char *ready, const char *barrier, pid_t *setup) {
  int p[2];
  if (pipe(p) != 0) return -1;
  pid_t browser = fork();
  if (browser == 0) {
    close(p[0]);
    char me[32];
    snprintf(me, sizeof me, "%d", (int)getpid());
    const char *argv[] = {python, stub, me, ready, barrier, NULL};
    const char *envp[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
    pid_t child = -1;
    int r = zb_agent_spawn_group(argv, envp, &child);
    if (write(p[1], &child, sizeof child) != sizeof child || r != 0) _exit(1);
    for (;;) pause();
  }
  close(p[1]);
  *setup = -1;
  if (read(p[0], setup, sizeof *setup) != sizeof *setup) *setup = -1;
  close(p[0]);
  return browser;
}

static void reap_survivors(pid_t pgid) {
  if (pgid > 0 && group_alive(pgid)) {
    printf("  cleanup: killing survivors of group %d\n", (int)pgid);
    kill(-pgid, SIGKILL);
  }
}

static int wait_ready(const char *ready, char *buf, size_t cap, double secs) {
  double until = now() + secs;
  while (now() < until) {
    if (read_file(ready, buf, cap) > 0) return 1;
    usleep(20000);
  }
  return 0;
}

static void case_armed(const char *python, const char *stub, const char *dir) {
  char ready[512], buf[64];
  snprintf(ready, sizeof ready, "%s/ready-armed", dir);
  pid_t setup = -1;
  pid_t browser = start_browser(python, stub, ready, NULL, &setup);
  if (browser <= 0 || setup <= 0) { fail("armed: the spawn did not start setup"); if (browser > 0) kill(browser, SIGKILL); return; }
  if (!wait_ready(ready, buf, sizeof buf, 20)) { fail("armed: setup never armed"); kill(browser, SIGKILL); reap_survivors(setup); return; }
  pid_t grandchild = (pid_t)atoi(buf);
  if (getpgid(setup) != setup) fail("armed: setup leads its own process group");
  if (grandchild <= 0 || getpgid(grandchild) != setup) fail("armed: setup's descendant is in setup's group");
  kill(browser, SIGKILL);
  waitpid(browser, NULL, 0);
  double until = now() + 2.0;
  while (now() < until && group_alive(setup)) usleep(20000);
  if (group_alive(setup) || alive(setup) || (grandchild > 0 && alive(grandchild)))
    fail("armed: within 2 s of the browser's SIGKILL no member of setup's group is alive");
  reap_survivors(setup);
}

static void case_barrier(const char *python, const char *stub, const char *dir) {
  char ready[512], barrier[512], buf[64];
  snprintf(ready, sizeof ready, "%s/ready-barrier", dir);
  snprintf(barrier, sizeof barrier, "%s/go", dir);
  pid_t setup = -1;
  pid_t browser = start_browser(python, stub, ready, barrier, &setup);
  if (browser <= 0 || setup <= 0) { fail("barrier: the spawn did not start setup"); if (browser > 0) kill(browser, SIGKILL); return; }
  if (!wait_ready(ready, buf, sizeof buf, 20) || strcmp(buf, "barrier") != 0) {
    fail("barrier: setup never reached the barrier");
    kill(browser, SIGKILL); reap_survivors(setup); return;
  }
  kill(browser, SIGKILL);  /* dies between the parent check and the registration */
  waitpid(browser, NULL, 0);
  FILE *go = fopen(barrier, "w");
  if (go != NULL) fclose(go);
  double until = now() + 2.0;
  while (now() < until && group_alive(setup)) usleep(20000);
  if (group_alive(setup) || alive(setup)) fail("barrier: a browser dead before the registration still takes the group within 2 s");
  reap_survivors(setup);
}

int main(int argc, char **argv) {
  if (zb_agent_spawn_group == NULL) {
    printf("FAIL\tms5-spawn-group\tzb_agent_spawn_group is missing (rev 14 item 5)\n");
    return 1;
  }
  if (argc != 3) { printf("FAIL\tms5-spawn-group\tusage: spawn_group_test <watch_stub.py> <python3>\n"); return 1; }
  char dir[] = "/tmp/zb-spawn-XXXXXX";
  if (mkdtemp(dir) == NULL) { printf("FAIL\tms5-spawn-group\tmkdtemp\n"); return 1; }
  case_armed(argv[2], argv[1], dir);
  case_barrier(argv[2], argv[1], dir);
  char rm[600];
  snprintf(rm, sizeof rm, "/bin/rm -rf '%s'", dir);
  if (system(rm) != 0) printf("  note: could not remove %s\n", dir);
  if (failures == 0) {
    printf("PASS\tms5-spawn-group\t2 cases\n");
    return 0;
  }
  printf("FAIL\tms5-spawn-group\t%d failure(s)\n", failures);
  return 1;
}
