#ifndef ZB_AGENT_HOST_H
#define ZB_AGENT_HOST_H

/* The Claude Agent helper's process side (chat-drawer plan D7, S3). Linux
 * (GTK backend) only. Plain C types, so Zig can import this header. */

/* Takes the agent home's owner lock (plan D12, S3.12): creates `home`
 * (0700) if needed, then flock(home/.zb-owner.lock, LOCK_EX|LOCK_NB). The
 * lock is held until the process exits. Returns 0 when held, -2 when another
 * process holds it, -1 on any other error. Taking it again is a no-op. */
int zb_agent_home_lock(const char *home);

/* Runs `argv` (NULL-terminated) with exactly `envp` (NULL-terminated) and
 * waits for it. Its stdin is /dev/null; stdout and stderr are the browser's.
 * It dies with the browser: PR_SET_PDEATHSIG, then a check that its parent
 * is still the browser, which closes the fork-to-prctl race (RoseCat 5330).
 * `spawn_delay_ms` (e2e only, else 0) widens that race for the regression
 * test. Returns its exit status
 * (0..255), 128+N when signal N ended it, or -1 when it could not start. */
int zb_agent_run_sync(const char *const *argv, const char *const *envp, unsigned int spawn_delay_ms);

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

/* netd's socket directory while it is ready, else NULL (S3b passes it on to
 * the helper's launch as --net-dir). */
const char *zb_agent_net_dir(void);

/* At quit, after the main loop: closes netd's stdin (its normal shutdown:
 * it removes its sockets and directory) and waits up to 2 s for it. */
void zb_agent_net_stop(void);

#endif
