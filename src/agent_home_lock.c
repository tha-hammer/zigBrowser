/* See agent_home_lock.h. Moved out of agent_host.c (macOS plan rev 14 item 4) with its behaviour unchanged;
 * the two GLib calls it used are replaced by their POSIX equivalents: g_mkdir_with_parents(home, 0700)
 * (create each missing component 0700; an existing non-directory is ENOTDIR) and g_build_filename. */
#include "agent_home_lock.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static int zb_agent_lock_fd = -1;

/* g_mkdir_with_parents(path, 0700): 0 when `path` is (now) a directory, else -1 with errno set. */
static int mkdir_with_parents(const char *path) {
  char buf[PATH_MAX];
  size_t len = strlen(path);
  if (len == 0 || len >= sizeof buf) {
    errno = len == 0 ? EINVAL : ENAMETOOLONG;
    return -1;
  }
  memcpy(buf, path, len + 1);
  for (char *p = buf + 1;; p++) {
    if (*p == '/' || *p == '\0') {
      char saved = *p;
      *p = '\0';
      struct stat st;
      if (stat(buf, &st) != 0) {
        if (mkdir(buf, 0700) != 0 && errno != EEXIST) {
          return -1;
        }
      } else if (!S_ISDIR(st.st_mode)) {
        errno = ENOTDIR;
        return -1;
      }
      *p = saved;
      if (saved == '\0') {
        break;
      }
    }
  }
  return 0;
}

int zb_agent_home_lock(const char *home) {
  if (zb_agent_lock_fd >= 0) {
    return 0;
  }
  if (home == NULL || mkdir_with_parents(home) != 0) {
    return -1;
  }
  char path[PATH_MAX];
  size_t n = strlen(home);
  const char *sep = n > 0 && home[n - 1] == '/' ? "" : "/";
  if (snprintf(path, sizeof path, "%s%s.zb-owner.lock", home, sep) >= (int)sizeof path) {
    return -1;
  }
  int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) {
    return -1;
  }
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    int busy = errno == EWOULDBLOCK;
    close(fd);
    return busy ? -2 : -1;
  }
  zb_agent_lock_fd = fd;
  return 0;
}
