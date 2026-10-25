part of '../database_snapshot_service.dart';

extension on DatabaseSnapshotService {
  Future<DatabaseSnapshotResult> _createAndroidSnapshot(
    DatabaseSnapshotControl control,
  ) async {
    final source = _native._backgroundSource!;
    final guard = _SnapshotGuard(
      control,
      () => !_disposed && source.isCurrent(),
    );
    final token = p.posix.basename(p.posix.dirname(_native._destinationPath));
    _AndroidSnapshotFiles? files;
    var result = const DatabaseSnapshotResult(DatabaseSnapshotStatus.unknown);
    var submitted = false, closed = false, retained = false, published = false;
    try {
      guard.check();
      if (!Platform.isAndroid ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(token) ||
          _native._destinationPath !=
              p.posix.join(
                source.namespace.workerStageRoot,
                token,
                'astoria-backup.db',
              )) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.unavailable);
      }
      await source._exclusively(() async {
        guard.check();
        final checked = await source._command('check', token);
        guard.check();
        if (checked['status'] != 'ready' || checked['closed'] != true) {
          throw const _SnapshotFailure(DatabaseSnapshotStatus.unavailable);
        }
        await source._inReadTransaction(() async {
          try {
            guard.check();
            files = _AndroidSnapshotFiles(source, token);
            files!.acquire(guard);
            submitted = true;
            var reply = await source._command('start', token);
            guard.check();
            _requireReply(reply, 'ready');
            for (
              var step = 0;
              step < _SnapshotLimits.maxPages ~/ 64 + 2;
              step++
            ) {
              files!.check();
              reply = await source._command('step', token);
              guard.check();
              await guard.boundary(DatabaseSnapshotBoundary.backupPage);
              if (reply['status'] == 'ready') break;
              _requireReply(reply, 'progress');
            }
            _requireReply(reply, 'ready');
            reply = await source._command('finish', token);
            closed = reply['closed'] == true;
            guard.check();
            _requireReply(reply, 'verified');
            if (!closed || reply['tableCount'] is! int) {
              throw const _SnapshotFailure(DatabaseSnapshotStatus.unknown);
            }
            files!.check();
            final pin = files!.stage;
            pin.seal();
            final digest = await pin.hash(guard);
            guard.check();
            final count = reply['tableCount'] as int;
            final bytes = pin.length;
            final handle = VerifiedDatabaseSnapshot._();
            final record = _SnapshotRecord(
              pin: pin,
              digest: digest,
              verifiedAt: DateTime.now().toUtc(),
              tableCount: count,
            );
            final completed = DatabaseSnapshotResult(
              DatabaseSnapshotStatus.verified,
              handle: handle,
              tableCount: count,
              byteCount: bytes,
            );
            await guard.boundary(DatabaseSnapshotBoundary.beforePublish);
            files!.check();
            guard.check();
            // All potentially fallible metadata work is before this point.
            // No await / user callback between last guard and native linkat.
            pin.publish();
            published = true;
            files!.transfer();
            _records[handle] = record;
            result = completed;
          } finally {
            if (submitted && !closed) {
              for (var attempt = 0; attempt < 2 && !closed; attempt++) {
                try {
                  final aborted = await source._command('abort', token);
                  closed = aborted['closed'] == true;
                  if (!closed) {
                    final checked = await source._command('check', token);
                    closed = checked['closed'] == true;
                  }
                } catch (_) {
                  /* original worker may still own its handles */
                }
              }
              if (!closed) {
                source.retainUnsettled(files!);
                retained = true;
                throw const _SnapshotFailure(DatabaseSnapshotStatus.unknown);
              }
            }
            if (!retained) {
              try {
                files?.close();
              } catch (_) {
                source.retainUnsettled(files!);
                retained = true;
                throw const _SnapshotFailure(DatabaseSnapshotStatus.unknown);
              }
            }
          }
        });
      });
    } on _SnapshotFailure catch (error) {
      result = DatabaseSnapshotResult(
        error.status,
        publicationOccurred: published,
      );
    } catch (_) {
      result = DatabaseSnapshotResult(
        guard.failure ?? DatabaseSnapshotStatus.unknown,
        publicationOccurred: published,
      );
    } finally {
      _running = false;
      if (_disposed) {
        try {
          _releaseRecords();
          if (_recordReleaseFailed) {
            result = DatabaseSnapshotResult(
              DatabaseSnapshotStatus.unknown,
              publicationOccurred: published,
            );
          }
        } catch (_) {
          source.retainUnsettled(_records);
          result = DatabaseSnapshotResult(
            DatabaseSnapshotStatus.unknown,
            publicationOccurred: published,
          );
        }
      }
    }
    return result;
  }

  void _requireReply(Map<String, Object?> reply, String status) {
    if (reply['status'] == status) return;
    throw _SnapshotFailure(switch (reply['status']) {
      'tooLarge' => DatabaseSnapshotStatus.tooLarge,
      'invalid' => DatabaseSnapshotStatus.invalid,
      'unavailable' => DatabaseSnapshotStatus.unavailable,
      _ => DatabaseSnapshotStatus.unknown,
    });
  }
}
