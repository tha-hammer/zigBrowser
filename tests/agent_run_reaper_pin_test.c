/* MS6.5 run-dir pin + path-swap, proven on Linux with real directories (RoseCat 3da2862 #4). zb_reaper_pin_dir
 * is portable (open O_NOFOLLOW + fstat/stat), so the pinned-identity guard and its path-swap detection are tested
 * here without a Mac. No signals are sent. */
#include "agent_run_reaper.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures = 0, total = 0;
static void check(int ok, const char *m) { total++; printf("  %s %s\n", ok ? "ok" : "FAIL", m); if (!ok) failures++; }

int main(void) {
  char parent[] = "/tmp/zb-pin-XXXXXX";
  if (mkdtemp(parent) == NULL) { printf("FAIL mkdtemp\n"); return 2; }

  char dir[512];
  snprintf(dir, sizeof dir, "%s/zigbrowser-agent-%d-0123456789abcdef", parent, (int)getpid());
  if (mkdir(dir, 0700) != 0) { printf("FAIL mkdir\n"); rmdir(parent); return 2; }

  struct zb_reaper_dir_id id;
  int fd = zb_reaper_pin_dir(dir, &id);
  check(fd >= 0, "pin succeeds on a 0700 app-grammar dir owned by us");
  check(fd >= 0 && zb_reaper_dir_still_pinned(fd, dir, &id), "still pinned immediately after");

  /* PATH SWAP: move the pinned dir aside and put a DIFFERENT inode at the same path. */
  char old[600];
  snprintf(old, sizeof old, "%s.old", dir);
  check(rename(dir, old) == 0 && mkdir(dir, 0700) == 0, "set up a path swap (new inode at the same path)");
  check(fd >= 0 && !zb_reaper_dir_still_pinned(fd, dir, &id), "the path swap is DETECTED (pin no longer holds)");
  if (fd >= 0) close(fd);
  rmdir(dir);
  rmdir(old);

  /* wrong mode: a 0755 dir is refused. */
  char d2[512];
  snprintf(d2, sizeof d2, "%s/zigbrowser-agent-%d-00112233445566ff", parent, (int)getpid());
  if (mkdir(d2, 0755) == 0) {
    check(zb_reaper_pin_dir(d2, &id) < 0, "pin refuses a non-0700 dir");
    rmdir(d2);
  } else check(0, "mkdir d2");

  /* a non-grammar name is refused before any open. */
  char d3[512];
  snprintf(d3, sizeof d3, "%s/not-the-app", parent);
  if (mkdir(d3, 0700) == 0) {
    check(zb_reaper_pin_dir(d3, &id) < 0, "pin refuses a non-grammar name");
    rmdir(d3);
  } else check(0, "mkdir d3");

  /* a symlink with a grammar name is refused by O_NOFOLLOW. */
  char real[512], link[560];
  snprintf(real, sizeof real, "%s/realdir", parent);
  snprintf(link, sizeof link, "%s/zigbrowser-agent-%d-aabbccddeeff0011", parent, (int)getpid());
  if (mkdir(real, 0700) == 0 && symlink(real, link) == 0) {
    check(zb_reaper_pin_dir(link, &id) < 0, "pin refuses a symlink (O_NOFOLLOW)");
    unlink(link);
    rmdir(real);
  } else check(0, "symlink setup");

  rmdir(parent);
  if (failures == 0) { printf("PASS ms6-5-reaper-pin %d checks\n", total); return 0; }
  printf("FAIL ms6-5-reaper-pin %d of %d check(s) failed\n", failures, total);
  return 1;
}
