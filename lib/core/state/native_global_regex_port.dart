import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/preset.dart';
import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'native_global_regex_json.dart';

/// Passive custody populated ONLY by the real notifier's ordinary build. Reading
/// this registry cannot read, flush or create a regex/preferences producer.
final class NativeGlobalRegexOwnerRegistry {
  final _owners =
      <
        Object,
        ({
          ProviderContainer container,
          NativeGlobalRegexPort? Function(bool Function()) capture,
        })
      >{};
  bool _disposed = false;

  void Function() register(
    ProviderContainer container,
    NativeGlobalRegexPort? Function(bool Function()) capture,
  ) {
    if (_disposed) return () {};
    final token = Object();
    _owners[token] = (container: container, capture: capture);
    return () => _owners.remove(token);
  }

  NativeGlobalRegexPort? capture(
    ProviderContainer container,
    bool Function() current,
  ) {
    if (_disposed) return null;
    // The passive registry may itself be inherited from a parent. Custody is
    // scoped to the notifier's ACTUAL build container, not that shared registry.
    // Inherited foreign owners are deliberately unavailable: matching prefs or
    // ancestry cannot authorize a root/sibling to adopt a child override.
    final owners = _owners.entries
        .where((entry) => identical(entry.value.container, container))
        .toList();
    if (owners.length != 1) return null;
    final original = owners.single;
    return original.value.capture(
      () =>
          !_disposed &&
          identical(_owners[original.key]?.container, container) &&
          identical(_owners[original.key]?.capture, original.value.capture) &&
          current(),
    );
  }

  void dispose() {
    _disposed = true;
    _owners.clear();
  }
}

final nativeGlobalRegexOwnerRegistryProvider =
    Provider<NativeGlobalRegexOwnerRegistry>((ref) {
      final registry = NativeGlobalRegexOwnerRegistry();
      ref.onDispose(registry.dispose);
      return registry;
    });

/// Observes the ACTUAL preferences provider/container retained by ordinary build
/// before its first await. Invalidation emits disposal synchronously; no state
/// getter, read/flush, replacement lookup or matching cache can renew this guard.
final class NativeGlobalRegexProducerLifetime extends ProviderObserver {
  NativeGlobalRegexProducerLifetime(this.container, this.provider) {
    container.observers.add(this);
  }
  final ProviderContainer container;
  final Object provider;
  bool _retired = false;
  // Riverpod exposes no container-disposed getter. Original producer disposal
  // and the regex build's own onDispose both synchronously retire this observer.
  bool get current => !_retired;

  bool _original(ProviderObserverContext context) =>
      identical(context.container, container) && context.provider == provider;

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    if (_original(context)) _retired = true;
  }

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    if (_original(context) &&
        newValue is AsyncValue &&
        (newValue.isLoading || newValue.hasError)) {
      _retired = true;
    }
  }

  void dispose() {
    _retired = true;
    container.observers.remove(this);
  }
}

/// One original loaded global-regex controller and original plugin producer.
/// Only disable and genuine retained Undo exist; there is no raw JSON setter.
final class NativeGlobalRegexPort {
  NativeGlobalRegexPort({
    required this.controller,
    required this.preferences,
    required this.isOriginalOwnerCurrent,
    required this.revision,
    required this.loaded,
    required this.publish,
  });
  static const key = 'gz_global_regex_scripts';
  final Object controller;
  final TrackedSharedPreferences preferences;
  final bool Function() isOriginalOwnerCurrent;
  final int Function() revision;
  final List<PresetRegex>? Function() loaded;
  final void Function(List<PresetRegex>) publish;
  bool _retired = false;

  bool get current {
    if (_retired) return false;
    try {
      if (!preferences.store.current ||
          !isOriginalOwnerCurrent() ||
          loaded() == null) {
        _retired = true;
      }
    } catch (_) {
      _retired = true;
    }
    return !_retired;
  }

  void dispose() => _retired = true;

  NativeGlobalRegexObservation? observe(String id) {
    if (!current) return null;
    final lease = preferences.store.owner.capture([
      key,
    ], store: preferences.store);
    final raw = preferences.get(key);
    if (raw is! String || !lease.current) return null;
    final document = NativeGlobalRegexJson.read(raw);
    final scripts = loaded();
    if (document == null ||
        scripts == null ||
        document.rows.length != scripts.length) {
      return null;
    }
    // Require exact already-loaded canonical fields. Defaults, coercion, legacy
    // aliases and a saved read projection cannot manufacture mutation authority.
    for (var i = 0; i < scripts.length; i++) {
      final row = document.rows[i];
      for (final entry in scripts[i].toJson().entries) {
        if (!row.containsKey(entry.key) ||
            jsonEncode(row[entry.key]) != jsonEncode(entry.value)) {
          return null;
        }
      }
    }
    final index = scripts.indexWhere((r) => r.id == id);
    if (index < 0 || !current || !lease.current) return null;
    return NativeGlobalRegexObservation._(
      this,
      id,
      index,
      raw,
      document.disabled(index),
      List.unmodifiable(scripts),
      revision(),
      lease,
    );
  }

