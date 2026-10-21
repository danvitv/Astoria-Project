import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/credentials/api_connection_metadata.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../models/support_workspace_models.dart';
import '../services/support_connection_metadata_service.dart';
import '../services/support_local_reply_service.dart';
import '../services/support_workspace_store.dart';
import 'support_workspace_state.dart';

export '../models/support_workspace_models.dart';
export 'support_workspace_state.dart';

final supportConnectionMetadataProvider = FutureProvider(
  (ref) => SupportConnectionMetadataService(
    ref.watch(apiConfigRepoProvider),
    () => ref.read(secretRedactorProvider),
  ).load(),
);
final supportConnectionsProvider = Provider<List<ApiConnectionMetadata>>(
  (ref) =>
      ref.watch(supportConnectionMetadataProvider).asData?.value ?? const [],
);
final supportSessionStoreProvider = Provider(
  (ref) => SupportWorkspaceStore(
    ref.watch(supportRepoProvider),
    () => ref.read(secretRedactorProvider),
  ),
);

/// Serial durable writes; selection stays synchronous and owns reply completion.
class SupportWorkspaceNotifier extends Notifier<SupportWorkspaceState> {
  Future<void> _tail = Future.value();
  int _selection = 0;
  bool _alive = true;
  late SupportWorkspaceStore _store;
  final _replies = const SupportLocalReplyService();

  @override
  SupportWorkspaceState build() {
    _alive = true;
    _store = ref.watch(supportSessionStoreProvider);
    ref.onDispose(() => _alive = false);
    unawaited(Future.microtask(() => _enqueue(_reload)));
    return const SupportWorkspaceState();
  }

  Future<bool> _enqueue(Future<void> Function() work) {
    final result = Completer<bool>();
    _tail = _tail.then((_) async {
      if (!_alive) {
        result.complete(false);
        return;
      }
      state = state.copyWith(isBusy: true, clearError: true);
      try {
        await work();
        result.complete(true);
      } catch (_) {
        if (_alive) {
          state = state.copyWith(
            error:
                'Не удалось прочитать или сохранить историю помощника. Проверь доступ к защищённому хранилищу.',
          );
        }
        result.complete(false);
      } finally {
        if (_alive) state = state.copyWith(isBusy: false, isLoading: false);
      }
    });
    return result.future;
  }

  Future<void> _reload() async {
    final snapshot = await _store.load();
    if (!_alive) return;
    final active = snapshot.sessions.any((s) => s.id == state.activeSessionId)
        ? state.activeSessionId
        : snapshot.sessions.firstOrNull?.id ?? '';
    state = state.copyWith(
      sessions: snapshot.sessions,
      messagesBySession: snapshot.messages,
      activeSessionId: active,
      settings: snapshot.settings[active] ?? const SupportAssistantSettings(),
      isLoading: false,
    );
  }

  Future<bool> refresh() => _enqueue(_reload);
  void setSessionSearchQuery(String query) {
    state = state.copyWith(sessionSearchQuery: query);
  }

  Future<String?> createNewSession({String? title}) async {
    final selection = ++_selection;
    String? id;
    await _enqueue(() async {
      await ref.read(supportConnectionMetadataProvider.future);
      if (!_alive) return;
      id = await _store.create(title);
      if (!_alive) return;
      if (_selection == selection) state = state.copyWith(activeSessionId: id);
      await _reload();
    });
    return id;
  }

  void selectSession(String sessionId) {
    if (!state.sessions.any((s) => s.id == sessionId)) return;
    _selection++;
    state = state.copyWith(
      activeSessionId: sessionId,
      settings: const SupportAssistantSettings(),
    );
    unawaited(_enqueue(_reload));
  }

  Future<bool> renameSession(String id, String title) => _enqueue(() async {
    await ref.read(supportConnectionMetadataProvider.future);
    if (!_alive) return;
    await _store.rename(id, title);
    if (_alive) await _reload();
  });
  Future<bool> togglePinSession(String id) => _enqueue(() async {
    await _store.togglePin(id);
    if (_alive) await _reload();
  });
  Future<bool> deleteSession(String id) {
    if (id == state.activeSessionId) _selection++;
    return _enqueue(() async {
      await _store.repo.deleteSession(id);
      if (_alive) await _reload();
    });
  }

