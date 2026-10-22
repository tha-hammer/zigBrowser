/* bd zigBrowser-4pa.76 (plan R30-MS7, R30.2 T16): the Linux Secrets window's C ABI (agent_secrets_window.h) and the
 * macOS Secrets window's entry point (agent_secrets_window_mac.h) must be able to meet in one translation unit, so
 * no two C functions share a name with different meanings. A TRIPWIRE (a compile of two headers), never proof: the
 * renamed macOS entry is proven only when it opens the real Secrets window on a Mac (the MS7.5 compiled gate).
 * Compiled, never run: build step `check-secrets-window-headers`, in `test` (Linux). */
#include "agent_secrets_window.h"
#include "agent_secrets_window_mac.h"
