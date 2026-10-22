//! WS6.1: a tiny Zig root that pulls src/agent_secrets_win.cpp into a Windows object, so the
//! `cross-check-secrets-win` gate proves the Credential Manager / DPAPI token store compiles for
//! x86_64-windows and exports its zb_secret_* C-ABI functions. No logic here; the C source is added via
//! addCSourceFile in build.zig.
comptime {}