  Future<bool> _settings(
    SupportAssistantSettings Function(SupportAssistantSettings) change,
  ) {
    final id = state.activeSessionId;
    if (id.isEmpty || state.isLoading) return Future.value(false);
    return _enqueue(() async {
      await ref.read(supportConnectionMetadataProvider.future);
      if (!_alive) return;
      await _store.changeSettings(id, change);
      if (_alive) await _reload();
    });
  }

  Future<bool> setMode(SupportAssistantMode mode) =>
      _settings((s) => s.copyWith(mode: mode));
  Future<bool> selectConnection(String? id, {String? defaultModelId}) =>
      _settings(
        (s) => s.copyWith(
          apiConfigId: id,
          clearApiConfigId: id == null,
          modelId: defaultModelId,
          clearModelId: defaultModelId == null,
        ),
      );
  Future<bool> selectModel(String? id) => _settings(
    (s) => s.copyWith(modelId: id, clearModelId: id == null || id.isEmpty),
  );
  Future<bool> setTemperature(double value) => _settings(
    (s) => s.copyWith(temperature: value.isFinite ? value.clamp(0, 2) : 0.35),
  );
  Future<bool> setMaxTokens(int value) =>
      _settings((s) => s.copyWith(maxTokens: value.clamp(256, 16384)));
  Future<bool> setReasoningEffort(SupportReasoningEffort effort) =>
      _settings((s) => s.copyWith(reasoningEffort: effort));
  Future<bool> setDcpCompression(bool enabled) =>
      _settings((s) => s.copyWith(dcpCompressionEnabled: enabled));
  void applyInitialTopic(String? topic) {
    if (topic == null ||
        topic.trim().isEmpty ||
        state.lastHandledTopic == topic ||
        state.isLoading) {
      return;
    }
    state = state.copyWith(lastHandledTopic: topic);
    unawaited(
      triggerQuickAction(switch (topic.trim().toLowerCase()) {
        'theme' => 'theme_setup',
        'provider' || 'api' => 'provider_setup',
        'memory' => 'memory_books_setup',
        'diagnostics' => 'connection_diagnostics',
        'report' => 'support_report',
        _ => topic.trim(),
      }),
    );
  }

  Future<bool> sendUserMessage(String text) => _send(text: text);
  Future<bool> triggerQuickAction(String topic) => _send(topic: topic);
  Future<bool> _send({String? text, String? topic}) async {
    final id = state.activeSessionId;
    if (id.isEmpty ||
        state.isLoading ||
        state.isBusy ||
        state.activeSession?.isLocked == true ||
        (text != null && text.trim().isEmpty)) {
      return false;
    }
    final selection = _selection;
    var accepted = false;
    await _enqueue(() async {
      final connections = await ref.read(
        supportConnectionMetadataProvider.future,
      );
      if (!_alive || _selection != selection) return;
      final settings = await _store.settingsFor(id);
      if (!_alive || _selection != selection) return;
      if (text != null) {
        await _store.appendUser(id, text);
        accepted =
            true; // Acceptance means the user row is durable, even if reply fails.
        if (!_alive || _selection != selection) {
          if (_alive) await _reload();
          return;
        }
      }
      final connection = connections
          .where((c) => c.connectionId == settings.apiConfigId)
          .firstOrNull;
      await _store.append(
        _replies.reply(id, topic ?? _replies.topicForText(text!), connection),
      );
      accepted = true;
      if (_alive) await _reload();
    });
    return accepted;
  }

  Future<bool> deleteMessage(String messageId) {
    final id = state.activeSessionId;
    return _enqueue(() async {
      await _store.deleteMessage(id, messageId);
      if (_alive) await _reload();
    });
  }

  // No executor/exporter exists in this phase.
  Future<bool> applyMutationPlan(String planId) async => false;
  Future<bool> rollbackMutation(String journalId) async => false;
}

final supportWorkspaceProvider =
    NotifierProvider<SupportWorkspaceNotifier, SupportWorkspaceState>(
      SupportWorkspaceNotifier.new,
    );
