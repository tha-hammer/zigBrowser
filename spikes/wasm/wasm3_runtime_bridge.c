#include "wasm3_runtime_bridge.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wasm3.h"
#include "m3_api_wasi.h"
#include "m3_api_libc.h"

struct PgWasmVm {
    IM3Environment env;
    IM3Runtime runtime;
    IM3Module module;
    IM3Function fn_init;
    IM3Function fn_eval;
    IM3Function fn_trap;
    uint8_t *wasm_bytes;
    uint32_t wasm_len;
    char last_error[256];
};

static void set_error(PgWasmVm *vm, const char *prefix, const char *detail) {
    if (!vm) return;
    snprintf(vm->last_error, sizeof(vm->last_error), "%s: %s", prefix, detail ? detail : "(none)");
}

static uint8_t *read_file_alloc(const char *path, uint32_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return NULL;
    }
    long sz = ftell(f);
    if (sz <= 0) {
        fclose(f);
        return NULL;
    }
    if (fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        return NULL;
    }

    uint8_t *buf = (uint8_t *)malloc((size_t)sz);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        fclose(f);
        free(buf);
        return NULL;
    }
    fclose(f);

    *out_len = (uint32_t)sz;
    return buf;
}

PgWasmVm *pg_wasm_vm_open(const char *wasm_path, uint32_t stack_bytes) {
    PgWasmVm *vm = (PgWasmVm *)calloc(1, sizeof(*vm));
    if (!vm) return NULL;

    vm->wasm_bytes = read_file_alloc(wasm_path, &vm->wasm_len);
    if (!vm->wasm_bytes) {
        set_error(vm, "read", "failed to read wasm file");
        return vm;
    }

    vm->env = m3_NewEnvironment();
    if (!vm->env) {
        set_error(vm, "env", "m3_NewEnvironment failed");
        return vm;
    }

    vm->runtime = m3_NewRuntime(vm->env, stack_bytes, NULL);
    if (!vm->runtime) {
        set_error(vm, "runtime", "m3_NewRuntime failed");
        return vm;
    }

    M3Result result = m3_ParseModule(vm->env, &vm->module, vm->wasm_bytes, vm->wasm_len);
    if (result) {
        set_error(vm, "parse", result);
        return vm;
    }

    result = m3_LoadModule(vm->runtime, vm->module);
    if (result) {
        set_error(vm, "load", result);
        return vm;
    }

    result = m3_LinkWASI(vm->module);
    if (result && result != m3Err_functionLookupFailed) {
        set_error(vm, "link_wasi", result);
        return vm;
    }

    result = m3_LinkLibC(vm->module);
    if (result && result != m3Err_functionLookupFailed) {
        set_error(vm, "link_libc", result);
        return vm;
    }

    result = m3_FindFunction(&vm->fn_init, vm->runtime, "pg_init");
    if (result) {
        set_error(vm, "find_pg_init", result);
        return vm;
    }

    result = m3_FindFunction(&vm->fn_eval, vm->runtime, "pg_eval_handle");
    if (result) {
        set_error(vm, "find_pg_eval_handle", result);
        return vm;
    }

    result = m3_FindFunction(&vm->fn_trap, vm->runtime, "pg_force_trap");
    if (result) {
        set_error(vm, "find_pg_force_trap", result);
        return vm;
    }

    vm->last_error[0] = '\0';
    return vm;
}

void pg_wasm_vm_close(PgWasmVm *vm) {
    if (!vm) return;
    if (vm->runtime) {
        m3_FreeRuntime(vm->runtime);
        vm->runtime = NULL;
    }
    if (vm->env) {
        m3_FreeEnvironment(vm->env);
        vm->env = NULL;
    }
    if (vm->wasm_bytes) {
        free(vm->wasm_bytes);
        vm->wasm_bytes = NULL;
    }
    free(vm);
}

const char *pg_wasm_vm_last_error(PgWasmVm *vm) {
    if (!vm) return "no-vm";
    return vm->last_error;
}

static int call_and_read_i32(PgWasmVm *vm, IM3Function fn, uint32_t argc, const void *argv[], int32_t *out_rc, const char *phase) {
    if (!vm || !fn || !out_rc) return 1;

    M3Result result = m3_Call(fn, argc, argv);
    if (result) {
        set_error(vm, phase, result);
        return 1;
    }

    const void *rets[1] = { out_rc };
    result = m3_GetResults(fn, 1, rets);
    if (result) {
        set_error(vm, phase, result);
        return 1;
    }

    vm->last_error[0] = '\0';
    return 0;
}

int pg_wasm_vm_call_init(PgWasmVm *vm, int32_t *out_rc) {
    return call_and_read_i32(vm, vm->fn_init, 0, NULL, out_rc, "call_pg_init");
}

int pg_wasm_vm_call_eval_handle(PgWasmVm *vm, uint64_t token, int32_t *out_rc) {
    int64_t token_signed = (int64_t)token;
    const void *args[1] = { &token_signed };
    return call_and_read_i32(vm, vm->fn_eval, 1, args, out_rc, "call_pg_eval_handle");
}

int pg_wasm_vm_call_force_trap(PgWasmVm *vm) {
    if (!vm || !vm->fn_trap) return 1;

    M3Result result = m3_Call(vm->fn_trap, 0, NULL);
    if (result) {
        set_error(vm, "call_pg_force_trap", result);
        return 1;
    }

    vm->last_error[0] = '\0';
    return 0;
}
