/* MS6.5 run-survivor classification (the user's decision 2026-10-21). See agent_run_reaper.h. The macOS libproc
 * sweep + the guarded kill that use these land with the both-Mac hard-gate case. */
#include "agent_run_reaper.h"

#include <string.h>

int zb_reaper_path_under(const char *path, const char *dir) {
  if (path == NULL || dir == NULL) return 0;
  size_t dl = strlen(dir);
  while (dl > 1 && dir[dl - 1] == '/') dl--; /* ignore trailing slashes on the run dir */
  /* Root ("/") and empty are NEVER run markers: matching them would sweep the whole system. Fail closed. */
  if (dl < 2) return 0;
  if (strncmp(path, dir, dl) != 0) return 0;
  const char c = path[dl];
  return c == '\0' || c == '/'; /* exactly the dir, or a child across a whole path component */
}

int zb_reaper_classify(const char *cwd, const char *exe, const char *const *fd_paths, int nfds,
                       const char *run_dir) {
  if (zb_reaper_path_under(cwd, run_dir)) return 1;
  if (zb_reaper_path_under(exe, run_dir)) return 1;
  for (int i = 0; i < nfds; i++) {
    if (fd_paths != NULL && zb_reaper_path_under(fd_paths[i], run_dir)) return 1;
  }
  return 0;
}
