/* A signal fake that NEVER forwards anything (RoseCat 7250 #1): every kill/killpg the linked code makes is written to
 * stderr as "FAKE-SIGNAL <kill|killpg> <pid> <sig>" and refused with EPERM. Linked with -Wl,--wrap=kill
 * -Wl,--wrap=killpg by tests/kill_group/spawn_io_no_stray_signal.sh, so no wrong pid can reach the kernel. */
#include <errno.h>
#include <stdio.h>
#include <sys/types.h>

int __wrap_kill(pid_t pid, int sig) {
  fprintf(stderr, "FAKE-SIGNAL kill %d %d\n", (int)pid, sig);
  errno = EPERM;
  return -1;
}

int __wrap_killpg(pid_t pgrp, int sig) {
  fprintf(stderr, "FAKE-SIGNAL killpg %d %d\n", (int)pgrp, sig);
  errno = EPERM;
  return -1;
}
