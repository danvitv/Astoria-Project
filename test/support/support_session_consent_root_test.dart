import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';

import 'helpers/support_game_source_native_fixture.dart';

/// Vertical contract tests prepared for the later CoreReader/ModelContext lane.
/// Run only at the parent's coherent final snapshot. Every source is synthetic,
/// with actual encrypted memory DB/providers and socket/platform tripwires.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> selectWhole(GameSourceNativeFixture f) async {
    await f.seedGame();
    final controller = f.model.container.read(
      supportNativeConsentControllerProvider,
    );
    final review = (await controller.prepareReview(resolveRecipient: false))!;
    final choice = (await controller.prepareSessionHistory(
      review,
      SupportConsentSelectionSource.roleplay,
      GameSourceNativeFixture.game,
    ))!;
    expect(await controller.selectSessionHistory(choice), isTrue);
    final p = f.runtime.snapshot.preferences!;
    expect(p.grants, isEmpty);
    expect(p.scope!.gameHistory, isNull);
    expect(p.scope!.gameHistoryExtent, SupportHistoryExtent.wholeSession);
    await f.model.grantHistory(p.scope!, [
      SupportPermission.readGameData,
      SupportPermission.modelGameHistory,
    ]);
  }

  test(
    'actual native root selection is metadata-only, scope-only; no implicit source reads',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame(grantModel: false);
        final controller = f.model.container.read(
          supportNativeConsentControllerProvider,
        );
        final review = (await controller.prepareReview(
          resolveRecipient: false,
        ))!;
        f.model.sql.observations.clear();
        final choice = (await controller.prepareSessionHistory(
          review,
          SupportConsentSelectionSource.roleplay,
          GameSourceNativeFixture.game,
        ))!;
        expect(
          f.model.sql.observations.where(
            (r) => r.statement.contains('api_configs'),
          ),
          isEmpty,
        );
        expect(
          f.model.sql.observations.where(
            (r) => r.statement.contains('support_messages'),
          ),
          isEmpty,
        );
        expect(choice.metadata.bodiesRead, isFalse);
        expect(await controller.selectSessionHistory(choice), isTrue);
        final p = f.runtime.snapshot.preferences!;
        expect(p.grants, isEmpty);
        expect(f.model.adapters, isEmpty);
        expect(p.allows(SupportPermission.modelGameHistory), isFalse);
        expect(p.allows(SupportPermission.reportGameHistory), isFalse);
      });
    },
  );

  test(
    'brand-new accepted game ID retires ORIGINAL preview and lease, fresh preview includes it',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await selectWhole(f);
        final m = f.model;
        final oldEmitter = m.emitter();
        final old = m.send(from: oldEmitter);
        final oldPreview = await m.preview(old);
        expect(oldPreview.gameMessages, 2);
        final owner = f.runtime.writeOwner, epoch = f.runtime.epoch;
        final settle = f.begin(messageIds: {'new-session-message'});
        expect(f.runtime.pending, 1);
        expect(f.runtime.epoch, greaterThan(epoch));
        expect(f.runtime.writeOwner, owner);
        expect(oldPreview.isCurrent, isFalse);
        expect(oldEmitter.isCurrent, isFalse);
        expect(old.approve(oldPreview), isNull);
        await (m.db.update(m.db.chatSessions)
              ..where((t) => t.sessionId.equals(GameSourceNativeFixture.game)))
            .write(
              ChatSessionsCompanion(
                messagesJson: Value(
                  jsonEncode([
                    {
                      'id': GameSourceNativeFixture.selected,
                      'role': 'user',
                      'content': 'Synthetic first',
                      'timestamp': 1,
                    },
                    {
                      'id': 'new-session-message',
                      'role': 'assistant',
                      'content': 'Synthetic future normal message',
                      'timestamp': 2,
                    },
                    {
                      'id': 'hidden-session-message',
                      'role': 'assistant',
                      'isHidden': true,
                      'content': 'HIDDEN_SESSION_CANARY',
                      'timestamp': 3,
                    },
                  ]),
                ),
              ),
            );
        settle();
        expect((await old.finished).saved, isTrue);
        expect(f.runtime.pending, 0);
        expect(
          f.runtime.snapshot.preferences!.allows(
            SupportPermission.modelGameHistory,
          ),
          isTrue,
        );
        expect(oldPreview.isCurrent, isFalse);
        final fresh = m.send();
        final preview = await m.preview(fresh);
        expect(preview.gameMessages, 2);
        expect(
          preview.messages.map((r) => r.text),
          contains('Synthetic future normal message'),
        );
        expect(
          preview.messages.map((r) => r.text),
          isNot(contains('HIDDEN_SESSION_CANARY')),
        );
        final result = await fresh.dispatch(fresh.approve(preview)!);
        expect(result.saved, isTrue);
        expect(m.adapters.single.fetches, 1);
        expect(
          m.adapters.single.upload,
          contains('Synthetic future normal message'),
        );
        expect(
          m.adapters.single.upload,
          isNot(contains('HIDDEN_SESSION_CANARY')),
        );
      });
    },
  );

  test(
    'quiet real fake-adapter SSE source stop retains ORIGINAL reply settlement once',
    () async {
      final f = GameSourceNativeFixture();
      f.model.quiet = true;
      await f.run((f) async {
        await selectWhole(f);
        final m = f.model;
        final send = m.send();
        final preview = await m.preview(send);
        final provenance = await m.repo.getContextBlockById(
          'support.reply_provenance:${preview.replyMessageId}',
        );
        final approval = send.approve(preview)!;
        final finished = send.dispatch(approval);
        final adapter = await m.adapterCreated.future;
        await adapter.responseListening;
        m.sql.writes.clear();
        final settle = f.begin(messageIds: {'new-ID-not-present-in-preview'});
        await adapter.cancelObserved.future;
        await adapter.native.responseCancelled.future;
        final result = await finished;
        expect(result.saved, isTrue);
        expect(result.message!.id, preview.replyMessageId);
        expect(result.message!.sessionId, preview.sessionId);
        expect(result.message!.runId, preview.runId);
        expect(result.message!.status, 'stopped');
        expect(
          await m.repo.getContextBlockById(
            'support.reply_provenance:${preview.replyMessageId}',
          ),
          provenance,
        );
        expect(
          m.sql.writes.where((s) => s.startsWith('UPDATE "support_messages"')),
          hasLength(1),
        );
        expect(await send.dispatch(approval), same(result));
        settle();
        settle();
        expect(f.runtime.pending, 0);
        expect(adapter.fetches, 1);
        expect(adapter.closed, isTrue);
        expect(
          f.runtime.snapshot.preferences!.allows(
            SupportPermission.modelGameHistory,
          ),
          isTrue,
        );
      });
    },
  );

  test(
    'unrelated session mutations leave whole-session original preview current',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await selectWhole(f);
        final send = f.model.send();
        final preview = await f.model.preview(send);
        final epoch = f.runtime.epoch;
        final settle = f.begin(
          sessionId: 'entirely-unrelated-game',
          messageIds: {'new-ID'},
        );
        expect(f.runtime.epoch, epoch);
        expect(f.runtime.pending, 0);
        expect(preview.isCurrent, isTrue);
        settle();
        send.stop();
        expect((await send.finished).saved, isTrue);
        expect(f.model.adapters, isEmpty);
      });
    },
  );
}
