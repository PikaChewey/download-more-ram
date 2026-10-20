/* CDarwinMem - thin C shims over libproc, sysctl, host_statistics64 and private SPI.
 * Every private struct is size-checked at runtime; on mismatch the call fails and the Swift
 * side falls back (never reads garbage). Nothing here allocates on the caller's behalf except
 * dm_proc_argv, whose buffer the caller frees. */
#ifndef CDARWINMEM_H
#define CDARWINMEM_H

#include <stdint.h>
#include <sys/types.h>

/* ---- system ---------------------------------------------------------------------------- */

typedef struct {
    uint64_t page_size;
    uint64_t free_count, active_count, inactive_count, speculative_count, throttled_count;
    uint64_t wire_count, purgeable_count, external_page_count, internal_page_count;
    uint64_t compressor_page_count, total_uncompressed_pages_in_compressor;
    uint64_t swapins, swapouts, pageins, pageouts, compressions, decompressions;
    uint64_t faults, purges, zero_fill_count, reactivations;
} dm_vm_stats;

/* host_statistics64(HOST_VM_INFO64); 0 on success, else the kern_return_t. */
int dm_vm_read(dm_vm_stats *out);

typedef struct { uint64_t total, avail, used; uint32_t pagesize; int encrypted; } dm_swap_usage;
/* sysctl vm.swapusage; 0 on success, else errno. */
int dm_swap_read(dm_swap_usage *out);

/* sysctlbyname readers that accept 4- or 8-byte integers. 0 on success, else errno. */
int dm_sysctl_u64(const char *name, uint64_t *out);
int dm_sysctl_i64(const char *name, int64_t *out);
/* Copies a string sysctl into buf (NUL-terminated). 0 on success, else errno. */
int dm_sysctl_string(const char *name, char *buf, size_t buflen);
/* Writes a 32-bit int sysctl (needs root). 0 on success, else errno. */
int dm_sysctl_write_i32(const char *name, int32_t value);

/* ---- processes ------------------------------------------------------------------------- */

/* Fills pids (capacity entries); returns the count, or -1 on error. Call with NULL/0 for size. */
int dm_list_pids(pid_t *pids, int capacity);

typedef struct {
    uint64_t phys_footprint;
    uint64_t lifetime_max_phys_footprint;
    uint64_t resident_size;
    uint64_t user_time_ns;      /* converted from mach timebase units */
    uint64_t system_time_ns;
    uint64_t pageins;
    uint64_t interrupt_wkups, pkg_idle_wkups;
} dm_rusage;

/* proc_pid_rusage(RUSAGE_INFO_V6). 0 on success, else errno (EPERM for other users' tasks). */
int dm_proc_rusage(pid_t pid, dm_rusage *out);

typedef struct {
    pid_t pid, ppid, pgid;
    uint32_t uid, ruid, status, flags;
    uint64_t start_sec, start_usec;
    char comm[17];
    char name[33];
} dm_bsdinfo;

/* proc_pidinfo(PROC_PIDTBSDINFO). 0 on success, else errno. */
int dm_proc_bsdinfo(pid_t pid, dm_bsdinfo *out);
/* proc_pidpath into buf. Returns length, or 0 on failure. */
int dm_proc_path(pid_t pid, char *buf, uint32_t buflen);
/* Current working directory via PROC_PIDVNODEPATHINFO. 0 on success, else errno. */
int dm_proc_cwd(pid_t pid, char *buf, uint32_t buflen);
/* KERN_PROCARGS2 argv joined with NUL separators. Returns argc (>= 0) and sets buf and len
 * (the caller frees buf), or -1 on failure (other users' processes fail with EINVAL/EPERM). */
int dm_proc_argv(pid_t pid, char **buf, size_t *len);
/* Copies the value of ONE environment variable `name` of a same-user process into buf (from
 * KERN_PROCARGS2). Never exposes any other variable. 0 on success, ENOENT if unset, else errno. */
int dm_proc_env(pid_t pid, const char *name, char *buf, size_t buflen);
/* responsibility_get_pid_responsible_for_pid via dlsym; -1 if the SPI is missing or fails. */
pid_t dm_responsible_pid(pid_t pid);
int dm_responsibility_available(void);
/* PROC_PIDCOALITIONINFO resource coalition id (size-checked); 0 on success, else errno. */
int dm_proc_coalition(pid_t pid, uint64_t *resource_coalition_id);
/* p_idversion from PROC_PIDUNIQIDENTIFIERINFO (size-checked) for audit-token signalling. */
int dm_proc_idversion(pid_t pid, int32_t *idversion);
/* Signal through an audit token (pid + idversion) so a reused pid is never hit.
 * 0 on success, else errno (ESRCH when the identity no longer matches). */
int dm_signal_audit(pid_t pid, int32_t idversion, int sig);


/* Resume a process the kernel suspended at the memory wall (what loginwindow's Resume button
 * calls: process_policy RESOURCE_STARVATION restore -> proc_resetpcontrol -> task_resume).
 * Root only. 0 on success, else errno. */
int dm_resume_paused(pid_t pid);

/* ---- restore guard --------------------------------------------------------------------- */

/* While armed, every catchable terminating signal (SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE,
 * SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, ...) first writes restore_value to the sysctl `name` (resolved
 * to a MIB up front so the handler only makes the raw syscall), unlinks `marker` (may be NULL) if
 * that succeeded, then re-raises with the default action. Returns 0, EBUSY if a hold is already
 * armed in this process, or the errno of the name lookup. */
int dm_restore_guard_arm(const char *name, int32_t restore_value, const char *marker);
void dm_restore_guard_disarm(void);
int dm_restore_guard_is_armed(void);

#endif
