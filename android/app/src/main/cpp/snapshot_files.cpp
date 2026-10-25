#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
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
  *pin = {fd, 1, false, false, false, value.st_dev, value.st_ino, parent, owned_name};
  if (parent) ++parent->refs;
  return pin;
}

int release(Pin* pin) {
  if (!pin || pin->unknown_close) return -1;
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
  Pin* result = retain(openat(parent->fd, name, O_RDONLY | O_NOFOLLOW |
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
  // No writing API is exported. SQLite's destination must already be closed.
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
