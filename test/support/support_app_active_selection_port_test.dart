import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/native_active_selection_port.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';

import 'support_app_domain_loop_fixture.dart';

/// Finite fault producer over the fixture's ORIGINAL synthetic in-memory plugin.
/// No singleton acquisition, channels, disk, raw real prefs, or replacement app.
final class _SelectionFaultProducer implements SharedPreferences {
  _SelectionFaultProducer(this.raw);
  final SharedPreferences raw;
  bool falseAfterWrite = false, throwAfterWrite = false;
  Future<void> Function()? afterWrite;
  @override
  Object? get(String key) => raw.get(key);
  @override
  String? getString(String key) => raw.getString(key);
  @override
  Future<bool> setString(String key, String value) async {
    final accepted = await raw.setString(key, value);
    await afterWrite?.call();
    if (throwAfterWrite) throw StateError('synthetic acknowledgement lost');
    return falseAfterWrite ? false : accepted;
  }
  @override
  Future<bool> remove(String key) => raw.remove(key);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Outside the finite synthetic selection producer.');
}

void main() {
  for (final failure in ['false', 'throw']) {
    domainLoopTest('original selection $failure acknowledgement cannot certify saved state',
        (tester, f) async {
      final core = f.screen.core;
      core.isolation.extraAllowed.add(activePersonaIdProvider);
      final producer = _SelectionFaultProducer(core.prefs)
        ..falseAfterWrite = failure == 'false'
        ..throwAfterWrite = failure == 'throw';
      SavedPreferencesOwner.process.attach(producer, trustedPlugin: true);
      final prefs = TrackedSharedPreferences.wrap(producer) as TrackedSharedPreferences;
      final original = core.container.read(activePersonaIdProvider.notifier);
      final port = NativeActiveSelectionPort(kind: NativeActiveSelectionKind.persona,
          controller: original, preferences: prefs,
          isOriginalOwnerCurrent: () => core.native.native.isCurrent);
      try {
        final observed = port.observe()!;
        final result = await configurationAction(tester, () => port.write(
            observed: observed, value: 'domain-persona',
            isCurrent: () => core.native.native.isCurrent));
        // The backing plugin DID write. False/throw is not observed no effect.
        expect(core.prefs.getString('activePersonaId'), 'domain-persona');
        expect(result.started, true);
        expect(result.saved, false);
        expect(result.published, false);
        expect(result.receipt, isNull);
        expect(original.state, isNull);
        expect(port.observe(), isNull); // Quarantine; no matching-cache renewal.
      } finally {
        port.dispose();
      }
    });
  }

  domainLoopTest('already-started selection plugin settles after original controller retirement',
      (tester, f) async {
    final core = f.screen.core;
    core.isolation.extraAllowed.add(activePresetIdProvider);
    final producer = _SelectionFaultProducer(core.prefs);
    SavedPreferencesOwner.process.attach(producer, trustedPlugin: true);
    final prefs = TrackedSharedPreferences.wrap(producer) as TrackedSharedPreferences;
    final original = core.container.read(activePresetIdProvider.notifier);
    final port = NativeActiveSelectionPort(kind: NativeActiveSelectionKind.preset,
        controller: original, preferences: prefs,
        isOriginalOwnerCurrent: () => core.native.native.isCurrent);
    final gates = await configurationAction(tester, () => (f.release(), f.release()));
    final entered = gates.$1, release = gates.$2;
    producer.afterWrite = () async {
      entered.complete();
      await release.future;
    };
    try {
      final observed = port.observe()!;
      final pending = await configurationAction(tester, () => (future: port.write(
          observed: observed, value: 'domain-collision',
          isCurrent: () => core.native.native.isCurrent)));
      await f.screen.join(tester, entered.future);
      core.container.invalidate(activePresetIdProvider);
      final replacement = core.container.read(activePresetIdProvider.notifier);
      expect(replacement, isNot(same(original)));
      replacement.state = 'new-controller-selection';
      await configurationAction(tester, release.complete);
      final result = await f.screen.join(tester, pending.future);
      expect(core.prefs.getString('activePresetId'), 'domain-collision');
      expect(result.started, true);
      expect(result.saved, true); // Keep acknowledged persistence, not no effect.
      expect(result.published, false);
      expect(result.receipt, isNull);
      expect(replacement.state, 'new-controller-selection');
      expect(port.observe(), isNull);
    } finally {
      producer.afterWrite = null;
      port.dispose();
    }
  });
}
