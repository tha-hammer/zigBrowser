/* The signal fake for tests/kill_group/kill_group_test.c (RoseCat 7172, 7182; the 2026-10-21 logouts). Every killpg and
 * kill that src/agent_spawn_posix.c makes lands here, NEVER in the kernel, unless the target is the one leader pid the
 * test allowlisted with zb_fake_allow() and the signal is SIGKILL. So no wrong pid (1 = kill(-1), our own group, a
 * stranger) can reach a real signal, even while the code under test is still unguarded (the red).
 * - Linux: the test links with -Wl,--wrap=killpg -Wl,--wrap=kill; the real calls are __real_killpg / __real_kill.
 * - Darwin: this file is its own dylib with a __DATA,__interpose table, which dyld applies to every OTHER image (the
 *   libzbspawn.dylib built from agent_spawn_posix.c); inside this image killpg/kill are the real ones. Measured on
 *   both Macs: an interposer in the main executable has no effect, one in a linked dylib does. */
#include <errno.h>
#include <signal.h>
#include <sys/types.h>

static pid_t allowed = 0;
static int calls = 0, forwarded = 0, bad = 0, kill_calls = 0;
static pid_t last_target = 0, first_bad_target = 0;
static int last_was_pg = 0, first_bad_was_pg = 0, first_bad_sig = 0;

void zb_fake_allow(pid_t pid) { allowed = pid; }
void zb_fake_reset(void) {
  calls = forwarded = bad = kill_calls = 0;
  last_target = first_bad_target = 0;
  last_was_pg = first_bad_was_pg = first_bad_sig = 0;
  allowed = 0;
}
int zb_fake_calls(void) { return calls; }              /* every killpg and kill */
int zb_fake_forwarded(void) { return forwarded; }      /* the permitted killpg/kill(allowed, SIGKILL) */
int zb_fake_bad(void) { return bad; }                  /* every refused call (never sent) */
int zb_fake_kill_calls(void) { return kill_calls; }    /* kill() calls, refused or not: never expected */
pid_t zb_fake_last_target(void) { return last_target; }
int zb_fake_last_was_pg(void) { return last_was_pg; }
pid_t zb_fake_first_bad_target(void) { return first_bad_target; }
int zb_fake_first_bad_was_pg(void) { return first_bad_was_pg; }
int zb_fake_first_bad_sig(void) { return first_bad_sig; }

#ifdef __APPLE__
static int real_killpg(pid_t p, int s) { return killpg(p, s); }
static int real_kill(pid_t p, int s) { return kill(p, s); }
#else
int __real_killpg(pid_t p, int s);
int __real_kill(pid_t p, int s);
#define real_killpg __real_killpg
#define real_kill __real_kill
#endif

static int hook(int is_pg, pid_t pid, int sig) {
  calls++;
  last_target = pid;
  last_was_pg = is_pg;
  if (!is_pg) kill_calls++;
  if (allowed > 1 && pid == allowed && sig == SIGKILL) {
    forwarded++;
    return is_pg ? real_killpg(pid, sig) : real_kill(pid, sig);
  }
  if (bad++ == 0) {
    first_bad_target = pid;
    first_bad_was_pg = is_pg;
    first_bad_sig = sig;
  }
  errno = EPERM;  /* refused here, never sent */
  return -1;
}

#ifdef __APPLE__
static int fake_killpg(pid_t p, int s) { return hook(1, p, s); }
static int fake_kill(pid_t p, int s) { return hook(0, p, s); }
__attribute__((used)) static struct {
  const void *replacement;
  const void *original;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)fake_killpg, (const void *)killpg},
    {(const void *)fake_kill, (const void *)kill},
};
#else
int __wrap_killpg(pid_t p, int s) { return hook(1, p, s); }
int __wrap_kill(pid_t p, int s) { return hook(0, p, s); }
#endif
