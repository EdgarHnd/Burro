// Query the kernel instead of trusting stale PID or lock files.
#include "CSystem.h"
#include <libproc.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <netinet/in.h>
#include <netinet/tcp_fsm.h>
int burro_list_pids(int *buffer, int capacity) {
    return proc_listallpids(buffer, capacity * (int)sizeof(int));
}
int burro_process_info(int pid, BurroProcess *result) {
    struct proc_bsdinfo bsd;
    memset(result, 0, sizeof(*result));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) return 0;
    result->pid = pid; result->ppid = bsd.pbi_ppid;
    result->uid = bsd.pbi_uid; result->started = bsd.pbi_start_tvsec;
    proc_pidpath(pid, result->executable, sizeof(result->executable));
    struct proc_vnodepathinfo vnode;
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, sizeof(vnode)) == sizeof(vnode)) {
        strncpy(result->cwd, vnode.pvi_cdir.vip_path, sizeof(result->cwd)-1);
        result->cwd_readable = 1;
    }
    return 1;
}
int burro_lock_held(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return errno == ENOENT ? 0 : -1;
    int result = flock(fd, LOCK_EX | LOCK_NB);
    int saved = errno;
    if (result == 0) flock(fd, LOCK_UN);
    close(fd);
    return result == 0 ? 0 : ((saved == EWOULDBLOCK || saved == EAGAIN) ? 1 : -1);
}

int burro_process_output_path(int pid, int fd, char *path, int capacity) {
    if ((fd != 1 && fd != 2) || capacity < 2) return -1;
    path[0] = 0;
    struct vnode_fdinfowithpath info;
    int size = proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, sizeof(info));
    if (size != sizeof(info)) {
        // Pipes/sockets and a process that exited between snapshots have no task vnode.
        return (errno == EBADF || errno == ESRCH || errno == ENOENT ||
                errno == EINVAL || errno == ENOTSUP) ? 0 : -1;
    }
    if (!(info.pfi.fi_openflags & FWRITE)) return 0;
    strncpy(path, info.pvip.vip_path, capacity - 1);
    path[capacity - 1] = 0;
    return path[0] ? 1 : 0;
}

int burro_process_usage(int pid, BurroTaskUsage *result) {
    memset(result, 0, sizeof(*result));
    struct proc_taskinfo task;
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) != sizeof(task)) return 0;
    // Task times are Mach ticks; Apple silicon ticks are not nanoseconds.
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) return 0;
    result->cpu_ns = (task.pti_total_user + task.pti_total_system) * timebase.numer / timebase.denom;
    result->resident = task.pti_resident_size;
    return 1;
}

int burro_process_arguments(int pid, char *buffer, int capacity, int *length) {
    *length = 0;
    if (capacity < 1) return -1;
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int)) return -1;
    char *raw = malloc(size);
    if (!raw) return -1;
    if (sysctl(mib, 3, raw, &size, NULL, 0) != 0 || size < sizeof(int)) { free(raw); return -1; }
    int argc = 0;
    memcpy(&argc, raw, sizeof(argc));
    char *cursor = raw + sizeof(int), *end = raw + size;
    while (cursor < end && *cursor) cursor++;    // executable path
    while (cursor < end && !*cursor) cursor++;   // alignment padding
    int copied = 0, used = 0;
    while (copied < argc && cursor < end) {
        size_t span = strnlen(cursor, (size_t)(end - cursor));
        if (used + (int)span + 1 > capacity) break;
        memcpy(buffer + used, cursor, span);
        buffer[used + span] = 0;
        used += (int)span + 1; copied++;
        cursor += span + 1;
    }
    free(raw);
    *length = used;
    return copied;
}

int burro_process_sockets(int pid, BurroSocket *buffer, int capacity) {
    int size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (size <= 0) return -1;
    size += 32 * (int)sizeof(struct proc_fdinfo);   // descriptors opened since the size query
    struct proc_fdinfo *fds = malloc((size_t)size);
    if (!fds) return -1;
    size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, size);
    if (size <= 0) { free(fds); return -1; }
    int count = size / (int)sizeof(struct proc_fdinfo), found = 0;
    for (int i = 0; i < count && found < capacity; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo info;
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info)) != sizeof(info)) continue;
        if (info.psi.soi_kind != SOCKINFO_TCP) continue;
        int state = info.psi.soi_proto.pri_tcp.tcpsi_state;
        if (state != TSI_S_LISTEN && state != TSI_S_ESTABLISHED) continue;
        buffer[found].local_port = ntohs((unsigned short)info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport);
        buffer[found].listening = state == TSI_S_LISTEN;
        found++;
    }
    free(fds);
    return found;
}

int burro_cpu_ticks(BurroCPUTicks *result) {
    memset(result, 0, sizeof(*result));
    host_cpu_load_info_data_t load;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t status = host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&load, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (status != KERN_SUCCESS) return 0;
    result->user = load.cpu_ticks[CPU_STATE_USER];
    result->system = load.cpu_ticks[CPU_STATE_SYSTEM];
    result->idle = load.cpu_ticks[CPU_STATE_IDLE];
    result->nice = load.cpu_ticks[CPU_STATE_NICE];
    return 1;
}

int burro_memory(BurroMemory *result) {
    memset(result, 0, sizeof(*result));
    size_t size = sizeof(result->total);
    if (sysctlbyname("hw.memsize", &result->total, &size, NULL, 0) != 0) return 0;
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t status = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (status != KERN_SUCCESS) return 0;
    uint64_t page = vm_kernel_page_size;
    uint64_t internal = vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0;
    result->app = internal * page;
    result->wired = (uint64_t)vm.wire_count * page;
    result->compressed = (uint64_t)vm.compressor_page_count * page;
    result->cached = ((uint64_t)vm.external_page_count + vm.purgeable_count) * page;
    result->free = (uint64_t)(vm.free_count > vm.speculative_count ? vm.free_count - vm.speculative_count : 0) * page;
    struct xsw_usage swap;
    size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0) {
        result->swap_total = swap.xsu_total; result->swap_used = swap.xsu_used;
    }
    int pressure = 0;
    size = sizeof(pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, NULL, 0) == 0) result->pressure = pressure;
    struct timeval boot;
    size = sizeof(boot);
    if (sysctlbyname("kern.boottime", &boot, &size, NULL, 0) == 0) result->booted = boot.tv_sec;
    return 1;
}
