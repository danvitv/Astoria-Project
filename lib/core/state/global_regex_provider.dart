import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/preset.dart';
import 'native_global_regex_port.dart';
import 'shared_prefs_provider.dart';

const _globalRegexKey = 'gz_global_regex_scripts';

/// Normalizes a raw ST-style or Glaze-style global regex script into our canonical PresetRegex JSON shape.
/// Handles field name mappings (scriptName→name, findRegex→regex, etc.) and all ST compatibility flags.
Map<String, dynamic> normalizeJsGlobalRegex(Map<String, dynamic> raw) {
  final map = Map<String, dynamic>.from(raw);
  if (!map.containsKey('id'))
    map['id'] = '${DateTime.now().millisecondsSinceEpoch}';
  if (!map.containsKey('name')) map['name'] = map['scriptName'] ?? 'Imported';
  if (!map.containsKey('regex')) map['regex'] = map['findRegex'] ?? '';
  if (!map.containsKey('replacement'))
    map['replacement'] = map['replaceString'] ?? '';
  if (!map.containsKey('trimOut'))
    map['trimOut'] = _joinTrimStrings(raw['trimStrings']);
  if (!map.containsKey('placement')) {
    final p = raw['placement'];
    if (p is List) {
      map['placement'] = p
          .map((e) => e is int ? e : int.tryParse(e.toString()) ?? 1)
          .toList();
    } else {
      map['placement'] = [1, 2];
    }
  }
  if (!map.containsKey('ephemerality')) {
    // ST scripts don't have ephemerality — they always apply to both
    // display (1) and prompt (2). Default [2] was wrong and caused
    // display-time regex scripts (HEADER, BOOTS, etc.) to be skipped.
    map['ephemerality'] = [1, 2];
  }
  if (map['placement'] is List) {
    map['placement'] = _migrateGlazePlacementIds(
      (map['placement'] as List)
          .map((e) => e is int ? e : int.tryParse(e.toString()) ?? 1)
          .toList(),
    );
  }
  // Preserve runOnEdit as a direct bool for ST compatibility
  if (raw.containsKey('runOnEdit')) {
    map['runOnEdit'] = _coerceToBool(raw['runOnEdit']);
  }
  // Map ST flags to our new fields (accept both camelCase and any ST variants)
  map['markdownOnly'] = _coerceToBool(
    raw['markdownOnly'] ?? raw['markdown_only'],
  );
  map['promptOnly'] = _coerceToBool(raw['promptOnly'] ?? raw['prompt_only']);
  map['substituteRegex'] =
      _coerceToInt(raw['substituteRegex'] ?? raw['substitute_regex']) ?? 0;
  map['minDepth'] = _coerceToInt(map['minDepth']);
  map['maxDepth'] = _coerceToInt(map['maxDepth']);
  map['disabled'] = _coerceToBool(map['disabled']);
  return map;
}

String _joinTrimStrings(dynamic trim) {
  if (trim is List) {
    return trim.whereType<String>().join('\n');
  }
  if (trim is String) return trim;
  return '';
}

int? _coerceToInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

bool _coerceToBool(dynamic v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  return false;
}

List<int> _migrateGlazePlacementIds(List<int> placement) {
  return placement.map((p) => p == 4 ? 5 : p).toList();
}

class GlobalRegexNotifier extends AsyncNotifier<List<PresetRegex>> {
  int _nativeRevision = 0;
  Object? _nativeProducer;
  SavedPreferencesStore? _nativeStore;
  TrackedSharedPreferences? _nativePreferences;
  List<PresetRegex>? _nativeLoaded;
  Object _nativeLoadedLifetime = Object();
  bool Function() _nativeBuildCurrent = () => false;

  /// Only an already-loaded original controller can issue this finite port.
  /// No build, import, normalization or plugin lookup occurs during capture.
  NativeGlobalRegexPort? captureNativePort(
    TrackedSharedPreferences preferences,
    bool Function() originalCurrent,
  ) {
    // AsyncNotifier.state and Ref reads can flush an invalidated build. Use only
    // facts delivered by this build's listenSelf and synchronous disposal guard.
    final buildCurrent = _nativeBuildCurrent;
    if (!buildCurrent() || _nativeLoaded == null) {
      return null;
    }
    if (!identical(preferences.delegate, _nativeProducer) ||
        !identical(preferences.store, _nativeStore) ||
        !preferences.store.current) {
      return null;
    }
    final lifetime = _nativeLifetime;
    final loadedLifetime = _nativeLoadedLifetime;
    return NativeGlobalRegexPort(
      controller: this,
      preferences: preferences,
      isOriginalOwnerCurrent: () =>
          buildCurrent() &&
          originalCurrent() &&
          identical(lifetime, _nativeLifetime) &&
          identical(loadedLifetime, _nativeLoadedLifetime),
      revision: () => _nativeRevision,
      loaded: () =>
          buildCurrent() && identical(loadedLifetime, _nativeLoadedLifetime)
          ? _nativeLoaded
          : null,
      publish: (scripts) {
        _nativeRevision++;
        state = AsyncData(scripts);
      },
    );
  }

  Object _nativeLifetime = Object();

