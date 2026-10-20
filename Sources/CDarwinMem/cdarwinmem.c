#include "cdarwinmem.h"

#include <bsm/libbsm.h>
#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <signal.h>
#include <sys/sysctl.h>

/* ---- private flavors, declared locally and size-checked against the xnu layouts ---------- */

#define DM_PROC_PIDUNIQIDENTIFIERINFO 17
#define DM_PROC_PIDCOALITIONINFO      20

struct dm_uniqidentifierinfo {
    uint8_t p_uuid[16];
    uint64_t p_uniqueid;
    uint64_t p_puniqueid;
    int32_t p_idversion;
    int32_t p_orig_ppidversion;
    uint64_t p_reserve2, p_reserve3;
};
struct dm_pidcoalitioninfo { uint64_t coalition_id[2]; uint64_t reserved1, reserved2, reserved3; };

_Static_assert(sizeof(struct dm_uniqidentifierinfo) == 56, "PROC_PIDUNIQIDENTIFIERINFO layout");
_Static_assert(sizeof(struct dm_pidcoalitioninfo) == 40, "PROC_PIDCOALITIONINFO layout");

/* ---- system ------------------------------------------------------------------------------ */

static mach_port_t dm_host(void) {
    static mach_port_t host = MACH_PORT_NULL;
    if (host == MACH_PORT_NULL) host = mach_host_self();   /* one send right, kept for life */
    return host;
}

int dm_vm_read(dm_vm_stats *out) {
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t kr = host_statistics64(dm_host(), HOST_VM_INFO64, (host_info64_t)&vm, &count);
    if (kr != KERN_SUCCESS) return (int)kr;
    memset(out, 0, sizeof *out);
    out->page_size = (uint64_t)vm_kernel_page_size;
    out->free_count = vm.free_count;
    out->active_count = vm.active_count;
    out->inactive_count = vm.inactive_count;
    out->speculative_count = vm.speculative_count;
    out->throttled_count = vm.throttled_count;
    out->wire_count = vm.wire_count;
    out->purgeable_count = vm.purgeable_count;
    out->external_page_count = vm.external_page_count;
    out->internal_page_count = vm.internal_page_count;
    out->compressor_page_count = vm.compressor_page_count;
    out->total_uncompressed_pages_in_compressor = vm.total_uncompressed_pages_in_compressor;
    out->swapins = vm.swapins;
    out->swapouts = vm.swapouts;
    out->pageins = vm.pageins;
    out->pageouts = vm.pageouts;
    out->compressions = vm.compressions;
    out->decompressions = vm.decompressions;
    out->faults = vm.faults;
    out->purges = vm.purges;
    out->zero_fill_count = vm.zero_fill_count;
    out->reactivations = vm.reactivations;
    return 0;
}

int dm_swap_read(dm_swap_usage *out) {
    struct xsw_usage xsw;
    size_t len = sizeof xsw;
    if (sysctlbyname("vm.swapusage", &xsw, &len, NULL, 0) != 0) return errno;
    out->total = xsw.xsu_total;
    out->avail = xsw.xsu_avail;
    out->used = xsw.xsu_used;
    out->pagesize = xsw.xsu_pagesize;
    out->encrypted = xsw.xsu_encrypted ? 1 : 0;
    return 0;
}

int dm_sysctl_u64(const char *name, uint64_t *out) {
    union { uint64_t u64; uint32_t u32; uint8_t raw[8]; } v;
    memset(&v, 0, sizeof v);
    size_t len = sizeof v;
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return errno;
    if (len == 8) *out = v.u64;
    else if (len == 4) *out = v.u32;
    else return EINVAL;
    return 0;
}

int dm_sysctl_i64(const char *name, int64_t *out) {
    union { int64_t i64; int32_t i32; uint8_t raw[8]; } v;
    memset(&v, 0, sizeof v);
    size_t len = sizeof v;
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return errno;
    if (len == 8) *out = v.i64;
    else if (len == 4) *out = v.i32;
    else return EINVAL;
    return 0;
}

int dm_sysctl_string(const char *name, char *buf, size_t buflen) {
    if (buflen == 0) return EINVAL;
    size_t len = buflen - 1;
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0) return errno;
    buf[len < buflen ? len : buflen - 1] = '\0';
    return 0;
}

int dm_sysctl_write_i32(const char *name, int32_t value) {
    if (sysctlbyname(name, NULL, NULL, &value, sizeof value) != 0) return errno;
    return 0;
}

/* ---- processes --------------------------------------------------------------------------- */

int dm_list_pids(pid_t *pids, int capacity) {
    if (pids == NULL || capacity <= 0) return proc_listallpids(NULL, 0);
    return proc_listallpids(pids, capacity * (int)sizeof(pid_t));
}

static uint64_t dm_abs_to_ns(uint64_t abs) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    if (tb.numer == tb.denom) return abs;
    return (uint64_t)(((__uint128_t)abs * tb.numer) / tb.denom);
}

