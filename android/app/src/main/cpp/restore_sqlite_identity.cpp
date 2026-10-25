#include "restore_sqlite_identity.h"

#include <cerrno>
#include <cstddef>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

// ABI declarations are the public sqlite3.h v3 VFS/file tables, not unixFile.
// https://sqlite.org/c3ref/vfs.html
// https://sqlite.org/c3ref/io_methods.html
// No SQLite header/dependency, absent-module load, or private field offsets.
namespace sqlite_public {
using Int64 = long long;
using SystemCall = void (*)(void);
struct File;
struct Methods {
  int iVersion;
  int (*xClose)(File*);
  int (*xRead)(File*, void*, int, Int64);
  int (*xWrite)(File*, const void*, int, Int64);
  int (*xTruncate)(File*, Int64);
  int (*xSync)(File*, int);
  int (*xFileSize)(File*, Int64*);
  int (*xLock)(File*, int);
  int (*xUnlock)(File*, int);
  int (*xCheckReservedLock)(File*, int*);
  int (*xFileControl)(File*, int, void*);
  int (*xSectorSize)(File*);
  int (*xDeviceCharacteristics)(File*);
  int (*xShmMap)(File*, int, int, int, void volatile**);
  int (*xShmLock)(File*, int, int, int);
  void (*xShmBarrier)(File*);
  int (*xShmUnmap)(File*, int);
  int (*xFetch)(File*, Int64, int, void**);
  int (*xUnfetch)(File*, Int64, void*);
};
struct File {
  const Methods* pMethods;
};
struct Vfs {
  int iVersion;
  int szOsFile;
  int mxPathname;
  Vfs* pNext;
  const char* zName;
  void* pAppData;
  int (*xOpen)(Vfs*, const char*, File*, int, int*);
  int (*xDelete)(Vfs*, const char*, int);
  int (*xAccess)(Vfs*, const char*, int, int*);
  int (*xFullPathname)(Vfs*, const char*, int, char*);
  void* (*xDlOpen)(Vfs*, const char*);
  void (*xDlError)(Vfs*, int, char*);
  SystemCall (*xDlSym)(Vfs*, void*, const char*);
  void (*xDlClose)(Vfs*, void*);
  int (*xRandomness)(Vfs*, int, char*);
  int (*xSleep)(Vfs*, int);
  int (*xCurrentTime)(Vfs*, double*);
  int (*xGetLastError)(Vfs*, int, char*);
  int (*xCurrentTimeInt64)(Vfs*, Int64*);
  int (*xSetSystemCall)(Vfs*, const char*, SystemCall);
  SystemCall (*xGetSystemCall)(Vfs*, const char*);
  const char* (*xNextSystemCall)(Vfs*, const char*);
};
}  // namespace sqlite_public

namespace {
using sqlite_public::File;
using sqlite_public::Int64;
using sqlite_public::Methods;
using sqlite_public::SystemCall;
using sqlite_public::Vfs;
using FindVfs = Vfs* (*)(const char*);
using RegisterVfs = int (*)(Vfs*, int);
// sqlite3* is opaque: never inspect it or dereference rawSqlite here.
using FileControl = int (*)(void*, const char*, int, void*);
using OpenCall = int (*)(const char*, int, int);
using CloseCall = int (*)(int);

constexpr int kOk = 0;
constexpr int kNotFound = 12;
constexpr int kFilePointer = 7;
constexpr int kVfsPointer = 27;
constexpr int kReadOnly = 0x00000001;
constexpr int kReadWrite = 0x00000002;
constexpr int kUri = 0x00000040;
constexpr int kAccessMask = kReadOnly | kReadWrite;
constexpr int kMainDb = 0x00000100;
constexpr int kFileTypeMask = 0x000fff00;
constexpr int kPrivateCache = 0x00040000;
// Root constructs URI parameters: cache=private and (RO candidate only)
// immutable=1. The public xOpen pathname is still the decoded canonical path.
// Cache/mutex flags may be masked by sqlite3OsOpen: private cache is a trusted
// caller prerequisite, not inferred here. Memory and creation are forbidden.
constexpr int kSupportedOpenFlags = kAccessMask | kUri | kMainDb | kPrivateCache |
    0x00008000 | 0x00010000 | 0x01000000 | 0x02000000;
constexpr size_t kMaxRecords = 256;
constexpr char kVfsName[] = "astoria_restore_unix";

enum class Phase {
  unused, reserved, armed, opening, captured, claiming, claimed, retired
};
enum class Setup { empty, installing, ready, poisoned };
}  // namespace

