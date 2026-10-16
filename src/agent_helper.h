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

/* The bubble for a missing runtime, and for no provisioned agent home at all (S5.5). */
#define ZB_AGENT_TEXT_RUNTIME "Agent runtime not set up: run zigBrowser --agent-setup"

/* The drawer of window `win_id` sends `text` (UTF-8, not empty). */
void zb_agent_helper_send(unsigned int win_id, const char *text);

/* The drawer of window `win_id` pressed Stop: its running reply is interrupted (S5.2).
 * Nothing runs: nothing happens. */
void zb_agent_helper_interrupt(unsigned int win_id);

/* Window `win_id` closes: `end_session` for its session only. */
void zb_agent_helper_window_closed(unsigned int win_id);

/* At quit, after the main loop: `shutdown`, 2 s, SIGTERM to the helper's
 * group, 1 s, SIGKILL (D7). A no-op when no helper runs. */
void zb_agent_helper_stop(void);

/* The stored token was removed (S4.2; the Secrets window's Remove): every session
 * ends and the helper stops (shutdown, then SIGTERM and SIGKILL on timers; the main
 * loop never blocks), because it holds the token it read at start. Then the agent is
 * idle, and the next Send starts afresh (no token: the Secrets window opens). No
 * helper running: nothing to stop. GTK main thread. */
void zb_agent_helper_token_removed(void);

/* Implemented by agent_drawer.c (the drawer's seam; JadeBeacon 5867 for a Cocoa drawer).
 * `win_id` 0 means every drawer. Every zb_drawer_agent_* call arrives on the UI thread
 * (here the GTK main thread). A drawer keeps the streamed text it shows: a later message
 * replaces it, an error or system bubble ends it as it is, and Stop ends it with
 * " (stopped)". */
void zb_drawer_agent_status(unsigned int win_id, const char *state, const char *reason);
void zb_drawer_agent_message(unsigned int win_id, const char *role, const char *text, size_t len);
void zb_drawer_agent_delta(unsigned int win_id, const char *session, const char *text, size_t len);
/* Window `win_id`'s reply was stopped: its bubble ends with "(stopped)" (S5.2). */
void zb_drawer_agent_stopped(unsigned int win_id);

#endif
