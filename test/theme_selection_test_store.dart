import 'dart:async';

import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_selection.dart';

const selectionA = ThemePreset(id: 'a', name: 'A');
const selectionB = ThemePreset(id: 'b', name: 'B', accentColor: '#112233');
const selectionC = ThemePreset(id: 'c', name: 'C', accentColor: '#445566');

class ThemeSelectionBacking {
  ThemeSelectionBacking({List<ThemePreset>? presets, this.activeId = 'a'})
    : presets = List.of(presets ?? [selectionA, selectionB, selectionC]);
  List<ThemePreset> presets;
  String activeId;
  bool malformed = false;
}

class ThemeSelectionGate {
  final started = Completer<void>();
  final release = Completer<void>();
  Future<void> pause() {
    started.complete();
    return release.future;
  }
}

enum ThemeSelectionSyntheticWrite {
  accepted,
  falseBeforeWrite,
  throwBeforeWrite,
  writeThenThrow,
  falseAfterWrite,
  acceptedWithoutWrite,
}

/// Independent backing list/selection and per-instance cache. No preferences,
/// DB, widget bootstrap, native plugin, file or network path is evaluated.
class ThemeSelectionTestStore implements ThemePresetStore, ThemeSelectionStore {
  ThemeSelectionTestStore(this.backing)
    : cachedPresets = List.of(backing.presets),
      cachedActiveId = backing.activeId;

  final ThemeSelectionBacking backing;
  List<ThemePreset> cachedPresets;
  String cachedActiveId;
  final checkedWrites = <String>[];
  final ordinaryWrites = <String>[];
  final savedLists = <List<ThemePreset>>[];
  final freshReadGates = <ThemeSelectionGate>[];
  final writeGates = <ThemeSelectionGate>[];
  final saveGates = <ThemeSelectionGate>[];
  final loadGates = <ThemeSelectionGate>[];
  final checkedModes = <ThemeSelectionSyntheticWrite>[];
  int freshReads = 0;
  int failAtFreshRead = -1;
  void Function()? afterCheckedWrite;

  @override
  Future<List<ThemePreset>> loadAll() async {
    final snapshot = List<ThemePreset>.of(cachedPresets);
    if (loadGates.isNotEmpty) await loadGates.removeAt(0).pause();
    return snapshot;
  }

  @override
  Future<String> loadActiveId() async => cachedActiveId;

  @override
  Future<ThemeSelectionStoredState> readSelectionFresh() async {
    ++freshReads;
    final shouldFail = freshReads == failAtFreshRead;
    if (freshReadGates.isNotEmpty) await freshReadGates.removeAt(0).pause();
    if (shouldFail) throw StateError('SYNTHETIC_PRIVATE_EXCEPTION_CANARY');
    cachedPresets = List.of(backing.presets);
    cachedActiveId = backing.activeId;
    if (backing.malformed) throw const ThemeSelectionInvalidStorage();
    return ThemeSelectionStoredState(
      presets: cachedPresets,
      activeId: cachedActiveId,
    );
  }

  @override
  Future<bool> setActiveChecked(String id) {
    checkedWrites.add(id); // invocation starts synchronously, before any gate
    final mode = checkedModes.isEmpty
        ? ThemeSelectionSyntheticWrite.accepted
        : checkedModes.removeAt(0);
    return _write(id, mode: mode, checked: true);
  }

  Future<bool> _write(
    String id, {
    required ThemeSelectionSyntheticWrite mode,
    required bool checked,
  }) async {
    // Deliberately optimistic cache, even when backing write will be rejected.
    cachedActiveId = id;
    if (writeGates.isNotEmpty) await writeGates.removeAt(0).pause();
    if (mode == ThemeSelectionSyntheticWrite.falseBeforeWrite) return false;
    if (mode == ThemeSelectionSyntheticWrite.throwBeforeWrite) {
      throw StateError('SYNTHETIC_PRIVATE_EXCEPTION_CANARY');
    }
    if (mode != ThemeSelectionSyntheticWrite.acceptedWithoutWrite) {
      backing.activeId = id;
    }
    if (checked) afterCheckedWrite?.call();
    if (mode == ThemeSelectionSyntheticWrite.writeThenThrow) {
      throw StateError('SYNTHETIC_PRIVATE_EXCEPTION_CANARY');
    }
    return mode != ThemeSelectionSyntheticWrite.falseAfterWrite;
  }

  @override
  Future<void> setActive(String id) async {
    ordinaryWrites.add(id);
    await _write(
      id,
      mode: ThemeSelectionSyntheticWrite.accepted,
      checked: false,
    );
  }

  @override
  Future<void> saveAll(List<ThemePreset> presets) async {
    final snapshot = List<ThemePreset>.of(presets);
    savedLists.add(snapshot);
    if (saveGates.isNotEmpty) await saveGates.removeAt(0).pause();
    backing.presets = snapshot;
    cachedPresets = List.of(snapshot);
  }

  @override
  Future<void> addPreset(ThemePreset preset) async {
    await saveAll([...backing.presets.where((p) => p.id != preset.id), preset]);
  }

  @override
  Future<void> removePreset(String id) async {
    await saveAll(backing.presets.where((p) => p.id != id).toList());
  }

  @override
  Future<ThemePreset> importFromFile(String path) =>
      throw StateError('File access forbidden in selection fixture');
}

class ThemeSelectionHarness {
  ThemeSelectionHarness(ThemeSelectionBacking backing)
    : store = ThemeSelectionTestStore(backing) {
    notifier = ThemeNotifier(
      storage: store,
      delay: (_) {
        final pending = Completer<void>();
        _delays.add(pending);
        return pending.future;
      },
    );
  }
  final ThemeSelectionTestStore store;
  late final ThemeNotifier notifier;
  final _delays = <Completer<void>>[];
  bool retired = false;

  static Future<ThemeSelectionHarness> create([
    ThemeSelectionBacking? backing,
  ]) async {
    final harness = ThemeSelectionHarness(backing ?? ThemeSelectionBacking());
    await harness.notifier.flushPersistence();
    return harness;
  }

  Future<ThemeSelectionPlan> plan([String target = 'b']) async {
    final read = await notifier.observeInstalledThemes(isCurrent: () => true);
    if (read.code != ThemeSelectionCode.ready) {
      throw StateError('Synthetic plan not ready: ${read.code}');
    }
    return read.observation!.planFor(target)!;
  }

  void dispose() {
    if (retired) return;
    retired = true;
    notifier.dispose();
    for (final delay in _delays) {
      delay.complete();
    }
  }
}
