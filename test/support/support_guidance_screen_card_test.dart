import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_card_codec.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_card_view.dart';

import 'support_guidance_screen_fixture.dart';

void main() {
  guidanceScreenTest(
    'all 28 restored CardViews are clickable typed navigation only, never serialized authority',
    (tester, f) async {
      const codec = SupportCardCodec();
      expect(SupportGuidanceTarget.values, hasLength(28));
      final destinations = <SupportGuidanceTarget>[];
      for (final target in SupportGuidanceTarget.values) {
        final encoded = codec.encode([SupportGuidanceCard(target: target)]);
        final payload = jsonDecode(encoded) as Map<String, dynamic>;
        expect((payload['cards'] as List).single, {
          'type': 'guidance',
          'target': target.name,
        });
        final restored = codec.decode(encoded).single;
        // Actual CardView action hit, no private executor callback is available.
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: f.container,
            child: MaterialApp(
              home: Material(
                child: Center(
                  child: SizedBox(
                    width: 500,
                    child: SupportCardView(
                      card: restored,
                      onGuidance: destinations.add,
                      onApplyPlan: (_) => fail('Guidance invoked legacy apply'),
                      onRollback: (_) =>
                          fail('Guidance invoked legacy rollback'),
                      onQuickAction: (_) =>
                          fail('Guidance invoked string action'),
                      onSetupAction: (_) =>
                          fail('Guidance invoked string setup'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await f.tapKey(tester, 'support_guidance_${target.name}');
        expect(destinations.last, same(target));
        expect(destinations, hasLength(target.index + 1));
        expect(f.sql.writes, 0);
        expect(f.sql.reads, isEmpty);
        expect(f.crypto, isEmpty);
      }
      for (final field in [
        'label',
        'sessionId',
        'scope',
        'grant',
        'approval',
        'action',
      ]) {
        expect(
          codec.decode(
            jsonEncode({
              'version': 1,
              'cards': [
                {
                  'type': 'guidance',
                  'target': 'readGameData',
                  field: 'foreign',
                },
              ],
            }),
          ),
          isEmpty,
        );
      }
      expect(destinations, SupportGuidanceTarget.values);
      expect((await f.saved(tester)).scope, isNull);
      expect((await f.saved(tester)).grants, isEmpty);
      expect(
        (await f.saved(tester, GuidanceScreenFixture.other)).grants,
        isEmpty,
      );
      f.noReadersOrWire();
    },
    screen: false,
  );
}
