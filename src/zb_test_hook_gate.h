// Pure, AppKit-free decisions of the e2e-only test hooks of wkwebview_shim.m, so test-only probes
// (tests/hook16_decision_test.zig, tests/hook14_decision_test.zig) drive them without starting AppKit, opening a
// window or creating any WebKit store.
#ifndef ZB_TEST_HOOK_GATE_H
#define ZB_TEST_HOOK_GATE_H

#include <stdlib.h>

enum { ZB_STORE_PERSISTENT = 0, ZB_STORE_EPHEMERAL = 1 };

// Hook 16 (ZB_DEBUG_EPHEMERAL_DATA_STORE): the website data store every window gets. hooks_enabled is
// zb_auto_test_hooks_enabled() (--e2e-protocol); without it the hook is inert and production keeps the
// persistent store, whatever the environment says.
static inline int zb_hook16_select_store(int hooks_enabled) {
  if (!hooks_enabled) return ZB_STORE_PERSISTENT;
  const char *v = getenv("ZB_DEBUG_EPHEMERAL_DATA_STORE");
  return (v != NULL && v[0] == '1') ? ZB_STORE_EPHEMERAL : ZB_STORE_PERSISTENT;
}

// Hook 14 (ZB_DEBUG_NATIVE_CLOSE_ON_TITLE, 4pa.58): the page title that makes a window close itself through
// -[NSWindow performClose:]. Without --e2e-protocol the hook is inert (NULL), so no page title ever closes a window.
static inline const char *zb_hook14_native_close_title(int hooks_enabled) {
  if (!hooks_enabled) return NULL;
  const char *v = getenv("ZB_DEBUG_NATIVE_CLOSE_ON_TITLE");
  return (v != NULL && v[0] != '\0') ? v : NULL;
}

#endif