struct AstoriaSqliteWitness {
  Phase phase;
  char path[PATH_MAX];
  uint64_t device;
  uint64_t inode;
  File* file;
  const Methods* methods;
  Methods methods_snapshot;
  void* raw;
  // Tracking survives retirement until the actual syscall-close. It NEVER
  // grants authority; SQLite can cache this FD after its logical xClose.
  int tracked_fd;
  int sqlite_flags;
  unsigned main_opens;
  unsigned syscall_opens;
  unsigned observers;
  unsigned opening;
  bool ambiguous_close;
};

namespace {
pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
Setup g_setup = Setup::empty;
Vfs* g_delegate = nullptr;
Vfs g_stock{};
Vfs g_forward{};
Vfs g_forward_snapshot{};
void* g_module = nullptr;
void* g_api_addresses[6]{};
FindVfs g_find = nullptr;
FileControl g_control = nullptr;
OpenCall g_open = nullptr;
CloseCall g_close = nullptr;
uid_t g_uid = 0;
AstoriaSqliteWitness g_records[kMaxRecords]{};
size_t g_record_count = 0;
// Only the pending job occupies this slot. Claimed witnesses are independently
// retained in g_records; claiming/retiring one never selects another as a job.
AstoriaSqliteWitness* g_job = nullptr;
unsigned g_opening = 0;

struct OpenScope {
  AstoriaSqliteWitness* witness;
  File* file;
};
// The arm is global (FFI threads may migrate); only a wrapper's synchronous
// delegate xOpen installs TLS. No pathname-only authority from default VFS.
thread_local OpenScope* g_scope = nullptr;

void lock() { pthread_mutex_lock(&g_mutex); }
void unlock() { pthread_mutex_unlock(&g_mutex); }

AstoriaSqliteWitness* known(AstoriaSqliteWitness* witness) {
  for (size_t i = 0; i < g_record_count; ++i) {
    if (witness == &g_records[i]) return witness;
  }
  return nullptr;
}

void release_retired_job_locked(AstoriaSqliteWitness* witness) {
  if (g_job == witness && witness->phase == Phase::retired &&
      witness->observers == 0 && witness->opening == 0) g_job = nullptr;
}

void retire_locked(AstoriaSqliteWitness* witness) {
  witness->phase = Phase::retired;
  witness->raw = nullptr;
  // Revoke authority immediately, but retain this pending reservation until
  // registry validation, xOpen and claim observers have actually drained.
  release_retired_job_locked(witness);
}

void poison_locked() {
  g_setup = Setup::poisoned;
  for (size_t i = 0; i < g_record_count; ++i) retire_locked(&g_records[i]);
}

bool module_address(const void* address, const void* module) {
  Dl_info info{};
  return address && dladdr(address, &info) != 0 && info.dli_fbase == module;
}

template <typename Function>
bool module_function(Function fn, const void* module) {
  return module_address(reinterpret_cast<const void*>(fn), module);
}

bool named_api(void* address, const char* name, void** module) {
  Dl_info info{};
  if (!address || dladdr(address, &info) == 0 || !info.dli_fbase ||
      info.dli_saddr != address || !info.dli_sname ||
      std::strcmp(info.dli_sname, name) != 0) return false;
  if (*module && *module != info.dli_fbase) return false;
  *module = info.dli_fbase;
  return true;
}

bool path_valid(const char* path, size_t* length) {
  if (!path || path[0] != '/') return false;
  const size_t size = ::strnlen(path, PATH_MAX);
  if (size < 2 || size >= PATH_MAX || path[size - 1] == '/') return false;
  size_t start = 1;
  for (size_t i = 1; i <= size; ++i) {
    const unsigned char ch = static_cast<unsigned char>(path[i]);
    if (i != size && (ch < 32 || ch == 127 || ch == '\\' ||
                      ch == '?' || ch == '#')) return false;
    if (ch != '/' && i != size) continue;
    const size_t count = i - start;
    if (count == 0 || count > NAME_MAX ||
        (count == 1 && path[start] == '.') ||
        (count == 2 && path[start] == '.' && path[start + 1] == '.')) return false;
    start = i + 1;
  }
  *length = size;
  return true;
}

bool main_flags(int flags) {
  const int access = flags & kAccessMask;
  return (flags & kFileTypeMask) == kMainDb &&
      (access == kReadOnly || access == kReadWrite) &&
      (flags & ~kSupportedOpenFlags) == 0;
}

int expected_fd_access(const AstoriaSqliteWitness* witness) {
  return (witness->sqlite_flags & kReadWrite) != 0 ? O_RDWR : O_RDONLY;
}

bool stock_supported(Vfs* vfs, void* module) {
  // Fail closed for a future layout we cannot copy completely.
  if (!module_address(vfs, module) || vfs->iVersion != 3 || !vfs->zName ||
      std::strcmp(vfs->zName, "unix") != 0 ||
      vfs->szOsFile < static_cast<int>(sizeof(File)) || vfs->szOsFile > 65536 ||
      vfs->mxPathname < 2 || vfs->mxPathname >= PATH_MAX) return false;
#define REQUIRED_VFS(field) if (!module_function(vfs->field, module)) return false
  REQUIRED_VFS(xOpen);
  REQUIRED_VFS(xDelete);
  REQUIRED_VFS(xAccess);
  REQUIRED_VFS(xFullPathname);
  REQUIRED_VFS(xRandomness);
  REQUIRED_VFS(xSleep);
  REQUIRED_VFS(xCurrentTime);
  REQUIRED_VFS(xGetLastError);
  REQUIRED_VFS(xCurrentTimeInt64);
  REQUIRED_VFS(xSetSystemCall);
  REQUIRED_VFS(xGetSystemCall);
  REQUIRED_VFS(xNextSystemCall);
#undef REQUIRED_VFS
  const bool any_dl = vfs->xDlOpen || vfs->xDlError || vfs->xDlSym || vfs->xDlClose;
  if (any_dl && (!module_function(vfs->xDlOpen, module) ||
      !module_function(vfs->xDlError, module) ||
      !module_function(vfs->xDlSym, module) ||
      !module_function(vfs->xDlClose, module))) return false;
  const char* first = vfs->xNextSystemCall(vfs, nullptr);
  const char* second = vfs->xNextSystemCall(vfs, "open");
  return first && second && std::strcmp(first, "open") == 0 &&
      std::strcmp(second, "close") == 0 &&
      module_function(vfs->xGetSystemCall(vfs, "open"), module) &&
      vfs->xGetSystemCall(vfs, "close") == reinterpret_cast<SystemCall>(&::close);
}

int intercepted_open(const char*, int, int);
int intercepted_close(int);

// Stock unix's public getter is a read-only lookup, without a SQLite mutex.
// Do not invoke vfs_find/file_control or the delegate xOpen under g_mutex:
// SQLite may already own its connection/inode mutex when it calls our hooks.
bool mechanism_locked() {
  if (g_setup != Setup::ready || geteuid() != g_uid || getuid() != g_uid)
    return false;
#define SAME_VFS(field) if (actual->field != expected->field) return false
  for (unsigned i = 0; i < 2; ++i) {
    const Vfs* actual = i == 0 ? g_delegate : &g_forward;
    const Vfs* expected = i == 0 ? &g_stock : &g_forward_snapshot;
    SAME_VFS(iVersion);
    SAME_VFS(szOsFile);
    SAME_VFS(mxPathname);
    SAME_VFS(zName);
    SAME_VFS(pAppData);
    SAME_VFS(xOpen);
    SAME_VFS(xDelete);
    SAME_VFS(xAccess);
    SAME_VFS(xFullPathname);
    SAME_VFS(xDlOpen);
    SAME_VFS(xDlError);
    SAME_VFS(xDlSym);
    SAME_VFS(xDlClose);
    SAME_VFS(xRandomness);
    SAME_VFS(xSleep);
    SAME_VFS(xCurrentTime);
    SAME_VFS(xGetLastError);
    SAME_VFS(xCurrentTimeInt64);
    SAME_VFS(xSetSystemCall);
    SAME_VFS(xGetSystemCall);
    SAME_VFS(xNextSystemCall);
  }
#undef SAME_VFS
  // pNext alone belongs to SQLite and is deliberately not inspected.
  return std::strcmp(g_delegate->zName, "unix") == 0 &&
      g_stock.xGetSystemCall(g_delegate, "open") ==
          reinterpret_cast<SystemCall>(&intercepted_open) &&
      g_stock.xGetSystemCall(g_delegate, "close") ==
          reinterpret_cast<SystemCall>(&intercepted_close);
}

bool registry_current() {
  return g_find("unix") == g_delegate && g_find(kVfsName) == &g_forward;
}

void copy_stock_vfs(Vfs* out, const Vfs* source) {
  // Existing pNext is mutable SQLite registry state. Do not even copy/read
  // it while unrelated VFS registrations can change it under SQLite's mutex.
#define COPY_VFS(field) out->field = source->field
  COPY_VFS(iVersion);
  COPY_VFS(szOsFile);
  COPY_VFS(mxPathname);
  COPY_VFS(zName);
  COPY_VFS(pAppData);
  COPY_VFS(xOpen);
  COPY_VFS(xDelete);
  COPY_VFS(xAccess);
  COPY_VFS(xFullPathname);
  COPY_VFS(xDlOpen);
  COPY_VFS(xDlError);
  COPY_VFS(xDlSym);
  COPY_VFS(xDlClose);
  COPY_VFS(xRandomness);
  COPY_VFS(xSleep);
  COPY_VFS(xCurrentTime);
  COPY_VFS(xGetLastError);
  COPY_VFS(xCurrentTimeInt64);
  COPY_VFS(xSetSystemCall);
  COPY_VFS(xGetSystemCall);
  COPY_VFS(xNextSystemCall);
#undef COPY_VFS
}

bool methods_supported(const Methods* methods) {
  if (!module_address(methods, g_module) || methods->iVersion != 3) return false;
#define REQUIRED_IO(field) if (!module_function(methods->field, g_module)) return false
  REQUIRED_IO(xClose);
  REQUIRED_IO(xRead);
  REQUIRED_IO(xWrite);
  REQUIRED_IO(xTruncate);
  REQUIRED_IO(xSync);
  REQUIRED_IO(xFileSize);
  REQUIRED_IO(xLock);
  REQUIRED_IO(xUnlock);
  REQUIRED_IO(xCheckReservedLock);
  REQUIRED_IO(xFileControl);
  REQUIRED_IO(xSectorSize);
  REQUIRED_IO(xDeviceCharacteristics);
  REQUIRED_IO(xShmMap);
  REQUIRED_IO(xShmLock);
  REQUIRED_IO(xShmBarrier);
  REQUIRED_IO(xShmUnmap);
  REQUIRED_IO(xFetch);
  REQUIRED_IO(xUnfetch);
#undef REQUIRED_IO
  return true;
}

bool methods_current(AstoriaSqliteWitness* witness) {
  if (!witness->file || witness->file->pMethods != witness->methods ||
      !witness->methods) return false;
  const Methods& a = *witness->methods;
  const Methods& b = witness->methods_snapshot;
#define SAME_IO(field) if (a.field != b.field) return false
  SAME_IO(iVersion);
  SAME_IO(xClose);
  SAME_IO(xRead);
  SAME_IO(xWrite);
  SAME_IO(xTruncate);
  SAME_IO(xSync);
  SAME_IO(xFileSize);
  SAME_IO(xLock);
  SAME_IO(xUnlock);
  SAME_IO(xCheckReservedLock);
  SAME_IO(xFileControl);
  SAME_IO(xSectorSize);
  SAME_IO(xDeviceCharacteristics);
  SAME_IO(xShmMap);
  SAME_IO(xShmLock);
  SAME_IO(xShmBarrier);
  SAME_IO(xShmUnmap);
  SAME_IO(xFetch);
  SAME_IO(xUnfetch);
#undef SAME_IO
  return true;
}

bool fd_current(AstoriaSqliteWitness* witness) {
  if (witness->tracked_fd < 3 || witness->ambiguous_close) return false;
  struct stat value{};
  const int flags = fcntl(witness->tracked_fd, F_GETFL);
  return flags >= 0 && (flags & O_ACCMODE) == expected_fd_access(witness) &&
      (flags & O_PATH) == 0 && fstat(witness->tracked_fd, &value) == 0 &&
      S_ISREG(value.st_mode) && value.st_uid == g_uid && value.st_nlink == 1 &&
      value.st_dev == witness->device && value.st_ino == witness->inode;
}

int intercepted_open(const char* path, int flags, int mode) {
  const int incoming_errno = errno;
  lock();
  const OpenCall original = g_open;
  unlock();
  errno = incoming_errno;
  const int fd = original(path, flags, mode);
  const int result_errno = errno;
  lock();
  if (fd >= 0) {
    // A still-tracked numeric FD being returned by open proves a missed close
    // or unsupported FD reuse. Never infer identity from its pathname/inode.
    for (size_t i = 0; i < g_record_count; ++i) {
      if (g_records[i].tracked_fd == fd) {
        g_records[i].tracked_fd = -1;
        poison_locked();
      }
    }
  }
  OpenScope* scope = g_scope;
  if (scope && scope->witness->phase == Phase::opening) {
    AstoriaSqliteWitness* witness = scope->witness;
    if (!mechanism_locked()) {
      poison_locked();
    } else if (fd >= 0 && path && std::strcmp(path, witness->path) == 0) {
      ++witness->syscall_opens;
      witness->tracked_fd = fd;
      if (witness->syscall_opens != 1 || scope->file != witness->file ||
          (flags & O_ACCMODE) != expected_fd_access(witness) ||
          (flags & (O_CREAT | O_TRUNC | O_EXCL | O_PATH)) != 0 ||
          !fd_current(witness)) retire_locked(witness);
    }
  }
  unlock();
  errno = result_errno;
  return fd;
}

int intercepted_close(int fd) {
  const int incoming_errno = errno;
  AstoriaSqliteWitness* closed[kMaxRecords];
  size_t count = 0;
  lock();
  const CloseCall original = g_close;
  for (size_t i = 0; i < g_record_count; ++i) {
    AstoriaSqliteWitness* witness = &g_records[i];
    if (witness->tracked_fd == fd && fd >= 0) {
      closed[count++] = witness;
      // Retire BEFORE forwarding. Even a same-inode FD returned immediately
      // on another thread can never resurrect the old witness.
      retire_locked(witness);
      witness->tracked_fd = -1;
    }
  }
  unlock();
  errno = incoming_errno;
  const int result = original(fd);
  const int result_errno = errno;
  if (result != 0 && count != 0) {
    lock();
    for (size_t i = 0; i < count; ++i) closed[i]->ambiguous_close = true;
    // Do not retry close, restore hooks, or admit a new job after ambiguity.
    poison_locked();
    unlock();
  }
  errno = result_errno;
  return result;
}

int forwarded_open(Vfs* vfs, const char* path, File* file, int flags, int* out) {
  const int incoming_errno = errno;
  OpenScope scope{nullptr, file};
  OpenScope* previous = g_scope;
  lock();
  if (g_job && (flags & kFileTypeMask) == kMainDb && path &&
      std::strcmp(path, g_job->path) == 0) {
    AstoriaSqliteWitness* witness = g_job;
    ++witness->main_opens;
    // Even a refused overlapping open must keep its exact pending job busy
    // until the original stock delegate returns. Retired TLS cannot capture FD
    // authority, but it still owns this opening/drain observation.
    ++witness->opening;
    ++g_opening;
    scope.witness = witness;
    const bool mechanism_ok = mechanism_locked();
    if (vfs != &g_forward || !file || previous ||
        witness->phase != Phase::armed || witness->main_opens != 1 ||
        !main_flags(flags) || !mechanism_ok ||
        ((flags & kUri) == 0 && path[std::strlen(path) + 1] != '\0')) {
      if (!mechanism_ok) poison_locked();
      else retire_locked(witness);
    } else {
      witness->phase = Phase::opening;
      witness->file = file;
      witness->sqlite_flags = flags;
    }
  }
  unlock();
  // Always shadow outer TLS, even for an unrelated/nested xOpen. A syscall
  // from an unrelated file may not be attributed to the outer source file.
  g_scope = scope.witness ? &scope : nullptr;
  errno = incoming_errno;
  const int result = g_stock.xOpen(g_delegate, path, file, flags, out);
  const int result_errno = errno;
  g_scope = previous;
  if (scope.witness) {
    lock();
    AstoriaSqliteWitness* witness = scope.witness;
    --witness->opening;
    --g_opening;
    if (witness->phase == Phase::opening) {
      const bool mechanism_ok = mechanism_locked();
      if (result != kOk || witness->syscall_opens != 1 ||
          !out || !main_flags(*out) ||
          (*out & kAccessMask) != (witness->sqlite_flags & kAccessMask) ||
          !mechanism_ok ||
          !methods_supported(file->pMethods) || !fd_current(witness)) {
        if (!mechanism_ok) poison_locked();
        else retire_locked(witness);
      } else {
        witness->methods = file->pMethods;
        witness->methods_snapshot = *file->pMethods;
        witness->phase = Phase::captured;
      }
    }
    release_retired_job_locked(witness);
    unlock();
  }
  // Stock file size, pMethods, locking, caching and xClose are UNCHANGED.
  // An xOpen error retires the witness but is returned verbatim to SQLite.
  errno = result_errno;
  return result;
}

// Forward the complete public VFS, ALWAYS with the original delegate pointer.
// This preserves stock pAppData/locking-finder semantics, not only its name.
int forwarded_delete(Vfs*, const char* name, int sync) {
  return g_stock.xDelete(g_delegate, name, sync);
}
int forwarded_access(Vfs*, const char* name, int flags, int* out) {
  return g_stock.xAccess(g_delegate, name, flags, out);
}
int forwarded_full_path(Vfs*, const char* name, int size, char* out) {
  return g_stock.xFullPathname(g_delegate, name, size, out);
}
void* forwarded_dl_open(Vfs*, const char* name) {
  return g_stock.xDlOpen(g_delegate, name);
}
void forwarded_dl_error(Vfs*, int size, char* out) {
  g_stock.xDlError(g_delegate, size, out);
}
SystemCall forwarded_dl_sym(Vfs*, void* handle, const char* name) {
  return g_stock.xDlSym(g_delegate, handle, name);
}
void forwarded_dl_close(Vfs*, void* handle) { g_stock.xDlClose(g_delegate, handle); }
int forwarded_random(Vfs*, int size, char* out) {
  return g_stock.xRandomness(g_delegate, size, out);
}
int forwarded_sleep(Vfs*, int time) { return g_stock.xSleep(g_delegate, time); }
int forwarded_time(Vfs*, double* out) { return g_stock.xCurrentTime(g_delegate, out); }
int forwarded_error(Vfs*, int size, char* out) {
  return g_stock.xGetLastError(g_delegate, size, out);
}
int forwarded_time64(Vfs*, Int64* out) {
  return g_stock.xCurrentTimeInt64(g_delegate, out);
}
int owned_set_system_call(Vfs*, const char*, SystemCall) {
  // Do not permit any syscall-table mutation through our process-owned VFS.
  // Other unix variants expose the same global table: external mutation is
  // unsupported and an observed mismatch permanently poisons all authority.
  return kNotFound;
}
SystemCall forwarded_get_system_call(Vfs*, const char* name) {
  return g_stock.xGetSystemCall(g_delegate, name);
}
const char* forwarded_next_system_call(Vfs*, const char* name) {
  return g_stock.xNextSystemCall(g_delegate, name);
}

void configure_forwarder() {
  g_forward = g_stock;
  g_forward.zName = kVfsName;
  g_forward.xOpen = &forwarded_open;
  g_forward.xDelete = &forwarded_delete;
  g_forward.xAccess = &forwarded_access;
  g_forward.xFullPathname = &forwarded_full_path;
  if (g_stock.xDlOpen) {
    g_forward.xDlOpen = &forwarded_dl_open;
    g_forward.xDlError = &forwarded_dl_error;
    g_forward.xDlSym = &forwarded_dl_sym;
    g_forward.xDlClose = &forwarded_dl_close;
  }
  g_forward.xRandomness = &forwarded_random;
  g_forward.xSleep = &forwarded_sleep;
  g_forward.xCurrentTime = &forwarded_time;
  g_forward.xGetLastError = &forwarded_error;
  g_forward.xCurrentTimeInt64 = &forwarded_time64;
  g_forward.xSetSystemCall = &owned_set_system_call;
  g_forward.xGetSystemCall = &forwarded_get_system_call;
  g_forward.xNextSystemCall = &forwarded_next_system_call;
  g_forward_snapshot = g_forward;
}

int observe(AstoriaSqliteWitness* input, void* raw, bool claim,
            uint64_t device, uint64_t inode) {
  lock();
  AstoriaSqliteWitness* witness = known(input);
  if (!witness) { unlock(); return -1; }
  const bool phase_ok = claim ? witness->phase == Phase::captured :
      witness->phase == Phase::claimed;
  if (!phase_ok || !raw || (claim && g_job != witness) || witness->observers != 0 ||
      witness->opening != 0 || witness->main_opens != 1 ||
      witness->syscall_opens != 1 ||
      (!claim && (witness->raw != raw || device != witness->device ||
                  inode != witness->inode))) {
    retire_locked(witness);
    unlock();
    return -1;
  }
  if (!mechanism_locked()) {
    poison_locked();
    unlock();
    return -1;
  }
  if (claim) witness->phase = Phase::claiming;
  ++witness->observers;
  unlock();

  // Never hold our mutex while obtaining SQLite's connection/btree mutex.
  // Retirement observes the observer count and cannot grant close permission
  // while these public getters use raw. The caller must obey that permission.
  File* actual_file = nullptr;
  Vfs* actual_vfs = nullptr;
  const bool registry_ok = registry_current();
  const bool file_ok = registry_ok &&
      g_control(raw, "main", kFilePointer, &actual_file) == kOk;
  const bool vfs_ok = file_ok &&
      g_control(raw, "main", kVfsPointer, &actual_vfs) == kOk;
  lock();
  --witness->observers;
  const Phase expected_phase = claim ? Phase::claiming : Phase::claimed;
  bool ok = witness->phase == expected_phase && (!claim || g_job == witness);
  if (!registry_ok || !mechanism_locked()) {
    poison_locked();
    ok = false;
  }
  // Only after FILE_POINTER equality is it safe to inspect the recorded
  // public file/methods. No HAS_MOVED/pathname-equivalence substitute.
  ok = ok && vfs_ok && actual_file == witness->file &&
      actual_vfs == &g_forward && methods_current(witness) && fd_current(witness);
  if (ok && claim) {
    witness->raw = raw;
    witness->phase = Phase::claimed;
    // Free only the pending job slot. Previously claimed records keep their
    // own raw/file/method/FD observations and close-retirement independently.
    g_job = nullptr;
  } else if (!ok) {
    retire_locked(witness);
  }
  unlock();
  return ok ? 0 : -1;
}
}  // namespace

