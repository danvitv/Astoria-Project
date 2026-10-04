import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/presets/preset_list_provider.dart';
import '../db/repositories/preset_repo.dart';
import '../state/db_provider.dart';
import '../state/shared_prefs_provider.dart';
import 'featured_presets.dart';

const _seededKey = 'defaultPresetsSeeded';
const _featuredSeededKey = 'featuredPresetsSeeded_v1';

// These shipped before per-preset tracking. An absent row on a v1 install
// belongs to a deletion; newer ids can still be offered once on that install.
const _legacyFeaturedIds = {
  'default_shino',
  'default_fawnie',
  'default_microcot',
  'default_renri',
};

/// The preset a first run lands on.
///
/// Shino is one of the featured presets the app ships and the one it ships to
/// be used. The old first-run preset, "Default Chat", was a bare skeleton
/// assembled in this file — a main prompt, an NSFW block and a one-line
/// jailbreak — that happened to sort first and so became what a new install
/// generated with without anyone choosing it. It is no longer created.
const defaultPresetId = 'default_shino';

/// The preset to make active on a first run, or null to leave the choice
/// alone.
///
/// [alreadySeeded] is the first-run flag; [activePresetId] is what the user is
/// already set to. A restored backup and a migration from the Vue app both
/// write an active preset and can both leave the flag clear, so an existing
/// choice always wins — this only ever fills a blank.
String? defaultPresetChoice({
  required bool alreadySeeded,
  required String? activePresetId,
}) {
  if (alreadySeeded) return null;
  if (activePresetId != null && activePresetId.isNotEmpty) return null;
  return defaultPresetId;
}

/// Writes a first run's active preset, before the app reads the preference.
///
/// Runs from `main()` rather than as one of the app's startup tasks so that by
/// the time `loadActiveSelections` reads `activePresetId` the value is simply
/// there, exactly as it is for an install that already has one. Deciding it
/// later means publishing into `activePresetIdProvider` while the router is
/// building its first routes, and a provider going dirty at that point leaves
/// Riverpod's refresh to land inside a build — which the framework refuses.
///
/// Runs exactly once per install: after the flag is written the active preset
/// is the user's own and is never touched here again.
Future<void> applyFirstRunPresetChoice({SharedPreferences? preferences}) async {
  final prefs = preferences ?? await SharedPreferences.getInstance();
  final choice = defaultPresetChoice(
    alreadySeeded: prefs.getBool(_seededKey) == true,
    activePresetId: prefs.getString('activePresetId'),
  );
  // Stamped either way: an install that arrived with a preset of its own has
  // had its first run, and there is nothing here to redo.
  await prefs.setBool(_seededKey, true);
  if (choice == null) return;
  await prefs.setString('activePresetId', choice);
}

/// Seeds new bundled presets and refreshes unchanged older copies. The v1
/// marker stays authoritative for old deletions; adding a preset does not reset
/// the library or active choice. Refresh a cached library only after DB writes.
Future<void> seedFeaturedPresets(WidgetRef ref) async {
  final context = ref.context;
  final prefs = await ref.read(sharedPreferencesProvider.future);
  if (!context.mounted) return;
  final repo = ref.read(presetRepoProvider);
  final changed = await reconcileFeaturedPresets(
    repo: repo,
    preferences: prefs,
  );
  if (context.mounted && changed) {
    ref.invalidate(presetListProvider);
  }
}

/// Independent of widget lifetime so accepted startup work can finish safely.
Future<bool> reconcileFeaturedPresets({
  required PresetRepo repo,
  required SharedPreferences preferences,
  List<FeaturedPreset> presets = featuredPresets,
}) async {
  final alreadySeeded = preferences.getBool(_featuredSeededKey) == true;
  var changed = false;
  for (final featured in presets) {
    final revisionKey = 'featuredPresetRev_${featured.id}';
    final hashKey = 'featuredPresetHash_${featured.id}';
    final savedRevision = preferences.getInt(revisionKey);
    if (savedRevision != null && savedRevision >= featured.revision) continue;

    final existing = await repo.getById(featured.id);
    final bundled = await loadFeaturedPreset(featured);
    if (existing == null) {
      final knownDeleted =
          savedRevision != null ||
          (alreadySeeded && _legacyFeaturedIds.contains(featured.id));
      if (!knownDeleted) {
        changed =
            await repo.putIfUnchanged(bundled, insertIfMissing: true) ||
            changed;
      }
    } else {
      final previousHash =
          preferences.getString(hashKey) ?? featured.previousContentHash;
      if (previousHash != null &&
          featuredPresetContentHash(existing) == previousHash) {
        changed =
            await repo.putIfUnchanged(bundled, expectedExisting: existing) ||
            changed;
      }
    }
    // Track the bundle, never a customized copy. Future updates compare with
    // what was shipped; even a skipped/deleted preset has now been considered.
    await preferences.setString(hashKey, featuredPresetContentHash(bundled));
    await preferences.setInt(revisionKey, featured.revision);
  }
  await preferences.setBool(_featuredSeededKey, true);
  return changed;
}
