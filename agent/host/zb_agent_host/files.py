"""Atomic file writes: a fresh O_EXCL temp beside the target, fsync, rename, fsync the directory. And the removal of a
throwaway tree that may hold write+search-only (0300) directories."""

import errno
import os
import secrets
import stat


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



_DIR_NOFOLLOW = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
_MAX_DEPTH = 64  # a deeper tree is left and reported, never recursed without bound


def chmod_nofollow(dir_fd, name, mode):
    """chmod `name` (a directory) relative to the held `dir_fd`, never through a symlink: macOS's fchmodat with
    AT_SYMLINK_NOFOLLOW, or Linux's O_PATH|O_NOFOLLOW pin of the inode changed through /proc/self/fd. Raises OSError
    when `name` is not a directory now, or when neither way exists (a path chmod would follow a swapped link)."""
    if os.chmod in os.supports_follow_symlinks:
        if not stat.S_ISDIR(os.stat(name, dir_fd=dir_fd, follow_symlinks=False).st_mode):
            raise NotADirectoryError(errno.ENOTDIR, "not a directory")
        os.chmod(name, mode, dir_fd=dir_fd, follow_symlinks=False)
        return
    if not hasattr(os, "O_PATH") or not os.path.isdir("/proc/self/fd"):
        raise OSError(errno.ENOTSUP, "no way to chmod without following a symlink")
    fd = os.open(name, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)
    try:
        if not stat.S_ISDIR(os.fstat(fd).st_mode):
            raise NotADirectoryError(errno.ENOTDIR, "not a directory")
        os.chmod(f"/proc/self/fd/{fd}", mode)  # the pinned inode, not a fresh lookup of `name`
    finally:
        os.close(fd)


def remove_tree(path):
    """Removes one of our own throwaway trees, held by file descriptors from its parent down (RoseCat 7421): every
    directory is opened relative to its held parent with O_DIRECTORY|O_NOFOLLOW, must be this user's (fstat), and
    only if it cannot be opened (token.FifoHandoff's 0300 directory) is it made 0700 with chmod_nofollow first; every
    other entry is unlinked relative to its parent, never opened or followed; a swapped-in symlink is unlinked as a
    link. Returns what is left, as `path` plus fixed stage/errno counts only, never a descendant name or an exception's
    text (a name inside the tree is chosen by the sandboxed run, which holds a token). Empty when all is gone."""
    path = str(path)
    counts = {}

    def fail(stage, exc=None):
        key = f"{stage}: {errno.errorcode.get(getattr(exc, 'errno', None), 'error') if exc is not None else 'refused'}"
        counts[key] = counts.get(key, 0) + 1

    def open_dir(dir_fd, name):
        try:
            return os.open(name, _DIR_NOFOLLOW, dir_fd=dir_fd)
        except PermissionError:
            chmod_nofollow(dir_fd, name, 0o700)
            return os.open(name, _DIR_NOFOLLOW, dir_fd=dir_fd)

    def remove(dir_fd, name, depth):
        try:
            st = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        except OSError as exc:
            fail("stat", exc)
            return
        if not stat.S_ISDIR(st.st_mode):
            try:
                os.unlink(name, dir_fd=dir_fd)
            except FileNotFoundError:
                pass
            except OSError as exc:
                fail("unlink", exc)
            return
        if depth > _MAX_DEPTH:
            fail("too deep")
            return
        try:
            fd = open_dir(dir_fd, name)
        except (NotADirectoryError, FileNotFoundError):
            return remove(dir_fd, name, depth)  # swapped for a non-directory meanwhile: unlinked as such
        except OSError as exc:
            if exc.errno == errno.ELOOP:  # swapped for a symlink: removed as a link, never followed
                return remove(dir_fd, name, depth)
            fail("open", exc)
            return
        try:
            st = os.fstat(fd)
            if st.st_uid != os.geteuid():
                fail("not this user's")
                return
            if stat.S_IMODE(st.st_mode) & 0o700 != 0o700:
                os.fchmod(fd, 0o700)
            for entry in list(os.scandir(fd)):
                remove(fd, entry.name, depth + 1)
        except OSError as exc:
            fail("list", exc)
            return
        finally:
            os.close(fd)
        try:
            os.rmdir(name, dir_fd=dir_fd)
        except FileNotFoundError:
            pass
        except OSError as exc:
            fail("rmdir", exc)

    parent, name = os.path.split(path.rstrip("/"))
    try:
        parent_fd = os.open(parent or ".", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    except OSError as exc:
        fail("open the parent", exc)
    else:
        try:
            remove(parent_fd, name, 0)
        finally:
            os.close(parent_fd)
    return [f"{path}: {key} x{n}" for key, n in sorted(counts.items())]
