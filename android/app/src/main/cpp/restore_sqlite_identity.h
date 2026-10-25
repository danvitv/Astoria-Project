#ifndef ASTORIA_RESTORE_SQLITE_IDENTITY_H
#define ASTORIA_RESTORE_SQLITE_IDENTITY_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define ASTORIA_SQLITE_IDENTITY_EXPORT __attribute__((visibility("default")))

typedef struct AstoriaSqliteWitness AstoriaSqliteWitness;

ASTORIA_SQLITE_IDENTITY_EXPORT int astoria_restore_sqlite_identity_abi(void);

// Borrow an already-loaded module using the named sqlite3_backup_init anchor.
// ONLY vfs_find/file_control/txn_state are resolvable. RTLD_NOLOAD is mandatory:
// no blind process lookup, absent-module load, or alternate-library fallback.
// The caller's native asset must retain that module for the process lifetime.
// The bridge releases only its temporary NOLOAD reference. Null is unsupported.
ASTORIA_SQLITE_IDENTITY_EXPORT void* astoria_restore_sqlite_symbol(
    void* knownBackupAddress, const char* name);

// Addresses must be the six named C APIs of the SAME already-loaded SQLite
// module used by package:sqlite3. No SQLite library is loaded by this bridge.
// Call once before database admission. Success is 0; unsupported/failure is -1.
// Installation (including a partially failed installation) is process-owned;
// do not unload either module, shut SQLite down, or change its syscall table.
ASTORIA_SQLITE_IDENTITY_EXPORT int astoria_restore_sqlite_install(
    void* backupInit, void* autoCommit, void* vfsFind, void* vfsRegister,
    void* fileControl, void* txnState);

// Only one pending open job is admitted; independently claimed witnesses may
// remain live together (candidate RO, target RW, logical-original RW).
// Use a fresh READONLY or READWRITE-without-CREATE connection explicitly
// selecting VFS "astoria_restore_unix". Empty, already-owned regular files
// are supported; creating a file through SQLite is not.
// A URI is supported ONLY under the trusted Root caller contract: Root builds
// it from this canonical path with fixed cache=private and optional immutable=1
// for the RO candidate, never arbitrary/model-provided query parameters.
// xOpen's decoded canonical pathname must still match this path exactly.
// Private cache and the fixed URI parameter policy are caller prerequisites:
// stock SQLite masks cache/mutex flags before xOpen, and this bridge does not
// parse URI storage or infer private Unix state. It only observes public flags,
// the actual file pointer, unchanged methods, and the actual borrowed FD.
// begin may run on a different thread from SQLite's subsequent xOpen.
// The caller owns canonical path/ancestor O_PATH pins and keeps them alive.
// A null result grants no authority. At most 256 records exist per process;
// records/paths are retained forever and never reused, including on failure.
ASTORIA_SQLITE_IDENTITY_EXPORT AstoriaSqliteWitness*
astoria_restore_sqlite_begin(const char* canonicalAbsolutePath,
                            uint64_t expectedDevice, uint64_t expectedInode);

// claim is one-use and ends the arm even on failure; its pending job remains
// reserved until observation finishes, so another begin cannot overlap it.
// A successful claim releases that job slot, NOT other claimed witnesses.
// Pass a LIVE raw handle
// from that exact fresh open. Neither claim nor check reads database pages,
// starts a transaction, duplicates, opens, or closes the borrowed SQLite FD.
// Success is 0; failure is -1 and permanently retires the witness.
ASTORIA_SQLITE_IDENTITY_EXPORT int astoria_restore_sqlite_claim(
    AstoriaSqliteWitness* witness, void* rawSqlite);
ASTORIA_SQLITE_IDENTITY_EXPORT int astoria_restore_sqlite_check(
    AstoriaSqliteWitness* witness, void* rawSqlite,
    uint64_t expectedDevice, uint64_t expectedInode);

// ALWAYS retire before any raw-handle close (including open/claim failure),
// detach, or other operation that can replace main's sqlite3_file. Retirement
// revokes authority immediately and never frees the record. 0 means native
// observers/xOpen have drained and raw close is permitted; -1 means invalid
// record OR an observer/xOpen is still in flight: DO NOT close, retry later.
// Retrying retirement is safe, but can never re-arm/re-claim a record.
// Serialize other operations on the same raw handle with these observations;
// this bridge is not a sqlite3 connection mutex or an atomic backup admission.
ASTORIA_SQLITE_IDENTITY_EXPORT int astoria_restore_sqlite_retire(
    AstoriaSqliteWitness* witness);

#undef ASTORIA_SQLITE_IDENTITY_EXPORT

#if defined(__cplusplus)
}
#endif

#endif  // ASTORIA_RESTORE_SQLITE_IDENTITY_H
