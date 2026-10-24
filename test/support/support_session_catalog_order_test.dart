import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'package:glaze_flutter/features/chat_history/chat_history_provider.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';

import 'synthetic_consent_selection_fixture.dart';
import 'support_session_consent_fixture.dart';

void main() {
  test(
    'catalog uses ordinary last-message/branch activity before pagination, not settings update time',
    () async {
      final f = SyntheticConsentSelectionFixture();
      addTearDown(f.close);
      await f.character('character');
      for (final entry in [
        (id: 'old-gilda', time: 1000, updated: 999999),
        (id: 'recent-tokyo', time: 3000, updated: 1),
        (id: 'new-branch', time: 900, updated: 2),
      ]) {
        await f.roleplay(
          entry.id,
          'character',
          jsonEncode([
            SyntheticConsentSelectionFixture.message(
              'm-${entry.id}',
              timestamp: entry.time,
            ),
          ]),
          updatedAt: entry.updated,
        );
      }
      await f.db.customStatement(
        'UPDATE chat_sessions SET session_vars_json = ? WHERE session_id = ?',
        [
          jsonEncode({
            'branchedAt': '4000',
            'private': SyntheticConsentSelectionFixture.secret,
          }),
          'new-branch',
        ],
      );
      // Reference is the real ordinary picker projection, on declared synthetic data.
      final ordinary = await ChatRepo(f.db).getAllSessionMetadata();
      ordinary.sort(
        (a, b) => sessionPreviewAndTime(
          b,
        ).time.compareTo(sessionPreviewAndTime(a).time),
      );
      final before = await f.snapshot();
      f.observe();
      final first = await f.repo.listRoleplaySessions(limit: 2);
      final second = await f.repo.listRoleplaySessions(
        offset: first.nextOffset!,
        limit: 2,
      );
      expect(
        [...first.items, ...second.items].map((s) => s.sessionId),
        ordinary.map((s) => s.sessionId),
      );
      expect(first.items.map((s) => s.sessionId), [
        'new-branch',
        'recent-tokyo',
      ]);
      expect(f.storage.reads, 0);
      expect(f.spy.writes, 0);
      for (final read in f.spy.reads) {
        expect(
          read.returnedColumns.intersection({
            'messages_json',
            'session_vars_json',
            'content',
            'reasoning',
          }),
          isEmpty,
        );
        expect(read.sql, isNot(contains(r'$.content')));
        expect(read.sql, isNot(contains(r'$.reasoning')));
        expect(read.sql, contains(r'$.branchedAt'));
      }
      f.spy.observing = false;
      expect(await f.snapshot(), before);
    },
  );

  for (final large in ['many messages', 'large body']) {
    test(
      'whole-session choice accepts valid $large without enabling or loading history',
      () async {
        final f = SessionConsentFixture();
        addTearDown(f.close);
        final json = large == 'many messages'
            ? jsonEncode(
                List.generate(
                  2001,
                  (i) => SyntheticConsentSelectionFixture.message('m$i'),
                ),
              )
            : jsonEncode([
                {
                  'id': 'm',
                  'role': 'user',
                  'timestamp': 1,
                  'content': 'x' * 2097153,
                },
              ]);
        await f.seed(messages: json);
        final review = await f.review();
        f.data.observe();
        final choice = await f.controller.prepareSessionHistory(
          review,
          SupportConsentSelectionSource.roleplay,
          SessionConsentFixture.game,
        );
        expect(choice, isNotNull);
        expect(choice!.metadata.bodiesRead, isFalse);
        expect(
          choice.metadata.messageCount,
          large == 'many messages' ? 2001 : 1,
        );
        expect(f.data.storage.reads, 0);
        f.data.spy.observing = false;
        expect(await f.controller.selectSessionHistory(choice), isTrue);
        final saved = await f.policy();
        expect(
          saved.scope!.gameHistoryExtent,
          SupportHistoryExtent.wholeSession,
        );
        expect(saved.grants, isEmpty);
        expect(f.messageReads, 0);
        expect(f.connectionReads, 0);
        expect(f.recipientReads, 0);
        f.data.spy.observing = false;
        // The old explicit message reader retains its independent hard budget.
        expect(
          (await f.data.repo.listRoleplayMessages(
            sessionId: SessionConsentFixture.game,
          )).status,
          SupportConsentSelectionStatus.limited,
        );
      },
    );
  }

  test(
    'ordinary zero variant order can be selected; invalid negative parent remains denied',
    () async {
      final f = SyntheticConsentSelectionFixture();
      addTearDown(f.close);
      await f.character('normal');
      await f.db.customStatement(
        'UPDATE characters SET variant_order = 0 WHERE char_id = ?',
        ['normal'],
      );
      await f.roleplay('normal-session', 'normal', '[]');
      f.observe();
      expect(
        (await f.repo.readSessionMetadata(
          source: SupportConsentSelectionSource.roleplay,
          sessionId: 'normal-session',
        )).isAvailable,
        isTrue,
      );
      expect(f.storage.reads, 0);
      f.spy.observing = false;
      await f.db.customStatement(
        'UPDATE characters SET variant_order = -1 WHERE char_id = ?',
        ['normal'],
      );
      f.observe();
      expect(
        (await f.repo.readSessionMetadata(
          source: SupportConsentSelectionSource.roleplay,
          sessionId: 'normal-session',
        )).isAvailable,
        isFalse,
      );
      expect(f.storage.reads, 0);
    },
  );
}
