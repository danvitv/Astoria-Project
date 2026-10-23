import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'theme_preset.dart';
import 'theme_preset_storage.dart';
import 'theme_selection.dart';

export 'theme_selection.dart'
    show
        ThemeSelectionCode,
        ThemeSelectionDisplay,
        ThemeSelectionFreshObservation,
        ThemeSelectionObservation,
        ThemeSelectionPlan,
        ThemeSelectionReadResult,
        ThemeSelectionReceipt,
        ThemeSelectionResult,
        ThemeSelectionWriteAcceptance;

class ThemeSettings {
  final ThemeMode mode;
  final Color accentColor;
  final ThemePreset activePreset;
  final List<ThemePreset> presets;
  final bool ignoreCustomFont;

  const ThemeSettings({
    this.mode = ThemeMode.dark,
    this.accentColor = const Color(0xFFF5C400),
    this.activePreset = const ThemePreset(
      id: 'default',
      name: 'Default',
      accentColor: '#F5C400',
    ),
    this.presets = const [
      ThemePreset(id: 'default', name: 'Default', accentColor: '#F5C400'),
    ],
    this.ignoreCustomFont = false,
  });

  ThemeSettings copyWith({
    ThemeMode? mode,
    Color? accentColor,
    ThemePreset? activePreset,
    List<ThemePreset>? presets,
    bool? ignoreCustomFont,
  }) => ThemeSettings(
    mode: mode ?? this.mode,
    accentColor: accentColor ?? this.accentColor,
    activePreset: activePreset ?? this.activePreset,
    presets: presets ?? this.presets,
    ignoreCustomFont: ignoreCustomFont ?? this.ignoreCustomFont,
  );
}

class ThemeNotifier extends StateNotifier<ThemeSettings> {
  ThemePresetStore? _storage;
  final Future<ThemePresetStore> Function() _storageFactory;
  final Duration _persistenceDebounce;
  final Future<void> Function(Duration) _delay;
  final Completer<void> _ready = Completer<void>();
  Future<void> _writeTail = Future<void>.value();
  List<ThemePreset>? _pendingPresets;
  Object? _persistenceError;
  StackTrace? _persistenceErrorStack;
  Object? _initializationError;
  StackTrace? _initializationErrorStack;
  int _debounceEpoch = 0;
  bool _disposed = false;
  late final ThemeSelectionOwner _selection = ThemeSelectionOwner(
    prepare: flushPersistence,
    sequence: _sequenceWrite,
    storage: () => _storage is ThemeSelectionStore
        ? _storage as ThemeSelectionStore
        : null,
    active: () => state.activePreset,
    publish: (preset) => state = state.copyWith(
      activePreset: preset,
      accentColor: preset.accent,
    ),
  );

  Future<ThemeSelectionReadResult> observeInstalledThemes({
    required bool Function() isCurrent,
  }) => _selection.observe(isCurrent: isCurrent);

  Future<ThemeSelectionResult> applyInstalledSelection(
    ThemeSelectionPlan plan, {
    required bool Function() isCurrent,
  }) => _selection.apply(plan, isCurrent: isCurrent);

  Future<ThemeSelectionResult> undoInstalledSelection(
    ThemeSelectionReceipt receipt, {
    required bool Function() isCurrent,
  }) => _selection.undo(receipt, isCurrent: isCurrent);

  ThemeNotifier({
    ThemePresetStore? storage,
    Future<ThemePresetStore> Function()? storageFactory,
    this._persistenceDebounce = const Duration(milliseconds: 300),
    Future<void> Function(Duration)? delay,
  }) : assert(storage == null || storageFactory == null),
       _storageFactory =
           storageFactory ??
           (storage != null
               ? (() async => storage)
               : ThemePresetStorage.create),
       _delay = delay ?? Future<void>.delayed,
       super(const ThemeSettings()) {
    _init();
  }

  Future<void> _init() async {
    try {
      _storage = await _storageFactory();
      if (_disposed) return;
      await _load();
    } catch (error, stackTrace) {
      _initializationError = error;
      _initializationErrorStack = stackTrace;
    } finally {
      _ready.complete();
    }
  }

  Future<void> _awaitReady() async {
    await _ready.future;
    final error = _initializationError;
    if (error != null) {
      Error.throwWithStackTrace(error, _initializationErrorStack!);
    }
  }

