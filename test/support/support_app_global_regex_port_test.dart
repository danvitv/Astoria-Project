import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/state/global_regex_provider.dart';
import 'package:glaze_flutter/core/state/native_global_regex_json.dart';
import 'package:glaze_flutter/core/state/native_global_regex_port.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';

import 'support_app_domain_loop_fixture.dart';
import 'support_app_global_regex_fixture.dart';

/// Only the fixture's original in-memory plugin. No singleton/reload/channels,
/// real preferences, raw real store or replacement application is consulted.
final class _RegexAckProducer implements SharedPreferences {
  _RegexAckProducer(this.raw);
  final SharedPreferences raw;
  bool falseAfterEffect = false, throwAfterEffect = false;
  int writes = 0;
  Future<void> Function()? afterEffect;
  @override
  Object? get(String key) => raw.get(key);
  @override
  String? getString(String key) => raw.getString(key);
  @override
  Future<bool> setString(String key, String value) async {
    expect(key, NativeGlobalRegexPort.key);
    writes++;
    final accepted = await raw.setString(key, value);
    await afterEffect?.call();
    if (throwAfterEffect)
      throw StateError('Synthetic original regex ack lost.');
    return falseAfterEffect ? false : accepted;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Outside finite synthetic global regex producer.');
}

/// Standalone finite-port fault injection retains the actual loaded notifier and
/// one ORIGINAL synthetic producer before any await. It does not issue the graph's
/// capture seam or attest a replacement producer as that notifier's loaded store.
NativeGlobalRegexPort _faultPort(
  GlobalRegexNotifier controller,
  TrackedSharedPreferences preferences,
  bool Function() current,
) {
  var revision = 0;
  List<PresetRegex> scripts = controller.state.value!;
  return NativeGlobalRegexPort(
    controller: controller,
    preferences: preferences,
    isOriginalOwnerCurrent: current,
    revision: () => revision,
    loaded: () => scripts,
    publish: (next) {
      revision++;
      scripts = next;
      controller.state = AsyncData(next);
    },
  );
}

void main() {
  for (final failure in ['false', 'throw']) {
    domainLoopTest(
      'original GLOBAL $failure after effect is uncertain, no publication/receipt/retry',
      (tester, f) async {
        final core = f.screen.core;
        final original = await loadedGlobalRegex(tester, f);
        final producer = _RegexAckProducer(core.prefs)
          ..falseAfterEffect = failure == 'false'
          ..throwAfterEffect = failure == 'throw';
        SavedPreferencesOwner.process.attach(producer, trustedPlugin: true);
        final prefs =
            TrackedSharedPreferences.wrap(producer) as TrackedSharedPreferences;
        expect(
          original.controller.captureNativePort(
            prefs,
            () => core.native.native.isCurrent,
          ),
          isNull,
        );
        final port = _faultPort(
          original.controller,
          prefs,
          () => core.native.native.isCurrent,
        );
        try {
          final result = await configurationAction(
            tester,
            () => port.disable(
              port.observe(syntheticGlobalRegexId)!,
              () => core.native.native.isCurrent,
            ),
          );
          expect(
            core.prefs.getString(NativeGlobalRegexPort.key),
            NativeGlobalRegexJson.read(original.raw)!.disabled(0),
          );
          expect(producer.writes, 1);
          expect(result.started, true);
          expect(result.saved, false);
          expect(result.published, false);
          expect(result.receipt, isNull);
          expect(
            core.container.read(globalRegexProvider).value!.first.disabled,
            false,
          );
          expect(port.observe(syntheticGlobalRegexId), isNull);
        } finally {
          port.dispose();
        }
      },
    );
  }

  for (final change in ['store', 'controller']) {
    domainLoopTest(
      'original GLOBAL $change retired in flight preserves true ack without publication',
      (tester, f) async {
        final core = f.screen.core;
        final original = await loadedGlobalRegex(tester, f);
        final producer = _RegexAckProducer(core.prefs);
        SavedPreferencesOwner.process.attach(producer, trustedPlugin: true);
        final prefs =
            TrackedSharedPreferences.wrap(producer) as TrackedSharedPreferences;
        var ownerCurrent = true;
        final port = _faultPort(
          original.controller,
          prefs,
          () => ownerCurrent && core.native.native.isCurrent,
        );
        final gates = await configurationAction(
          tester,
          () => (f.release(), f.release()),
        );
        final entered = gates.$1, release = gates.$2;
        producer.afterEffect = () async {
          entered.complete();
          await release.future;
        };
        try {
          final observed = port.observe(syntheticGlobalRegexId)!;
          final pending = await configurationAction(
            tester,
            () => (
              future: port.disable(
                observed,
                () => core.native.native.isCurrent,
              ),
            ),
          );
          await f.screen.join(tester, entered.future);
          await configurationAction(tester, () {
            if (change == 'store') {
              SavedPreferencesOwner.process.attach(
                _RegexAckProducer(core.prefs),
                trustedPlugin: true,
              );
            } else {
              ownerCurrent = false;
              core.container.invalidate(globalRegexProvider);
            }
            release.complete();
          });
          final result = await f.screen.join(tester, pending.future);
          expect(
            core.prefs.getString(NativeGlobalRegexPort.key),
            NativeGlobalRegexJson.read(original.raw)!.disabled(0),
          );
          expect(producer.writes, 1);
          expect(result.started, true);
          expect(result.saved, true);
          expect(result.published, false);
          expect(result.receipt, isNull);
          expect(port.observe(syntheticGlobalRegexId), isNull);
        } finally {
          producer.afterEffect = null;
          port.dispose();
        }
      },
    );
  }

  domainLoopTest(
    'original GLOBAL final actual CAS guard retirement starts zero plugin writes',
    (tester, f) async {
      final core = f.screen.core;
      final original = await loadedGlobalRegex(tester, f);
      final producer = _RegexAckProducer(core.prefs);
      SavedPreferencesOwner.process.attach(producer, trustedPlugin: true);
      final prefs =
          TrackedSharedPreferences.wrap(producer) as TrackedSharedPreferences;
      final port = _faultPort(
        original.controller,
        prefs,
        () => core.native.native.isCurrent,
      );
      var admissions = 0;
      try {
        final observed = port.observe(syntheticGlobalRegexId)!;
        final result = await configurationAction(
          tester,
          () => port.disable(observed, () => ++admissions < 3),
        );
        expect(admissions, 3); // Port, read CAS, actual plugin CAS start.
        expect(producer.writes, 0);
        expect(result.started, false);
        expect(result.saved, false);
        expect(result.receipt, isNull);
        expect(core.prefs.getString(NativeGlobalRegexPort.key), original.raw);
      } finally {
        port.dispose();
      }
    },
  );

  domainLoopTest(
    'GLOBAL lossless observer rejects ambiguous or noncanonical original JSON',
    (tester, f) async {
      final core = f.screen.core;
      final original = await loadedGlobalRegex(tester, f);
      final port = original.controller.captureNativePort(
        original.prefs,
        () => core.native.native.isCurrent,
      )!;
      try {
        for (final invalid in [
          original.raw.replaceFirst('"disabled":false', '"disabled":0'),
          original.raw.replaceFirst(
            '"disabled":false',
            '"disabled":false,"disabl\\u0065d":false',
          ),
          original.raw.replaceFirst(
            '"id":"other-global"',
            '"id":"$syntheticGlobalRegexId"',
          ),
          original.raw.replaceFirst(
            '"id":"$syntheticGlobalRegexId"',
            '"id":""',
          ),
          original.raw.replaceFirst('"replacement":', '"notReplacement":'),
        ]) {
          await configurationAction(
            tester,
            () => original.prefs.setString(NativeGlobalRegexPort.key, invalid),
          );
          expect(port.observe(syntheticGlobalRegexId), isNull);
          expect(
            original.prefs.getString(NativeGlobalRegexPort.key),
            invalid,
          ); // No normalization/persist.
        }
        expect(
          core.container.read(globalRegexProvider).value!.first.disabled,
          false,
        );
      } finally {
        port.dispose();
      }
    },
  );

  domainLoopTest(
    'GLOBAL native receipt refuses same-value raw ABA and is never JSON-authorized',
    (tester, f) async {
      final core = f.screen.core;
      final original = await loadedGlobalRegex(tester, f);
      final port = original.controller.captureNativePort(
        original.prefs,
        () => core.native.native.isCurrent,
      )!;
      try {
        final written = await configurationAction(
          tester,
          () => port.disable(
            port.observe(syntheticGlobalRegexId)!,
            () => core.native.native.isCurrent,
          ),
        );
        expect(written.saved, true);
        expect(written.published, true);
        final receipt = written.receipt!;
        await configurationAction(
          tester,
          () => original.prefs.setString(
            NativeGlobalRegexPort.key,
            receipt.afterRaw,
          ),
        );
        expect(receipt.current, false);
        final observed = port.observe(syntheticGlobalRegexId)!;
        final undone = await configurationAction(
          tester,
          () =>
              port.undo(observed, receipt, () => core.native.native.isCurrent),
        );
        expect(undone.started, false);
        expect(
          original.prefs.getString(NativeGlobalRegexPort.key),
          receipt.afterRaw,
        );
      } finally {
        port.dispose();
      }
    },
  );
}
