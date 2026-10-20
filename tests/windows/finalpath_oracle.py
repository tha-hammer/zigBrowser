"""VM-side oracle for the Windows PathResolver (bead zigBrowser-d1d, part 1).

Opens each path with CreateFileW — following reparse points (it does NOT pass FILE_FLAG_OPEN_REPARSE_POINT,
so a junction/symlink resolves to its target, never the link) — and returns GetFinalPathNameByHandleW's raw
output. A junction that cannot be followed makes CreateFileW fail, which the caller treats as a denial. This
is the independent Win32 oracle the Linux test checks `wincontain.normalize_final_path` /
`wincontain.resolved_within` against, so the pure logic is validated against the REAL API rather than a
re-implementation of its documented behaviour.

Pure ctypes + stdlib; runs with the VM's system `python`. Usage:
    python finalpath_oracle.py <paths.json>     # {"paths": ["C:\\...", ...]}
prints {"results": [{"path", "final", "error"}, ...]} on stdout.
"""
import ctypes
import ctypes.wintypes as w
import json
import sys

# 0 access = query metadata only (enough for GetFinalPathNameByHandle), widest sharing so an open handle on
# the target never blocks a concurrent swap we are trying to observe in the TOCTOU reds.
_QUERY_ACCESS = 0
_SHARE_ALL = 0x1 | 0x2 | 0x4            # READ | WRITE | DELETE
_OPEN_EXISTING = 3
_FILE_FLAG_BACKUP_SEMANTICS = 0x02000000  # required to obtain a directory handle
_FILE_NAME_NORMALIZED = 0x0
_VOLUME_NAME_DOS = 0x0
_INVALID_HANDLE = ctypes.c_void_p(-1).value

_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_CreateFileW = _k32.CreateFileW
_CreateFileW.restype = w.HANDLE
_CreateFileW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, ctypes.c_void_p, w.DWORD, w.DWORD, w.HANDLE]
_GetFinal = _k32.GetFinalPathNameByHandleW
_GetFinal.restype = w.DWORD
_GetFinal.argtypes = [w.HANDLE, w.LPWSTR, w.DWORD, w.DWORD]
_CloseHandle = _k32.CloseHandle
_CloseHandle.argtypes = [w.HANDLE]
_CloseHandle.restype = w.BOOL


def resolve_one(path):
    h = _CreateFileW(path, _QUERY_ACCESS, _SHARE_ALL, None, _OPEN_EXISTING, _FILE_FLAG_BACKUP_SEMANTICS, None)
    hv = ctypes.cast(h, ctypes.c_void_p).value
    if hv is None or hv == _INVALID_HANDLE:
        return {"path": path, "final": None, "error": f"CreateFileW failed (GetLastError={ctypes.get_last_error()})"}
    try:
        buf = ctypes.create_unicode_buffer(32768)
        n = _GetFinal(h, buf, len(buf), _FILE_NAME_NORMALIZED | _VOLUME_NAME_DOS)
        if n == 0:
            return {"path": path, "final": None, "error": f"GetFinalPathNameByHandleW failed (GetLastError={ctypes.get_last_error()})"}
        if n >= len(buf):
            return {"path": path, "final": None, "error": f"final path too long ({n} chars)"}
        return {"path": path, "final": buf.value, "error": None}
    finally:
        _CloseHandle(h)


def main():
    with open(sys.argv[1], encoding="utf-8") as fh:
        paths = json.load(fh)["paths"]
    print(json.dumps({"results": [resolve_one(p) for p in paths]}))


if __name__ == "__main__":
    main()
