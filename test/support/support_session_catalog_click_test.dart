import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support_guidance_screen_fixture.dart';

void main() {
  guidanceScreenTest(
    'another catalog row is clickable while the initial metadata proposal is held; late original cannot replace it',
    (tester, f) async {
      final gate = f.sql.barrier();
      var held = false;
      f.sql.afterRead = (read) async {
        if (!held &&
            read.exactSessionMetadata &&
            read.args.contains(GuidanceScreenFixture.newest)) {
          held = true;
          if (!gate.entered.isCompleted) gate.entered.complete();
          await gate.release.future;
        }
      };
      final open = find.byKey(const ValueKey('support_guidance_gameSession'));
      await f.reveal(tester, open);
      await f.turns.real(tester, () => tester.tap(open));
      await f.turns.until(
        tester,
        () => gate.entered.isCompleted,
        label: 'original initial metadata query held',
      );
      // The query can reach its real gate before the modal's first layout.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await f.turns.until(
        tester,
        () => find
            .byKey(
              ValueKey(
                'support_session_scope_option_${GuidanceScreenFixture.older}',
              ),
            )
            .evaluate()
            .isNotEmpty,
        label:
            'original catalog rows laid out while default query remains held',
      );
      final older = find.byKey(
        ValueKey('support_session_scope_option_${GuidanceScreenFixture.older}'),
      );
      await f.reveal(tester, older);
      await f.turns.real(tester, () => tester.tap(older));
      await f.turns.until(
        tester,
        () {
          final proposal = find.byKey(
            const ValueKey('support_session_scope_proposal'),
          );
          return proposal.evaluate().isNotEmpty &&
              tester.widget<Text>(proposal).data!.endsWith('Session 1');
        },
        label: 'original alternative row chosen despite pending default query',
      );
      expect(f.sql.writes, 0);
      expect((await f.saved(tester)).scope, isNull);
      gate.release.complete();
      await f.idle(tester);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('support_session_scope_proposal')),
            )
            .data,
        endsWith('Session 1'),
      );
      await f.tapKey(tester, 'support_session_scope_confirm');
      await f.idle(tester);
      final p = await f.saved(tester);
      expect(p.scope!.gameSessionId, GuidanceScreenFixture.older);
      expect(p.grants, isEmpty);
      f.noReadersOrWire();
    },
    screen: false,
  );
}
