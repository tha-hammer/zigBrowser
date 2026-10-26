/* MS6.1 token-isolation probe (RoseCat; plan §MS6.1).
 *
 * A stand-in for a MALICIOUS HOOK: given a target pid and a canary string, it attempts every process-
 * introspection path a hook could use to steal the CLI's token, and reports whether the canary leaked.
 *
 *   1. kern.procargs2  — the DETERMINISTIC sacrificial target. A same-user process normally reads another's
 *      argv+env this way (ps does), so a canary placed in the target's argv IS exposed here when the
 *      Seatbelt deny is absent. This is the mutant anchor: removing the deny leaks the canary (not a TCC
 *      artifact that would stay denied regardless).
 *   2. task_for_pid    — acquiring the target's task port (would allow vm_read of its memory).
 *   3. proc_pidpath    — the target's executable path (a lesser info leak).
 *   4. Security.framework — direct access to a disposable Keychain item. The
 *      trusted test parent creates the item without putting its value in argv
 *      or env; a sandboxed CLI/hook must not be able to read it.
 *
 * Exit code: 0 = BREACH (the canary leaked via procargs2, OR the task port was acquired); 1 = contained
 * (every path denied / no canary). Human-readable lines go to stdout for the harness to log.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <Security/Security.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static const char keychain_value[] = "zb-ms61-keychain-value-not-an-argv";

static int seed_keychain(const char *path, const char *password, const char *service, const char *account) {
    SecKeychainRef keychain = NULL;
    OSStatus status = SecKeychainCreate(path, (UInt32)strlen(password), password, false, NULL, &keychain);
    if (status == errSecDuplicateKeychain) {
        status = SecKeychainOpen(path, &keychain);
        if (status == errSecSuccess) {
            status = SecKeychainUnlock(keychain, (UInt32)strlen(password), password, true);
        }
    }
    if (status == errSecSuccess) {
        status = SecKeychainAddGenericPassword(keychain, (UInt32)strlen(service), service,
                                               (UInt32)strlen(account), account,
                                               (UInt32)(sizeof keychain_value - 1), keychain_value, NULL);
    }
    if (keychain != NULL) CFRelease(keychain);
    if (status != errSecSuccess) {
        printf("KEYCHAIN-SEED-FAILED status=%d\n", (int)status);
        return 1;
    }
    printf("KEYCHAIN-SEED-OK\n");
    return 0;
}

static int keychain_readable(const char *path, const char *password, const char *service, const char *account) {
    SecKeychainRef keychain = NULL;
    OSStatus status = SecKeychainOpen(path, &keychain);
    if (status == errSecSuccess) {
        status = SecKeychainUnlock(keychain, (UInt32)strlen(password), password, true);
    }
    UInt32 length = 0;
    void *data = NULL;
    if (status == errSecSuccess) {
        status = SecKeychainFindGenericPassword(keychain, (UInt32)strlen(service), service,
                                                (UInt32)strlen(account), account,
                                                &length, &data, NULL);
    }
    int readable = status == errSecSuccess && length == sizeof keychain_value - 1 &&
                   data != NULL && memcmp(data, keychain_value, length) == 0;
    if (data != NULL) SecKeychainItemFreeContent(NULL, data);
    if (keychain != NULL) CFRelease(keychain);
    if (readable) {
        printf("keychain: READABLE\n");
        return 1;
    }
    printf("keychain: denied status=%d\n", (int)status);
    return 0;
}

static int procargs2_leaks_canary(pid_t target, const char *canary) {
    int argmax = 0;
    size_t am_sz = sizeof(argmax);
    int am_mib[2] = { CTL_KERN, KERN_ARGMAX };
    if (sysctl(am_mib, 2, &argmax, &am_sz, NULL, 0) != 0 || argmax <= 0) argmax = 262144;
    char *buf = malloc((size_t)argmax);
    if (buf == NULL) { printf("procargs2: malloc failed\n"); return 0; }
    size_t size = (size_t)argmax;
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, target };
    int rc = sysctl(mib, 3, buf, &size, NULL, 0);
    int found = 0;
    if (rc == 0) {
        size_t clen = strlen(canary);
        for (size_t i = 0; clen > 0 && i + clen <= size; i++) {
            if (memcmp(buf + i, canary, clen) == 0) { found = 1; break; }
        }
        printf("procargs2: rc=0 canary=%s\n", found ? "FOUND" : "absent");
    } else {
        printf("procargs2: rc=%d errno=%d(%s)\n", rc, errno, strerror(errno));
    }
    free(buf);
    return found;
}

static int task_port_acquired(pid_t target) {
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), target, &task);
    if (kr == KERN_SUCCESS) {
        printf("task_for_pid: ACQUIRED (kr=0)\n");
        if (task != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), task);
        return 1;
    }
    printf("task_for_pid: denied kr=%d (%s)\n", kr, mach_error_string(kr));
    return 0;
}

static int proc_pidpath_leaks(pid_t target) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int n = proc_pidpath(target, path, sizeof(path));
    if (n > 0) { printf("proc_pidpath: leaked '%s'\n", path); return 1; }
    printf("proc_pidpath: denied errno=%d(%s)\n", errno, strerror(errno));
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 6 && strcmp(argv[1], "--seed-keychain") == 0) {
        return seed_keychain(argv[2], argv[3], argv[4], argv[5]);
    }
    if (argc != 7) {
        fprintf(stderr, "usage: %s <pid> <canary> <keychain> <password> <service> <account>\n", argv[0]);
        return 2;
    }
    pid_t target = (pid_t)atoi(argv[1]);
    const char *canary = argv[2];
    int breach = 0;
    if (procargs2_leaks_canary(target, canary)) breach = 1;  /* the token canary — the primary anchor */
    if (task_port_acquired(target)) breach = 1;
    if (proc_pidpath_leaks(target)) breach = 1;               /* any process-info leak is a breach too */
    if (keychain_readable(argv[3], argv[4], argv[5], argv[6])) breach = 1;
    printf("RESULT: %s\n", breach ? "BREACH" : "CONTAINED");
    return breach ? 0 : 1;
}

#pragma clang diagnostic pop
