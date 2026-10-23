import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';

import 'helpers/support_model_provider_fixture.dart';

/// Actual isolated native provider ROOT, declared memory SQLite, FakeVault and
/// real AEAD/fake wire. No commands or production database/bootstrap. All guards
/// start BEFORE fixture construction and remain through original settlement.
void sessionModelTest(
  String name,
  Future<void> Function(ModelProviderFixture f) body,
) {
  test(name, () async {
    final attempts = <String>[];
    Never block(String boundary) {
      attempts.add(boundary);
      throw StateError('Outside synthetic session-model boundary');
    }
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) => block('native $channel');
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () => ModelProviderFixture().run(body),
          createFile: (_) => block('file/default database'),
          createDirectory: (_) => block('directory/default database'),
          createLink: (_) => block('link'),
        ),
        createHttpClient: (_) => block('HTTP'),
      );
      await messenger.platformMessagesFinished;
      expect(attempts, isEmpty);
    } finally {
      messenger.allMessagesHandler = previous;
    }
  });
}

const sessionModelGame = 'session-model-game';
const sessionModelGameBody = 'SYNTHETIC_WHOLE_GAME_VISIBLE_421';
const sessionModelFutureBody = 'SYNTHETIC_WHOLE_GAME_FUTURE_642';
const sessionModelHiddenBody = 'SYNTHETIC_WHOLE_GAME_HIDDEN_199';

extension SessionModelSourceFixture on ModelProviderFixture {
  /// The base fixture intentionally seeds a legacy unknown assistant. Each test
  /// explicitly decides whether to retain it; no production backfill is made.
  Future<void> readableOwnHistory() => repo.deleteMessage('old-excluded');

  Future<void> wholeScope({
    bool own = false,
    bool game = false,
    bool gameLocal = true,
    bool gameModel = true,
    bool ownModel = true,
  }) => grantHistory(
    SupportPermissionScope(
      selectionRevision: 1,
      supportHistoryExtent: own
          ? SupportHistoryExtent.wholeSession
          : SupportHistoryExtent.selectedMessages,
      gameSessionId: game ? sessionModelGame : null,
      gameHistoryExtent: game
          ? SupportHistoryExtent.wholeSession
          : SupportHistoryExtent.selectedMessages,
    ),
    [
      if (own && ownModel) SupportPermission.modelSupportHistory,
      if (game && gameLocal) SupportPermission.readGameData,
      if (game && gameModel) SupportPermission.modelGameHistory,
    ],
  );

  Future<void> seedWholeGame() async {
    await db.into(db.characters).insert(CharactersCompanion.insert(
      charId: 'session-model-character', name: 'Synthetic',
    ));
    await db.into(db.chatSessions).insert(ChatSessionsCompanion.insert(
      sessionId: sessionModelGame,
      characterId: 'session-model-character',
      sessionIndex: 0,
      messagesJson: jsonEncode([
        {'id': 'game-old', 'role': 'user', 'content': sessionModelGameBody,
         'timestamp': 1, 'reasoning': sessionModelHiddenBody},
        {'id': 'game-hidden', 'role': 'assistant', 'content': sessionModelHiddenBody,
         'timestamp': 2, 'isHidden': true},
      ]),
    ));
  }

  Future<void> replaceWholeGame(List<Object?> messages) =>
    (db.update(db.chatSessions)..where((t) => t.sessionId.equals(sessionModelGame)))
      .write(ChatSessionsCompanion(messagesJson: Value(jsonEncode(messages))));

  Future<SupportModelProvenance> recipeFor(String reply) async {
    final block = await repo.getContextBlockById('support.reply_provenance:$reply');
    expect(block, isNotNull);
    expect(block!.isActive, isFalse);
    expect(block.startMessageId, reply);
    expect(block.endMessageId, reply);
    expect(block.summary, isEmpty);
    final decoded = SupportModelProvenanceCodec.decodeFromEncryptedStorage(block.protectedFactsJson);
    expect(decoded.isValid, isTrue);
    return decoded.recipe!;
  }

  Future<void> seedGameDerived({String originGame = sessionModelGame}) async {
    final user = await repo.appendCurrentUser(
      message: const SupportMessage(
        id: 'derived-user', sessionId: ModelProviderFixture.session,
        role: 'user', body: 'Synthetic earlier question', runId: 'derived-run',
        createdAt: 3,
      ),
      isCurrent: () => true,
    );
    final recipe = SupportModelProvenance(
      supportSessionId: ModelProviderFixture.session,
      replyMessageId: 'derived-reply', runId: 'derived-run',
      currentUserMessageId: 'derived-user',
      originalRanges: [SupportModelSourceRange(
        domain: SupportModelSourceDomain.game, sessionId: originGame,
        orderedMessageIds: ['game-old'],
      )], directReplies: const [],
    );
    final reservation = await repo.reserveOrderedReply(
      message: const SupportMessage(
        id: 'derived-reply', sessionId: ModelProviderFixture.session,
        role: 'assistant', body: '', runId: 'derived-run', status: 'preparing',
        createdAt: 4,
      ),
      originatingUser: user!,
      provenanceJson: SupportModelProvenanceCodec.encodeForEncryptedStorage(recipe),
      isCurrent: () => true,
    );
    expect(reservation, isNotNull);
    expect(await repo.settleReply(expected: reservation!, status: 'complete',
      body: 'Synthetic game-derived answer', isCurrent: () => true), isNotNull);
  }
}
