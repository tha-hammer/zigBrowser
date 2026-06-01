# E2E Protocol (Normative)

The `--e2e-protocol` stream is line-delimited, UTF-8 text on stdout.

Rules:
- One event per line.
- Fields are tab-separated (`\t`).
- Prefix is the first field.
- Field payloads MUST be sanitized by the producer (tabs/newlines removed or escaped).
- Writers MUST flush each emitted line.

## Line Schemas

`NAV`:
- `NAV\t<uri>\t<title>`
- Example: `NAV\tfile:///app/index.html\tHome`

`IPC`:
- `IPC\t<cmd>\t<result_json>`
- Example: `IPC\techo\t"hi-42"`

`IPCERR`:
- `IPCERR\t<cmd>\t<error_name>`
- Example: `IPCERR\techo\tBadArgs`

`BLOCKED`:
- `BLOCKED\t<candidate_uri>`
- Example: `BLOCKED\tfile:///etc/passwd`

`LOAD_FAIL`:
- `LOAD_FAIL\t<uri>\t<domain>\t<code>`
- Example: `LOAD_FAIL\tfile:///x\t1\t-2`

`SUBWIN`:
- `SUBWIN\t<uri>`
- Example: `SUBWIN\thttps://example.org/`

`WINCOUNT`:
- `WINCOUNT\t<n>`
- Example: `WINCOUNT\t2`