extern "C" int astoria_restore_sqlite_identity_abi(void) { return 1; }

extern "C" void* astoria_restore_sqlite_symbol(void* knownBackupAddress,
                                              const char* name) {
#if defined(RTLD_NOLOAD)
  if (!name || (std::strcmp(name, "sqlite3_vfs_find") != 0 &&
      std::strcmp(name, "sqlite3_file_control") != 0 &&
      std::strcmp(name, "sqlite3_txn_state") != 0)) return nullptr;
  void* module = nullptr;
  if (!named_api(knownBackupAddress, "sqlite3_backup_init", &module)) return nullptr;
  Dl_info anchor{};
  if (dladdr(knownBackupAddress, &anchor) == 0 || !anchor.dli_fname ||
      !*anchor.dli_fname || anchor.dli_fbase != module) return nullptr;
  // NOLOAD fails if this exact namespace/path cannot borrow the loaded asset.
  // Never retry without it, search other sonames, or use RTLD_DEFAULT.
  void* borrowed = dlopen(anchor.dli_fname, RTLD_NOW | RTLD_NOLOAD);
  if (!borrowed) return nullptr;
  void* symbol = dlsym(borrowed, name);
  void* symbol_module = module;
  const bool same_module = named_api(symbol, name, &symbol_module);
  const int released = dlclose(borrowed);
  // The native asset anchor retains the real module. This closes ONLY our
  // own NOLOAD reference, once; release ambiguity grants no symbol authority.
  return same_module && released == 0 ? symbol : nullptr;
#else
  (void)knownBackupAddress;
  (void)name;
  return nullptr;
#endif
}

