import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show MigrationStrategy;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/application/chat_source_mutation_registry.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/studio_config_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_message_service.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/controllers/chat_message_ops_controller.dart';
import 'package:glaze_flutter/features/chat/controllers/chat_swipe_controller.dart';
import 'package:glaze_flutter/features/chat/state/chat_session_write_queue.dart';
import 'package:glaze_flutter/features/chat/state/cached_token_breakdown.dart';
import 'package:glaze_flutter/features/chat_history/chat_history_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/info_blocks_provider.dart';
import 'package:glaze_flutter/features/extensions/state/message_variables_notifier.dart';

final gameSourceHarnessProvider = Provider(GameSourceHarness.new);

/// Only an initialized declared memory schema and the real bounded producer
/// graph. No App, environment, assets, default DB, cipher/vault, or model setup.
final class GameSourceFixture {
  GameSourceFixture._(
    this.db,
    this.container,
    this._guard,
    this._http,
    this._previousHttp,
    this._restoreNative,
    this.nativeAttempts,
  );

  final AppDatabase db;
  final ProviderContainer container;
  final _ProviderGuard _guard;
  final _DenyHttp _http;
  final HttpOverrides? _previousHttp;
  final void Function() _restoreNative;
  final List<String> nativeAttempts;
  final events = <ChatSourceMutationChange>[];
  void Function()? _unsubscribe;

  ChatSourceMutationRegistry get registry =>
      container.read(chatSourceMutationRegistryProvider);
  GameSourceHarness get harness => container.read(gameSourceHarnessProvider);

  static Future<GameSourceFixture> create({
    bool observe = true,
    Completer<Character?>? characterGate,
    Completer<void>? characterReadStarted,
    Completer<StudioConfig?>? studioGate,
    Future<List<PresetRegex>>? regexes,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final previousHttp = Zone.root.run(() => HttpOverrides.current);
    final http = _DenyHttp();
    HttpOverrides.global = http;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previousNative = messenger.allMessagesHandler;
    // One shared attempt list from setup through cleanup, including failures.
    final nativeAttempts = <String>[];
    messenger.allMessagesHandler = (channel, handler, message) {
      nativeAttempts.add(channel);
      throw StateError('Unexpected native channel: $channel');
    };
    final guard = _ProviderGuard();
    AppDatabase? createdDb;
    ProviderContainer? createdContainer;
    try {
      final db = _GameSourceMemoryDatabase(NativeDatabase.memory());
      createdDb = db;
      // Force complete declared-schema initialization before provider evaluation.
      await db.select(db.chatSessions).get();
      Never denied(String name) {
        guard.denied.add(name);
        throw StateError('Forbidden provider: $name');
      }

      final container = ProviderContainer(
        observers: [guard],
        overrides: [
          appDbProvider.overrideWithValue(db),
          chatHistoryProvider.overrideWith(_QuietHistory.new),
          activeRegexesProvider.overrideWith(
            (ref) => regexes ?? Future.value([]),
          ),
          if (characterGate != null)
            characterRepoProvider.overrideWithValue(
              _PausedCharacterRepo(db, characterGate, characterReadStarted),
            ),
          if (studioGate != null)
            studioConfigRepoProvider.overrideWithValue(
              _PausedStudioRepo(db, studioGate),
            ),
          credentialVaultProvider.overrideWith((ref) => denied('vault')),
          supportRepoProvider.overrideWith((ref) => denied('support repo')),
          supportPayloadCipherProvider.overrideWith((ref) => denied('cipher')),
          apiConfigRepoProvider.overrideWith((ref) => denied('API/config')),
          imageStorageProvider.overrideWith((ref) => denied('image/files')),
          migrationServiceProvider.overrideWith((ref) => denied('migration')),
        ],
      );
      createdContainer = container;
      final fixture = GameSourceFixture._(
        db,
        container,
        guard,
        http,
        previousHttp,
        () => messenger.allMessagesHandler = previousNative,
        nativeAttempts,
      );
      if (observe) {
        fixture._unsubscribe = fixture.registry.subscribe(fixture.events.add);
      }
      return fixture;
    } catch (_) {
      // Failed setup is still owned; never leave a live DB/container or remove
      // tripwires before their cleanup completes. Setup errors are not swallowed.
      try {
        try {
          createdContainer?.dispose();
        } finally {
          try {
            await createdDb?.close();
          } finally {
            try {
              await messenger.platformMessagesFinished;
            } finally {
              expect(nativeAttempts, isEmpty);
              expect(http.attempts, 0);
              expect(guard.denied, isEmpty);
              expect(guard.unexpected, isEmpty);
            }
          }
        }
      } finally {
        try {
          messenger.allMessagesHandler = previousNative;
        } finally {
          HttpOverrides.global = previousHttp;
        }
      }
      rethrow;
    }
  }

  Future<void> seed(ChatSession session) async {
    await container.read(chatRepoProvider).put(session);
    harness.state = ChatState(session: session);
  }

  bool pending(String messageId, {String sessionId = 'game'}) =>
      registry.isPending(sessionId: sessionId, messageIds: [messageId]);

  Future<void> close() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    try {
      _unsubscribe?.call();
      container.dispose();
      ChatSessionService.clearCache();
      await db.close();
      await messenger.platformMessagesFinished;
      // All tripwires remain installed THROUGH disposal/DB close/pending cleanup.
      expect(nativeAttempts, isEmpty);
      expect(_http.attempts, 0);
      expect(_guard.denied, isEmpty);
      expect(_guard.unexpected, isEmpty);
    } finally {
      try {
        _restoreNative();
      } finally {
        HttpOverrides.global = _previousHttp;
      }
    }
  }
}