  Future<void> _load({int? expectedRevision}) async {
    bool ownsPublication() =>
        !_disposed &&
        (expectedRevision == null || expectedRevision == _selection.revision);
    if (_storage == null || !ownsPublication()) return;
    final presets = await _storage!.loadAll();
    if (!ownsPublication()) return;
    final activeId = await _storage!.loadActiveId();
    if (!ownsPublication()) return;
    final active = presets.firstWhere(
      (p) => p.id == activeId,
      orElse: () => presets.first,
    );
    state = ThemeSettings(
      mode: state.mode,
      accentColor: active.accent,
      activePreset: active,
      presets: presets,
    );
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_disposed) return;
    _selection.admitOrdinaryMutation();
    state = state.copyWith(mode: mode);
  }

  Future<void> setAccentColor(Color color) async {
    if (_disposed) return;
    _selection.admitOrdinaryMutation();
    state = state.copyWith(accentColor: color);
  }

  Future<void> applyPreset(ThemePreset preset) async {
    _selection.admitOrdinaryMutation();
    await _awaitReady();
    if (_disposed) return;
    state = state.copyWith(accentColor: preset.accent, activePreset: preset);
    await _sequenceWrite(() async {
      if (_disposed) return;
      await _storage!.setActive(preset.id);
    });
  }

  Future<void> importPreset(ThemePreset preset) async {
    final revision = _selection.admitOrdinaryMutation();
    await _awaitReady();
    if (_disposed) return;
    await flushPersistence();
    if (_disposed) return;
    await _sequenceWrite(() async {
      if (_disposed) return;
      await _storage!.addPreset(preset);
    });
    if (_disposed) return;
    final presets = await _storage!.loadAll();
    if (_disposed || revision != _selection.revision) return;
    state = state.copyWith(presets: presets);
  }

  Future<ThemePreset?> importPresetFromFile(
    String path, {
    bool apply = true,
  }) async {
    _selection.admitOrdinaryMutation();
    await _awaitReady();
    if (_disposed) return null;
    final preset = await _storage!.importFromFile(path);
    if (_disposed) return null;
    await importPreset(preset);
    if (_disposed) return null;
    if (apply) {
      await applyPreset(preset);
    }
    return preset;
  }

  Future<void> deletePreset(String id) async {
    final revision = _selection.admitOrdinaryMutation();
    await _awaitReady();
    if (_disposed) return;
    await flushPersistence();
    if (_disposed) return;
    await _sequenceWrite(() async {
      if (_disposed) return;
      await _storage!.removePreset(id);
    });
    if (_disposed) return;
    final presets = await _storage!.loadAll();
    if (_disposed || revision != _selection.revision) return;
    var active = state.activePreset;
    if (active.id == id) {
      active = presets.first;
    }
    state = state.copyWith(
      presets: presets,
      activePreset: active,
      accentColor: active.accent,
    );
  }

  /// Live-update the active preset and persist it (mirrors JS auto-save on change).
  Future<void> updatePreset(ThemePreset preset) {
    _selection.admitOrdinaryMutation();
    if (!_ready.isCompleted) return _updatePresetWhenReady(preset);
    final error = _initializationError;
    if (error != null) {
      return Future<void>.error(error, _initializationErrorStack);
    }
    if (_disposed) return Future<void>.value();
    _previewAndSchedulePreset(preset);
    return Future<void>.value();
  }

  Future<void> _updatePresetWhenReady(ThemePreset preset) async {
    await _awaitReady();
    if (_disposed) return;
    _previewAndSchedulePreset(preset);
  }

  void _previewAndSchedulePreset(ThemePreset preset) {
    final updated = state.presets
        .map((p) => p.id == preset.id ? preset : p)
        .toList();
    state = state.copyWith(
      activePreset: preset,
      accentColor: preset.accent,
      presets: updated,
    );
    _pendingPresets = updated;
    final epoch = ++_debounceEpoch;
    unawaited(_persistAfterDebounce(epoch));
  }

  Future<void> _persistAfterDebounce(int epoch) async {
    try {
      await _delay(_persistenceDebounce);
    } catch (error, stackTrace) {
      _recordPersistenceError(error, stackTrace);
      return;
    }
    if (_disposed || epoch != _debounceEpoch) return;
    _enqueuePendingPresets();
  }

  void _enqueuePendingPresets() {
    final presets = _pendingPresets;
    if (presets == null) return;
    _pendingPresets = null;
    unawaited(
      _sequenceWrite(() async {
        if (_disposed) return;
        await _storage!.saveAll(presets);
      }).catchError((Object error, StackTrace stackTrace) {
        _recordPersistenceError(error, stackTrace);
      }),
    );
  }

  Future<T> _sequenceWrite<T>(Future<T> Function() write) {
    final result = _writeTail.then((_) => write());
    _writeTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  void _recordPersistenceError(Object error, StackTrace stackTrace) {
    _persistenceError = error;
    _persistenceErrorStack = stackTrace;
  }

  /// Persists the latest preview immediately and waits for all prior writes.
  Future<void> flushPersistence() async {
    await _awaitReady();
    if (_disposed) return;
    ++_debounceEpoch;
    _enqueuePendingPresets();
    await _writeTail;
    final error = _persistenceError;
    if (error != null) {
      final stackTrace = _persistenceErrorStack!;
      _persistenceError = null;
      _persistenceErrorStack = null;
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> reload() async {
    final revision = _selection.admitOrdinaryMutation();
    await flushPersistence();
    if (_disposed || revision != _selection.revision) return;
    await _sequenceWrite(() => _load(expectedRevision: revision));
  }

  void setIgnoreCustomFont(bool value) {
    if (_disposed) return;
    _selection.admitOrdinaryMutation();
    state = state.copyWith(ignoreCustomFont: value);
  }

  @override
  void dispose() {
    _disposed = true;
    _selection.retire();
    ++_debounceEpoch;
    _pendingPresets = null;
    super.dispose();
  }
}

final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeSettings>(
  (ref) => ThemeNotifier(),
);
