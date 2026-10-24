import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';

import 'helpers/support_model_screen_fixture.dart';
import 'support_guidance_screen_isolation.dart';

export 'helpers/support_model_screen_fixture.dart'
    show ModelScreenFixture, ScreenSignal;

const directSend = ValueKey('support_composer_send_btn');
const directStop = ValueKey('support_composer_stop_btn');
const directInput = ValueKey('support_composer_input');
const directLocalHelp = 'SYNTHETIC_VISIBLE_ORIGINLESS_LOCAL_HELP';
const directExcluded = 'SYNTHETIC_EXCLUDED_PRIVATE_GAME_POLICY_CONTEXT';

/// Actual screen/provider/repository/transport composition. Existing declared
/// NativeDatabase.memory + FakeVault + real XChaCha AEAD + final fake adapter
/// suppliers are injected BEFORE any graph access. These extra file/socket/
/// channel tripwires start BEFORE fixture construction and cover its cleanup.
/// No fake workspace/native/model service, environment or production bootstrap.
void directConversationTest(
  String name,
  Future<void> Function(WidgetTester, ModelScreenFixture) body, {
  bool enterToSend = true,
}) {
  testWidgets(name, (tester) async {
    // Framework localization initialization reads ONLY this explicit empty
    // in-memory preferences backend; no application graph has been created.
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(EasyLocalization.ensureInitialized);
    final isolation = GuidanceScreenIsolation();
    await isolation.run(tester, () async {
      final fixture = ModelScreenFixture(
        confirm: false,
        enterToSend: enterToSend,
      );
      await fixture.run(tester, () async {
        final seed = await fixture.signal(tester, () async {
          final old = await fixture.repo.getMessageById('old');
          await fixture.repo.putMessage(old!.copyWith(body: directLocalHelp));
          await fixture.repo.putMessage(
            const SupportMessage(
              id: 'private-system',
              sessionId: ModelScreenFixture.session,
              role: 'system',
              body: directExcluded,
              createdAt: 3,
            ),
          );
          await fixture.repo.putMessage(
            const SupportMessage(
              id: 'other-private',
              sessionId: ModelScreenFixture.other,
              role: 'user',
              body: directExcluded,
              createdAt: 3,
            ),
          );
          await fixture.repo.putContextBlock(
            const SupportContextBlock(
              id: 'hidden-context',
              sessionId: ModelScreenFixture.session,
              startMessageId: 'old',
              endMessageId: 'old',
              summary: directExcluded,
              protectedFactsJson: directExcluded,
              createdAt: 3,
            ),
          );
          await fixture.db
              .into(fixture.db.characters)
              .insert(
                CharactersCompanion.insert(
                  charId: 'excluded-game-character',
                  name: 'Synthetic',
                ),
              );
          await fixture.db
              .into(fixture.db.chatSessions)
              .insert(
                ChatSessionsCompanion.insert(
                  sessionId: 'excluded-game',
                  characterId: 'excluded-game-character',
                  sessionIndex: 0,
                  messagesJson: jsonEncode([
                    {
                      'id': 'excluded-game-message',
                      'role': 'user',
                      'content': directExcluded,
                      'timestamp': 1,
                    },
                  ]),
                ),
              );
          await fixture.workspace.refresh();
        }, label: 'explicit isolated visible/excluded source seed');
        await fixture.finish(tester, seed);
        await tester.pumpAndSettle();
        expect(fixture.adapters, isEmpty);
        await body(tester, fixture);
      });
    });
  });
}

TextEditingController directDraft(WidgetTester tester) => tester
    .widget<SupportComposerBar>(find.byType(SupportComposerBar))
    .controller;

Future<SupportModelRunView> directTerminal(ModelScreenFixture fixture) {
  final original = fixture.bridge;
  final reached = Completer<SupportModelRunView>();
  late final void Function() stop;
  stop = original.listen(() {
    if (!reached.isCompleted &&
        original.view.phase == SupportModelPhase.settled &&
        !original.view.busy) {
      stop();
      reached.complete(original.view);
    }
  });
  addTearDown(stop);
  return reached.future;
}

Future<void> directRelease(SupportModelUiBridge original) {
  final done = Completer<void>();
  late final void Function() stop;
  stop = original.listen(() {
    if (!original.view.busy && !done.isCompleted) {
      stop();
      done.complete();
    }
  });
  addTearDown(stop);
  return Future.any([done.future, original.drained]);
}

List<Map<String, dynamic>> directWire(ModelScreenFixture f, int index) {
  final adapter = f.adapters[index];
  expect(adapter.fetches, 1);
  expect(adapter.options!.method, 'POST');
  expect(adapter.options!.uri.toString(), f.api.endpoint);
  expect(
    adapter.options!.headers['Authorization'],
    'Bearer ${ModelScreenFixture.key}',
  );
  final upload = adapter.upload!;
  for (final excluded in [
    directExcluded,
    ModelScreenFixture.secret,
    ModelScreenFixture.key,
    ModelScreenFixture.excluded,
    'SYNTHETIC_STALE_VAULT_KEY',
    'support.model_provenance',
    'policyIdentity',
    'protectedFacts',
    'cardsJson',
    'runId',
    'sessionId',
  ]) {
    expect(upload, isNot(contains(excluded)));
  }
  final payload = jsonDecode(upload) as Map<String, dynamic>;
  expect(payload['model'], f.settings.modelId);
  return (payload['messages'] as List).cast<Map<String, dynamic>>();
}
