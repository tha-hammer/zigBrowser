/* The agent home's owner lock (chat-drawer plan D12, S3.12), POSIX only (no GLib), so the GTK build and the
 * macOS build share it (macOS plan rev 14 item 4; moved out of agent_host.c, behaviour unchanged). */
#ifndef ZB_AGENT_HOME_LOCK_H
#define ZB_AGENT_HOME_LOCK_H

#ifdef __cplusplus
extern "C" {
#endif

/* Takes the agent home's owner lock: creates `home` (0700, with any missing parents) if needed, then
 * flock(home/.zb-owner.lock, LOCK_EX|LOCK_NB). The lock is held until the process exits. Returns 0 when
 * held, -2 when another process holds it, -1 on any other error. Taking it again is a no-op. */
int zb_agent_home_lock(const char *home);

#ifdef __cplusplus
}
#endif

#endif /* ZB_AGENT_HOME_LOCK_H */
