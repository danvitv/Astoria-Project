# Astoria: Android existing-only secure-storage read

## Provenance and vendoring boundary

Base: the installed public `flutter_secure_storage` **10.3.4** package at
`Z:/Pub/Cache/hosted/pub.dev/flutter_secure_storage-10.3.4`.
Copied `lib/`, `android/` (including its existing tests and Gradle configuration),
`pubspec.yaml`, `LICENSE`, and `README.md` into this project-local directory.
The example app and package-root test/documentation ecosystem were not vendored.
Upstream `LICENSE` is unchanged; only trailing whitespace was trimmed in `README.md`.
The upstream package name,
version, dependencies, plugin registration, platform delegation, Android package,
SDK/Gradle configuration and namespace conventions are unchanged.
The shared Pub cache was not edited.

## Public API and channel contract

```dart
Future<String?> FlutterSecureStorage.readExisting({
  required String key,
  AndroidOptions? aOptions,
})
```

Android only; elsewhere this throws `UnsupportedError('unsupported_platform')`
without invoking a channel. Android uses the original plugin method channel
`plugins.it_nomads.com/flutter_secure_storage`, with a distinct `readExisting`
method and the ordinary `key` / `options` payload. It deliberately bypasses
`FlutterSecureStoragePlatform` and its ordinary-read mocks/fallbacks. Application
tests should mock this channel method explicitly.

The native method is dispatched on the existing worker **before** config/cache
lookup, normal storage construction/initialization, recovery, migration, or the
ordinary reset-on-error handler. It never retrieves or publishes a cached
`FlutterSecureStorage`. A warm normal instance gives it no additional permission.
It neither calls ordinary `read` nor notifies Dart write/delete listeners.

All Android-path Dart/native failures expose only:

- code: `READ_EXISTING_FAILED`
- message: `Existing secure storage is unavailable.`
- details: null

No new runtime path logs a key, namespace, value, exception body, cause, or stack
trace. Config warning output is disabled only for this new path. Dart also
redacts missing-plugin errors, invalid channel responses and platform error
bodies. A value is returned to the caller only on successful authenticated
decryption and strict UTF-8 decoding. Empty plaintext is valid.

## Existing-only eligibility and limits

- Support is intentionally limited to explicit, per-data-backend markers
  `RSA_ECB_OAEPwithSHA_256andMGF1Padding` + `AES_GCM_NoPadding` on API 23+.
  Requested algorithm preferences do **not** choose the cipher or rewrite the
  saved algorithm. No legacy-global marker fallback, marker adoption, guessed
  defaults, probing alternative algorithms or namespace recovery occurs.
- Data, key and configuration XML must already exist at the ordinary Android
  preference paths. A `.xml.bak` recovery file causes denial; it is not restored
  or deleted. Files are read through `FileInputStream`, never Android
  `SharedPreferences`, so its cached values, corrupt-XML-to-empty behavior and
  automatic backup restoration cannot authorize a read or cause a mutation.
  The base path comes from `ApplicationInfo` metadata, not `getDataDir`,
  `getFilesDir`, or a preferences-directory getter. Native `lstat`/`fstat`
  operations require an existing real preferences directory and regular XML
  files, deny symbolic-link files/directories, and identify each opened file by
  its device/inode and metadata. Errors checking `.bak` are denial, not absence.
  All three original read-only descriptors remain open until after key loading
  and decryption. Before returning either a value or null, the reader compares
  original bytes, device/inode, metadata and backup absence again. It never
  restores a replaced/changed file or reopens another candidate as a fallback.
- The bounded XML reader accepts the string/boolean map entries that this
  backend writes. It preserves XML escapes and rejects malformed/truncated XML,
  duplicate entries, nesting, unknown preference types, DTDs and processing
  instructions. It does not follow external entities or create directories/files.
  XML larger than 4 MiB per file is explicitly unsupported and denied.
- Namespace/key-prefix selection uses the unchanged native config semantics.
  Normal names remain `FlutterSecureStorage`, `FlutterSecureKeyStorage`, and
  `FlutterSecureStorageConfiguration:<data-name>`. With `storageNamespace`, the
  normal namespaced key preferences and Keystore suffix are used. Names with
  path separators are explicitly unsupported; no alternative path is searched.