  @override
  Future<List<PresetRegex>> build() {
    final buildRef = ref;
    final lifetime = _nativeLifetime = Object();
    var alive = true;
    NativeGlobalRegexProducerLifetime? originalProducer;
    bool current() =>
        alive &&
        buildRef.mounted &&
        identical(lifetime, _nativeLifetime) &&
        (originalProducer?.current ?? true);
    _nativeBuildCurrent = current;
    _nativeProducer = null;
    _nativeStore = null;
    _nativePreferences = null;
    _nativeLoaded = null;
    _nativeLoadedLifetime = Object();
    _nativeRevision++;
    // Invalidate calls onDispose immediately, before the scheduled rebuild. The
    // original snapshot and all its ports retire without reading notifier.state.
    buildRef.onDispose(() {
      alive = false;
      if (identical(lifetime, _nativeLifetime)) _nativeLoaded = null;
    });
    final registry = buildRef.read(nativeGlobalRegexOwnerRegistryProvider);
    buildRef.onDispose(
      registry.register(buildRef.container, (originalCurrent) {
        if (!current()) return null;
        final preferences = _nativePreferences;
        return preferences == null
            ? null
            : captureNativePort(preferences, originalCurrent);
      }),
    );
    listenSelf((_, next) {
      if (current()) {
        if (next.isLoading || next.hasError) {
          _nativeLoadedLifetime = Object();
        }
        _nativeLoaded = next.isLoading || next.hasError ? null : next.value;
      }
    });
    // Retain the actual producer future and existing raw-plugin store BEFORE
    // awaiting. A tracked result carries its own original store; an untracked
    // result may bind only this pre-await store, never a later matching lookup.
    final originalStore = SavedPreferencesOwner.process.originalStore;
    final producer = buildRef.read(sharedPreferencesProvider.future);
    final producerSource = buildRef.container.allProviders().firstWhere(
      (source) => source.provider == sharedPreferencesProvider,
    );
    final producerLifetime = NativeGlobalRegexProducerLifetime(
      producerSource.container,
      producerSource.provider,
    );
    originalProducer = producerLifetime;
    buildRef.onDispose(producerLifetime.dispose);
    return SavedPreferencesWrites.run([_globalRegexKey], () async {
      final prefs = await producer;
      if (!current()) return [];
      // Retain the producer that actually loaded this notifier. A later graph
      // cannot pair an old controller with a matching replacement store/cache.
      if (current()) {
        _nativeProducer = prefs is TrackedSharedPreferences
            ? prefs.delegate
            : prefs;
        _nativeStore = prefs is TrackedSharedPreferences
            ? prefs.store
            : originalStore != null &&
                  originalStore.current &&
                  identical(originalStore.actualStore, prefs)
            ? originalStore
            : null;
        _nativePreferences = prefs is TrackedSharedPreferences
            ? prefs
            : _nativeStore != null
            ? TrackedSharedPreferences.wrap(prefs) as TrackedSharedPreferences
            : null;
      }
      final raw = prefs.getString(_globalRegexKey);
      if (raw == null || raw.isEmpty) return [];
      try {
        final list = jsonDecode(raw) as List;
        final result = list
            .map(
              (e) => PresetRegex.fromJson(
                normalizeJsGlobalRegex(e as Map<String, dynamic>),
              ),
            )
            .toList();
        if (!current()) return [];
        // Normal UI initialization still normalizes, using the ORIGINAL producer
        // retained before its await, not a replacement preference lookup.
        await SavedPreferencesWrites.run([_globalRegexKey], () async {
          if (!current()) return;
          await prefs.setString(
            _globalRegexKey,
            jsonEncode(result.map((e) => e.toJson()).toList()),
          );
        });
        return result;
      } catch (_) {
        return [];
      }
    });
  }

  Future<void> _persist(List<PresetRegex> scripts) =>
      SavedPreferencesWrites.run([_globalRegexKey], () async {
        final prefs = await ref.read(sharedPreferencesProvider.future);
        final json = scripts.map((e) => e.toJson()).toList();
        await prefs.setString(_globalRegexKey, jsonEncode(json));
      });

  Future<void> addRegex(PresetRegex regex) =>
      SavedPreferencesWrites.run([_globalRegexKey], () async {
        _nativeRevision++;
        final current = state.value ?? [];
        final updated = [...current, regex];
        state = AsyncData(updated);
        await _persist(updated);
      });

  Future<void> updateRegex(PresetRegex regex) => SavedPreferencesWrites.run(
    [_globalRegexKey],
    () async {
      _nativeRevision++;
      final current = state.value ?? [];
      final updated = current.map((r) => r.id == regex.id ? regex : r).toList();
      state = AsyncData(updated);
      await _persist(updated);
    },
  );

  Future<void> removeRegex(String id) =>
      SavedPreferencesWrites.run([_globalRegexKey], () async {
        _nativeRevision++;
        final current = state.value ?? [];
        final updated = current.where((r) => r.id != id).toList();
        state = AsyncData(updated);
        await _persist(updated);
      });

  Future<void> importFromJsBackup(List<dynamic> rawList) =>
      SavedPreferencesWrites.run([_globalRegexKey], () async {
        _nativeRevision++;
        final existing = state.value ?? [];
        final existingIds = existing.map((e) => e.id).toSet();
        final imported = <PresetRegex>[];
        for (final raw in rawList) {
          if (raw is! Map<String, dynamic>) continue;
          try {
            final regex = PresetRegex.fromJson(normalizeJsGlobalRegex(raw));
            if (!existingIds.contains(regex.id)) {
              imported.add(regex);
              existingIds.add(regex.id);
            }
          } catch (_) {}
        }
        if (imported.isNotEmpty) {
          final updated = [...existing, ...imported];
          state = AsyncData(updated);
          await _persist(updated);
        }
      });
}

final globalRegexProvider =
    AsyncNotifierProvider<GlobalRegexNotifier, List<PresetRegex>>(
      GlobalRegexNotifier.new,
    );
