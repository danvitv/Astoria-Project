import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';

import 'support_model_provider_fixture.dart';

const modelProviderGameSession = 'synthetic-provider-game';
const modelProviderGameMessage = 'synthetic-game-selected';

/// Declared-schema synthetic game ONLY. This native-store local grant is a
/// fixture input, NOT proof that the current read-only privacy UI enables it.
extension ModelProviderGameFixture on ModelProviderFixture {
  Future<void> seedSelectedGame() async {
    await db
        .into(db.characters)
        .insert(
          CharactersCompanion.insert(
            charId: 'synthetic-game-character',
            name: 'Synthetic',
            description: const Value(ModelProviderFixture.excluded),
          ),
        );
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: modelProviderGameSession,
            characterId: 'synthetic-game-character',
            sessionIndex: 0,
            messagesJson: jsonEncode([
              {
                'id': modelProviderGameMessage,
                'role': 'user',
                'content': 'Selected game text',
                'timestamp': 1,
                'reasoning': ModelProviderFixture.excluded,
              },
              {
                'id': 'game-excluded',
                'role': 'user',
                'content': ModelProviderFixture.excluded,
                'timestamp': 2,
              },
            ]),
            sessionVarsJson: const Value(
              '{"private":"${ModelProviderFixture.excluded}"}',
            ),
          ),
        );
    await grantHistory(
      SupportPermissionScope(
        selectionRevision: 1,
        gameSessionId: modelProviderGameSession,
        gameHistory: SupportMessageSelection([modelProviderGameMessage]),
      ),
      [SupportPermission.modelGameHistory],
    );
    final runtime = container.read(supportNativeRuntimeProvider);
    await runtime.permissions.setGrantFromNative(
      ModelProviderFixture.session,
      SupportPermission.readGameData,
      true,
      isCurrent: () => true,
    );
    await runtime.refresh(resolve: true);
  }
}
