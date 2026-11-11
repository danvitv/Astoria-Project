# Pinned SQLite build input

Unmodified official SQLite **3.53.1** amalgamation, acquired from the official
2026 archive. `PROVENANCE.json` records the acquisition URL, exact source ID,
locally computed archive/header hashes and the **upstream-published C SHA3-256**.
That published C digest was verified before configuring the build. No published
archive digest was located; local archive hashes are not claimed upstream-issued.
The archive is retained as acquired; only C and the two headers were extracted.
There is no authored C, alternative library, copied Astoria implementation or
dependency version change here.

## Platform-aware build entrypoint

The installed `sqlite3` 3.3.2 source hook owns the same sole asset:
`package:sqlite3/src/ffi/libsqlite3.g.dart`. It accepts only a flat defines map.
Disabling defaults is necessary to remove `SQLITE_OMIT_PROGRESS_CALLBACK`; a
null override does **not** undefine it. The explicit list retains **every other
installed default**. The authored build entrypoint `tool/sqlite3_source.c` includes
this unmodified official amalgamation and defines
`SQLITE_API=__declspec(dllexport)` **only when the compiler targets Windows**
(`_WIN32`). Android compilation, including cross-compilation on a Windows host,
does not receive that declaration. No package cache or global SDK configuration
is modified.

The ARM64 Android wrapper (`scripts/build_android_arm64.ps1`), Windows builds
and native checks use the same checked-in hook configuration. **No SQLite hook
target selection or restoration is required.** To verify the pin and restore its
marked configuration if necessary, use the installed Dart executable directly
(not `dart run`, which may build native assets):

```powershell
& 'Z:/GlazeProject/flutter/bin/cache/dart-sdk/bin/dart.exe' --packages=.dart_tool/package_config.json tool/configure_source_sqlite.dart
```

The script verifies pinned source/header SHA256 and source/version identity,
then changes **only** its marked pubspec hook section. It performs no native
build/probe/download. Legacy `windows` and `android` arguments remain accepted,
but both now produce the identical platform-aware configuration. Dependencies,
lockfile and upstream source stay unchanged.

Windows/Android compilation and native symbol, BLOB, allocation, progress,
migration, readiness and actual model integration evidence remain main-owned.
Compiler configuration alone proves none of them. This does not claim hard
blocked OS-I/O interruption or bounded distant-cell traversal. Linux is not an
accepted target here: the installed source hook's linker export allowlist does
not include the additional Astoria interfaces; the preparation script does not
accept Linux as a target.

## Paused checkpoint

`ASTORIA_SOURCE_NAVIGATION_EXPERIMENTAL` defaults to false. The unfinished four
source-navigation tools and local history-preparation entry are not exposed in
the checkpoint APK. Source code and schema 138 are retained for later work;
the current index-ready test still returns `incomplete`. Do not treat a successful
build or an explicit opt-in as native source-feature verification.