extern "C" int astoria_restore_sqlite_install(
    void* backupInit, void* autoCommit, void* vfsFind, void* vfsRegister,
    void* fileControl, void* txnState) {
  void* addresses[] = {backupInit, autoCommit, vfsFind, vfsRegister, fileControl,
                       txnState};
  const char* names[] = {"sqlite3_backup_init", "sqlite3_get_autocommit",
      "sqlite3_vfs_find", "sqlite3_vfs_register", "sqlite3_file_control",
      "sqlite3_txn_state"};
  lock();
  if (g_setup != Setup::empty) {
    bool same = g_setup == Setup::ready;
    for (size_t i = 0; i < 6; ++i) same = same && addresses[i] == g_api_addresses[i];
    if (same && !mechanism_locked()) { poison_locked(); same = false; }
    unlock();
    return same ? 0 : -1;
  }
  g_setup = Setup::installing;
  unlock();
  void* module = nullptr;
  bool supported = getuid() == geteuid() && geteuid() != 0;
  for (size_t i = 0; i < 6; ++i)
    supported = supported && named_api(addresses[i], names[i], &module);
  Vfs* delegate = nullptr;
  const FindVfs find = reinterpret_cast<FindVfs>(vfsFind);
  const RegisterVfs register_vfs = reinterpret_cast<RegisterVfs>(vfsRegister);
  if (supported) {
    delegate = find("unix");
    supported = stock_supported(delegate, module) && !find(kVfsName);
  }
  if (!supported) {
    lock();
    poison_locked();
    unlock();
    return -1;
  }
  lock();
  g_delegate = delegate;
  copy_stock_vfs(&g_stock, delegate);
  g_module = module;
  g_find = find;
  g_control = reinterpret_cast<FileControl>(fileControl);
  g_open = reinterpret_cast<OpenCall>(g_stock.xGetSystemCall(delegate, "open"));
  g_close = reinterpret_cast<CloseCall>(g_stock.xGetSystemCall(delegate, "close"));
  g_uid = geteuid();
  for (size_t i = 0; i < 6; ++i) g_api_addresses[i] = addresses[i];
  configure_forwarder();
  unlock();
  // One startup installation only. Publish originals before installing each
  // hook, so even concurrent unrelated stock Unix calls forward correctly.
  // NEVER roll back a partially installed table or unregister this VFS.
  supported = g_stock.xSetSystemCall(delegate, "open",
      reinterpret_cast<SystemCall>(&intercepted_open)) == kOk;
  if (supported) supported = g_stock.xSetSystemCall(delegate, "close",
      reinterpret_cast<SystemCall>(&intercepted_close)) == kOk;
  if (supported) supported = register_vfs(&g_forward, 0) == kOk;
  if (supported) supported = registry_current();
  lock();
  g_setup = supported ? Setup::ready : Setup::poisoned;
  if (supported && !mechanism_locked()) { poison_locked(); supported = false; }
  unlock();
  return supported ? 0 : -1;
}

