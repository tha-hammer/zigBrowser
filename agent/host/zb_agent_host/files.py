"""Atomic file writes: a fresh O_EXCL temp beside the target, fsync, rename, fsync the directory."""

import os
import secrets


def write_all(fd, data, write=None):
    """Writes every byte: a regular-file write may be short."""
    write = write or os.write
    view = memoryview(data)
    while view:
        n = write(fd, view)
        if n <= 0:
            raise OSError(f"write made no progress ({n})")
        view = view[n:]


def atomic_write(path, data, mode=0o600):
    path = str(path)
    directory = os.path.dirname(path) or "."
    tmp = os.path.join(directory, f".{os.path.basename(path)}.{secrets.token_hex(8)}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, mode)
    try:
        write_all(fd, data if isinstance(data, bytes) else data.encode())
        os.fchmod(fd, mode)
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.replace(tmp, path)
    except OSError:
        os.unlink(tmp)
        raise
    dfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
    return path
