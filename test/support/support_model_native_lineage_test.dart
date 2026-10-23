import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';

import 'helpers/support_model_fixture.dart';
import 'helpers/support_native_provenance_fixture.dart';

void main() {
  for (final control in [
    'exact-all',
    'missing-origin',
    'missing-reference',
    'game-model-OFF',
    'game-local-OFF',
    'legacy',
  ]) {
    isolatedProvenance(
      'actual service inherited native provenance remains conjunctive: $control',
      () async {
        final f = await SupportModelFixture.create(
          scope: SupportPermissionScope(
            selectionRevision: 1,
            supportHistory: SupportMessageSelection([
              if (control != 'missing-origin') 'ancestor-user',
              if (control != 'missing-reference') 'ancestor',
              'origin',
              'derived',
            ]),
            gameSessionId: 'synthetic-game',
            gameHistory: SupportMessageSelection(['game-selected']),
          ),
          grants: [
            SupportPermission.modelSupportHistory,
            if (control != 'game-local-OFF') SupportPermission.readGameData,
            if (control != 'game-model-OFF') SupportPermission.modelGameHistory,
            SupportPermission
                .reportGameHistory, // Reporting is NOT model authority.
          ],
        );
        try {
          await f.game();
          await f.history(
            'ancestor-user',
            runId: 'ancestor-run',
            body: 'SYNTHETIC_ANCESTOR_USER_113',
            time: 2,
          );
          await f.history(
            'ancestor',
            role: 'assistant',
            runId: 'ancestor-run',
            body: 'SYNTHETIC_ANCESTOR_BODY_884',
            time: 3,
          );
          await f.history('origin', runId: 'derived-run', time: 4);
          await f.history(
            'derived',
            role: 'assistant',
            runId: 'derived-run',
            body: 'SYNTHETIC_DERIVED_BODY_443',
            time: 5,
          );
          final ancestor = SupportModelProvenance(
            supportSessionId: 'session',
            replyMessageId: 'ancestor',
            runId: 'ancestor-run',
            currentUserMessageId: 'ancestor-user',
            originalRanges: [
              SupportModelSourceRange(
                domain: SupportModelSourceDomain.game,
                sessionId: 'synthetic-game',
                orderedMessageIds: ['game-selected'],
              ),
            ],
            directReplies: const [],
          );
          final derived = SupportModelProvenance(
            supportSessionId: 'session',
            replyMessageId: 'derived',
            runId: 'derived-run',
            currentUserMessageId: 'origin',
            originalRanges: [
              SupportModelSourceRange(
                domain: SupportModelSourceDomain.support,
                sessionId: 'session',
                orderedMessageIds: ['ancestor-user', 'ancestor'],
              ),
            ],
            directReplies: [
              SupportModelReplyReference(
                sessionId: 'session',
                messageId: 'ancestor',
                runId: 'ancestor-run',
              ),
            ],
          );
          if (control != 'legacy') {
            await _seedRecipe(f, ancestor, 3);
            await _seedRecipe(f, derived, 5);
          }
          f.sql.observations.clear();
          f.primitive.decryptAads.clear();
          final submission = await f.submit();
          expect(await submission.accepted, isTrue);
          final preparation = await submission.prepared;
          if (control == 'exact-all') {
            expect(preparation.reason, SupportModelRefusal.none);
            final preview = preparation.preview!;
            expect(preview.supportMessages, 4);
            expect(preview.gameMessages, 1);
            expect(
              preview.messages.map((m) => m.text).join(),
              isNot(contains('support.model_provenance')),
            );
            final result = await f.service.dispatch(
              f.service.approve(preview)!,
            );
            expect(result.accepted, isTrue);
            expect(result.saved, isTrue);
            expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
            expect(f.adapters.single.calls, 1);
            final upload = f.adapters.single.delegate.upload!;
            for (final text in [
              'SYNTHETIC_ANCESTOR_BODY_884',
              'SYNTHETIC_DERIVED_BODY_443',
              'Selected game',
            ]) {
              expect(upload, contains(text));
            }
            for (final native in [
              'support.model_provenance',
              'supportSessionId',
              'originalRanges',
              'directReplies',
              SupportModelFixture.unselected,
            ]) {
              expect(upload, isNot(contains(native)));
            }
            final block = await f.repo.getContextBlockById(
              'support.reply_provenance:${preview.replyMessageId}',
            );
            final recipe =
                SupportModelProvenanceCodec.decodeFromEncryptedStorage(
                  block!.protectedFactsJson,
                ).recipe!;
            expect(recipe.directReplies.map((r) => r.messageId), [
              'ancestor',
              'derived',
            ]);
            expect(recipe.directReplies.map((r) => r.runId), [
              'ancestor-run',
              'derived-run',
            ]);
            expect(recipe.originalRanges.first.orderedMessageIds, [
              'ancestor-user',
              'ancestor',
              'origin',
              'derived',
            ]);
            expect(
              recipe.originalRanges.last.domain,
              SupportModelSourceDomain.game,
            );
            expect(recipe.originalRanges.last.orderedMessageIds, [
              'game-selected',
            ]);
            // Newly reserved lineage does not flatten/change either stored recipe.
            for (final stored in [ancestor, derived]) {
              final retained = await f.repo.getContextBlockById(
                'support.reply_provenance:${stored.replyMessageId}',
              );
              expect(
                retained!.protectedFactsJson,
                SupportModelProvenanceCodec.encodeForEncryptedStorage(stored),
              );
            }
          } else {
            expect(preparation.preview, isNull);
            expect(
              preparation.reason,
              control == 'game-local-OFF'
                  ? SupportModelRefusal.historyDenied
                  : SupportModelRefusal.lineageUnavailable,
            );
            expect((await submission.finished).accepted, isTrue);
            expect(f.adapters, isEmpty);
            if (control == 'game-local-OFF') {
              expect(
                f.sql.observations.where(
                  (o) =>
                      o.statement.contains('ROW_NUMBER()') ||
                      o.statement.contains('json_each'),
                ),
                isEmpty,
              );
            }
            if (control == 'missing-origin') {
              expect(
                f.primitive.decryptAads.where(
                  (aad) => aad.contains('|ancestor-user|'),
                ),
                isEmpty,
              );
            }
            if (control == 'missing-reference') {
              expect(
                f.primitive.decryptAads.where(
                  (aad) => aad.contains('|ancestor|'),
                ),
                isEmpty,
              );
            }
            if (control == 'game-model-OFF') {
              expect(
                f.sql.observations.where(
                  (o) => o.statement.contains('json_each'),
                ),
                isEmpty,
              );
            }
          }
        } finally {
          await f.close();
        }
      },
    );
  }
}

Future<void> _seedRecipe(
  SupportModelFixture f,
  SupportModelProvenance recipe,
  int time,
) => f.repo.putContextBlock(
  SupportContextBlock(
    id: 'support.reply_provenance:${recipe.replyMessageId}',
    sessionId: recipe.supportSessionId,
    startMessageId: recipe.replyMessageId,
    endMessageId: recipe.replyMessageId,
    summary: '',
    protectedFactsJson: SupportModelProvenanceCodec.encodeForEncryptedStorage(
      recipe,
    ),
    isActive: false,
    createdAt: time,
  ),
);