extern "C" AstoriaSqliteWitness* astoria_restore_sqlite_begin(
    const char* path, uint64_t device, uint64_t inode) {
  size_t length = 0;
  if (!path_valid(path, &length) || inode == 0) return nullptr;
  lock();
  if (g_setup != Setup::ready || g_job || g_opening ||
      g_record_count == kMaxRecords) { unlock(); return nullptr; }
  if (!mechanism_locked()) { poison_locked(); unlock(); return nullptr; }
  if (length > static_cast<size_t>(g_stock.mxPathname)) { unlock(); return nullptr; }
  // Reserve first, then validate registry outside the mutex. No other begin
  // can steal this slot; record storage is never reused after any failure.
  AstoriaSqliteWitness* witness = &g_records[g_record_count++];
  witness->phase = Phase::reserved;
  std::memcpy(witness->path, path, length + 1);
  witness->device = device;
  witness->inode = inode;
  witness->tracked_fd = -1;
  g_job = witness;
  ++witness->observers;
  // Do not arm until registry validation finishes; an overlapping xOpen of
  // this exact source fails closed instead of silently joining this job.
  unlock();
  const bool registry_ok = registry_current();
  lock();
  --witness->observers;
  bool ok = registry_ok && mechanism_locked() && witness == g_job &&
      witness->phase == Phase::reserved;
  if (!registry_ok || !mechanism_locked()) { poison_locked(); ok = false; }
  if (ok) witness->phase = Phase::armed;
  else retire_locked(witness);
  unlock();
  return ok ? witness : nullptr;
}

extern "C" int astoria_restore_sqlite_claim(AstoriaSqliteWitness* witness,
                                           void* raw) {
  return observe(witness, raw, true, 0, 0);
}

extern "C" int astoria_restore_sqlite_check(AstoriaSqliteWitness* witness,
    void* raw, uint64_t device, uint64_t inode) {
  return observe(witness, raw, false, device, inode);
}

extern "C" int astoria_restore_sqlite_retire(AstoriaSqliteWitness* input) {
  lock();
  AstoriaSqliteWitness* witness = known(input);
  if (!witness) { unlock(); return -1; }
  retire_locked(witness);
  const bool drained = witness->observers == 0 && witness->opening == 0;
  unlock();
  return drained ? 0 : -1;
}