- The exact existing OAEP alias is loaded, with existing RSA private key and
  certificate/public key required. Missing/wrong-type/unavailable/invalidated
  Keystore material fails without key generation or deletion. The upstream OAEP
  provider, digest SHA-256 and MGF1 SHA-1 parameters are reused unchanged.
- Only the modern wrapped-AES preference name is used. Missing/corrupt material
  fails; legacy typo/CBC names are not adopted or tried. The unwrapped application
  key must be a 16-byte AES secret key, matching this upstream RSA/GCM backend.
  Its existing AES-GCM implementation is reused: 12-byte IV followed by payload
  and 128-bit authentication tag. No new cryptographic implementation was added.
- Existing-only RSA wrapping/deletion and AES encryption/deletion are explicitly
  disabled, including accidental attempts to reuse those cipher objects for writes.
- Markerless/v9/CBC/PKCS1 and persisted AES/biometric wrapping are unsupported.
  Explicit `encryptedSharedPreferences=true` or `enforceBiometrics=true` requests
  are denied. ESP keyset artifacts, backup-status entries and `_BACKUP` /
  `_MIGRATED` artifacts cause denial. No Tink/ESP or biometric UI is initialized.
  Merely requesting reset/migration flags never enables their mutating behavior.
- A missing entry returns null **only after** all three persisted maps and
  existing key material have been validated and the existing cipher constructed.
  Backend absence or corruption is an error, not a request to initialize it.
- This is a per-call no-write capability, not a lock against ordinary writers,
  unrelated asynchronous initialization, other processes or OS storage changes.
  It makes no preference/Keystore/file mutations and uses persisted snapshots;
   cross-file linearizability under an external concurrent writer is not claimed.
  Observed file replacement/content/metadata changes or backup appearance are
  denied while the held original descriptors are still owned by this call.
  The application must separately coordinate when normal initialization/writes
  are allowed. This patch does not cancel or alter upstream async operations.

## Changed runtime files and ordinary-path impact

All paths below are relative to this directory:

| File | Change / ordinary-path impact |
| --- | --- |
| `lib/flutter_secure_storage.dart` | New Android-only API and fixed-error boundary; existing methods unchanged. |
| `android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStoragePlugin.java` | Early distinct dispatch and redacted result; ordinary initialize/switch/reset handlers unchanged. |
| `android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStorageConfig.java` | Package-local warning-suppression overload; original public constructor still enables the same upstream warning. |
| `android/src/main/java/com/it_nomads/fluttersecurestorage/ExistingStorageReader.java` | New per-call selector, eligibility checks and strict UTF-8 decode; no cache/editor/normal storage calls. |
| `android/src/main/java/com/it_nomads/fluttersecurestorage/ExistingPreferencesSnapshot.java` | New bounded read-only persisted XML snapshots, avoiding framework preference recovery/cache. |
| `android/src/main/java/com/it_nomads/fluttersecurestorage/ciphers/StorageCipherFactory.java` | New static explicit-marker validator and existing-only constructor route; original constructor/selection/migration methods unchanged. |
| `android/src/main/java/com/it_nomads/fluttersecurestorage/ciphers/KeyCipherImplementationRSA18.java` | Existing-only constructor and wrap/delete guards; original constructor delegates with false and preserves original creation behavior. |
| `android/src/main/java/com/it_nomads/fluttersecurestorage/ciphers/KeyCipherImplementationRSAOAEP.java` | Existing-only overload; original constructor and crypto parameters unchanged. |
| `android/src/main/java/com/it_nomads/fluttersecurestorage/ciphers/StorageCipherImplementationGCM.java` | Separate existing-key-snapshot constructor and write/delete guards; original construction, legacy adoption, key generation, preference editing and encryption/decryption format remain unchanged. |

No other upstream runtime behavior is intentionally changed. Trailing whitespace
only was trimmed in `FlutterSecureStorage.java`, `NamespacedConfigSource.java`
and `crypto/EncryptedSharedPreferences.java` to satisfy the project's diff check.

