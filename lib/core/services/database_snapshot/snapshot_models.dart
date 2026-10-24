part of '../database_snapshot_service.dart';

enum DatabaseSnapshotStatus {
  verified,
  invalid,
  unknown,
  tooLarge,
  cancelled,
  stale,
  destinationExists,
  unsupportedIdentity,
  unsupportedRestore,
  unavailable,
}

enum DatabaseSnapshotBoundary { backupPage, beforePublish }

/// Native-owner/test diagnostics only, never part of a snapshot scalar report.
enum DatabaseSnapshotIdentityRole {
  sourcePath,
  destinationPath,
  ancestor,
  source,
  sourceSidecar,
  ownedStage,
  retainedSnapshot,
}

enum DatabaseSnapshotIdentityBoundary {
  platform,
  canonicalPath,
  localFixedDrive,
  volumeInformation,
  ntfs,
  entryAttributes,
  handleOpen,
  handleInformation,
  reparsePoint,
  entityKind,
  linkCount,
}

/// Only fixed enums: no filename, ancestor depth, OS error or other metadata.
final class DatabaseSnapshotIdentityFailure {
  const DatabaseSnapshotIdentityFailure._(this.role, this.boundary);
  final DatabaseSnapshotIdentityRole role;
  final DatabaseSnapshotIdentityBoundary boundary;

  @override
  String toString() => '${role.name}:${boundary.name}';
}

/// This capability has neither a path nor a content-derived identifier.
final class VerifiedDatabaseSnapshot {
  VerifiedDatabaseSnapshot._();

  @override
  String toString() => 'VerifiedDatabaseSnapshot';
}

/// Fixed scalar metadata only. Verification is physical, not semantic repair.
final class DatabaseSnapshotResult {
  const DatabaseSnapshotResult(
    this.status, {
    this.handle,
    this.tableCount = 0,
    this.byteCount = 0,
  });

  final DatabaseSnapshotStatus status;
  final VerifiedDatabaseSnapshot? handle;
  final int tableCount;
  final int byteCount;

  // Database ciphertext and credential bytes survive unchanged. No external
  // vault, preferences, .env or media are read or included. Key availability
  // cannot be inferred from readable SQLite, so keyless recovery is NOT proven.
  bool get externalKeyVaultIncluded => false;
  bool get keyRecoverabilityKnown => false;
  bool get missingKeysCannotBeRecovered => true;

  @override
  String toString() => 'DatabaseSnapshotResult(${status.name})';
}

/// The boundary callback is a native test/control hook, not a payload channel.
final class DatabaseSnapshotControl {
  DatabaseSnapshotControl({required this._isCurrent, this._onBoundary});

  final bool Function() _isCurrent;
  final Future<void> Function(DatabaseSnapshotBoundary)? _onBoundary;
  bool _cancelled = false;
  void cancel() => _cancelled = true;
}

abstract final class _SnapshotLimits {
  static const maxBytes = 256 * 1024 * 1024;
  static const maxPages = 65536;
  static const stepPages = 128;
  static const maxBackupSteps = maxPages ~/ stepPages + 2;
  static const maxTables = 512;
  static const maxEntities = 4096;
  static const maxSchemaBytes = 4 * 1024 * 1024;
  static const maxIdentifierBytes = 1024;
  static const maxIssues = 64;
  static const maxRows = 100000000;
  static const maxDuration = Duration(minutes: 2);
  static const hashChunk = 64 * 1024;
}

final class _SnapshotGuard {
  _SnapshotGuard(this.control, this.sourceCurrent);
  final DatabaseSnapshotControl control;
  final bool Function() sourceCurrent;
  final Stopwatch clock = Stopwatch()..start();
  DatabaseSnapshotStatus? failure;

  void check() {
    if (control._cancelled) {
      failure = DatabaseSnapshotStatus.cancelled;
    } else if (!control._isCurrent() || !sourceCurrent()) {
      failure = DatabaseSnapshotStatus.stale;
    } else if (clock.elapsed > _SnapshotLimits.maxDuration) {
      failure = DatabaseSnapshotStatus.unknown;
    }
    if (failure != null) throw _SnapshotFailure(failure!);
  }

  Future<void> boundary(DatabaseSnapshotBoundary boundary) async {
    check();
    final hook = control._onBoundary;
    if (hook != null) {
      try {
        await hook(
          boundary,
        ).timeout(_SnapshotLimits.maxDuration - clock.elapsed);
      } on TimeoutException {
        failure = DatabaseSnapshotStatus.unknown;
        throw const _SnapshotFailure(DatabaseSnapshotStatus.unknown);
      }
    }
    check();
  }
}

final class _SnapshotFailure implements Exception {
  const _SnapshotFailure(this.status, {this.identityFailure});
  final DatabaseSnapshotStatus status;
  final DatabaseSnapshotIdentityFailure? identityFailure;
  @override
  String toString() => 'Database snapshot unavailable';
}

final class _SnapshotRecord {
  const _SnapshotRecord({
    required this.pin,
    required this.digest,
    required this.verifiedAt,
    required this.schema,
  });
  final _WindowsPin pin;
  final Digest digest;
  final DateTime verifiedAt;
  final _SnapshotSchema schema;
  DatabaseSnapshotStatus get verificationStatus =>
      DatabaseSnapshotStatus.verified;
}
