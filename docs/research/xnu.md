# macOS memory-pressure internals (research, 2026-10-20)

Primary sources: XNU tag `xnu-12377.121.6` (the target runs `xnu-12377.121.10~1`), libdispatch-1542.100.32,
libmalloc-812.100.31, system_cmds-1042.120.1, all from github.com/apple-oss-distributions. Line numbers refer
to those tags. macOS is built without CONFIG_JETSAM and without CONFIG_FREEZE.
`XNU = https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.121.6/`

## 1. The wall ("Your system has run out of application memory")

Chain on macOS:
1. Compressor thread: `compressor_needs_to_swap()` -> `if (should_swap && vm_swap_low_on_space()) memorystatus_respond_to_swap_exhaustion();`
   (`osfmk/vm/vm_compressor.c#L2915-L2918`); compressor-side exhaustion also responds (`#L5171`, `#L5423`).
2. Throttled to one action per `no_paging_space_throttle_delay_ns` = 5 s (`bsd/kern/kern_memorystatus.c#L1173-L1176`).
3. Health check picks `MEMORYSTATUS_NO_PAGING_SPACE` when compressor/swap is *low* (after idle-daemon kills)
   (`bsd/kern/kern_memorystatus_policy.c#L417-L495`).
4. `memstat_perform_no_paging_space_action()` -> `no_paging_space_action()` -> `memorystatus_send_low_swap_note()`
   ("Put up the 'Out of Application Memory' dialogue", `kern_memorystatus.c#L4824-L4845`).
5. Victim (`bsd/kern/kern_proc.c#L5084-L5165`): if the largest process that did NOT register a pcontrol action holds
   > 50% of all compressed pages it is SIGKILLed (no dialog); otherwise the largest pcontrol-registered process not
   yet acted on is handled by `proc_dopcontrol()`: `P_PCSUSP` -> `task_suspend` (the "(paused)" in Force Quit).
   Every 5 s the next largest registered process is suspended.