## Synthetic tests provided, not executed in this implementation lane

Uses only upstream JUnit 4.13.2 and Robolectric 4.16.1 facilities; no added
framework, Maven/Pub dependency or test runner configuration.

- `android/src/test/java/com/it_nomads/fluttersecurestorage/ExistingStorageDispatchTest.java`:
  early dispatch despite an occupied normal cache, no ordinary initialization,
  unchanged cache membership and fixed native error redaction.
- `android/src/test/java/com/it_nomads/fluttersecurestorage/ExistingStorageReaderTest.java`:
  persisted selection rather than caller algorithms, no framework preference
  calls/editors, backend-before-missing-entry checks, no legacy fallback,
  unsupported modes, migration/ESP/.bak artifacts, malformed channel data,
  malformed/cached-corrupt XML, strict UTF-8 and valid empty plaintext.
  Its injected cipher loader is synthetic; key/crypto assertions are separate.
- `android/src/test/java/com/it_nomads/fluttersecurestorage/ExistingPreferencesSnapshotTest.java`:
  ordinary XML strings/booleans and escaping, unchanged file bytes, explicit
  empty maps versus malformed/duplicate/unknown XML, DTD denial, no allocation
  of missing or traversed preference paths, immutable views, held-descriptor
  content/path changes, new backup denial, and no repair on those failures.
- `android/src/test/java/com/it_nomads/fluttersecurestorage/ciphers/ExistingStorageCipherTest.java`:
  ordinary upstream GCM ciphertext stays readable using a synthetic unwrap
  provider; no editor/wrap/delete, no legacy adoption or fresh key generation,
  wrong-size/corrupt/invalidated material, authentication failure, continued
  usability of ordinary cipher instances, and explicit supported markers.
- `android/src/test/java/com/it_nomads/fluttersecurestorage/ciphers/ExistingRSAKeyTest.java`:
  synthetic AndroidKeyStore read spy and forbidden generator/writer/deleter,
  exact normal OAEP namespace, and missing/wrong-type/certificate-less/invalidated
  key rejection. This does not establish behavior on a real Android Keystore.

No test, analyzer, compiler, dependency installation, build, application/device
launch, or commit was run in this lane. The owning session is responsible for
offline native/channel/application checks and independent review. Real-device
Keystore and full Android application compatibility remain unverified here.

## Parent verification and bounded review correction

- `flutter pub get --offline` changes only this dependency's source to the local
  path, retaining version **10.3.4** and every other locked dependency.
- All 26 runtime Java files compiled with the same installed Android 36 API,
  Flutter embedding and dependency classpath as the 24-file unmodified baseline,
  using Java 17 target compatibility. No Gradle, signing or application launch.
- Fourteen application/channel/synthetic-vault/real-AEAD tests pass. They cover
  ordinary method/options, separate existing-only dispatch, no ordinary fallback,
  local write/delete denial, key preflight and real decrypt with synthetic keys.
  They do not execute Android Keystore or the supplied native test classes.
- Full application analyzer: zero errors/warnings, 293 informational style
  findings. No suppression or analysis configuration changes.
- Initial source review found a directory-identity gap: replacing `shared_prefs`
  with a symlink to its renamed original left XML identity/content unchanged.
  The reader now retains its initially checked directory device/inode and checks
  the pathname's non-symlink directory type and identity around each metadata
  verification. A supplied synthetic native case exercises this exact swap;
  native test-runtime execution remains unavailable without additional jars.
  Updated compilation of all 26 runtime Java files passes after this correction;
  the bounded same-risk source re-review closes the exact finding without another
  material blocker. Dart/analyzer evidence is reused because this correction
  changes only the native directory witness. This remains source/compile/synthetic
  evidence, not execution of native tests or real-device compatibility.
The parent reported successful compilation of the unmodified 24-file upstream
Java baseline using JDK 21 / `--release 17` and installed Android 36/Flutter/Tink
dependencies. That is baseline evidence, not execution or compilation evidence
for this patch. JUnit/Robolectric/android-all runtime jars are absent in the
installed cache; no downloads or replacement test framework are authorized.
