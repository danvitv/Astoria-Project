#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#define EXPORTED extern "C" __attribute__((visibility("default")))

namespace {
struct Pin {
  int fd;
  unsigned refs;
  bool unknown_close;
  bool sealed;
  bool published;
  // Android's 32-bit stat still returns full 64-bit identities. Do not narrow
  // through the older dev_t / ino_t aliases and accept an inode collision.
  uint64_t device;
  uint64_t inode;
  Pin* parent;
  char* name;
  // Restore capabilities are separate from the snapshot seal/publish protocol.
  // Metadata proofs use O_PATH: closing one must not drop SQLite's process-wide
  // POSIX record locks on the live main database.
  bool restore_owned;
  bool restore_readable;
  bool restore_writable;
  bool restore_deleted;
  bool restore_uncertain;
};

bool component(const char* name) {
  if (!name || !*name || std::strlen(name) > 128 ||
      std::strcmp(name, ".") == 0 || std::strcmp(name, "..") == 0) return false;
  return std::strchr(name, '/') == nullptr;
}

bool info(Pin* pin, struct stat* result) {
  return pin && !pin->unknown_close && pin->fd >= 0 &&
      fstat(pin->fd, result) == 0 && result->st_dev == pin->device &&
      result->st_ino == pin->inode;
}

bool current(Pin* pin) {
  struct stat value{};
  if (!info(pin, &value)) return false;
  if (pin->parent) {
    if (!current(pin->parent)) return false;
    struct stat named{};
    if (fstatat(pin->parent->fd, pin->name, &named, AT_SYMLINK_NOFOLLOW) != 0 ||
        named.st_dev != value.st_dev || named.st_ino != value.st_ino ||
        S_ISLNK(named.st_mode)) return false;
  }
  return true;
}

Pin* retain(int fd, Pin* parent, const char* name) {
  if (fd < 0) return nullptr;
  struct stat value{};
  if (fstat(fd, &value) != 0) {
    close(fd);
    return nullptr;
  }
  auto* pin = static_cast<Pin*>(std::calloc(1, sizeof(Pin)));
  char* owned_name = name ? ::strdup(name) : nullptr;
  if (!pin || (name && !owned_name)) {
    std::free(pin);
    std::free(owned_name);
    close(fd);
    return nullptr;
  }
  *pin = {fd, 1, false, false, false, value.st_dev, value.st_ino, parent, owned_name,
      false, false, false, false, false};
  if (parent) ++parent->refs;
  return pin;
}

int release(Pin* pin) {
  if (!pin || pin->unknown_close || pin->restore_uncertain) return -1;
  if (pin->refs > 1) {
    --pin->refs;
    return 0;
  }
  // Linux close must not be retried after an ambiguous error: the numeric fd
  // may already have been reused. Preserve the unknown capability instead.
  const int fd = pin->fd;
  pin->fd = -1;
  if (close(fd) != 0) {
    pin->unknown_close = true;
    return -1;
  }
  Pin* parent = pin->parent;
  if (parent && release(parent) != 0) {
    // Keep THIS pointer valid on failure too. Dart must never receive an error
    // for an already-freed capability and then accidentally retry a stale fd.
    pin->unknown_close = true;
    return -1;
  }
  std::free(pin->name);
  std::free(pin);
  return 0;
}

Pin* canonical_root(const char* path, unsigned forbidden_mode) {
  if (!path || path[0] != '/' || std::strlen(path) > 4096) return nullptr;
  char* spelling = ::strdup(path + 1);
  if (!spelling) return nullptr;
  Pin* pin = retain(open("/", O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
      nullptr, nullptr);
  char* state = nullptr;
  for (char* name = strtok_r(spelling, "/", &state); name && pin;
       name = strtok_r(nullptr, "/", &state)) {
    if (!component(name)) { release(pin); pin = nullptr; break; }
    Pin* next = retain(openat(pin->fd, name, O_PATH | O_DIRECTORY |
        O_NOFOLLOW | O_CLOEXEC), pin, name);
    const int closed = release(pin);
    pin = next;
    if (closed != 0) { if (pin) release(pin); pin = nullptr; }
  }
  std::free(spelling);
  struct stat value{};
  if (pin && (!info(pin, &value) || value.st_uid != getuid() ||
      (value.st_mode & forbidden_mode) != 0)) { release(pin); pin = nullptr; }
  return pin;
}
}  // namespace

EXPORTED int astoria_snapshot_abi() { return 1; }
EXPORTED void* astoria_snapshot_allocate(uint64_t size) {
  return size > 0 && size <= 65536 ? std::calloc(1, static_cast<size_t>(size)) : nullptr;
}
EXPORTED void astoria_snapshot_free(void* memory) { std::free(memory); }

// The root spelling comes ONLY from the Android application's own Context.
// Walk from / with openat and NOFOLLOW; never resolve an arbitrary model path.
EXPORTED Pin* astoria_snapshot_root(const char* path) {
  if (!path || path[0] != '/' || std::strlen(path) > 4096) return nullptr;
  char* spelling = ::strdup(path + 1);
  if (!spelling) return nullptr;
  Pin* pin = retain(open("/", O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), nullptr, nullptr);
  char* state = nullptr;
  for (char* name = strtok_r(spelling, "/", &state); name && pin;
       name = strtok_r(nullptr, "/", &state)) {
    if (!component(name)) { release(pin); pin = nullptr; break; }
    Pin* next = retain(openat(pin->fd, name, O_PATH | O_DIRECTORY |
        O_NOFOLLOW | O_CLOEXEC), pin, name);
    const int closed = release(pin);
    pin = next;
    if (closed != 0) { if (pin) release(pin); pin = nullptr; }
  }
  std::free(spelling);
  struct stat value{};
  if (pin && (!info(pin, &value) || value.st_uid != getuid() ||
      (value.st_mode & 0077) != 0)) { release(pin); pin = nullptr; }
  return pin;
}

EXPORTED Pin* astoria_snapshot_directory(Pin* parent, const char* name, int create) {
  if (!component(name) || !current(parent)) return nullptr;
  if (create && mkdirat(parent->fd, name, 0700) != 0 &&
      (create == 2 || errno != EEXIST)) return nullptr;
  Pin* result = retain(openat(parent->fd, name, O_PATH | O_DIRECTORY |
      O_NOFOLLOW | O_CLOEXEC), parent, name);
  struct stat value{};
  if (result && (!info(result, &value) || value.st_uid != getuid() ||
      (value.st_mode & 0022) != 0)) { release(result); result = nullptr; }
  return result;
}

EXPORTED Pin* astoria_snapshot_stage(Pin* parent, const char* name) {
  if (!component(name) || !current(parent)) return nullptr;
  return retain(openat(parent->fd, name, O_RDWR | O_CREAT | O_EXCL |
      O_NOFOLLOW | O_CLOEXEC, 0600), parent, name);
}

EXPORTED Pin* astoria_snapshot_file(Pin* parent, const char* name) {
  if (!component(name) || !current(parent)) return nullptr;
  Pin* result = retain(openat(parent->fd, name, O_PATH | O_NOFOLLOW |
      O_CLOEXEC), parent, name);
  struct stat value{};
  if (result && (!info(result, &value) || !S_ISREG(value.st_mode) ||
      value.st_uid != getuid() || value.st_nlink != 1)) {
    release(result);
    result = nullptr;
  }
  return result;
}

// Fixed-width output avoids exposing libc's architecture-specific stat layout.
EXPORTED int astoria_snapshot_info(Pin* pin, uint64_t* output) {
  struct stat value{};
  if (!output || !current(pin) || !info(pin, &value) || value.st_size < 0) return -1;
  output[0] = static_cast<uint64_t>(value.st_dev);
  output[1] = static_cast<uint64_t>(value.st_ino);
  output[2] = static_cast<uint64_t>(value.st_mode);
  output[3] = static_cast<uint64_t>(value.st_uid);
  output[4] = static_cast<uint64_t>(value.st_nlink);
  output[5] = static_cast<uint64_t>(value.st_size);
  return 0;
}

EXPORTED int astoria_snapshot_seal(Pin* pin) {
  struct stat value{};
  if (!current(pin) || !info(pin, &value) || !S_ISREG(value.st_mode) ||
      value.st_nlink != 1 || fchmod(pin->fd, 0400) != 0) return -1;
  // Snapshot stages have no restore-write capability. SQLite's destination must
  // already be closed before this snapshot seal is issued.
  pin->sealed = true;
  return 0;
}

EXPORTED int64_t astoria_snapshot_read(Pin* pin, uint8_t* bytes,
                                     uint64_t size, uint64_t offset) {
  if (!pin || !pin->sealed || !bytes || size == 0 || size > 65536 ||
      offset > 268435456 || !current(pin)) return -1;
  return static_cast<int64_t>(pread(pin->fd, bytes, static_cast<size_t>(size),
      static_cast<off_t>(offset)));
}

EXPORTED int astoria_snapshot_publish(Pin* pin, const char* destination) {
  if (!pin || !pin->sealed || pin->published || !component(destination) ||
      !pin->parent || !current(pin)) return -1;
  char* next_name = ::strdup(destination);
  if (!next_name) return -1;
  if (linkat(pin->parent->fd, pin->name, pin->parent->fd, destination, 0) != 0) {
    std::free(next_name);
    return -1;  // Atomic no-replace, including a concurrent existing name.
  }
  // The link is the linearization point. Never report that nothing was saved
  // after this line, including an owned-stage unlink failure.
  pin->published = true;
  const int removed = unlinkat(pin->parent->fd, pin->name, 0);
  std::free(pin->name);
  pin->name = next_name;
  return removed == 0 ? 0 : 1;
}

EXPORTED int astoria_snapshot_discard(Pin* pin) {
  if (!pin || pin->published || !pin->parent || !current(pin)) return -1;
  return unlinkat(pin->parent->fd, pin->name, 0);
}
EXPORTED int astoria_snapshot_discard_directory(Pin* pin) {
  struct stat value{};
  if (!pin || !pin->parent || !current(pin) || !info(pin, &value) ||
      !S_ISDIR(value.st_mode)) return -1;
  return unlinkat(pin->parent->fd, pin->name, AT_REMOVEDIR);
}
EXPORTED int astoria_snapshot_close(Pin* pin) { return release(pin); }

namespace {
constexpr uint64_t kRestoreMaxBytes = 268435456;
constexpr const char* kRestoreLock = ".astoria-restore-startup.lock";

bool restore_mode(const struct stat& value, bool directory) {
  return value.st_uid == getuid() && (value.st_mode & 0022) == 0 &&
      (directory ? S_ISDIR(value.st_mode) :
          (S_ISREG(value.st_mode) && value.st_nlink == 1));
}

bool restore_info(Pin* pin, struct stat* value, bool directory) {
  return pin && !pin->restore_uncertain && current(pin) && info(pin, value) &&
      restore_mode(*value, directory);
}

// Allocate custody BEFORE the exclusive creation syscall. On a later metadata
// failure return this original capsule, not an unowned artifact or a reused fd.
Pin* prepare_restore(Pin* parent, const char* name) {
  auto* pin = static_cast<Pin*>(std::calloc(1, sizeof(Pin)));
  char* spelling = ::strdup(name);
  if (!pin || !spelling) {
    std::free(pin);
    std::free(spelling);
    return nullptr;
  }
  pin->fd = -1;
  pin->refs = 1;
  pin->parent = parent;
  pin->name = spelling;
  ++parent->refs;
  return pin;
}

// Only for capsules whose syscall did NOT create or acquire an artifact.
void abandon_unopened(Pin* pin) {
  if (!pin) return;
  // The caller still holds its own parent reference; this cannot close its fd.
  --pin->parent->refs;
  std::free(pin->name);
  std::free(pin);
}

bool admit_restore_fd(Pin* pin, bool directory) {
  struct stat value{};
  if (pin->fd < 0 || fstat(pin->fd, &value) != 0) return false;
  pin->device = value.st_dev;
  pin->inode = value.st_ino;
  return restore_mode(value, directory) && current(pin);
}

bool sync_restore_directory(Pin* pin) {
  struct stat value{};
  if (!restore_info(pin, &value, true)) return false;
  // O_PATH itself cannot be fsynced. Open ONLY this directory, verify the exact
  // inode, consume the fd before close, and never retry an ambiguous close.
  int fd = openat(pin->fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return false;
  struct stat actual{};
  const bool synced = fstat(fd, &actual) == 0 &&
      actual.st_dev == value.st_dev && actual.st_ino == value.st_ino &&
      restore_mode(actual, true) && fsync(fd) == 0;
  const int consumed = fd;
  fd = -1;
  if (close(consumed) != 0) {
    pin->unknown_close = true;
    return false;
  }
  return synced && current(pin);
}
}  // namespace

EXPORTED uint64_t astoria_restore_uid() { return static_cast<uint64_t>(getuid()); }

// Restore admits app-owned read/traverse permissions but never group/other
// writing. The snapshot export above keeps its original private-root policy.
EXPORTED Pin* astoria_restore_root(const char* path) {
  return canonical_root(path, 0022);
}

// Missing means ONLY ENOENT for this known no-follow component. ENOTDIR, ACL,
// symlink, hard link, foreign uid, writable namespace and all other errors refuse.
EXPORTED int astoria_restore_entry_kind(Pin* parent, const char* name) {
  struct stat value{};
  if (!component(name) || !restore_info(parent, &value, true)) return -1;
  if (fstatat(parent->fd, name, &value, AT_SYMLINK_NOFOLLOW) != 0)
    return errno == ENOENT ? 0 : -1;
  if (S_ISDIR(value.st_mode)) return restore_mode(value, true) ? 1 : -1;
  return restore_mode(value, false) ? 2 : -1;
}

// This reader is ONLY for a distinct, preflighted immutable candidate. Metadata
// identity on a live SQLite main must continue to use astoria_snapshot_file.
EXPORTED Pin* astoria_restore_candidate_file(Pin* parent, const char* name,
                                            int* status) {
  if (!status) return nullptr;
  *status = -1;
  struct stat before{};
  if (!component(name) || !restore_info(parent, &before, true) ||
      fstatat(parent->fd, name, &before, AT_SYMLINK_NOFOLLOW) != 0 ||
      !restore_mode(before, false)) return nullptr;
  Pin* result = prepare_restore(parent, name);
  if (!result) return nullptr;
  result->fd = openat(parent->fd, name,
      O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
  if (result->fd < 0) { abandon_unopened(result); return nullptr; }
  struct stat value{};
  if (!admit_restore_fd(result, false) || !info(result, &value) ||
      value.st_dev != before.st_dev || value.st_ino != before.st_ino) {
    result->restore_uncertain = true;
    return result;
  }
  result->restore_readable = true;
  *status = 0;
  return result;
}

// status: 0 acquired, 1 actual EWOULDBLOCK/EAGAIN, -1 other refusal. The fixed
// root lock is never a PID lease and is never unlinked. A returned failure
// capsule represents uncertain custody and must remain retained, not retried.
EXPORTED Pin* astoria_restore_startup_lock(Pin* root, int* status) {
  if (!status) return nullptr;
  *status = -1;
  struct stat value{};
  if (!restore_info(root, &value, true)) return nullptr;
  Pin* pin = prepare_restore(root, kRestoreLock);
  if (!pin) return nullptr;
  pin->fd = openat(root->fd, kRestoreLock,
      O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (pin->fd < 0) { abandon_unopened(pin); return nullptr; }
  if (!admit_restore_fd(pin, false)) {
    pin->restore_uncertain = true;
    return pin;
  }
  if (flock(pin->fd, LOCK_EX | LOCK_NB) != 0) {
    const int conflict = errno;
    // Only this non-SQLite lock inode is closed on a known lock refusal.
    if (release(pin) != 0) return pin;
    *status = conflict == EWOULDBLOCK || conflict == EAGAIN ? 1 : -1;
    return nullptr;
  }
  if (!current(pin)) { pin->restore_uncertain = true; return pin; }
  *status = 0;
  return pin;
}

EXPORTED Pin* astoria_restore_create_directory(Pin* parent, const char* name,
                                               int* status) {
  if (!status) return nullptr;
  *status = -1;
  struct stat value{};
  if (!component(name) || !restore_info(parent, &value, true)) return nullptr;
  Pin* pin = prepare_restore(parent, name);
  if (!pin) return nullptr;
  if (mkdirat(parent->fd, name, 0700) != 0) {
    abandon_unopened(pin);
    return nullptr;
  }
  pin->restore_owned = true;
  pin->fd = openat(parent->fd, name, O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (!admit_restore_fd(pin, true) || !info(pin, &value) ||
      (value.st_mode & 0777) != 0700) {
    pin->restore_uncertain = true;
    return pin;
  }
  // A failed sync keeps the exact new directory's O_PATH ownership proof.
  if (sync_restore_directory(parent)) *status = 0;
  return pin;
}

EXPORTED Pin* astoria_restore_create_file(Pin* parent, const char* name,
                                         Pin** proof, int* status) {
  if (!proof || !status) return nullptr;
  *proof = nullptr;
  *status = -1;
  struct stat value{};
  if (!component(name) || !restore_info(parent, &value, true)) return nullptr;
  Pin* writer = prepare_restore(parent, name);
  if (!writer) return nullptr;
  Pin* metadata = prepare_restore(parent, name);
  if (!metadata) { abandon_unopened(writer); return nullptr; }
  writer->fd = openat(parent->fd, name,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (writer->fd < 0) {
    abandon_unopened(metadata);
    abandon_unopened(writer);
    return nullptr;
  }
  writer->restore_owned = true;
  writer->restore_readable = true;
  writer->restore_writable = true;
  metadata->restore_owned = true;
  *proof = metadata;  // Always transfer post-creation custody, even on failure.
  metadata->fd = openat(parent->fd, name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
  if (!admit_restore_fd(writer, false) || !admit_restore_fd(metadata, false) ||
      writer->device != metadata->device || writer->inode != metadata->inode) {
    writer->restore_uncertain = true;
    metadata->restore_uncertain = true;
    return writer;
  }
  if (sync_restore_directory(parent)) *status = 0;
  return writer;
}

EXPORTED int64_t astoria_restore_pread(Pin* pin, uint8_t* bytes,
                                     uint64_t size, uint64_t offset) {
  struct stat value{};
  if (!pin || !pin->restore_readable || !bytes || size == 0 || size > 65536 ||
      offset > kRestoreMaxBytes || size > kRestoreMaxBytes + 1 - offset ||
      !restore_info(pin, &value, false) || (fcntl(pin->fd, F_GETFL) & O_PATH) != 0)
    return -1;
  return static_cast<int64_t>(pread(pin->fd, bytes, static_cast<size_t>(size),
      static_cast<off_t>(offset)));
}

EXPORTED int64_t astoria_restore_pwrite(Pin* pin, const uint8_t* bytes,
                                      uint64_t size, uint64_t offset) {
  struct stat value{};
  if (!pin || !pin->restore_owned || !pin->restore_writable || pin->sealed ||
      pin->published || !bytes ||
      size == 0 || size > 65536 || offset > kRestoreMaxBytes ||
      size > kRestoreMaxBytes - offset || !restore_info(pin, &value, false) ||
      (fcntl(pin->fd, F_GETFL) & O_PATH) != 0) return -1;
  return static_cast<int64_t>(pwrite(pin->fd, bytes, static_cast<size_t>(size),
      static_cast<off_t>(offset)));
}

EXPORTED int astoria_restore_sync_file(Pin* pin) {
  struct stat value{};
  return pin && pin->restore_owned && pin->restore_writable &&
      restore_info(pin, &value, false) && fdatasync(pin->fd) == 0 &&
      fsync(pin->fd) == 0 && current(pin) ? 0 : -1;
}

EXPORTED int astoria_restore_sync_parent(Pin* pin) {
  return pin && pin->parent && sync_restore_directory(pin->parent) ? 0 : -1;
}

EXPORTED int astoria_restore_sync_directory(Pin* pin) {
  return sync_restore_directory(pin) ? 0 : -1;
}

EXPORTED int astoria_restore_delete_owned(Pin* proof, int directory) {
  struct stat value{};
  if (!proof || !proof->restore_owned || proof->restore_uncertain ||
      !proof->parent || !info(proof, &value) ||
      ((fcntl(proof->fd, F_GETFL) & O_PATH) == 0) ||
      (directory ? !S_ISDIR(value.st_mode) : !S_ISREG(value.st_mode))) return -1;
  // A successful unlink followed by failed parent sync is NOT retried against
  // the old name. The original metadata tombstone remains live until release.
  if (proof->restore_deleted)
    return sync_restore_directory(proof->parent) ? 0 : -1;
  if (!restore_info(proof, &value, directory != 0) ||
      unlinkat(proof->parent->fd, proof->name, directory ? AT_REMOVEDIR : 0) != 0)
    return -1;
  proof->restore_deleted = true;
  return sync_restore_directory(proof->parent) ? 0 : -1;
}
