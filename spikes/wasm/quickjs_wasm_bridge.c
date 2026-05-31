#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "quickjs.h"

static JSRuntime *g_rt = NULL;
static JSContext *g_ctx = NULL;

__attribute__((export_name("pg_init")))
int pg_init(void) {
    if (g_rt != NULL || g_ctx != NULL) {
        return 0;
    }

    g_rt = JS_NewRuntime();
    if (!g_rt) return -1;

    g_ctx = JS_NewContext(g_rt);
    if (!g_ctx) {
        JS_FreeRuntime(g_rt);
        g_rt = NULL;
        return -2;
    }

    return 0;
}

__attribute__((export_name("pg_eval_handle")))
int pg_eval_handle(uint64_t token) {
    if (!g_ctx) return -11;

    char script[128];
    int n = snprintf(script, sizeof(script), "(%llu);", (unsigned long long)token);
    if (n <= 0 || n >= (int)sizeof(script)) return -12;

    JSValue res = JS_Eval(g_ctx, script, (size_t)n, "<pg-eval>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(res)) {
        JS_FreeValue(g_ctx, res);
        return -13;
    }

    int64_t recovered = 0;
    if (JS_ToInt64Ext(g_ctx, &recovered, res) < 0) {
        JS_FreeValue(g_ctx, res);
        return -14;
    }
    JS_FreeValue(g_ctx, res);

    return (uint64_t)recovered == token ? 0 : -15;
}

__attribute__((export_name("pg_force_trap")))
int pg_force_trap(void) {
#if defined(__wasm__)
    __builtin_trap();
#endif
    return 0;
}

__attribute__((export_name("pg_destroy")))
void pg_destroy(void) {
    if (g_ctx) {
        JS_FreeContext(g_ctx);
        g_ctx = NULL;
    }
    if (g_rt) {
        JS_FreeRuntime(g_rt);
        g_rt = NULL;
    }
}
