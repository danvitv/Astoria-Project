# Pinned SQLite build input

Unmodified official SQLite **3.53.1** amalgamation, acquired from the official
2026 archive. `PROVENANCE.json` records the acquisition URL, exact source ID,
locally computed archive/header hashes and the **upstream-published C SHA3-256**.
That published C digest was verified before configuring the build. No published
archive digest was located; local archive hashes are not claimed upstream-issued.
The archive is retained as acquired; only C and the two headers were extracted.
There is no authored C, alternative library, copied Astoria implementation or
dependency version change here.

## Target-specific preparation (required before native checks/builds)

The installed `sqlite3` 3.3.2 source hook owns the same sole asset:
`package:sqlite3/src/ffi/libsqlite3.g.dart`. It accepts only a flat defines map.
Disabling defaults is necessary to remove `SQLITE_OMIT_PROGRESS_CALLBACK`; a
null override does **not** undefine it. The explicit list retains **every other
installed default**, adding `SQLITE_API=__declspec(dllexport)` **only on Windows**.
No package cache or global SDK configuration is modified.

Use the installed Dart executable directly (not `dart run`, which may build
native assets) to select the target before main-owned checks/builds:

```powershell
& 'Z:/GlazeProject/flutter/bin/cache/dart-sdk/bin/dart.exe' --packages=.dart_tool/package_config.json tool/configure_source_sqlite.dart windows
# Before Android compilation, select android instead:
& 'Z:/GlazeProject/flutter/bin/cache/dart-sdk/bin/dart.exe' --packages=.dart_tool/package_config.json tool/configure_source_sqlite.dart android
```

The script verifies pinned source/header SHA256 and source/version identity,
then changes **only** its marked pubspec hook section. It performs no native
build/probe/download. The checked-in configuration is Windows, including the
required DLL exports. Select Android explicitly before an APK build, then restore
Windows immediately afterwards; leaving Android defines active breaks Windows
SQLite loading. Target selection is explicit, not an automatic platform-aware hook.
Do not build Android with the Windows configuration. Select Windows again before
Windows evidence. Dependencies, lockfile and upstream source stay unchanged.

Windows/Android compilation and native symbol, BLOB, allocation, progress,
migration, readiness and actual model integration evidence remain main-owned.
Compiler configuration alone proves none of them. This does not claim hard
blocked OS-I/O interruption or bounded distant-cell traversal. Linux is not an
accepted target here: the installed source hook's linker export allowlist does
not include the additional Astoria interfaces; the selector refuses Linux.

## Paused checkpoint

`ASTORIA_SOURCE_NAVIGATION_EXPERIMENTAL` defaults to false. The unfinished four
source-navigation tools and local history-preparation entry are not exposed in
the checkpoint APK. Source code and schema 138 are retained for later work;
the current index-ready test still returns `incomplete`. Do not treat a successful
build or an explicit opt-in as native source-feature verification.