int dm_proc_rusage(pid_t pid, dm_rusage *out) {
    struct rusage_info_v6 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) return errno ? errno : EINVAL;
    memset(out, 0, sizeof *out);
    out->phys_footprint = ri.ri_phys_footprint;
    out->lifetime_max_phys_footprint = ri.ri_lifetime_max_phys_footprint;
    out->resident_size = ri.ri_resident_size;
    out->user_time_ns = dm_abs_to_ns(ri.ri_user_time);
    out->system_time_ns = dm_abs_to_ns(ri.ri_system_time);
    out->pageins = ri.ri_pageins;
    out->interrupt_wkups = ri.ri_interrupt_wkups;
    out->pkg_idle_wkups = ri.ri_pkg_idle_wkups;
    return 0;
}

int dm_proc_bsdinfo(pid_t pid, dm_bsdinfo *out) {
    memset(out, 0, sizeof *out);
    struct proc_bsdinfo bi;
    int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi);
    if (n == (int)sizeof bi) {
        out->pid = (pid_t)bi.pbi_pid;
        out->ppid = (pid_t)bi.pbi_ppid;
        out->pgid = (pid_t)bi.pbi_pgid;
        out->uid = bi.pbi_uid;
        out->ruid = bi.pbi_ruid;
        out->status = bi.pbi_status;
        out->flags = bi.pbi_flags;
        out->start_sec = bi.pbi_start_tvsec;
        out->start_usec = bi.pbi_start_tvusec;
        memcpy(out->comm, bi.pbi_comm, sizeof out->comm - 1);
        memcpy(out->name, bi.pbi_name, sizeof out->name - 1);
        return 0;
    }
    /* The short flavor is allowed for more callers; it has no start time. */
    struct proc_bsdshortinfo si;
    n = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si);
    if (n != (int)sizeof si) return errno ? errno : ESRCH;
    out->pid = (pid_t)si.pbsi_pid;
    out->ppid = (pid_t)si.pbsi_ppid;
    out->pgid = (pid_t)si.pbsi_pgid;
    out->uid = si.pbsi_uid;
    out->ruid = si.pbsi_ruid;
    out->status = si.pbsi_status;
    out->flags = si.pbsi_flags;
    memcpy(out->comm, si.pbsi_comm, sizeof out->comm - 1);
    return 0;
}

int dm_proc_path(pid_t pid, char *buf, uint32_t buflen) {
    int n = proc_pidpath(pid, buf, buflen);
    if (n <= 0) { if (buflen) buf[0] = '\0'; return 0; }
    return n;
}

int dm_proc_cwd(pid_t pid, char *buf, uint32_t buflen) {
    struct proc_vnodepathinfo vpi;
    int n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof vpi);
    if (n != (int)sizeof vpi) return errno ? errno : EPERM;
    strlcpy(buf, vpi.pvi_cdir.vip_path, buflen);
    return 0;
}

int dm_proc_argv(pid_t pid, char **buf, size_t *len) {
    *buf = NULL;
    *len = 0;
    int mib[3] = {CTL_KERN, KERN_ARGMAX, 0};
    int argmax = 0;
    size_t sz = sizeof argmax;
    if (sysctl(mib, 2, &argmax, &sz, NULL, 0) != 0 || argmax <= 0) return -1;
    char *raw = malloc((size_t)argmax);
    if (raw == NULL) return -1;
    mib[1] = KERN_PROCARGS2;
    mib[2] = pid;
    sz = (size_t)argmax;
    if (sysctl(mib, 3, raw, &sz, NULL, 0) != 0 || sz < sizeof(int)) { free(raw); return -1; }
    int argc = 0;
    memcpy(&argc, raw, sizeof argc);
    char *p = raw + sizeof(int);
    char *end = raw + sz;
    while (p < end && *p != '\0') p++;          /* skip exec path */
    while (p < end && *p == '\0') p++;          /* skip padding */
    char *args = p;
    int seen = 0;
    while (p < end && seen < argc) {             /* walk argc NUL-terminated strings */
        while (p < end && *p != '\0') p++;
        if (p < end) p++;
        seen++;
    }
    size_t argsLen = (size_t)(p - args);
    char *outBuf = malloc(argsLen + 1);
    if (outBuf == NULL) { free(raw); return -1; }
    memcpy(outBuf, args, argsLen);
    outBuf[argsLen] = '\0';
    free(raw);
    *buf = outBuf;
    *len = argsLen;
    return seen;
}

