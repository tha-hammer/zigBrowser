#ifndef ZB_WASM3_RUNTIME_BRIDGE_H
#define ZB_WASM3_RUNTIME_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PgWasmVm PgWasmVm;

PgWasmVm *pg_wasm_vm_open(const char *wasm_path, uint32_t stack_bytes);
void pg_wasm_vm_close(PgWasmVm *vm);
const char *pg_wasm_vm_last_error(PgWasmVm *vm);

int pg_wasm_vm_call_init(PgWasmVm *vm, int32_t *out_rc);
int pg_wasm_vm_call_eval_handle(PgWasmVm *vm, uint64_t token, int32_t *out_rc);
int pg_wasm_vm_call_force_trap(PgWasmVm *vm);

#ifdef __cplusplus
}
#endif

#endif
