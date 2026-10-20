/* The screenshot fit seam (chat-drawer plan section 10, S7b, rev 16.20.35): see
 * agent_image.h. */

#include "agent_image.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <math.h>
#include <string.h>

static const unsigned char png_signature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
/* A PNG's last chunk: an empty IEND. GdkPixbuf decodes a PNG cut short (the rest blank), so a
 * PNG without it is refused rather than shown. */
static const unsigned char png_iend[12] = {0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82};

static size_t b64_len(size_t len) {
  return (len + 2) / 3 * 4;
}

/* The decoded PNG without alpha (JPEG has none): composited over white. */
static GdkPixbuf *decode_opaque(const unsigned char *png, size_t len) {
  GdkPixbufLoader *loader = gdk_pixbuf_loader_new_with_type("png", NULL);
  if (loader == NULL) {
    return NULL;
  }
  GdkPixbuf *decoded = NULL;
  if (gdk_pixbuf_loader_write(loader, png, len, NULL) && gdk_pixbuf_loader_close(loader, NULL)) {
    decoded = gdk_pixbuf_loader_get_pixbuf(loader);
  } else {
    gdk_pixbuf_loader_close(loader, NULL);
  }
  GdkPixbuf *out = NULL;
  if (decoded != NULL) {
    int w = gdk_pixbuf_get_width(decoded), h = gdk_pixbuf_get_height(decoded);
    if (!gdk_pixbuf_get_has_alpha(decoded)) {
      out = g_object_ref(decoded);
    } else if ((out = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, w, h)) != NULL) {
      gdk_pixbuf_fill(out, 0xffffffffu);
      gdk_pixbuf_composite(decoded, out, 0, 0, w, h, 0, 0, 1, 1, GDK_INTERP_NEAREST, 255);
    }
  }
  g_object_unref(loader);
  return out;
}

int zb_agent_image_fit(const unsigned char *png, size_t len, size_t max_b64, char **out_b64,
                       const char **out_mime) {
  *out_b64 = NULL;
  *out_mime = NULL;
  if (png == NULL || len < sizeof png_signature + sizeof png_iend ||
      memcmp(png, png_signature, sizeof png_signature) != 0 ||
      memcmp(png + len - sizeof png_iend, png_iend, sizeof png_iend) != 0) {
    return ZB_IMAGE_FIT_UNREADABLE;
  }
  /* Decoded first, even when it fits as is: bytes that only look like a PNG are refused,
   * never sent (RoseCat fb75e11). */
  GdkPixbuf *full = decode_opaque(png, len);
  if (full == NULL) {
    return ZB_IMAGE_FIT_UNREADABLE;
  }
  if (b64_len(len) <= max_b64) {
    g_object_unref(full);
    *out_b64 = g_base64_encode(png, len);
    *out_mime = "image/png";
    return ZB_IMAGE_FIT_OK;
  }
  static const double scales[] = {1.0, 0.75, 0.5, 0.35, 0.25};
  static const char *const qualities[] = {"85", "70", "50"};
  const int w = gdk_pixbuf_get_width(full), h = gdk_pixbuf_get_height(full);
  int rc = ZB_IMAGE_FIT_TOO_LARGE;
  for (size_t s = 0; s < G_N_ELEMENTS(scales) && rc != ZB_IMAGE_FIT_OK; s++) {
    const int sw = MAX(1, (int)lround(w * scales[s])), sh = MAX(1, (int)lround(h * scales[s]));
    GdkPixbuf *scaled = s == 0 ? g_object_ref(full) : gdk_pixbuf_scale_simple(full, sw, sh, GDK_INTERP_BILINEAR);
    if (scaled == NULL) {
      continue;
    }
    for (size_t q = 0; q < G_N_ELEMENTS(qualities); q++) {
      gchar *jpeg = NULL;
      gsize jpeg_len = 0;
      if (!gdk_pixbuf_save_to_buffer(scaled, &jpeg, &jpeg_len, "jpeg", NULL, "quality", qualities[q], NULL)) {
        continue;
      }
      if (b64_len(jpeg_len) <= max_b64) {
        *out_b64 = g_base64_encode((const guchar *)jpeg, jpeg_len);
        *out_mime = "image/jpeg";
        rc = ZB_IMAGE_FIT_OK;
      }
      g_free(jpeg);
      if (rc == ZB_IMAGE_FIT_OK) {
        break;
      }
    }
    g_object_unref(scaled);
  }
  g_object_unref(full);
  return rc;
}

void zb_agent_image_free(void *b64) {
  g_free(b64);
}
