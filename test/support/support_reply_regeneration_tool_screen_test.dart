import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_app_domain_loop_fixture.dart';

void main() {
  domainLoopTest(
    'actual tool-effect answer regenerates without readvertising or replaying an action',
    (tester, f) async {
      final core = f.screen.core;
      core.replies.addAll([
        core.call('astoria_preferences_update', {'hideTooltips': true}),
        core.answer('The delegated preference was saved.'),
        // This old fixture deliberately supplies a non-SSE tool payload. The
        // regeneration text transport must fail closed, never execute it.
        core.call('astoria_preferences_update', {'hideTooltips': false}),
      ]);
      final bridge = core.container.read(supportModelUiBridgeProvider);
      final firstSettled = Completer<void>();
      void observeFirst() {
        final view = bridge.view;
        if (!view.busy &&
            (view.phase == SupportModelPhase.settled ||
                view.reason != SupportModelRefusal.none) &&
            !firstSettled.isCompleted) {
          firstSettled.complete();
        }
      }

      final stopFirst = bridge.listen(observeFirst);
      await tester.enterText(find.byType(TextField).first, 'Hide tooltips.');
      await configurationAction(
        tester,
        () =>
            tester.tap(find.byKey(const ValueKey('support_composer_send_btn'))),
      );
      try {
        await f.screen.join(tester, firstSettled.future);
      } finally {
        stopFirst();
      }
      expect(bridge.view.reason, SupportModelRefusal.none);
      expect(
        bridge.view.status,
        PrivateTextStatus.complete,
        reason: 'First actual attempt: ${bridge.view.transportReason}',
      );
      expect(core.firstFetch.isCompleted, true);
      await tester.pumpAndSettle();
      expect(core.prefs.getBool('hideTooltips'), isTrue);
      await f.screen.revealReply(tester, 'The delegated preference was saved.');
      final row = core.container
          .read(supportWorkspaceProvider)
          .activeMessages
          .last;
      final before = await tester.runAsync(
        () => core.native.db.select(core.native.db.supportMessages).get(),
      );
      final button = find.byKey(ValueKey('support_regenerate_${row.id}'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      final callback = tester.widget<GlazeActionButton>(button).onTap!;
      await configurationAction(tester, () async {
        callback();
        callback();
      });
      await f.screen.terminal(tester);
      await tester.pumpAndSettle();
      expect(core.wire, hasLength(3));
      expect(core.wire.last.containsKey('tools'), isFalse);
      expect(
        core.wire.last['messages'].toString(),
        isNot(contains('The delegated preference was saved.')),
      );
      expect(core.prefs.getBool('hideTooltips'), isTrue);
      final after = await tester.runAsync(
        () => core.native.db.select(core.native.db.supportMessages).get(),
      );
      expect(after, hasLength(before!.length));
      for (final user in before.where((m) => m.role == 'user')) {
        expect(after!.singleWhere((m) => m.id == user.id), user);
      }
      final latest = core.container
          .read(supportWorkspaceProvider)
          .activeMessages
          .last;
      expect(latest.id, row.id);
      expect(latest.createdAt, row.createdAt);
      expect(latest.runId, isNot(row.runId));
      expect(latest.status, 'error');
    },
  );
}
