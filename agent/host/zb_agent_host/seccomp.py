"""The outer seccomp filter (D11/D12), passed to the helper's bwrap as `--seccomp <fd>`.

The program, in order:
1. kills the process when seccomp_data.arch is not x86_64;
2. returns EPERM for any x32 syscall number (bit 0x40000000);
3. returns EPERM for ptrace, process_vm_readv and process_vm_writev;
4. allows everything else, including clone, clone3, unshare, mount, pivot_root
   and setns, which the nested zb-hook-run bwrap needs.
bwrap installs it after its own setup; every descendant inherits it.
Standard library only.
"""

import os
import struct
import sys

if sys.platform != "win32":  # POSIX-only (WS7.5, bead zigBrowser-2p3): the module still imports on Windows
    import fcntl

from .files import write_all

AUDIT_ARCH_X86_64 = 0xC000003E
X32_SYSCALL_BIT = 0x40000000
DENIED = {"ptrace": 101, "process_vm_readv": 310, "process_vm_writev": 311}

RET_KILL_PROCESS = 0x80000000
RET_ERRNO = 0x00050000
RET_ALLOW = 0x7FFF0000
EPERM = 1
LD_W_ABS, JEQ_K, JGE_K, RET_K = 0x20, 0x15, 0x35, 0x06


def program():
    """The filter as raw classic BPF (struct sock_filter[]). Jumps are relative: i + 1 + k."""
    denied = list(DENIED.values())
    deny = 5 + len(denied) + 1
    insns = [
        (LD_W_ABS, 0, 0, 4),                        # 0: A = seccomp_data.arch
        (JEQ_K, 1, 0, AUDIT_ARCH_X86_64),           # 1: x86_64 -> 3
        (RET_K, 0, 0, RET_KILL_PROCESS),            # 2: any other ABI
        (LD_W_ABS, 0, 0, 0),                        # 3: A = seccomp_data.nr
        (JGE_K, deny - 5, 0, X32_SYSCALL_BIT),      # 4: x32 numbers -> EPERM
    ]
    for i, nr in enumerate(denied):
        insns.append((JEQ_K, deny - (5 + i) - 1, 0, nr))
    insns.append((RET_K, 0, 0, RET_ALLOW))
    insns.append((RET_K, 0, 0, RET_ERRNO | EPERM))
    return b"".join(struct.pack("<HBBI", *insn) for insn in insns)


def seccomp_fd(min_fd=10):
    """A memfd holding program() at a descriptor >= min_fd (clear of the token's fd 3),
    inheritable, for `--seccomp <fd>`. The caller closes it after the spawn."""
    fd = os.memfd_create("zb-seccomp", os.MFD_CLOEXEC)
    try:
        write_all(fd, program())
        os.lseek(fd, 0, os.SEEK_SET)
        high = fcntl.fcntl(fd, fcntl.F_DUPFD, min_fd)
    finally:
        os.close(fd)
    os.set_inheritable(high, True)
    return high
