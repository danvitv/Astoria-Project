import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/cloud_sync/services/reconciliation_page_cache.dart';

String _hash(Uint8List bytes) => sha256.convert(bytes).toString();

void main() {
  late Directory temporaryRoot;
  late Directory cacheRoot;

  setUp(() async {
    final local = Platform.environment['LOCALAPPDATA'];
    final parent = local == null
        ? Directory.systemTemp
        : Directory('$local/Temp/opencode');
    temporaryRoot = await parent.createTemp('journal-cache-test-');
    cacheRoot = Directory('${temporaryRoot.path}/cache');
  });
  tearDown(() => temporaryRoot.delete(recursive: true));

  test(
    'persistent exact bytes survive a new owner without pending files',
    () async {
      final bytes = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final cache = ReconciliationPageCache(cacheRoot);
      expect(await cache.read(_hash(bytes), bytes.length), isNull);
      expect(await cacheRoot.exists(), isFalse);
      await cache.write(_hash(bytes), bytes);
      await cache.write(_hash(bytes), bytes);
      expect(await cacheRoot.list().length, 1);
      expect(
        await ReconciliationPageCache(
          cacheRoot,
        ).read(_hash(bytes), bytes.length),
        bytes,
      );
    },
  );

  test('wrong SHA, length and oversized cache objects are misses', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final cache = ReconciliationPageCache(cacheRoot);
    final file = File('${cacheRoot.path}/${_hash(bytes)}.page');
    await cache.write(_hash(bytes), bytes);
    await file.writeAsBytes([1, 2, 4]);
    expect(await cache.read(_hash(bytes), bytes.length), isNull);
    expect(await file.exists(), isFalse);
    await cache.write(_hash(bytes), bytes);
    expect(await cache.read(_hash(bytes), 2), isNull);
    expect(await file.exists(), isFalse);
    await file.writeAsBytes(
      Uint8List(ReconciliationPageCache.maxPageBytes + 1),
    );
    expect(await cache.read(_hash(bytes), bytes.length), isNull);
    expect(await file.exists(), isFalse);
  });

  test('external cache deletion does not poison later writes', () async {
    final a = Uint8List.fromList([1, 2, 3]);
    final b = Uint8List.fromList([4, 5, 6]);
    final c = Uint8List.fromList([7, 8, 9]);
    final cache = ReconciliationPageCache(
      cacheRoot,
      maxBytes: 6,
      maxEntries: 2,
    );
    await cache.write(_hash(a), a);
    await cache.write(_hash(b), b);
    await cacheRoot.delete(recursive: true);
    expect(await cache.read(_hash(a), a.length), isNull);
    await cache.write(_hash(c), c);
    expect(await cache.read(_hash(c), c.length), c);
  });

  test(
    'eviction respects both budgets and does not remove unknown files',
    () async {
      final a = Uint8List.fromList([1, 2, 3]);
      final b = Uint8List.fromList([4, 5, 6]);
      final c = Uint8List.fromList([7, 8, 9]);
      final cache = ReconciliationPageCache(
        cacheRoot,
        maxBytes: 6,
        maxEntries: 2,
      );
      await cache.write(_hash(a), a);
      final foreign = File('${cacheRoot.path}/do-not-touch.txt');
      await foreign.writeAsString('unmanaged');
      await cache.write(_hash(b), b);
      await cache.read(_hash(a), a.length);
      await cache.write(_hash(c), c);
      expect(await cache.read(_hash(b), b.length), isNull);
      expect(await cache.read(_hash(a), a.length), a);
      expect(await cache.read(_hash(c), c.length), c);
      expect(await foreign.readAsString(), 'unmanaged');
      final pages = await cacheRoot
          .list()
          .where((e) => e.path.endsWith('.page'))
          .toList();
      expect(pages.length, 2);
      var total = 0;
      for (final file in pages.cast<File>()) {
        total += await file.length();
      }
      expect(total, 6);
    },
  );

  test(
    'restart inventories and trims managed old files to new budget',
    () async {
      final first = ReconciliationPageCache(cacheRoot);
      final pages = [
        for (var i = 0; i < 4; i++) Uint8List.fromList([i, i + 1]),
      ];
      for (final page in pages) {
        await first.write(_hash(page), page);
      }
      final restarted = ReconciliationPageCache(
        cacheRoot,
        maxBytes: 4,
        maxEntries: 2,
      );
      await restarted.read(_hash(pages.last), pages.last.length);
      expect(await cacheRoot.list().length, 2);
    },
  );

  test('serialized concurrent puts stay bounded and remain readable', () async {
    final cache = ReconciliationPageCache(
      cacheRoot,
      maxBytes: 12,
      maxEntries: 4,
    );
    final pages = [
      for (var i = 0; i < 10; i++) Uint8List.fromList([i, i, i]),
    ];
    await Future.wait([
      for (final page in pages) cache.write(_hash(page), page),
    ]);
    expect(await cacheRoot.list().length, 4);
    for (final page in pages.skip(6)) {
      expect(await cache.read(_hash(page), page.length), page);
    }
  });

  test(
    'invalid names, empty and over-budget inputs cause no disk writes',
    () async {
      final cache = ReconciliationPageCache(cacheRoot, maxBytes: 2);
      final bytes = Uint8List.fromList([1, 2, 3]);
      await cache.write('../outside', bytes);
      await cache.write(_hash(bytes), bytes);
      await cache.write(_hash(Uint8List(0)), Uint8List(0));
      await cache.write(
        'a' * 64,
        Uint8List(ReconciliationPageCache.maxPageBytes + 1),
      );
      expect(await cache.read('../outside', 3), isNull);
      expect(await cacheRoot.exists(), isFalse);
      expect(
        cache.write('a' * 64, Uint8List.fromList([1])),
        throwsFormatException,
      );
    },
  );

  test(
    'inaccessible root degrades to misses without changing that file',
    () async {
      await File(cacheRoot.path).writeAsString('not a directory');
      final cache = ReconciliationPageCache(cacheRoot);
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(await cache.read(_hash(bytes), bytes.length), isNull);
      await cache.write(_hash(bytes), bytes);
      expect(await File(cacheRoot.path).readAsString(), 'not a directory');
    },
  );

  test('retired writes propagate; a later admission is not poisoned', () async {
    final cache = ReconciliationPageCache(cacheRoot);
    final bytes = Uint8List.fromList([1, 2, 3]);
    var checks = 0;
    void retired() {
      if (++checks >= 5) throw StateError('original workflow retired');
    }

    await expectLater(
      cache.write(_hash(bytes), bytes, checkActive: retired),
      throwsStateError,
    );
    expect(
      await File('${cacheRoot.path}/${_hash(bytes)}.page').exists(),
      isFalse,
    );
    await cache.write(_hash(bytes), bytes);
    await expectLater(
      cache.read(
        _hash(bytes),
        bytes.length,
        checkActive: () => throw StateError('retired'),
      ),
      throwsStateError,
    );
    expect(await cache.read(_hash(bytes), bytes.length), bytes);
  });

  test(
    'retirement after rename still accounts for the published page',
    () async {
      final a = Uint8List.fromList([1, 2, 3]);
      final b = Uint8List.fromList([4, 5, 6]);
      final cache = ReconciliationPageCache(
        cacheRoot,
        maxBytes: 3,
        maxEntries: 1,
      );
      final published = File('${cacheRoot.path}/${_hash(a)}.page');
      await expectLater(
        cache.write(
          _hash(a),
          a,
          checkActive: () {
            if (published.existsSync()) {
              throw StateError('retired after rename');
            }
          },
        ),
        throwsStateError,
      );
      expect(await published.exists(), isTrue);
      await cache.write(_hash(b), b);
      expect(await cacheRoot.list().length, 1);
      expect(await published.exists(), isFalse);
      expect(await cache.read(_hash(b), b.length), b);
    },
  );

  test('replaced directory root cannot redirect reads or eviction', () async {
    final a = Uint8List.fromList([1, 2, 3]);
    final b = Uint8List.fromList([4, 5, 6]);
    final cache = ReconciliationPageCache(
      cacheRoot,
      maxBytes: 3,
      maxEntries: 1,
    );
    await cache.write(_hash(a), a);
    await cacheRoot.rename('${temporaryRoot.path}/original-cache');
    final victim = await Directory(
      '${temporaryRoot.path}/other-directory',
    ).create();
    final protected = File('${victim.path}/${_hash(a)}.page');
    await protected.writeAsBytes([0, 0, 0]);
    if (Platform.isWindows) {
      // Junctions do not need Windows symlink privileges. Both paths are solely
      // owned by this fixture; this is not an app/real user-directory launch.
      final result =
          await Process.run(Platform.environment['COMSPEC'] ?? 'cmd.exe', [
            '/c',
            'mklink',
            '/J',
            cacheRoot.path.replaceAll('/', '\\'),
            victim.path.replaceAll('/', '\\'),
          ]);
      if (result.exitCode != 0) {
        markTestSkipped(
          'Fixture directory junction unavailable (${result.exitCode})',
        );
        return;
      }
    } else {
      await Link(cacheRoot.path).create(victim.path);
    }
    try {
      expect(await cache.read(_hash(a), a.length), isNull);
      await cache.write(_hash(b), b);
      expect(await protected.readAsBytes(), [0, 0, 0]);
      expect(await File('${victim.path}/${_hash(b)}.page').exists(), isFalse);
    } finally {
      await Link(cacheRoot.path).delete();
    }
  });
}
