/* The one-shot sign-in (chat-drawer plan S6b1, rev 16.18.3; D7b login frames).
 *
 * One sign-in at a time. Start runs its own login netd (runtime/net-login.json,
 * `<chat sockdir>-login`, egress only), waits for `netd ready`, then starts the
 * login helper (`launch --command login`) with its stdin and stdout as the frame
 * pipes and a pipe as its fd 4. Every frame is validated (agent_login.zig). The
 * token is read from fd 4 only after `done`, handed to the listener once, and
 * wiped. At the end the helper exits, then the login netd's stdin closes, so no
 * login netd and no `-login` directory remain.
 *
 * GTK main thread only. */
#ifndef ZB_AGENT_LOGIN_H
#define ZB_AGENT_LOGIN_H

typedef enum {
  ZB_LOGIN_EV_STARTING,
  ZB_LOGIN_EV_AUTH_URL,  /* detail: the authorize URL (S6b2's auth window) */
  ZB_LOGIN_EV_NEED_CODE, /* the CLI shows its prompt */
  ZB_LOGIN_EV_DONE,      /* detail: the token, valid only during the call; wiped after it */
  ZB_LOGIN_EV_ERROR,     /* detail: cli, timeout, shape, protocol or network */
  ZB_LOGIN_EV_CANCELLED,
} ZbLoginEvent;

typedef void (*ZbLoginListener)(ZbLoginEvent event, const char *detail, void *data);

/* Copies everything. A NULL argv means the agent is not set up: start refuses. */
void zb_login_configure(const char *const *netd_argv, const char *const *netd_envp, const char *login_dir,
                        const char *const *launch_argv, const char *const *launch_envp);
int zb_login_configured(void);
/* 0 when a sign-in started (STARTING is sent at once), -1 when none can (not
 * configured, or one is running). Exactly one ending event follows: DONE, ERROR
 * or CANCELLED. */
int zb_login_start(ZbLoginListener listener, void *data);
/* 0 when `code` matched the `code` frame's grammar and was sent; -1 otherwise
 * (nothing is sent). */
int zb_login_send_code(const char *code);
/* Ends a running sign-in with CANCELLED (the helper is told; one that does not
 * answer within 3 s is killed). */
void zb_login_cancel(void);
int zb_login_running(void);

#endif
