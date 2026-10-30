import 'dart:async';

import '../../../../../core/db/app_db.dart';
import '../../../../../core/services/database_snapshot_service.dart';
import '../../../models/support_app_action.dart';
import 'support_backup_file_host.dart';

/// One finite native LOCAL save, not export-to-model, hashing or live restore.
final class SupportDatabaseBackupAdapter implements SupportAppActionAdapter {
  SupportDatabaseBackupAdapter({
    required this.native,
    required this.originalSource,
    required this.isOriginalOwnerCurrent,
  });
  final SupportBackupNativeFileHost? native;
  final NativeDataSourceIdentity? Function() originalSource;
  final bool Function() isOriginalOwnerCurrent;
  final _attempted = Expando<bool>();
  final _services = <DatabaseSnapshotService>{};
  bool _disposed = false, _busy = false;

  bool get _current => !_disposed && isOriginalOwnerCurrent();

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: SupportBackupNativeFileHost.action,
      description:
          'Save and physically verify the whole ORIGINAL open database '
          'to one native-selected new local file after exact confirmation. '
          'No paths or data are returned. No upload, key recovery or live restore.',
      risk: SupportAppActionRisk.nativeFile,
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    final host = native;
    final root = context.domainRoot;
    if (action != SupportBackupNativeFileHost.action ||
        arguments.isNotEmpty ||
        host == null ||
        !host.isCurrent ||
        root is! SupportBackupOriginalDatabaseRoot ||
        !identical(context.confirmation, host) ||
        !_current ||
        !context.current ||
        _attempted[context] == true) {
      return null;
    }
    final source = originalSource();
    if (source == null || !source.isCurrent) return null;
    var retired = false;
    bool original() {
      if (retired) return false;
      try {
        if (!_current ||
            !host.isCurrent ||
            !context.current ||
            !source.isCurrent ||
            !identical(originalSource(), source) ||
            !root.retainsBackupSource(source, context) ||
            !_current ||
            !context.current) {
          retired = true;
        }
      } catch (_) {
        retired = true;
      }
      return !retired;
    }

    if (!original()) return null;
    final selection = await host.choose(context, source, original);
    if (!original() || selection == null) return null;
    return SupportAppPreparedAction(
      target: SupportBackupNativeFileHost.target,
      observation: selection,
      observationIsCurrent: () => original() && selection.isCurrent,
      preview: SupportBackupNativeFileHost.preview,
      execute: (admitted) =>
          _save(context, root, selection, () => original() && admitted()),
    );
  }

  Future<SupportAppActionOutcome> _save(
    SupportAppActionContext context,
    SupportBackupOriginalDatabaseRoot root,
    SupportBackupFileSelection selection,
    bool Function() current,
  ) async {
    if (_busy || _attempted[context] == true || !current()) {
      return _outcome('unavailable');
    }
    _busy = true;
    _attempted[context] = true; // No retry of an attempted original save.
    DatabaseSnapshotService? service;
    SupportBackupRootLease? custody;
    var published = false;
    Future<SupportAppActionOutcome> perform() async {
      try {
        final admittedCustody = await root.admitBackupFile(selection, context);
        custody = admittedCustody;
        if (admittedCustody == null || !current()) {
          return _outcome('unavailable');
        }
        bool live() => current() && admittedCustody.isCurrent && current();
        final owner = selection.consume(
          custody: admittedCustody,
          isCurrent: live,
        );
        if (owner == null || !live()) return _outcome('unavailable');
        final snapshots = DatabaseSnapshotService(native: owner);
        service = snapshots;
        _services.add(snapshots);
        final control = DatabaseSnapshotControl(isCurrent: live);
        unawaited(context.cancelToken.whenCancel.then((_) => control.cancel()));
        if (context.cancelToken.isCancelled) control.cancel();
        if (!live()) return _outcome('cancelled');
        final created = await snapshots.create(control: control);
        // The native no-replace publication is factual even if Stop arrives now.
        published = created.wasPublished;
        if (!live()) {
          return _outcome(
            context.cancelToken.isCancelled ? 'cancelled' : 'uncertain',
            published: published,
          );
        }
        if (!published) return _outcome(_status(created.status));
        final exactHandle =
            created.handle; // Opaque native capability, never JSON.
        if (exactHandle == null) return _outcome('uncertain', published: true);
        final checked = await snapshots.verifyHandle(
          exactHandle,
          control: control,
        );
        if (!live()) {
          return _outcome(
            context.cancelToken.isCancelled ? 'cancelled' : 'uncertain',
            published: true,
          );
        }
        final verified =
            checked.status == DatabaseSnapshotStatus.verified &&
            identical(checked.handle, exactHandle);
        return _outcome(
          verified
              ? 'verified'
              : checked.status == DatabaseSnapshotStatus.verified
              ? 'uncertain'
              : _status(checked.status),
          published: true,
        );
      } catch (_) {
        return _outcome(
          context.cancelToken.isCancelled ? 'cancelled' : 'uncertain',
          published: published,
        );
      }
    }

    late final SupportAppActionOutcome outcome;
    try {
      outcome = await perform();
    } finally {
      try {
        // Settle pin release BEFORE reporting the factual native outcome.
        service?.dispose();
      } finally {
        _services.remove(service);
        custody?.close();
        _busy = false;
      }
    }
    return service?.hasUnsettledRelease == true
        ? _outcome('uncertain', published: published)
        : outcome;
  }

  String _status(DatabaseSnapshotStatus status) => switch (status) {
    DatabaseSnapshotStatus.verified => 'verified',
    DatabaseSnapshotStatus.cancelled => 'cancelled',
    DatabaseSnapshotStatus.unavailable ||
    DatabaseSnapshotStatus.destinationExists ||
    DatabaseSnapshotStatus.unsupportedIdentity ||
    DatabaseSnapshotStatus.unsupportedRestore => 'unavailable',
    _ => 'uncertain',
  };

  SupportAppActionOutcome _outcome(String status, {bool published = false}) =>
      SupportAppActionOutcome(
        switch (status) {
          'verified' => SupportAppActionCode.completed,
          'cancelled' => SupportAppActionCode.cancelled,
          'unavailable' || 'missing' => SupportAppActionCode.unavailable,
          _ => SupportAppActionCode.storageUncertain,
        },
        effect: published
            ? SupportAppActionEffect.persisted
            : SupportAppActionEffect.none,
        data: {
          'status': status,
        }, // No counts, bytes, body, hash, path or schema.
      );

  void dispose() {
    _disposed = true;
    for (final service in _services.toList()) {
      service.dispose();
    }
    _services.clear();
  }
}