int dm_proc_env(pid_t pid, const char *name, char *buf, size_t buflen) {
    if (buflen == 0 || name == NULL) return EINVAL;
    buf[0] = '\0';
    int mib[3] = {CTL_KERN, KERN_ARGMAX, 0};
    int argmax = 0;
    size_t sz = sizeof argmax;
    if (sysctl(mib, 2, &argmax, &sz, NULL, 0) != 0 || argmax <= 0) return errno ? errno : EINVAL;
    char *raw = malloc((size_t)argmax);
    if (raw == NULL) return ENOMEM;
    mib[1] = KERN_PROCARGS2;
    mib[2] = pid;
    sz = (size_t)argmax;
    if (sysctl(mib, 3, raw, &sz, NULL, 0) != 0 || sz < sizeof(int)) { int e = errno; free(raw); return e ? e : EINVAL; }
    int argc = 0;
    memcpy(&argc, raw, sizeof argc);
    char *p = raw + sizeof(int), *end = raw + sz;
    while (p < end && *p != '\0') p++;          /* exec path */
    while (p < end && *p == '\0') p++;          /* padding */
    for (int i = 0; i < argc && p < end; i++) {  /* argv */
        while (p < end && *p != '\0') p++;
        if (p < end) p++;
    }
    size_t nlen = strlen(name);
    int rc = ENOENT;
    while (p < end && *p != '\0') {             /* environment, "NAME=value" each */
        char *start = p;
        while (p < end && *p != '\0') p++;
        size_t len = (size_t)(p - start);
        if (len > nlen && strncmp(start, name, nlen) == 0 && start[nlen] == '=') {
            size_t vlen = len - nlen - 1;
            if (vlen >= buflen) vlen = buflen - 1;
            memcpy(buf, start + nlen + 1, vlen);
            buf[vlen] = '\0';
            rc = 0;
            break;
        }
        if (p < end) p++;
    }
    free(raw);
    return rc;
}

typedef pid_t (*dm_responsible_fn)(pid_t);

static dm_responsible_fn dm_lookup_responsible(void) {
    static dm_responsible_fn fn = NULL;
    static int looked = 0;
    if (!looked) {
        fn = (dm_responsible_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
        looked = 1;
    }
    return fn;
}

pid_t dm_responsible_pid(pid_t pid) {
    dm_responsible_fn fn = dm_lookup_responsible();
    if (fn == NULL) return -1;
    return fn(pid);
}

int dm_responsibility_available(void) { return dm_lookup_responsible() != NULL; }

int dm_proc_coalition(pid_t pid, uint64_t *resource_coalition_id) {
    struct dm_pidcoalitioninfo ci;
    int n = proc_pidinfo(pid, DM_PROC_PIDCOALITIONINFO, 0, &ci, sizeof ci);
    if (n != (int)sizeof ci) return errno ? errno : EINVAL;
    *resource_coalition_id = ci.coalition_id[0];
    return 0;
}

int dm_proc_idversion(pid_t pid, int32_t *idversion) {
    struct dm_uniqidentifierinfo ui;
    int n = proc_pidinfo(pid, DM_PROC_PIDUNIQIDENTIFIERINFO, 0, &ui, sizeof ui);
    if (n != (int)sizeof ui) return errno ? errno : EINVAL;
    *idversion = ui.p_idversion;
    return 0;
}

int dm_signal_audit(pid_t pid, int32_t idversion, int sig) {
    audit_token_t token;
    memset(&token, 0, sizeof token);
    token.val[5] = (unsigned int)pid;
    token.val[7] = (unsigned int)idversion;
    int rv = proc_signal_with_audittoken(&token, sig);
    if (rv == -1) return errno ? errno : EINVAL;
    return rv;
}

/* libsystem_kernel exports this (libproc private header); declared here because the SDK omits it. */
extern int proc_clear_vmpressure(pid_t pid);

int dm_resume_paused(pid_t pid) {
    return proc_clear_vmpressure(pid);
}

/* ---- restore guard ------------------------------------------------------------------------- */

static int g_guard_mib[CTL_MAXNAME];
static u_int g_guard_miblen = 0;
static int32_t g_guard_value = 0;
static volatile sig_atomic_t g_guard_armed = 0;
static struct sigaction g_old_int, g_old_term, g_old_hup;

static void dm_guard_handler(int sig) {
    if (g_guard_armed) {
        int32_t v = g_guard_value;
        (void)sysctl(g_guard_mib, g_guard_miblen, NULL, NULL, &v, sizeof v);
        g_guard_armed = 0;
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

int dm_restore_guard_arm(const char *name, int32_t restore_value) {
    size_t len = CTL_MAXNAME;
    if (sysctlnametomib(name, g_guard_mib, &len) != 0) return errno;
    g_guard_miblen = (u_int)len;
    g_guard_value = restore_value;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = dm_guard_handler;
    sigemptyset(&sa.sa_mask);
    g_guard_armed = 1;
    sigaction(SIGINT, &sa, &g_old_int);
    sigaction(SIGTERM, &sa, &g_old_term);
    sigaction(SIGHUP, &sa, &g_old_hup);
    return 0;
}

void dm_restore_guard_disarm(void) {
    if (!g_guard_armed && g_guard_miblen == 0) return;
    g_guard_armed = 0;
    sigaction(SIGINT, &g_old_int, NULL);
    sigaction(SIGTERM, &g_old_term, NULL);
    sigaction(SIGHUP, &g_old_hup, NULL);
}
