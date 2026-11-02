import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_engine.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_lifecycle_test.dart' as fixtures;

class _Cloud extends fixtures.FakeCloudAdapter {
  String? blockedUpload;
  String? blockedDownload;
  String? retryUpload;
  int retriesRemaining = 0;
  final started = Completer<void>();
  final resume = Completer<void>();

  Future<void> _block() async {
    if (!started.isCompleted) started.complete();
    await resume.future;
  }

  @override
  Future<void> upload(String path, String data) async {
    if (path == retryUpload && retriesRemaining > 0) {
      retriesRemaining--;
      throw Exception('503');
    }
    if (path == blockedUpload) await _block();
    await super.upload(path, data);
  }

  @override
  Future<String> download(String path) async {
    if (path == blockedDownload) await _block();
    return super.download(path);
  }
}

void _expectIncomplete(List<SyncProgress> progress) {
  final tasks = progress.where((event) => event.total > 0);
  expect(tasks, isNotEmpty);
  expect(tasks.every((event) => event.current < event.total), isTrue);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final failures in [0, 2]) {
    test('push counts completion once with $failures retry failures', () async {
      final cloud = _Cloud();
      final world = fixtures.SyncWorld(cloudAdapter: cloud);
      await world.characters.put(
        fixtures.makeChar('character', name: 'Before'),
      );
      await world.engine.pushEntities(onProgress: (_) {});
      await world.characters.put(fixtures.makeChar('character', name: 'After'));
      final path = cloudPath('character', 'character');
      cloud.blockedUpload = path;
      cloud.retryUpload = path;
      cloud.retriesRemaining = failures;
      final progress = <SyncProgress>[];
      final pending = world.engine.pushEntities(onProgress: progress.add);
      try {
        await cloud.started.future.timeout(const Duration(seconds: 10));
        _expectIncomplete(progress);
        final starts = progress.where(
          (event) => event.message == 'Pushing character:character',
        );
        expect(starts.length, failures + 1);
        expect(
          starts.every((event) => event.current == 0 && event.total == 1),
          isTrue,
        );
      } finally {
        cloud.resume.complete();
      }
      await pending;
      final completed = progress.where(
        (event) => event.message == 'Pushed character:character',
      );
      expect(completed, hasLength(1));
      expect(completed.single.current, 1);
      expect(completed.single.total, 1);
      expect(progress.last.message, 'Publishing sync manifest...');
      expect(progress.last.current, progress.last.total);
    });
  }

  test('failed push never reports the failed entity as completed', () async {
    final world = fixtures.SyncWorld();
    await world.characters.put(fixtures.makeChar('character', name: 'Before'));
    await world.engine.pushEntities(onProgress: (_) {});
    await world.characters.put(fixtures.makeChar('character', name: 'After'));
    world.cloud.uploadFailures.add(cloudPath('character', 'character'));
    final progress = <SyncProgress>[];
    await expectLater(
      world.engine.pushEntities(onProgress: progress.add),
      throwsA(isA<Exception>()),
    );
    _expectIncomplete(progress);
    expect(
      progress.any((event) => event.message == 'Pushed character:character'),
      isFalse,
    );
  });

  test(
    'pull counter stays incomplete while final entity is downloading',
    () async {
      final sender = fixtures.SyncWorld();
      await sender.characters.put(fixtures.makeChar('character'));
      await sender.engine.pushEntities(onProgress: (_) {});
      final cloud = _Cloud()..files.addAll(sender.cloud.files);
      final receiver = fixtures.SyncWorld(cloudAdapter: cloud);
      cloud.blockedDownload = cloudPath('character', 'character');
      final progress = <SyncProgress>[];
      final pending = receiver.engine.pullEntities(
        onProgress: progress.add,
        onConflict: (_) {},
      );
      try {
        await cloud.started.future.timeout(const Duration(seconds: 10));
        _expectIncomplete(progress);
        expect(await receiver.characters.getById('character'), isNull);
      } finally {
        cloud.resume.complete();
      }
      await pending;
      final completed = progress.where(
        (event) => event.message == 'Pulled character:character',
      );
      expect(completed, hasLength(1));
      expect(completed.single.current, completed.single.total);
      expect(await receiver.characters.getById('character'), isNotNull);
      expect(progress.last.message, 'Saving local sync manifest...');
    },
  );

  test('pull labels the local rebuild after the final applied task', () async {
    final sender = fixtures.SyncWorld();
    await sender.characters.put(fixtures.makeChar('character'));
    await sender.engine.pushEntities(onProgress: (_) {});
    final receiver = fixtures.SyncWorld();
    receiver.cloud.files.addAll(sender.cloud.files);
    final started = Completer<void>();
    final resume = Completer<void>();
    receiver.manifestProvider.beforeBuild = (applyAcceptedHashes) async {
      if (applyAcceptedHashes) return;
      started.complete();
      await resume.future;
    };
    final progress = <SyncProgress>[];
    final pending = receiver.engine.pullEntities(
      onProgress: progress.add,
      onConflict: (_) {},
    );
    try {
      await started.future.timeout(const Duration(seconds: 10));
      expect(await receiver.characters.getById('character'), isNotNull);
      expect(progress.last.message, 'Rebuilding local sync manifest...');
      expect(progress.last.current, progress.last.total);
      expect(
        (await receiver.manifestProvider.readLocalManifest()).entries
            .containsKey('character:character'),
        isFalse,
      );
      expect(
        progress.any(
          (event) => event.message == 'Saving local sync manifest...',
        ),
        isFalse,
      );
    } finally {
      resume.complete();
    }
    await pending;
    expect(
      progress
          .skipWhile(
            (event) => event.message != 'Rebuilding local sync manifest...',
          )
          .map((event) => event.message),
      [
        'Rebuilding local sync manifest...',
        'Verifying sync anchors...',
        'Saving local sync manifest...',
      ],
    );
    expect(
      (await receiver.manifestProvider.readLocalManifest()).entries.containsKey(
        'character:character',
      ),
      isTrue,
    );
  });

  test('failed local rebuild never reports or writes acceptance', () async {
    final sender = fixtures.SyncWorld();
    await sender.characters.put(fixtures.makeChar('character'));
    await sender.engine.pushEntities(onProgress: (_) {});
    final receiver = fixtures.SyncWorld();
    receiver.cloud.files.addAll(sender.cloud.files);
    receiver.manifestProvider.beforeBuild = (applyAcceptedHashes) async {
      if (!applyAcceptedHashes) throw StateError('Synthetic rebuild failure');
    };
    final progress = <SyncProgress>[];
    await expectLater(
      receiver.engine.pullEntities(
        onProgress: progress.add,
        onConflict: (_) {},
      ),
      throwsA(isA<StateError>()),
    );
    expect(progress.last.message, 'Rebuilding local sync manifest...');
    expect(
      (await receiver.manifestProvider.readLocalManifest()).entries.containsKey(
        'character:character',
      ),
      isFalse,
    );
  });

  for (final pending in [false, true]) {
    test('empty pull still labels finalization (pending=$pending)', () async {
      final world = fixtures.SyncWorld();
      await world.engine.pushEntities(onProgress: (_) {});
      final progress = <SyncProgress>[];
      if (pending) {
        await world.engine.applyPendingPull(onProgress: progress.add);
      } else {
        await world.engine.pullEntities(
          onProgress: progress.add,
          onConflict: (_) {},
        );
      }
      expect(
        progress.any((event) => event.message == 'Nothing to pull'),
        isTrue,
      );
      expect(progress.last.message, 'Saving local sync manifest...');
      expect(progress.last.current, 0);
      expect(progress.last.total, 0);
    });
  }
}
