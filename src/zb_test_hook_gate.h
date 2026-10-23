// Pure, AppKit-free decisions of the e2e-only test hooks of wkwebview_shim.m, so a test-only probe
// (tests/hook16_decision_test.zig) drives them without starting AppKit or creating any WebKit store.
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

#endif
