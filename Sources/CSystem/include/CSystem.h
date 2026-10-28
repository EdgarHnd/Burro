// Read-only process inspection and system SQLite bindings.
#include <sqlite3.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct {
    int pid;
    int ppid;
    unsigned int uid;
    uint64_t started;
    int cwd_readable;
    char executable[4096];
    char cwd[4096];
} BurroProcess;
int burro_list_pids(int *buffer, int capacity);
int burro_process_info(int pid, BurroProcess *result);
// 1 held by another process, 0 free, -1 unreadable. Never creates a lock.
int burro_lock_held(const char *path);

// 1 writable stdout/stderr vnode path, 0 closed/non-vnode/read-only, -1 inspection denied.
int burro_process_output_path(int pid, int fd, char *path, int capacity);

// Mac Health: read-only resource sampling. Each returns 1 when read, 0 when unavailable.
typedef struct {
    uint64_t cpu_ns;      // user + system CPU time, converted from Mach ticks
    uint64_t resident;    // bytes
} BurroTaskUsage;
int burro_process_usage(int pid, BurroTaskUsage *result);
// NUL-separated argv (argv[0] first), truncated to capacity. Returns the copied argument count, -1 if unreadable.
int burro_process_arguments(int pid, char *buffer, int capacity, int *length);
typedef struct {
    int local_port;
    int listening;        // 1 listening, 0 established
} BurroSocket;
// TCP listening/established sockets owned by pid, or -1 when its descriptors are unreadable.
int burro_process_sockets(int pid, BurroSocket *buffer, int capacity);
typedef struct {
    uint64_t user, system, idle, nice;   // cumulative ticks across all cores
} BurroCPUTicks;
int burro_cpu_ticks(BurroCPUTicks *result);
typedef struct {
    uint64_t total, app, wired, compressed, cached, free;   // bytes, Activity Monitor categories
    uint64_t swap_total, swap_used;
    int pressure;         // kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical, 0 unknown
    int64_t booted;       // seconds since 1970, 0 unknown
} BurroMemory;
int burro_memory(BurroMemory *result);
