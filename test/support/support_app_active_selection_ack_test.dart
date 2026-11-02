import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/native_active_selection_port.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';

import 'support_app_domain_loop_fixture.dart';

/// Faults over ONLY the fixture's original in-memory plugin. No disk, channels,
/// singleton reload, real preferences or replacement application is used.
final class _AckProducer implements SharedPreferences {
  _AckProducer(this.raw);
  final SharedPreferences raw;
  bool falseAfterEffect = false, throwAfterEffect = false;
  int writes = 0;
  Future<void> Function()? afterEffect;
  @override
  Object? get(String key) => raw.get(key);
  @override
  String? getString(String key) => raw.getString(key);
  Future<bool> _effect(Future<bool> Function() action) async {
    writes++;
    final acknowledged = await action();
    await afterEffect?.call();
    if (throwAfterEffect) throw StateError('synthetic acknowledgement lost');
    return falseAfterEffect ? false : acknowledged;
  }
  @override
  Future<bool> setString(String key, String value) =>
      _effect(() => raw.setString(key, value));
  @override
  Future<bool> remove(String key) => _effect(() => raw.remove(key));
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Outside finite synthetic selection acknowledgement producer.');
}

void main() {
  for (final failure in ['false', 'throw']) {
    domainLoopTest('original nullable selection remove $failure aftereffect is uncertain',
        (tester, f) async {
      final core = f.screen.core;
      core.isolation.extraAllowed.add(activePersonaIdProvider);
      await configurationAction(tester,
          () => core.prefs.setString('activePersonaId', 'domain-persona'));
      final producer = _AckProducer(core.prefs)
        ..falseAfterEffect = failure == 'false'
        ..throwAfterEffect = failure == 'throw';
      SavedPreferencesOwner.process.attach(producer, trustedPlugin: true);
      final prefs = TrackedSharedPreferences.wrap(producer) as TrackedSharedPreferences;
      final original = core.container.read(activePersonaIdProvider.notifier);
      original.state = 'domain-persona';
      final port = NativeActiveSelectionPort(kind: NativeActiveSelectionKind.persona,
          controller: original, preferences: prefs,
          isOriginalOwnerCurrent: () => core.native.native.isCurrent);
      try {
        final observed = port.observe()!;
        final result = await configurationAction(tester, () => port.write(
            observed: observed, value: null,
            isCurrent: () => core.native.native.isCurrent));
        expect(core.prefs.containsKey('activePersonaId'), false);
        expect(producer.writes, 1);
        expect(result.started, true);
        expect(result.saved, false);
        expect(result.published, false);
        expect(result.receipt, isNull);
        expect(original.state, 'domain-persona');
        expect(port.observe(), isNull);
      } finally {
        port.dispose();
      }
    });
  }

  domainLoopTest('original selection store replaced in flight preserves acknowledged fact',
      (tester, f) async {
    final core = f.screen.core;
    core.isolation.extraAllowed.add(activePresetIdProvider);
    final producer = _AckProducer(core.prefs);
    SavedPreferencesOwner.process.attach(producer, trustedPlugin: true);
    final prefs = TrackedSharedPreferences.wrap(producer) as TrackedSharedPreferences;
    final original = core.container.read(activePresetIdProvider.notifier);
    final port = NativeActiveSelectionPort(kind: NativeActiveSelectionKind.preset,
        controller: original, preferences: prefs,
        isOriginalOwnerCurrent: () => core.native.native.isCurrent);
    final gates = await configurationAction(tester, () => (f.release(), f.release()));
    final entered = gates.$1, release = gates.$2;
    producer.afterEffect = () async { entered.complete(); await release.future; };
    try {
      final observed = port.observe()!;
      final pending = await configurationAction(tester, () => (future: port.write(
          observed: observed, value: 'domain-collision',
          isCurrent: () => core.native.native.isCurrent)));
      await f.screen.join(tester, entered.future);
      // Attest a second synthetic producer only to RETIRE the original lifetime.
      // Never resolve/write it or use it to renew the original port's authority.
      final replacement = _AckProducer(core.prefs);
      SavedPreferencesOwner.process.attach(replacement, trustedPlugin: true);
      await configurationAction(tester, release.complete);
      final result = await f.screen.join(tester, pending.future);
      expect(core.prefs.getString('activePresetId'), 'domain-collision');
      expect(producer.writes, 1);
      expect(replacement.writes, 0);
      expect(result.started, true);
      expect(result.saved, true);
      expect(result.published, false);
      expect(result.receipt, isNull);
      expect(original.state, isNull);
      expect(port.observe(), isNull);
    } finally {
      producer.afterEffect = null;
      port.dispose();
    }
  });

  domainLoopTest('original selection throwing publication listener preserves acknowledged fact',
      (tester, f) async {
    final core = f.screen.core;
    core.isolation.extraAllowed.add(activePersonaIdProvider);
    final producer = _AckProducer(core.prefs);
    SavedPreferencesOwner.process.attach(producer, trustedPlugin: true);
    final prefs = TrackedSharedPreferences.wrap(producer) as TrackedSharedPreferences;
    final original = core.container.read(activePersonaIdProvider.notifier);
    final port = NativeActiveSelectionPort(kind: NativeActiveSelectionKind.persona,
        controller: original, preferences: prefs,
        isOriginalOwnerCurrent: () => core.native.native.isCurrent);
    final remove = original.addListener((_) =>
        throw StateError('synthetic publication listener failed'), fireImmediately: false);
    final reported = <Object>[];
    try {
      final observed = port.observe()!;
      final result = await configurationAction(tester, () => runZoned(() => port.write(
          observed: observed, value: 'domain-persona',
          isCurrent: () => core.native.native.isCurrent),
          zoneSpecification: ZoneSpecification(handleUncaughtError:
              (self, parent, zone, error, stack) => reported.add(error))));
      expect(core.prefs.getString('activePersonaId'), 'domain-persona');
      expect(result.started, true);
      expect(result.saved, true);
      expect(result.published, false);
      expect(result.receipt, isNull);
      expect(producer.writes, 1);
      expect(reported.every((e) => e.toString().contains(
          'synthetic publication listener failed')), true);
    } finally {
      remove();
      port.dispose();
    }
  });

  domainLoopTest('original selection final admission guard retirement starts zero plugin writes',
      (tester, f) async {
    final core = f.screen.core;
    core.isolation.extraAllowed.add(activePersonaIdProvider);
    final producer = _AckProducer(core.prefs);
    SavedPreferencesOwner.process.attach(producer, trustedPlugin: true);
    final prefs = TrackedSharedPreferences.wrap(producer) as TrackedSharedPreferences;
    final original = core.container.read(activePersonaIdProvider.notifier);
    final port = NativeActiveSelectionPort(kind: NativeActiveSelectionKind.persona,
        controller: original, preferences: prefs,
        isOriginalOwnerCurrent: () => core.native.native.isCurrent);
    var admissions = 0;
    try {
      final observed = port.observe()!;
      final result = await configurationAction(tester, () => port.write(
          observed: observed, value: 'domain-persona',
          isCurrent: () => ++admissions < 3));
      // Port admission, CAS read admission, then the actual pending CAS start.
      expect(admissions, 3);
      expect(producer.writes, 0);
      expect(result.started, false);
      expect(result.saved, false);
      expect(result.receipt, isNull);
    } finally {
      port.dispose();
    }
  });
}
