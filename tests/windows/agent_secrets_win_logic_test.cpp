// WS6.1 (c) RED — UNREGISTERED. Compile+run on the host:
//   zig c++ -I src tests/windows/agent_secrets_win_logic_test.cpp -o /tmp/zbwinlogic && /tmp/zbwinlogic
//
// Drives the Windows token-store ORCHESTRATION (agent_secrets_win_logic.h) through a FAKE Win32-call table
// that records every call, so save/read/remove and the DPAPI file fallback are exercised on the host — not a
// substring grep (RoseCat). Asserts the production choices and flips each with a mutant: wrong target, wrong
// CRED type, wrong persistence, plaintext fallback, UI-enabled DPAPI, non-owner DACL, and a missing delete.
//
// Red now: src/agent_secrets_win_logic.h does not exist, so this does not compile. Green adds the header and
// refactors agent_secrets_win.cpp to drive it with the real Win32 backend.
#include "agent_secrets_win_logic.h"

#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cwchar>

namespace {

struct Recorder {
  // last cred_write
  wchar_t w_target[128] = {};
  int w_type = -1, w_persist = -1;
  unsigned char w_blob[512] = {};
  unsigned long w_len = 0;
  // last dpapi_protect
  int p_ui_forbidden = -1;
  // last file_write
  wchar_t f_path[260] = {};
  int f_owner_only = -1;
  unsigned char f_bytes[512] = {};
  unsigned long f_len = 0;
  int deletes = 0;
};

// A toy reversible "DPAPI": XOR 0x5A, so wrapped != plaintext yet unprotect(protect(x)) == x.
unsigned long fake_protect(void* ctx, int ui_forbidden, const unsigned char* in, unsigned long in_len,
                           unsigned char* out, unsigned long cap, unsigned long* out_len) {
  auto* r = static_cast<Recorder*>(ctx);
  r->p_ui_forbidden = ui_forbidden;
  if (in_len > cap) return 1;
  for (unsigned long i = 0; i < in_len; i++) out[i] = in[i] ^ 0x5A;
  *out_len = in_len;
  return 0;
}
unsigned long fake_unprotect(void*, const unsigned char* in, unsigned long in_len,
                             unsigned char* out, unsigned long cap, unsigned long* out_len) {
  if (in_len > cap) return 1;
  for (unsigned long i = 0; i < in_len; i++) out[i] = in[i] ^ 0x5A;
  *out_len = in_len;
  return 0;
}
unsigned long fake_cred_write(void* ctx, const wchar_t* target, int type, int persist,
                              const unsigned char* blob, unsigned long len) {
  auto* r = static_cast<Recorder*>(ctx);
  wcsncpy(r->w_target, target, 127);
  r->w_type = type;
  r->w_persist = persist;
  r->w_len = len;
  if (len <= sizeof r->w_blob) memcpy(r->w_blob, blob, len);
  return 0;
}
unsigned long fake_cred_read(void*, const wchar_t*, int, unsigned char*, unsigned long, unsigned long*) { return 0; }
unsigned long fake_cred_delete(void* ctx, const wchar_t*, int) { static_cast<Recorder*>(ctx)->deletes++; return 0; }
unsigned long fake_file_write(void* ctx, const wchar_t* path, int owner_only, const unsigned char* data, unsigned long len) {
  auto* r = static_cast<Recorder*>(ctx);
  wcsncpy(r->f_path, path, 259);
  r->f_owner_only = owner_only;
  r->f_len = len;
  if (len <= sizeof r->f_bytes) memcpy(r->f_bytes, data, len);
  return 0;
}
unsigned long fake_file_read(void* ctx, const wchar_t*, unsigned char* buf, unsigned long cap, unsigned long* out) {
  auto* r = static_cast<Recorder*>(ctx);
  if (r->f_len > cap) return 1;
  memcpy(buf, r->f_bytes, r->f_len);
  *out = r->f_len;
  return 0;
}

WinCredBackend make_backend(Recorder* r) {
  WinCredBackend b{};
  b.cred_write = fake_cred_write;
  b.cred_read = fake_cred_read;
  b.cred_delete = fake_cred_delete;
  b.dpapi_protect = fake_protect;
  b.dpapi_unprotect = fake_unprotect;
  b.file_write = fake_file_write;
  b.file_read = fake_file_read;
  b.ctx = r;
  return b;
}

int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { std::printf("FAIL: %s\n", msg); failures++; } } while (0)

}  // namespace

int main() {
  const wchar_t* target = L"zigBrowser-test-deadbeef";
  const unsigned char token[] = "sk-ant-oat01-ZBCANARY-0123456789abcdef";
  const unsigned long tlen = (unsigned long)sizeof(token) - 1;

  // save -> CredWriteW with CRED_TYPE_GENERIC, CRED_PERSIST_LOCAL_MACHINE, the right target and the token bytes.
  Recorder r;
  WinCredBackend b = make_backend(&r);
  CHECK(store_save(&b, target, token, tlen) == 0, "store_save rc");
  CHECK(wcscmp(r.w_target, target) == 0, "save target");
  CHECK(r.w_type == kCredTypeGeneric, "save type is CRED_TYPE_GENERIC");
  CHECK(r.w_persist == kCredPersistLocalMachine, "save persist is CRED_PERSIST_LOCAL_MACHINE");
  CHECK(r.w_len == tlen && memcmp(r.w_blob, token, tlen) == 0, "save blob is the token");

  // remove -> CredDeleteW once.
  CHECK(store_remove(&b, target) == 0 && r.deletes == 1, "remove deletes once");

  // file fallback -> DPAPI-wrap with UI forbidden, write owner-only, and the file bytes are NOT plaintext.
  Recorder rf;
  WinCredBackend bf = make_backend(&rf);
  CHECK(store_save_file(&bf, L"C:/u/secrets/claude-token", token, tlen) == 0, "store_save_file rc");
  CHECK(rf.p_ui_forbidden == 1, "DPAPI must be UI-forbidden");
  CHECK(rf.f_owner_only == 1, "file DACL must be owner-only");
  CHECK(!(rf.f_len == tlen && memcmp(rf.f_bytes, token, tlen) == 0), "file bytes must NOT be plaintext");
  // read_file -> file_read then dpapi_unprotect round-trips to the token.
  unsigned char got[512]; unsigned long glen = 0;
  CHECK(store_read_file(&bf, L"C:/u/secrets/claude-token", got, sizeof got, &glen) == 0, "store_read_file rc");
  CHECK(glen == tlen && memcmp(got, token, tlen) == 0, "read_file round-trips to the token");

  if (failures == 0) std::printf("OK\n");
  return failures == 0 ? 0 : 1;
}
