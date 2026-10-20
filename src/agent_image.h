#ifndef ZB_AGENT_IMAGE_H
#define ZB_AGENT_IMAGE_H

/* The screenshot fit seam (chat-drawer plan section 10, S7b, rev 16.20.35). Linux (GTK
 * backend) only; GdkPixbuf, no main loop, so it runs on a broker's worker thread. Plain C
 * types, so Zig can import this header. */

#include <stddef.h>

enum {
  ZB_IMAGE_FIT_OK = 0,
  ZB_IMAGE_FIT_TOO_LARGE = 1,  /* "result too large" */
  ZB_IMAGE_FIT_UNREADABLE = 2, /* "the screenshot could not be read" */
};

/* Fits a page.screenshot PNG into one image block whose base64 is at most `max_b64`:
 * - the PNG as is (`image/png`) when its base64 fits;
 * - else a JPEG (`image/jpeg`) at scale 1, 0.75, 0.5, 0.35, 0.25, each at quality 85, 70,
 *   50, the first that fits;
 * - else ZB_IMAGE_FIT_TOO_LARGE. Bytes without the PNG signature or its closing IEND chunk
 *   (a PNG cut short), or a PNG GdkPixbuf cannot decode, are ZB_IMAGE_FIT_UNREADABLE.
 * On ZB_IMAGE_FIT_OK, `*out_b64` is NUL-terminated base64 (free it with
 * zb_agent_image_free) and `*out_mime` a static string; otherwise both are NULL. */
int zb_agent_image_fit(const unsigned char *png, size_t len, size_t max_b64, char **out_b64,
                       const char **out_mime);

void zb_agent_image_free(void *b64);

#endif
