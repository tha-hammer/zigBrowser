/* S7b red only (chat-drawer plan rev 16.20.35): the screenshot fit seam is not built yet, so
 * tests/agent_image_fit_test.zig links this stand-in, which answers -1 (not built) and sets
 * nothing. The green links src/agent_image.c instead and removes this file. */

#include <stddef.h>

int zb_agent_image_fit(const unsigned char *png, size_t len, size_t max_b64, char **out_b64,
                       const char **out_mime) {
  (void)png;
  (void)len;
  (void)max_b64;
  *out_b64 = NULL;
  *out_mime = NULL;
  return -1;
}

void zb_agent_image_free(void *b64) {
  (void)b64;
}
