import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/cloud_sync/cloud_read_only_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict_diagnostics_download.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';

import 'sync_lifecycle_test.dart' as fakes;

class CapabilitySpy extends fakes.FakeCloudAdapter
    implements CloudReadOnlyAdapter {
  final readOnlyCalls = <String>[];
  Object? failure;

  @override
  Future<String> downloadReadOnly(String path) async {
    readOnlyCalls.add(path);
    if (failure != null) throw failure!;
    return '{}';
  }

  @override
  Future<String> download(String path) async =>
      fail('Ordinary download is forbidden');
}

void main() {
  test('unsupported adapter has no ordinary download fallback', () async {
    final adapter = fakes.FakeCloudAdapter();
    final download = SyncConflictDiagnosticDownload(adapter);
    expect(download.supported, isFalse);
    await expectLater(
      download.download(cloudPath('character', 'synthetic')),
      throwsA(isA<SyncDiagnosticAdapterUnsupported>()),
    );
    expect(adapter.downloadCalls, isEmpty);
    expect(adapter.ensuredFolders, isEmpty);
  });

  test(
    'complete canonical ASCII paths are validated before capability',
    () async {
      final adapter = CapabilitySpy();
      final download = SyncConflictDiagnosticDownload(adapter);
      for (final path in [
        '/arbitrary/secret',
        '${cloudPath('character', 'synthetic')}\n',
        '${cloudPath('character', 'synthetic')}?secret',
        cloudPath('character', '../secret'),
        cloudPath('character', 'é'),
        cloudPath('character', 'a' * 513),
        cloudPath('api_presets', 'synthetic'),
      ]) {
        await expectLater(
          download.download(path),
          throwsA(isA<SyncDiagnosticInvalidIdentity>()),
        );
      }
      expect(adapter.readOnlyCalls, isEmpty);
      for (final type in ['character', 'character_knowledge', 'memory_graph']) {
        await download.download(cloudPath(type, 'a' * 512));
      }
      expect(adapter.readOnlyCalls.length, 3);
    },
  );

  test('capability statuses translate to fixed safe wrappers', () async {
    final adapter = CapabilitySpy();
    final download = SyncConflictDiagnosticDownload(adapter);
    for (final pair in <(Object, Matcher)>[
      (
        const CloudReadOnlyDownloadException(
          CloudReadOnlyDownloadStatus.reauthenticate,
        ),
        isA<SyncDiagnosticAuthUnavailable>(),
      ),
      (
        const CloudReadOnlyDownloadException(
          CloudReadOnlyDownloadStatus.missing,
        ),
        isA<SyncDiagnosticDownloadMissing>(),
      ),
      (
        const CloudReadOnlyDownloadException(
          CloudReadOnlyDownloadStatus.unreadable,
        ),
        isA<SyncDiagnosticDownloadFailed>(),
      ),
      (
        const CloudReadOnlyDownloadException(
          CloudReadOnlyDownloadStatus.invalidPath,
        ),
        isA<SyncDiagnosticInvalidIdentity>(),
      ),
      (StateError('SECRET_CANARY'), isA<SyncDiagnosticDownloadFailed>()),
    ]) {
      adapter.failure = pair.$1;
      try {
        await download.download(cloudPath('character', 'synthetic'));
        fail('Expected failure');
      } catch (error) {
        expect(error, pair.$2);
        expect(error.toString(), isNot(contains('SECRET_CANARY')));
      }
    }
  });
}
