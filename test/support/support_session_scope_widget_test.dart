import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_guidance_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_session_scope_sheet.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_guidance_screen_fixture.dart';
import 'support_session_scope_widget_sql.dart';

Future<void> _ready(WidgetTester tester, GuidanceScreenFixture f) =>
    f.turns.until(
      tester,
      () =>
          find
              .byKey(const ValueKey('support_session_scope_confirm'))
              .evaluate()
              .isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty,
      label: 'original native session proposal',
    );

void main() {
  guidanceScreenTest(
    'older scope wins newest; retained final callbacks cannot write after source/session ABA, replacement or pop',
    (tester, f) async {
      // Seed only through actual C/review/metadata/opaque choice, not fake policy.
      final review = (await f.action(
        tester,
        () => f.controller.prepareReview(resolveRecipient: false),
      ))!;
      final choice = (await f.action(
        tester,
        () => f.controller.prepareSessionHistory(
          review,
          SupportConsentSelectionSource.roleplay,
          GuidanceScreenFixture.older,
        ),
      ))!;
      expect(
        await f.action(tester, () => f.controller.selectSessionHistory(choice)),
        isTrue,
      );
      await f.idle(tester);
      final before = await f.saved(tester);
      expect(before.scope!.gameSessionId, GuidanceScreenFixture.older);
      for (final retirement in [
        'source-aba',
        'session-aba',
        'controller',
        'modal',
      ]) {
        f.observe();
        await f.tapKey(tester, 'support_guidance_gameSession');
        await _ready(tester, f);
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('support_session_scope_proposal')),
              )
              .data,
          'Synthetic metadata parent · Native variant · Session 1',
        );
        expect(f.sql.writes, 0);
        final original = f.controller;
        final callback = tester
            .widget<GlazeActionButton>(
              find.byKey(const ValueKey('support_session_scope_confirm')),
            )
            .onTap!;
        switch (retirement) {
          case 'source-aba':
            await f.turns.real(tester, () async {
              final settle = f.container
                  .read(chatSourceMutationRegistryProvider)
                  .beginMutation(sessionId: GuidanceScreenFixture.older);
              settle();
            });
          case 'session-aba':
            await f.turns.real(tester, () async {
              f.workspace.selectSession(GuidanceScreenFixture.other);
              f.workspace.selectSession(GuidanceScreenFixture.session);
            });
            await f.idle(tester);
          case 'controller':
            await f.turns.real(tester, () async {
              f.container.invalidate(supportNativeConsentControllerProvider);
              expect(f.controller, isNot(same(original)));
            });
          case 'modal':
            await f.closeTop(tester);
        }
        await f.turns.real(tester, () async {
          callback();
        });
        await tester.pump();
        await f.idle(tester);
        final after = await f.saved(tester);
        expect(after.scope!.sameAs(before.scope), isTrue, reason: retirement);
        expect(after.revision, before.revision);
        expect(after.grants, isEmpty);
        expect(f.sql.writes, 0);
        if (retirement != 'session-aba') f.noRecipientResolver();
        // Workspace rehydration during actual session ABA legitimately reads
        // current settings, but STILL cannot invoke selected API/model readers.
        f.noReadersOrWire();
        if (find.byType(SupportSessionScopeSheet).evaluate().isNotEmpty) {
          await f.closeTop(tester);
        }
        await f.closeTop(tester);
      }
    },
    screen: false,
  );

  guidanceScreenTest(
    'held real metadata plus source/current-session ABA/controller replacement cannot publish scope or grants',
    (tester, f) async {
      for (final retirement in [
        'source-aba',
        'session-aba',
        'controller',
        'modal',
      ]) {
        final gate = f.sql.barrier();
        SessionScopeWidgetRead? originalRead;
        f.sql.afterRead = (read) async {
          if (originalRead == null &&
              read.roleplayMetadata &&
              read.exactSessionMetadata) {
            originalRead = read;
            await gate.wait();
          }
        };
        await f.tapKey(tester, 'support_guidance_gameSession');
        await f.turns.until(tester, () {
          if (originalRead?.settled == true && !gate.entered.isCompleted) {
            fail('Original metadata job settled before the declared gate.');
          }
          return gate.entered.isCompleted;
        }, label: 'original exact-target metadata gate');
        expect(originalRead!.args, [GuidanceScreenFixture.newest]);
        expect(originalRead!.settled, isFalse);
        expect(
          find.byKey(const ValueKey('support_session_scope_confirm')),
          findsNothing,
        );
        expect(f.sql.writes, 0);
        final originalController = f.controller;
        switch (retirement) {
          case 'source-aba':
            await f.turns.real(tester, () async {
              final settle = f.container
                  .read(chatSourceMutationRegistryProvider)
                  .beginMutation(sessionId: GuidanceScreenFixture.newest);
              settle(); // Same IDs/metadata, DIFFERENT process-local checkpoint.
            });
          case 'session-aba':
            await f.turns.real(tester, () async {
              f.workspace.selectSession(GuidanceScreenFixture.other);
              f.workspace.selectSession(GuidanceScreenFixture.session);
            });
          case 'controller':
            await f.turns.real(tester, () async {
              f.container.invalidate(supportNativeConsentControllerProvider);
              expect(f.controller, isNot(same(originalController)));
            });
          case 'modal':
            // Do not wait for idle while the original SQL read is deliberately held.
            final sheet = tester.widget<SupportSessionScopeSheet>(
              find.byType(SupportSessionScopeSheet),
            );
            final context = tester.element(
              find.byType(SupportSessionScopeSheet),
            );
            expect(sheet.controller, same(originalController));
            await f.turns.real(tester, () async {
              Navigator.of(context).pop();
            });
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
        }
        // Release and drain the ORIGINAL job, even when its UI owner has gone.
        await f.turns.real(tester, () async {
          f.sql.afterRead = null;
          gate.release.complete();
        });
        await f.turns.until(
          tester,
          () => originalRead!.settled,
          label: 'original held metadata completion after retirement',
        );
        await f.idle(tester);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('support_session_scope_confirm')),
          findsNothing,
          reason:
              '$retirement never promotes old metadata into a new native choice.',
        );
        final saved = await f.saved(tester);
        expect(saved.scope, isNull);
        expect(saved.grants, isEmpty);
        expect(saved.recipient, isNull);
        expect(
          (await f.saved(tester, GuidanceScreenFixture.other)).scope,
          isNull,
        );
        expect(f.sql.writes, 0);
        if (retirement != 'session-aba') f.noRecipientResolver();
        f.noReadersOrWire();
        if (find.byType(SupportSessionScopeSheet).evaluate().isNotEmpty) {
          await f.closeTop(tester);
        }
        if (find.byType(SupportGuidanceSheet).evaluate().isNotEmpty) {
          await f.closeTop(tester);
        }
        f.observe();
      }
      expect(await f.messageCount(tester), 0);
    },
    screen: false,
  );
}
