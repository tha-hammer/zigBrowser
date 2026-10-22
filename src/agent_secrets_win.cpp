// WS6.1: the Windows Claude Agent token store (skeleton). Credential Manager (CRED_TYPE_GENERIC, target
// zigBrowser/ClaudeAgentToken/default, CRED_PERSIST_LOCAL_MACHINE) for the default store, and a DPAPI-wrapped
// owner-only file for the "Save to a private file instead" path (CryptProtectData, CRYPTPROTECT_UI_FORBIDDEN).
//
// The token SHAPE is NOT checked here: the one rule lives in the portable Zig (agent_secrets_shape.validToken)
// and the Zig TokenStore.save enforces it before calling in, so this backend never duplicates it. Nothing here
// prints the token. Cross-compiled only (the Win32 runtime needs a real session); source-bound offline.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <wincred.h>
#include <dpapi.h>
#include <sddl.h>

#include <stdio.h>
#include <string.h>

extern "C" {

// The production Credential Manager target for the agent token (mirrors agent_secrets_store.zig prod_target).
static const wchar_t *kDefaultTarget = L"zigBrowser/ClaudeAgentToken/default";

// Save `token` (len bytes) under `target` (or the default). CRED_TYPE_GENERIC + CRED_PERSIST_LOCAL_MACHINE;
// a 512-char token fits the 2560-byte CredentialBlob. Returns 0 on success, else GetLastError().
unsigned long zb_secret_cred_save(const wchar_t *target, const unsigned char *token, unsigned long len) {
  CREDENTIALW cred;
  ZeroMemory(&cred, sizeof(cred));
  cred.Type = CRED_TYPE_GENERIC;
  cred.TargetName = const_cast<LPWSTR>(target != nullptr ? target : kDefaultTarget);
  cred.CredentialBlobSize = len;
  cred.CredentialBlob = const_cast<LPBYTE>(token);
  cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
  if (!CredWriteW(&cred, 0)) return GetLastError();
  return 0;
}

// Read the token under `target` into `buf` (capacity `cap`); *out_len gets the byte count. Returns 0, or
// GetLastError() (ERROR_NOT_FOUND when absent, ERROR_INSUFFICIENT_BUFFER when it does not fit).
unsigned long zb_secret_cred_read(const wchar_t *target, unsigned char *buf, unsigned long cap,
                                  unsigned long *out_len) {
  PCREDENTIALW cred = nullptr;
  if (!CredReadW(target != nullptr ? target : kDefaultTarget, CRED_TYPE_GENERIC, 0, &cred)) {
    return GetLastError();
  }
  unsigned long n = cred->CredentialBlobSize;
  unsigned long rc = 0;
  if (n > cap) {
    rc = ERROR_INSUFFICIENT_BUFFER;
  } else {
    if (n > 0) memcpy(buf, cred->CredentialBlob, n);
    if (out_len != nullptr) *out_len = n;
  }
  CredFree(cred);
  return rc;
}

// Remove the token under `target`. Returns 0, or GetLastError() (ERROR_NOT_FOUND when already absent).
unsigned long zb_secret_cred_delete(const wchar_t *target) {
  if (!CredDeleteW(target != nullptr ? target : kDefaultTarget, CRED_TYPE_GENERIC, 0)) return GetLastError();
  return 0;
}

// DPAPI-wrap `in` (in_len bytes) into `out` (capacity cap); *out_len gets the wrapped length. The current
// user is the only principal that can unwrap it. CRYPTPROTECT_UI_FORBIDDEN: never prompt (headless/service).
// Returns 0, or GetLastError() / ERROR_INSUFFICIENT_BUFFER.
unsigned long zb_secret_dpapi_protect(const unsigned char *in, unsigned long in_len, unsigned char *out,
                                      unsigned long cap, unsigned long *out_len) {
  DATA_BLOB plain;
  plain.pbData = const_cast<BYTE *>(in);
  plain.cbData = in_len;
  DATA_BLOB wrapped;
  ZeroMemory(&wrapped, sizeof(wrapped));
  if (!CryptProtectData(&plain, L"zigBrowser agent token", nullptr, nullptr, nullptr,
                        CRYPTPROTECT_UI_FORBIDDEN, &wrapped)) {
    return GetLastError();
  }
  unsigned long rc = 0;
  if (wrapped.cbData > cap) {
    rc = ERROR_INSUFFICIENT_BUFFER;
  } else {
    if (wrapped.cbData > 0) memcpy(out, wrapped.pbData, wrapped.cbData);
    if (out_len != nullptr) *out_len = wrapped.cbData;
  }
  if (wrapped.pbData != nullptr) LocalFree(wrapped.pbData);
  return rc;
}

// Build an OWNER-ONLY, protected DACL (SDDL "D:P(A;;FA;;;OW)" — only the object owner has access, no
// inherited ACEs) for the private token file, returned as a SECURITY_ATTRIBUTES whose descriptor the caller
// frees with LocalFree. Returns 0 on success, else GetLastError().
unsigned long zb_secret_owner_only_sa(SECURITY_ATTRIBUTES *sa) {
  if (sa == nullptr) return ERROR_INVALID_PARAMETER;
  PSECURITY_DESCRIPTOR sd = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;;FA;;;OW)", SDDL_REVISION_1, &sd, nullptr)) {
    return GetLastError();
  }
  sa->nLength = sizeof(SECURITY_ATTRIBUTES);
  sa->lpSecurityDescriptor = sd;  // caller LocalFree()s this
  sa->bInheritHandle = FALSE;
  return 0;
}

}  // extern "C"
