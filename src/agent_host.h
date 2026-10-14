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

#endif
