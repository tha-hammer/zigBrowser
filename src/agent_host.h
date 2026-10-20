#ifndef ZB_AGENT_HOST_H
#define ZB_AGENT_HOST_H

/* The Claude Agent helper's process side (chat-drawer plan D7, S3). Linux
 * (GTK backend) only. Plain C types, so Zig can import this header. */

#include <sys/types.h>

#if defined(_WIN32) && !defined(__MINGW32__)
/* This subsystem is Linux-only (fork/prctl/flock/netd) and is never called on Windows (app.zig guards
 * every use with builtin.os.tag == .linux), but the header must still TRANSLATE for the Windows build's
 * unconditional @cImport, where MSVC's <sys/types.h> has no pid_t. MinGW (the x86_64-windows-gnu
 * cross-check target) DOES define pid_t in <sys/types.h>, so excluding __MINGW32__ avoids a typedef
 * redefinition clash there while still supplying pid_t for the real MSVC build. */
typedef int pid_t;
#endif

/* Takes the agent home's owner lock (plan D12, S3.12): creates `home`
 * (0700) if needed, then flock(home/.zb-owner.lock, LOCK_EX|LOCK_NB). The
 * lock is held until the process exits. Returns 0 when held, -2 when another
 * process holds it, -1 on any other error. Taking it again is a no-op. */
int zb_agent_home_lock(const char *home);

/* The spawn/lifetime policy a sandbox backend supplies (MS0, macOS launch plan
 * rev 6, route a): the Linux facts behind the child setup, named so a macOS
 * backend (MS6) can later supply its own (posix_spawn + kqueue NOTE_EXIT) for
 * the same semantic contract. `pdeathsig` is the signal the child dies with
 * when the browser does (SIGKILL on Linux); `check_parent_race`, when set,
 * _exit(127)s if the child was already reparented between fork and prctl,
 * closing that race (RoseCat 5330); `delay_ms` (e2e only, else 0) widens it for
 * the regression test. It governs die-with-browser ONLY — it does not create a
 * process group (G_SPAWN_DEFAULT does not, and the helper makes its own with
 * setpgid in its own child setup). */
typedef struct {
  int pdeathsig;
  int check_parent_race;
  unsigned int delay_ms;
} ZbSpawnPolicy;

/* The Linux spawn/lifetime policy: SIGKILL, race-check on, `delay_ms` (e2e). */
ZbSpawnPolicy zb_spawn_policy_linux(unsigned int delay_ms);

/* A spawn's child setup (GSpawnChildSetupFunc): applies `policy` in the child
 * before exec — die with the browser, then the parent-race check. `parent` is
 * the browser's pid at fork. The helper's spawn (agent_helper.c, S3b) uses it
 * too (after its own setpgid). */
typedef struct {
  pid_t parent;
  ZbSpawnPolicy policy;
} ZbChildSetup;
void zb_agent_die_with_browser(void *data);

/* Runs `argv` (NULL-terminated) with exactly `envp` (NULL-terminated) and
 * waits for it. Its stdin is /dev/null; stdout and stderr are the browser's.
 * `policy` is the caller-supplied spawn/lifetime policy (MS0 rev 6, route a): the
 * Zig caller passes zb_spawn_policy_linux(delay_ms) today, so a backend owns the
 * die-with-browser contract rather than this function hard-coding it (a macOS
 * backend can supply its own for the same meaning). It dies with the browser by
 * PR_SET_PDEATHSIG, then re-checks its parent to close the fork-to-prctl race
 * (RoseCat 5330); policy.delay_ms (e2e only, else 0) widens that race for the
 * regression test. Returns its exit status
 * (0..255), 128+N when signal N ended it, or -1 when it could not start. */
int zb_agent_run_sync(const char *const *argv, const char *const *envp, ZbSpawnPolicy policy);

/* The agent's network helper, netd (chat-drawer plan rev 16.2 §3c.2; S3n2
 * native spawn wiring). One per browser, started at most once. GTK thread
 * only. With --e2e-protocol every state change writes the row
 * `AGENTNET <starting|ready DIR|unavailable REASON>`. */
enum {
  ZB_AGENT_NET_NOT_SET_UP = 0, /* not configured: no provisioned agent home */
  ZB_AGENT_NET_IDLE = 1,
  ZB_AGENT_NET_STARTING = 2,
  ZB_AGENT_NET_READY = 3,
  ZB_AGENT_NET_UNAVAILABLE = 4,
};

/* Called once, before the first window: netd's argv and its whole
 * environment (NULL-terminated, copied), its socket directory, and
 * `refusal`: when non-NULL, the one stderr line that refuses the agent (a bad
 * seam, no XDG_RUNTIME_DIR), printed when the agent would start. */
void zb_agent_net_configure(const char *const *argv, const char *const *envp, const char *sockdir,
                            const char *refusal, int e2e_protocol);

/* Starts netd the first time (it dies with the browser, its stdin and stdout
 * are pipes the browser keeps), and returns the state now. netd has 5 s to
 * print `netd ready`. Whenever it becomes unavailable (a refusal, a failed
 * spawn, no `netd ready` in time, or its exit, logged as
 * `zigBrowser: agent: network helper exited (exit N|signal N)`), the
 * listener is called once; it is never started again. */
int zb_agent_net_ensure(void);
void zb_agent_net_set_listener(void (*listener)(void *data), void *data);
/* Called once when netd prints `netd ready` (S3b starts the helper then). */
void zb_agent_net_set_ready_listener(void (*listener)(void *data), void *data);

/* netd's socket directory while it is ready, else NULL (S3b passes it on to
 * the helper's launch as --net-dir). */
const char *zb_agent_net_dir(void);

/* At quit, after the main loop: closes netd's stdin (its normal shutdown:
 * it removes its sockets and directory) and waits up to 2 s for it. */
void zb_agent_net_stop(void);

#endif