  Future<NativeGlobalRegexWrite> disable(
    NativeGlobalRegexObservation observed,
    bool Function() isCurrent,
  ) => _write(
    observed,
    observed.disabledRaw,
    observed.scripts[observed.index].disabled
        ? observed.scripts
        : List.unmodifiable([
            for (var i = 0; i < observed.scripts.length; i++)
              i == observed.index
                  ? observed.scripts[i].copyWith(disabled: true)
                  : observed.scripts[i],
          ]),
    isCurrent,
  );

  Future<NativeGlobalRegexWrite> undo(
    NativeGlobalRegexObservation observed,
    NativeGlobalRegexReceipt receipt,
    bool Function() isCurrent,
  ) {
    if (!identical(receipt.owner, this) ||
        !receipt.current ||
        receipt.id != observed.id ||
        receipt.afterRaw != observed.raw) {
      return Future.value(
        const NativeGlobalRegexWrite._(false, false, false, null),
      );
    }
    return _write(
      observed,
      receipt.beforeRaw,
      receipt.beforeScripts,
      isCurrent,
    );
  }

  Future<NativeGlobalRegexWrite> _write(
    NativeGlobalRegexObservation observed,
    String next,
    List<PresetRegex> scripts,
    bool Function() isCurrent,
  ) async {
    if (!identical(observed.owner, this) || !isCurrent() || !observed.current) {
      return const NativeGlobalRegexWrite._(false, false, false, null);
    }
    final originalRevision = observed._revision;
    ({bool started, bool accepted, SavedPreferencesLease? receipt}) result;
    try {
      result = await preferences.compareAndSetString(
        key: key,
        expectedRaw: observed.raw,
        value: next,
        expected: observed._lease,
        // The native CAS consumes its read lease itself. Do not check that lease
        // after admission; retain the original controller/state and own revision.
        isCurrent: () =>
            isCurrent() &&
            current &&
            revision() == originalRevision &&
            _sameScripts(loaded(), observed.scripts),
      );
    } catch (_) {
      preferences.store.owner.acknowledge(preferences.store, key, false);
      return const NativeGlobalRegexWrite._(true, false, false, null);
    }
    final saved = result.started && result.accepted;
    // A true ORIGINAL plugin ack survives lost store/controller/publication.
    if (!saved ||
        !current ||
        !isCurrent() ||
        revision() != originalRevision ||
        result.receipt?.current != true ||
        preferences.get(key) != next ||
        !_sameScripts(loaded(), observed.scripts)) {
      return NativeGlobalRegexWrite._(result.started, saved, false, null);
    }
    try {
      publish(scripts);
    } catch (_) {
      return NativeGlobalRegexWrite._(result.started, true, false, null);
    }
    if (!current ||
        !isCurrent() ||
        result.receipt?.current != true ||
        revision() != originalRevision + 1 ||
        !_sameScripts(loaded(), scripts)) {
      return NativeGlobalRegexWrite._(result.started, true, false, null);
    }
    return NativeGlobalRegexWrite._(
      result.started,
      true,
      true,
      NativeGlobalRegexReceipt._(
        this,
        observed.id,
        observed.raw,
        next,
        observed.scripts,
        scripts,
        originalRevision + 1,
        result.receipt!,
      ),
    );
  }

  static bool _sameScripts(List<PresetRegex>? a, List<PresetRegex> b) =>
      a != null &&
      a.length == b.length &&
      Iterable<int>.generate(b.length).every((i) => a[i] == b[i]);
}

final class NativeGlobalRegexObservation {
  NativeGlobalRegexObservation._(
    this.owner,
    this.id,
    this.index,
    this.raw,
    this.disabledRaw,
    this.scripts,
    this._revision,
    this._lease,
  );
  final NativeGlobalRegexPort owner;
  final String id, raw, disabledRaw;
  final int index, _revision;
  final List<PresetRegex> scripts;
  final SavedPreferencesLease _lease;
  bool _retired = false;
  bool get disabled => scripts[index].disabled;
  bool get current {
    if (_retired) return false;
    if (!owner.current ||
        !_lease.current ||
        owner.revision() != _revision ||
        owner.preferences.get(NativeGlobalRegexPort.key) != raw ||
        !NativeGlobalRegexPort._sameScripts(owner.loaded(), scripts)) {
      _retired = true;
    }
    return !_retired;
  }
}

/// Genuine private native custody; never reconstructible from journal JSON.
final class NativeGlobalRegexReceipt {
  NativeGlobalRegexReceipt._(
    this.owner,
    this.id,
    this.beforeRaw,
    this.afterRaw,
    this.beforeScripts,
    this.afterScripts,
    this._revision,
    this._lease,
  );
  final NativeGlobalRegexPort owner;
  final String id, beforeRaw, afterRaw;
  final List<PresetRegex> beforeScripts, afterScripts;
  final int _revision;
  final SavedPreferencesLease _lease;
  bool _retired = false;
  bool get current {
    if (_retired) return false;
    if (!owner.current ||
        !_lease.current ||
        owner.revision() != _revision ||
        owner.preferences.get(NativeGlobalRegexPort.key) != afterRaw ||
        !NativeGlobalRegexPort._sameScripts(owner.loaded(), afterScripts)) {
      _retired = true;
    }
    return !_retired;
  }
}

final class NativeGlobalRegexWrite {
  const NativeGlobalRegexWrite._(
    this.started,
    this.saved,
    this.published,
    this.receipt,
  );
  final bool started, saved, published;
  final NativeGlobalRegexReceipt? receipt;
}
