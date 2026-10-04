import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/preset_repo.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/services/featured_presets.dart';
import 'package:glaze_flutter/core/services/preset_seeder.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DelayedSeedRepo extends PresetRepo {
  _DelayedSeedRepo(super.db);
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<bool> putIfUnchanged(
    Preset preset, {
    Preset? expectedExisting,
    bool insertIfMissing = false,
  }) async {
    entered.complete();
    await release.future;
    return super.putIfUnchanged(
      preset,
      expectedExisting: expectedExisting,
      insertIfMissing: insertIfMissing,
    );
  }
}

FeaturedPreset revisionOf(
  FeaturedPreset source,
  int revision,
  String oldHash,
) => FeaturedPreset(
  id: source.id,
  name: source.name,
  author: source.author,
  jsonAsset: source.jsonAsset,
  imageAsset: source.imageAsset,
  createdAt: source.createdAt,
  reasoningEnabled: source.reasoningEnabled,
  reasoningStart: source.reasoningStart,
  reasoningEnd: source.reasoningEnd,
  revision: revision,
  previousContentHash: oldHash,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late PresetRepo repo;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = PresetRepo(db);
  });
  tearDown(() => db.close());

  test('bundled parsing produces a stable fingerprint', () async {
    final shino = featuredPresets.first;
    final first = await loadFeaturedPreset(shino);
    final second = await loadFeaturedPreset(shino);
    expect(featuredPresetContentHash(first), featuredPresetContentHash(second));
    expect(
      featuredPresetContentHash(first.copyWith(name: 'Edited')),
      isNot(featuredPresetContentHash(first)),
    );
  });

  test(
    'fresh install gets five presets once and preserves active choice',
    () async {
      await prefs.setString('activePresetId', 'my-preset');
      expect(
        await reconcileFeaturedPresets(repo: repo, preferences: prefs),
        isTrue,
      );
      expect(
        (await repo.getAll()).map((p) => p.id),
        unorderedEquals(featuredPresets.map((f) => f.id)),
      );
      expect(prefs.getString('activePresetId'), 'my-preset');
      expect(
        await reconcileFeaturedPresets(repo: repo, preferences: prefs),
        isFalse,
      );
    },
  );

  test(
    'v1 install gets NoriMyn without restoring four deleted presets',
    () async {
      await prefs.setBool('featuredPresetsSeeded_v1', true);
      expect(
        await reconcileFeaturedPresets(repo: repo, preferences: prefs),
        isTrue,
      );
      final presets = await repo.getAll();
      expect(presets.map((p) => p.id), ['default_norimyn']);
      expect(presets.single.reasoningStart, '<think>');
      expect(presets.single.reasoningEnd, '</think>');
      await repo.delete('default_norimyn');
      expect(
        await reconcileFeaturedPresets(repo: repo, preferences: prefs),
        isFalse,
      );
      expect(await repo.getAll(), isEmpty);
    },
  );

  test(
    'an existing customized Shino and an imported NoriMyn stay intact',
    () async {
      await prefs.setBool('featuredPresetsSeeded_v1', true);
      final customized = (await loadFeaturedPreset(
        featuredPresets.first,
      )).copyWith(name: 'My Shino', imagePath: 'avatars/custom.png');
      const imported = Preset(id: 'default_norimyn', name: 'Imported');
      await repo.put(customized);
      await repo.put(imported);
      expect(
        await reconcileFeaturedPresets(repo: repo, preferences: prefs),
        isFalse,
      );
      expect(await repo.getById(customized.id), customized);
      expect(await repo.getById(imported.id), imported);
    },
  );

  test(
    'previous fingerprint updates only an unchanged serialized copy',
    () async {
      final bundled = await loadFeaturedPreset(featuredPresets.first);
      final previous = bundled.copyWith(
        blocks: [
          ...bundled.blocks,
          const PresetBlock(
            id: 'old',
            name: 'Old',
            role: 'system',
            content: 'old',
          ),
        ],
      );
      final revision = revisionOf(
        featuredPresets.first,
        3,
        featuredPresetContentHash(previous),
      );
      await repo.put(previous);
      expect(
        await reconcileFeaturedPresets(
          repo: repo,
          preferences: prefs,
          presets: [revision],
        ),
        isTrue,
      );
      expect(await repo.getById(previous.id), bundled);
      expect(prefs.getInt('featuredPresetRev_${previous.id}'), 3);
    },
  );

  test(
    'tracked bundle fingerprints do not adopt edits as a new baseline',
    () async {
      final source = featuredPresets.first;
      final bundled = await loadFeaturedPreset(source);
      await reconcileFeaturedPresets(
        repo: repo,
        preferences: prefs,
        presets: [source],
      );
      final edited = bundled.copyWith(blocks: bundled.blocks.reversed.toList());
      await repo.put(edited);
      final next = revisionOf(source, 3, 'unused-fallback');
      expect(
        await reconcileFeaturedPresets(
          repo: repo,
          preferences: prefs,
          presets: [next],
        ),
        isFalse,
      );
      expect(await repo.getById(source.id), edited);
      expect(
        prefs.getString('featuredPresetHash_${source.id}'),
        featuredPresetContentHash(bundled),
      );
      final last = revisionOf(source, 4, 'unused-fallback');
      expect(
        await reconcileFeaturedPresets(
          repo: repo,
          preferences: prefs,
          presets: [last],
        ),
        isFalse,
      );
      expect(await repo.getById(source.id), edited);
    },
  );

  test(
    'a deleted tracked preset stays deleted after a bundle update',
    () async {
      final source = featuredPresets.last;
      await reconcileFeaturedPresets(
        repo: repo,
        preferences: prefs,
        presets: [source],
      );
      await repo.delete(source.id);
      final next = revisionOf(source, 2, 'irrelevant');
      expect(
        await reconcileFeaturedPresets(
          repo: repo,
          preferences: prefs,
          presets: [next],
        ),
        isFalse,
      );
      expect(await repo.getById(source.id), isNull);
      expect(prefs.getInt('featuredPresetRev_${source.id}'), 2);
    },
  );

  for (final mutation in ['edit', 'delete', 'import']) {
    test('seeding cannot overwrite a concurrent $mutation', () async {
      final source = featuredPresets.first;
      final bundled = await loadFeaturedPreset(source);
      final previous = bundled.copyWith(name: 'Old bundle');
      final delayed = _DelayedSeedRepo(db);
      if (mutation != 'import') await repo.put(previous);
      final revision = revisionOf(
        source,
        3,
        featuredPresetContentHash(previous),
      );
      final seed = reconcileFeaturedPresets(
        repo: delayed,
        preferences: prefs,
        presets: [revision],
      );
      await delayed.entered.future;
      if (mutation == 'delete') {
        await repo.delete(source.id);
      } else {
        await repo.put(bundled.copyWith(name: 'My newest edit'));
      }
      delayed.release.complete();
      expect(await seed, isFalse);
      final durable = await repo.getById(source.id);
      if (mutation == 'delete') {
        expect(durable, isNull);
      } else {
        expect(durable!.name, 'My newest edit');
      }
    });
  }

  test(
    'updated Shino carries its regex scripts and NoriMyn has bundled art',
    () async {
      final shino = await loadFeaturedPreset(featuredPresets.first);
      expect(shino.regexes.map((r) => r.name), contains('Replace Em Dashes'));
      expect(
        shino.regexes.map((r) => r.name),
        contains('RP plan - exclude old checklists from outgoing history'),
      );
      expect(
        shino.blocks.any(
          (b) =>
              b.enabled &&
              !b.isStashed &&
              b.content.contains('<roleplay_rules>'),
        ),
        isTrue,
      );
      expect(
        featuredPresetImageAsset('default_norimyn'),
        'assets/presets/norimyn.jpg',
      );
    },
  );
}
