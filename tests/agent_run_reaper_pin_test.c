/* MS6.5 fd-based run-dir pin, proven on Linux with real directories (RoseCat c09d439 #2/#3). zb_reaper_pin_fd /
 * zb_reaper_dir_fd_ok fstat a HELD dir fd — never a pathname — so a renamed/swapped path or a symlink back to
 * the held inode cannot fool the guard, a changed mode breaks it, and the inode survives a rename. Portable, no
 * signals. */
#include "agent_run_reaper.h"

#include <errno.h>
#include <fcntl.h>
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

  int fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  check(fd >= 0, "opened the run dir O_NOFOLLOW");
  struct zb_reaper_dir_id id;
  check(fd >= 0 && zb_reaper_pin_fd(fd, &id) == 0, "pin_fd captures a 0700 dir owned by us");
  check(fd >= 0 && zb_reaper_dir_fd_ok(fd, &id) == 1, "dir_fd_ok: the held fd still matches the pin");

  /* rename the held dir: the inode is unchanged, so the pin still holds (a rename is not an attack). */
  char moved[600];
  snprintf(moved, sizeof moved, "%s.moved", dir);
  check(rename(dir, moved) == 0, "rename the held dir aside");
  check(fd >= 0 && zb_reaper_dir_fd_ok(fd, &id) == 1, "dir_fd_ok still true after a rename (same inode)");

  /* SYMLINK-BACK bypass attempt: plant a symlink at the original path pointing to the held inode. dir_fd_ok
   * fstats the FD, never the path, so the symlink is irrelevant — no bypass, still correct. */
  check(symlink(moved, dir) == 0, "plant a symlink at the original path -> the held inode");
  check(fd >= 0 && zb_reaper_dir_fd_ok(fd, &id) == 1, "dir_fd_ok ignores the path (fstat only): no symlink bypass");
  unlink(dir);

  /* a changed mode breaks the pin. */
  check(fchmod(fd, 0755) == 0, "fchmod the held dir to 0755");
  check(fd >= 0 && zb_reaper_dir_fd_ok(fd, &id) == 0, "dir_fd_ok: a changed mode breaks the pin");
  if (fd >= 0) close(fd);
  rmdir(moved);

  /* a DIFFERENT dir's fd does not match the first pin (dev/ino differ). */
  char d2[512];
  snprintf(d2, sizeof d2, "%s/zigbrowser-agent-%d-fedcba9876543210", parent, (int)getpid());
  if (mkdir(d2, 0700) == 0) {
    int fd2 = open(d2, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    check(fd2 >= 0 && zb_reaper_dir_fd_ok(fd2, &id) == 0, "dir_fd_ok: a different dir's fd does not match the pin");
    if (fd2 >= 0) close(fd2);
    rmdir(d2);
  } else check(0, "mkdir d2");

  /* pin_fd rejects a non-0700 dir, a non-directory fd, and bad args. */
  char d3[512];
  snprintf(d3, sizeof d3, "%s/perms", parent);
  if (mkdir(d3, 0755) == 0) {
    int fd3 = open(d3, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    check(fd3 >= 0 && zb_reaper_pin_fd(fd3, &id) == EINVAL, "pin_fd refuses a non-0700 dir");
    if (fd3 >= 0) close(fd3);
    rmdir(d3);
  } else check(0, "mkdir d3");
  char file[512];
  snprintf(file, sizeof file, "%s/afile", parent);
  int ff = open(file, O_RDWR | O_CREAT, 0600);
  check(ff >= 0 && zb_reaper_pin_fd(ff, &id) == EINVAL, "pin_fd refuses a non-directory fd");
  if (ff >= 0) close(ff);
  unlink(file);
  check(zb_reaper_pin_fd(-1, &id) == EINVAL && zb_reaper_pin_fd(0, NULL) == EINVAL, "pin_fd refuses bad args");

  rmdir(parent);
  if (failures == 0) { printf("PASS ms6-5-reaper-pin %d checks\n", total); return 0; }
  printf("FAIL ms6-5-reaper-pin %d of %d check(s) failed\n", failures, total);
  return 1;
}
