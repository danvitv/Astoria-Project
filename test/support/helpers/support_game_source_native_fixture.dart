import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/chat_source_mutation_registry.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';

import 'support_model_provider_fixture.dart';

/// Source-audited low-level ModelProviderFixture owns declared onCreate=createAll
/// memory DB, fake storage/vault, actual XChaCha AEAD, real credential observer,
/// native/runtime/workspace/model providers and private socket-free adapter.
/// This adds a blanket native tripwire, including unknown channels, THROUGH all
/// original settlement, DB close and pending platform-message cleanup.
final class GameSourceNativeFixture {
  final model = ModelProviderFixture();
  final nativeAttempts = <String>[];
  static const game = 'source-adapter-game', selected = 'source-selected';

  ChatSourceMutationRegistry get registry =>
      model.container.read(chatSourceMutationRegistryProvider);
  SupportNativeRuntime get runtime =>
      model.container.read(supportNativeRuntimeProvider);
  void Function() begin({String sessionId = game, Set<String>? messageIds}) =>
      registry.beginMutation(sessionId: sessionId, messageIds: messageIds);

  Future<void> seedGame({
    String sessionId = game,
    String messageId = selected,
    bool grantModel = true,
    bool confirm = true,
  }) async {
    final db = model.db;
    await db
        .into(db.characters)
        .insert(
          CharactersCompanion.insert(
            charId: 'source-character',
            name: 'Synthetic',
          ),
          mode: InsertMode.insertOrIgnore,
        );
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: sessionId,
            characterId: 'source-character',
            sessionIndex: 0,
            messagesJson: jsonEncode([
              {
                'id': messageId,
                'role': 'user',
                'content': 'Selected synthetic game text',
                'timestamp': 1,
                'reasoning': ModelProviderFixture.excluded,
              },
              {
                'id': 'source-excluded',
                'role': 'user',
                'content': ModelProviderFixture.excluded,
                'timestamp': 2,
              },
            ]),
            sessionVarsJson: const Value(
              '{"private":"EXCLUDED_SOURCE_VARIABLE"}',
            ),
          ),
        );
    final scope = SupportPermissionScope(
      selectionRevision: 1,
      gameSessionId: sessionId,
      gameHistory: SupportMessageSelection([messageId]),
    );
    if (confirm) {
      await model.grantHistory(
        scope,
        grantModel ? [SupportPermission.modelGameHistory] : [],
      );
    } else {
      await runtime.permissions.selectScopeFromNative(
        ModelProviderFixture.session,
        scope,
        isCurrent: () => true,
      );
      await runtime.refresh();
    }
    await runtime.permissions.setGrantFromNative(
      ModelProviderFixture.session,
      SupportPermission.readGameData,
      true,
      isCurrent: () => true,
    );
    await runtime.refresh();
  }

  Future<void> selectAway() async {
    final old = runtime.snapshot.preferences!.scope!;
    await runtime.permissions.selectScopeFromNative(
      ModelProviderFixture.session,
      SupportPermissionScope(selectionRevision: old.selectionRevision + 1),
      isCurrent: () => true,
    );
    await runtime.refresh(resolve: true);
    await model.confirmRecipient();
  }

  /// Owned synthetic source write ONLY, never a producer replacement or model
  /// authority override. Tests separately choose whether intent is observed.
  Future<void> replaceSelectedText(String text) async {
    final db = model.db;
    await (db.update(
      db.chatSessions,
    )..where((t) => t.sessionId.equals(game))).write(
      ChatSessionsCompanion(
        messagesJson: Value(
          jsonEncode([
            {'id': selected, 'role': 'user', 'content': text, 'timestamp': 1},
            {
              'id': 'source-excluded',
              'role': 'user',
              'content': ModelProviderFixture.excluded,
              'timestamp': 2,
            },
          ]),
        ),
      ),
    );
  }

  void expectNoSourceReads() => expect(
    model.sql.observations.where((o) => o.statement.contains('chat_sessions')),
    isEmpty,
  );

  Future<void> run(
    Future<void> Function(GameSourceNativeFixture) body, {
    bool configured = true,
    bool initialize = true,
  }) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) {
      nativeAttempts.add(channel);
      throw StateError('Native startup is outside the owned source fixture.');
    };
    try {
      await model.isolation.run(() async {
        try {
          if (initialize) await model.initialize(configured: configured);
          await body(this);
        } finally {
          try {
            await model.close();
          } finally {
            await messenger.platformMessagesFinished;
            expect(nativeAttempts, isEmpty);
            expect(model.isolation.attempts, isEmpty);
          }
        }
      });
    } finally {
      messenger.allMessagesHandler = previous;
    }
  }
}
