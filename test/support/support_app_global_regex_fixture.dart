import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/state/global_regex_provider.dart';
import 'package:glaze_flutter/core/state/native_global_regex_port.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';

import 'support_app_domain_loop_fixture.dart';

const syntheticGlobalRegexId = 'native-global-existing';
const syntheticGlobalRegex = PresetRegex(
  id: syntheticGlobalRegexId,
  name: DomainLoopFixture.private,
  regex: '${DomainLoopFixture.private}([',
  replacement: '${DomainLoopFixture.private}{{private}}',
  trimOut: DomainLoopFixture.private,
  macroRules: DomainLoopFixture.private,
);

/// Explicit configuration BEFORE Send, over only the fixture's memory plugin.
/// Load the actual notifier once, then retain private unknown fields and JSON
/// whitespace on the already-loaded original producer. Astoria capture must NOT
/// repeat that normalizing build or persist a canonical copy of this document.
Future<
  ({TrackedSharedPreferences prefs, String raw, GlobalRegexNotifier controller})
>
loadedGlobalRegex(
  WidgetTester tester,
  DomainLoopFixture f, {
  bool disabled = false,
  ProviderContainer? container,
}) async {
  final core = f.screen.core;
  final origin = container ?? core.container;
  core.isolation.extraAllowed.add(globalRegexProvider);
  core.isolation.extraAllowed.add(nativeGlobalRegexOwnerRegistryProvider);
  return configurationAction(tester, () async {
    final producer = await origin.read(sharedPreferencesProvider.future);
    expect(producer, same(core.prefs));
    SavedPreferencesOwner.process.attach(producer, trustedPlugin: true);
    final prefs =
        TrackedSharedPreferences.wrap(producer) as TrackedSharedPreferences;
    final row = syntheticGlobalRegex.copyWith(disabled: disabled).toJson();
    row['enabled'] =
        true; // Unknown flag must stay exactly as originally saved.
    row['privateUnknown'] = {
      'body': DomainLoopFixture.private,
      'nested': [
        {'disabled': false, 'id': syntheticGlobalRegexId},
      ],
      'number': 1.25,
      'null': null,
      'escaped': '"disabled":false',
    };
    final raw =
        '[\n  ${jsonEncode(row)},\n  '
        '${jsonEncode(syntheticGlobalRegex.copyWith(id: 'other-global', disabled: true).toJson())}\n]\n';
    await prefs.setString(NativeGlobalRegexPort.key, raw);
    await origin.read(globalRegexProvider.future);
    final controller = origin.read(globalRegexProvider.notifier);
    // Only explicit ordinary UI initialization may canonicalize. Restore the
    // original private document on that SAME loaded plugin before graph capture.
    await prefs.setString(NativeGlobalRegexPort.key, raw);
    return (prefs: prefs, raw: raw, controller: controller);
  });
}