final class _GameSourceMemoryDatabase extends AppDatabase {
  _GameSourceMemoryDatabase(super.e) : super.forTesting();

  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}

final class _DenyHttp extends HttpOverrides {
  int attempts = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('HTTP is outside the declared game-source fixture');
  }
}

final class GameSourceHarness {
  GameSourceHarness(Ref ref) {
    messages = ChatMessageService(ref);
    sessions = ChatSessionService(ref);
    ops = ChatMessageOpsController(
      ref: ref,
      charId: 'character',
      writes: queue,
      getState: () => AsyncData(state),
      setState: publish,
      invalidateHistory: () {},
    );
    swipes = ChatSwipeController(
      ref: ref,
      charId: 'character',
      writes: queue,
      getState: () => AsyncData(state),
      setState: publish,
      invalidateHistory: () {},
    );
  }

  ChatState state = const ChatState();
  final queue = ChatSessionWriteQueue();
  late final ChatMessageService messages;
  late final ChatSessionService sessions;
  late final ChatMessageOpsController ops;
  late final ChatSwipeController swipes;
  void Function(ChatState)? onPublish;

  void publish(AsyncValue<ChatState> value) {
    state = value.requireValue;
    onPublish?.call(state);
  }
}

class _QuietHistory extends ChatHistoryNotifier {
  @override
  Future<List<ChatSessionInfo>> build() async => const [];
}

class _PausedCharacterRepo extends CharacterRepo {
  _PausedCharacterRepo(super.db, this.gate, this.started);
  final Completer<Character?> gate;
  final Completer<void>? started;
  @override
  Future<Character?> getById(String id) {
    if (started != null && !started!.isCompleted) started!.complete();
    return gate.future;
  }
}

class _PausedStudioRepo extends StudioConfigRepo {
  _PausedStudioRepo(super.db, this.gate);
  final Completer<StudioConfig?> gate;
  @override
  Future<StudioConfig?> getBySessionId(String id) => gate.future;
}

final class _ProviderGuard extends ProviderObserver {
  final denied = <String>[];
  final unexpected = <Object>[];
  final _allowed = <Object>{
    gameSourceHarnessProvider,
    appDbProvider,
    chatSourceMutationRegistryProvider,
    chatRepoProvider,
    characterRepoProvider,
    personaRepoProvider,
    studioConfigRepoProvider,
    sessionDeletionRepoProvider,
    chatHistoryProvider,
    activeRegexesProvider,
    activePersonaIdProvider,
    personaConnectionsProvider,
    trackerSnapshotRepoProvider,
    trackerRepoProvider,
    memoryBookRepoProvider,
    characterKnowledgeFactRepoProvider,
    ledgerReconciliationCheckpointRepoProvider,
    ledgerReconciliationRunRepoProvider,
    infoBlocksRepoProvider,
    cardEvolutionProposalRunRepoProvider,
    sessionCanonRollbackRepoProvider,
    embeddingRepoProvider,
    lorebookUseManifestRepoProvider,
    infoBlocksProvider('game'),
    cachedTokenBreakdownProvider('character'),
    lastVectorLoreTokensProvider('character'),
    messageVariablesProvider,
  };

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (_allowed.contains(context.provider)) return;
    unexpected.add(context.provider);
    throw StateError('Provider outside the declared low-level fixture graph');
  }
}
