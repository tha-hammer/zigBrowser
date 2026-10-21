"""Atomic file writes: a fresh O_EXCL temp beside the target, fsync, rename, fsync the directory. And the removal of a
throwaway tree that may hold write+search-only (0300) directories."""

import os
import secrets
import shutil


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


def remove_tree(path):
    """Removes one of our own throwaway trees and returns what could not be removed (empty when it is all gone). A
    0300 directory (token.FifoHandoff's) cannot be listed even by its owner, so every directory is first opened to
    0700, top-down, never through a symlink and only when this user owns it (anything else is left closed and
    reported); special entries are unlinked, never opened; nothing is ignored silently (16bad65 left such trees on
    both Macs)."""
    path = str(path)
    problems = []
    if not os.path.lexists(path):
        return problems
    def open_dir(d):
        try:
            if os.lstat(d).st_uid != os.geteuid():
                problems.append(f"{d}: not this user's, left as it is")
                return
            os.chmod(d, 0o700)
        except OSError as exc:
            problems.append(f"{d}: {exc.strerror or exc}")

    if os.path.isdir(path) and not os.path.islink(path):
        open_dir(path)
        def unwalkable(exc):
            problems.append(f"{exc.filename}: {exc.strerror}")

        for dirpath, dirnames, _files in os.walk(path, onerror=unwalkable):
            for d in dirnames:
                sub = os.path.join(dirpath, d)
                if os.path.islink(sub):
                    continue  # removed as a link, never followed
                open_dir(sub)

    def failed(_func, failed_path, exc):
        problems.append(f"{failed_path}: {getattr(exc, 'strerror', None) or exc}")

    shutil.rmtree(path, onexc=failed)
    if os.path.lexists(path) and not problems:
        problems.append(f"{path}: still present")
    return problems
