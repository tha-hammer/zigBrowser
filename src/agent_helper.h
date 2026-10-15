#ifndef ZB_AGENT_HELPER_H
#define ZB_AGENT_HELPER_H

/* The chat helper's process side (chat-drawer plan D7, D7b, S3.2-S3.4, S3.12;
 * rev 16 §3c.2; S3b). Linux (GTK backend) only, GTK main thread only.
 *
 * On the first Send it takes the agent home's owner lock, starts netd
 * (agent_host.c), fetches the token (agent_secrets.h), then spawns the
 * launch argv (app.zig, agent_helper.zig) with the token on a pipe at fd 3,
 * its own process group, and PDEATHSIG. Every helper stdout line is
 * validated natively (agent_protocol.zig) before anything acts on it. */

#include <stddef.h>

/* Called once by app.zig before the first window. Everything is copied.
 * `argv`/`envp`: the launch command (NULL-terminated). `unavailable`:
 * when non-NULL, the status reason that makes the agent unavailable before
 * anything starts (`runtime-missing`, `config-changed`), with `bubble` the
 * system message shown with it; `refusal`: a stderr line printed on the first
 * Send (a bad e2e seam), which also makes the agent unavailable. */
void zb_agent_helper_configure(const char *const *argv, const char *const *envp, const char *home,
                               const char *unavailable, const char *bubble, const char *refusal,
                               int e2e_protocol);

/* 1 once zb_agent_helper_configure was called (a provisioned agent home). */
int zb_agent_helper_configured(void);

/* The drawer of window `win_id` sends `text` (UTF-8, not empty). */
void zb_agent_helper_send(unsigned int win_id, const char *text);

/* Window `win_id` closes: `end_session` for its session only. */
void zb_agent_helper_window_closed(unsigned int win_id);

/* At quit, after the main loop: `shutdown`, 2 s, SIGTERM to the helper's
 * group, 1 s, SIGKILL (D7). A no-op when no helper runs. */
void zb_agent_helper_stop(void);

/* Implemented by agent_drawer.c. `win_id` 0 means every drawer. */
void zb_drawer_agent_status(unsigned int win_id, const char *state, const char *reason);
void zb_drawer_agent_message(unsigned int win_id, const char *role, const char *text, size_t len);
void zb_drawer_agent_delta(unsigned int win_id, const char *session, const char *text, size_t len);

#endif