6. loginwindow receives `NOTE_MEMORYSTATUS_LOW_SWAP` and shows LowMemoryPanel (VERIFIED in this Mac's log).

pcontrol state is readable for any pid: `proc_pidinfo(PROC_PIDT_SHORTBSDINFO).pbsi_flags` (same bits in
`PROC_PIDTBSDINFO.pbi_flags`): `PROC_FLAG_PC_THROTTLE 0x200`, `PC_SUSP 0x400`, `PC_KILL 0x600`, acted-on
`PROC_FLAG_PA_THROTTLE 0x800`, `PA_SUSP 0x1000` (`bsd/sys/proc_info.h#L113-L119`). VERIFIED on the target: 7
processes registered for suspend, 12 for kill, and Raycast's `com.apple.WebKit.Networking` (pid 1149) still
`PA_SUSP` hours after the 03:40 episode.

### Formulas (`osfmk/vm/vm_compressor_backing_store.c`)

- `vm_swap_low_on_space()` (`#L2458-L2486`): free swap < `vm_swapfile_hiwater_segs / 8` (= 32 MiB with 64 KiB
  chunks) AND (the last swapfile creation failed more recently than the last success OR 100 files exist).
- `vm_swap_out_of_space()` (`#L2488-L2509`): free swap < 8 segments (512 KiB) AND 100 files exist.
- A new swapfile is created when files < 100, free swap < 256 MiB (hiwater) and > 15 s since the last failure;
  sizes tried 1 GiB, 512 MiB, 256 MiB (`#L806-L815`, `#L1565-L1690`). Files are removed when >= 1.7 GiB is free.
- `vm_num_swap_files_config` = 100 on macOS (no RAM- or disk-based budget; disk only matters if
  `vnode_setsize` fails). So the target's swap stopping at 11 x 1 GiB with 93 GB free means creating swapfile11
  failed transiently (it later grew to 16 files). Cause UNCONFIRMED (needs `sudo dmesg`).

Compressor (`osfmk/vm/vm_compressor.c#L572-L607`, sizing `#L833-L930`):
- low on space = pages_compressed > 98% of `c_segment_pages_compressed_limit` OR segments > 98% of `c_segments_limit`.
- out of space = >= 100% of either.
- `compressor_pool_size` = 4 x max_mem on 8-32 GiB Macs (16/8/4/2 x for <=4/<=8/<=32/>32 GiB, cap 192 GiB);
  `c_segments_limit = pool / (64 KiB + page)`; `c_segment_pages_compressed_limit = c_segments_limit * 4 * multiplier`.
  VERIFIED: 16,502,996,992 x 4 = 66,011,987,968 = `vm.compressor_pool_size`; / 81,920 = 805,810 =
  `vm.compressor.segment.limit`; x 4 x 2 = 6,446,480 = `vm.compressor.pages_compressed_limit`.
- `c_segment_count` (sysctl `vm.compressor.segment.total`) includes swapped-out segments, so the real ceiling on
  compressed data in RAM + swap is ~805,810 x 64 KiB = ~49 GiB here.

Pressure levels (`osfmk/vm/vm_pageout.c#L10750-L10811`), with AM = active+inactive+free+speculative+compressor
pages and ANCM = AM minus compressor pages: normal->warn when ANCM < 0.50 AM; warn->critical when compressor low on
space or ANCM < 0.343 AM; back down at 0.40 / 0.60. `kern.memorystatus_level` = ANCM x 100 / max_mem pages.

### Unprivileged inputs used by the wall model

`vm.swapusage`, `vm.compressor.pages_compressed`, `vm.compressor.pages_compressed_limit`,
`vm.compressor.segment.total`, `vm.compressor.segment.limit`, `kern.memorystatus_level`,
`kern.memorystatus_vm_pressure_level`, `statfs(/System/Volumes/VM)`, swapfile count from the directory listing.

## 2. `kern.memorypressure_manual_trigger` (`bsd/kern/kern_memorystatus_notify.c#L1913-L2019`)

- Value `(request << 16) | level`, request 1-6 (`TEST_LOW_MEMORY_PURGEABLE_TRIGGER_ALL` = 6), level
  `NOTE_MEMORYSTATUS_PRESSURE_NORMAL 0x1 / WARN 0x2 / CRITICAL 0x4`. Root only (no `CTLFLAG_ANYBODY`), no entitlement.
- Sets `memorystatus_manual_testing_on = TRUE` and forces `memorystatus_vm_pressure_level`. `vm_pressure_response()`
  returns early while testing is on (`vm_pageout.c#L5285`), so real tracking is frozen until a value with level
  NORMAL is written. **Gotcha: the flag is set before validation, so even an EINVAL write must be followed by a
  reset.** Reset value used: `0x60001` (393217).
- Request 6 purges purgeable objects (critical: all 8 volatile groups) and notifies every eligible registered
  process, one per `memorystatus_update_vm_pressure()` call, skipping the 250 ms inter-notification delay.
- Side effect on macOS: non-normal levels also kill clean idle-exitable daemons (`memstat_kill_idle_process`, up to
  100; launchd relaunches them on demand).
- Eligibility: registered knote for that level, footprint >= 10 MB, not suspended/terminated, priority >= 20;
  ordered by lowest task importance then largest footprint. Re-notification of the same level is suppressed for
  25 s after everyone was notified.

## 3. `memory_pressure -S -l critical -s N` (system_cmds `memory_pressure.c`)

Writes `0x60004`, sleeps N (default 1), writes `0x60001`. If killed during the sleep the reset never happens.

## 4. libdispatch + libmalloc

libdispatch registers the malloc pressure source lazily (first kqueue use) and calls
`malloc_memory_event_handler()`. On Apple-silicon macOS 26 the default allocator is **xzone malloc**, whose
`pressure_relief` is a no-op (`malloc_zone_pressure_relief_fallback` returns 0); it already madvises freed chunks.
So pressure notifications make no extra heap pages come back unless the app itself handles the event.

## 5. Single-pid notification

Not possible on release kernels: `kern.memorystatus_vm_pressure_send` is DEBUG/DEVELOPMENT only (and needs
`com.apple.private.memorystatus`); no `memorystatus_control` command delivers a note to a pid.

## 6. Footprint

`phys_footprint` = (internal + internal_compressed - alternate accounting) + IOKit mapped + purgeable nonvolatile
(+ compressed) + page tables + tagged/network/media/graphics/neural ledgers (`osfmk/kern/task.c#L1255-L1296`).
Activity Monitor's Memory column, top's MEM and Xcode's gauge all read this ledger (footprint(1) man page).
`proc_pid_rusage(RUSAGE_INFO_V6)` needs same uid (EPERM otherwise); `PROC_PIDT_SHORTBSDINFO`,
`PROC_PIDCOALITIONINFO`, `PROC_PIDPATHINFO` work cross-user.

## 7. Freeing memory: what actually works

- munmap / vm_deallocate / madvise(MADV_FREE(_REUSABLE)) drop compressed copies immediately; swapped segments become
  sparse and swap space returns only on defragmentation or when a segment empties; swapfiles shrink at >= 1.7 GiB free.
- Suspending a process frees nothing.
- `purge` (`vfs_purge`) only flushes file-backed cache; it cannot reduce app, compressed or swapped memory.
- Volatile purgeable memory was 2 pages on the target under pressure: the kernel had already purged it.
