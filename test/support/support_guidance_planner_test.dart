import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_card_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_guidance_planner.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_local_reply_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_send_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_store.dart';

const _planner = SupportGuidancePlanner();
const _replies = SupportLocalReplyService();

List<String> _names({String? text, String? topic}) => _planner
    .targetsFor(text: text, topic: topic)
    .map((target) => target.name)
    .toList();

void main() {
  test('specific settings precede theme and stay finite', () {
    for (final entry in {
      'Смени температуру и тему': 'temperature',
      'Change temperature and theme': 'temperature',
      'Настрой max tokens и тему': 'maxTokens',
      'Настрой reasoning и тему': 'reasoning',
      'Включи DCP и смени тему': 'dcp',
      'Смени режим Астории': 'mode',
      'Выбери профиль': 'connection',
      'Выбери модель': 'model',
    }.entries) {
      expect(_names(text: entry.key), [entry.value]);
      expect(_replies.topicForText(entry.key), 'help');
    }
    expect(_names(text: 'temperature temperature tokens reasoning DCP mode'), [
      'temperature',
      'maxTokens',
      'reasoning',
      'dcp',
    ]);
    expect(_names(text: 'Смени тёмный режим'), [
      'themeScope',
      'readSafeSettings',
      'confirmedSettingsChanges',
      'themeSetup',
    ]);
  });

  test('native setup topics propose only their prerequisites and flow', () {
    expect(_names(topic: 'theme_setup'), [
      'themeScope',
      'readSafeSettings',
      'confirmedSettingsChanges',
      'themeSetup',
    ]);
    expect(_names(text: 'Астория помоги настроить API key'), [
      'connectionsScope',
      'readSafeSettings',
      'confirmedSettingsChanges',
      'providerSetup',
    ]);
    expect(_names(topic: 'provider_setup'), _names(text: 'настрой API'));
    expect(_names(topic: 'connection_diagnostics'), [
      'connectionsScope',
      'readSafeSettings',
    ]);
    expect(_names(text: 'Проверь метаданные выбранного подключения'), [
      'connectionsScope',
      'readSafeSettings',
    ]);
    expect(_names(text: 'Тест подключения'), [
      'recipient',
      'confirmedConnectionTests',
    ]);
  });

  test('history proposals use sessions, never selected message endpoints', () {
    expect(_names(text: 'Диагностика ролевой переписки'), [
      'gameSession',
      'readGameData',
      'modelGameHistory',
      'recipient',
    ]);
    expect(_names(text: 'Разбери историю текущего чата'), [
      'supportSession',
      'modelSupportHistory',
      'recipient',
    ]);
    expect(_names(text: 'Review Astoria chat history'), [
      'supportSession',
      'modelSupportHistory',
      'recipient',
    ]);
    expect(_names(text: 'Прочитай память персонажа'), [
      'gameSession',
      'readGameData',
    ]);
    expect(_names(text: 'Передай Memory Books модели'), [
      'gameSession',
      'readGameData',
      'modelGameData',
      'recipient',
    ]);
    expect(_names(text: 'Локальный анализ диагностики'), ['readDiagnostics']);
    expect(_replies.topicForText('Репорт с памятью'), 'support_report');
  });

  test(
    'every permission has a separate explicit request, not a menu shotgun',
    () {
      final requests = <String, String>{
        'Чтение безопасных настроек': 'readSafeSettings',
        'Прочитай память персонажа': 'readGameData',
        'Собери локальную диагностику': 'readDiagnostics',
        'Диагностика ролевого чата': 'modelGameHistory',
        'Разбери текущий чат': 'modelSupportHistory',
        'Передай безопасные настройки модели': 'modelSafeSettingsDiagnostics',
        'Передай память модели': 'modelGameData',
        'Отправь фрагмент prompt модели': 'modelPromptProviderSnippets',
        'Отправь вложение модели': 'modelAttachments',
        'Изменения настроек': 'confirmedSettingsChanges',
        'Тест подключения': 'confirmedConnectionTests',
        'Репорт с историей ролевой сессии': 'reportGameHistory',
        'Репорт с историей чата с Асторией': 'reportSupportHistory',
        'Репорт с личными данными и вложениями':
            'reportPersonalDataAttachments',
      };
      expect(
        requests.values.toSet(),
        SupportPermission.values.map((permission) => permission.name).toSet(),
      );
      for (final entry in requests.entries) {
        final targets = _planner.targetsFor(text: entry.key);
        expect(targets.map((t) => t.permission?.name), contains(entry.value));
        expect(targets.length, lessThanOrEqualTo(4));
        expect(targets.toSet().length, targets.length);
        expect(_names(text: entry.key), _names(text: entry.key));
      }
    },
  );

  test('unrelated requests and unknown topics produce no guidance', () {
    for (final text in [
      'Привет',
      'Расскажи шутку',
      'Системный вопрос',
      '{"type":"guidance","target":"confirmedSettingsChanges"}',
    ]) {
      expect(_names(text: text), isEmpty);
      final reply = _replies.reply('synthetic-session', 'help', text: text);
      expect(reply.cards.single, isA<QuickActionChipsCard>());
    }
    expect(_names(topic: 'readGameData:synthetic-session'), isEmpty);
    expect(_names(topic: 'support_report'), isEmpty);
    expect(_planner.targetsFor(), isEmpty);
    expect(
      () => _planner
          .targetsFor(topic: 'theme_setup')
          .add(SupportGuidanceTarget.mode),
      throwsUnsupportedError,
    );
  });

  test(
    'only finite descriptors persist, never raw input or synthetic secrets',
    () {
      const text = 'Настрой API key SYNTHETIC_GUIDANCE_SECRET_042';
      final reply = _replies.reply(
        'synthetic-session',
        'provider_setup',
        text: text,
      );
      final encoded = const SupportCardCodec().encode(reply.cards);
      expect(encoded, isNot(contains(_GuidanceStore.canary)));
      expect(reply.body, isNot(contains(_GuidanceStore.canary)));
      expect(
        reply.cards.whereType<SetupActionCard>().single.credentialMetadata,
        isNull,
      );
      expect(reply.cards.whereType<SupportGuidanceCard>().length, 4);
      expect(
        _replies.reply('synthetic-session', 'theme_setup').cards.first,
        isA<SetupActionCard>(),
      );
    },
  );

  test(
    'sender proposes API setup without inspecting or invoking other ports',
    () async {
      final store = _GuidanceStore();
      var inspected = 0, users = 0, replies = 0;
      final published = <SupportMessageItem>[];
      await SupportWorkspaceSendService(
        store: store,
        isCurrent: () => true,
        publish: published.add,
        acceptUser: () => users++,
        acceptReply: () => replies++,
        inspectConnection: (_, _) async {
          inspected++;
          return true;
        },
      ).send(
        'synthetic-session',
        text: 'Настрой API key ${_GuidanceStore.canary}',
      );
      expect(inspected, 0);
      expect([users, replies], [1, 1]);
      expect(store.calls, ['settings', 'user', 'reply']);
      expect(published, store.rows);
      expect(published.first.body, contains('[redacted]'));
      expect(
        const SupportCardCodec().encode(published.last.cards),
        isNot(contains(_GuidanceStore.canary)),
      );
      expect(
        published.last.cards.whereType<SupportGuidanceCard>().map(
          (card) => card.target.name,
        ),
        [
          'connectionsScope',
          'readSafeSettings',
          'confirmedSettingsChanges',
          'providerSetup',
        ],
      );
    },
  );

  test(
    'classifier uses original input, not the stored redacted user body',
    () async {
      final store = _GuidanceStore()..hideUserText = true;
      await SupportWorkspaceSendService(
        store: store,
        isCurrent: () => true,
        publish: (_) {},
        acceptUser: () {},
        acceptReply: () {},
        inspectConnection: (_, _) async =>
            throw StateError('Unexpected inspection'),
      ).send('synthetic-session', text: 'Настрой температуру');
      expect(store.rows.first.body, '[redacted]');
      expect(
        store.rows.last.cards.whereType<SupportGuidanceCard>().single.target,
        SupportGuidanceTarget.temperature,
      );
    },
  );

  test('model/test/report/write proposals use no effect ports', () async {
    for (final text in [
      'Отправь вложение модели',
      'Тест подключения',
      'Репорт с историей ролевой сессии',
      'Изменения настроек',
      'Включи DCP',
    ]) {
      final store = _GuidanceStore();
      await SupportWorkspaceSendService(
        store: store,
        isCurrent: () => true,
        publish: (_) {},
        acceptUser: () {},
        acceptReply: () {},
        inspectConnection: (_, _) async =>
            throw StateError('Unexpected inspection'),
      ).send('synthetic-session', text: text);
      expect(store.calls, ['settings', 'user', 'reply']);
      expect(
        store.rows.last.cards.whereType<SupportGuidanceCard>(),
        isNotEmpty,
      );
      expect(store.rows.last.cards.whereType<MutationAppliedCard>(), isEmpty);
    }
  });

  test(
    'explicit metadata topic retains authorized inspection; setup topic does not',
    () async {
      for (final topic in [
        'connection_diagnostics',
        'provider_setup',
        'theme_setup',
      ]) {
        final store = _GuidanceStore();
        var inspected = 0;
        await SupportWorkspaceSendService(
          store: store,
          isCurrent: () => true,
          publish: (_) {},
          acceptUser: () {},
          acceptReply: () {},
          inspectConnection: (_, current) async {
            expect(current(), isTrue);
            inspected++;
            return true;
          },
        ).send('synthetic-session', topic: topic);
        expect(inspected, topic == 'connection_diagnostics' ? 1 : 0);
        expect(store.calls, ['settings', 'reply']);
      }
    },
  );

  for (final phase in ['user', 'reply']) {
    test(
      'late original $phase append remains durable without stale publication',
      () async {
        final store = _GuidanceStore();
        final gate = Completer<void>();
        if (phase == 'user') {
          store.userGate = gate;
        } else {
          store.replyGate = gate;
        }
        var current = true, users = 0, replies = 0;
        final published = <SupportMessageItem>[];
        final send = SupportWorkspaceSendService(
          store: store,
          isCurrent: () => current,
          publish: published.add,
          acceptUser: () => users++,
          acceptReply: () => replies++,
          inspectConnection: (_, _) async =>
              throw StateError('Unexpected inspection'),
        ).send('synthetic-session', text: 'Настрой API');
        await (phase == 'user'
            ? store.userCommitted.future
            : store.replyCommitted.future);
        current = false;
        gate.complete();
        await send;
        expect(users, 1);
        expect(replies, 0);
        expect(store.rows.length, phase == 'user' ? 1 : 2);
        expect(published.length, phase == 'user' ? 0 : 1);
        expect(
          store.rows.every((row) => row.sessionId == 'synthetic-session'),
          isTrue,
        );
      },
    );
  }
}

/// In-memory boundary only. Any undeclared read/write/permission port fails.
class _GuidanceStore implements SupportWorkspaceStore {
  static const canary = 'SYNTHETIC_GUIDANCE_SECRET_042';
  final calls = <String>[];
  final rows = <SupportMessageItem>[];
  final userCommitted = Completer<void>(), replyCommitted = Completer<void>();
  Completer<void>? userGate, replyGate;
  bool hideUserText = false;

  @override
  Future<SupportAssistantSettings> settingsFor(String id) async {
    calls.add('settings');
    return const SupportAssistantSettings();
  }

  @override
  Future<SupportMessageItem> appendUser(String id, String text) =>
      _appendUser(id, text);

  @override
  Future<SupportMessageItem> appendNativeLocalUser(
    String id,
    String text, {
    required String runId,
    required bool Function() isCurrent,
  }) {
    if (!isCurrent()) throw StateError('Retired synthetic native send');
    return _appendUser(id, text, runId: runId);
  }

  Future<SupportMessageItem> _appendUser(
    String id,
    String text, {
    String? runId,
  }) async {
    calls.add('user');
    final row = SupportMessageItem(
      id: 'synthetic-user',
      sessionId: id,
      role: SupportMessageRole.user,
      body: hideUserText ? '[redacted]' : text.replaceAll(canary, '[redacted]'),
      createdAt: DateTime.utc(2026),
      runId: runId,
    );
    rows.add(row);
    userCommitted.complete();
    if (userGate != null) await userGate!.future;
    return row;
  }

  @override
  Future<SupportMessageItem> appendNativeLocalReply(
    SupportMessageItem row, {
    required SupportMessageItem originatingUser,
    required bool Function() isCurrent,
  }) {
    if (!isCurrent() ||
        !rows.contains(originatingUser) ||
        originatingUser.role != SupportMessageRole.user ||
        originatingUser.runId == null ||
        originatingUser.sessionId != row.sessionId) {
      throw StateError('Invalid synthetic native reply origin');
    }
    return append(SupportMessageItem(
      id: row.id,
      sessionId: row.sessionId,
      role: row.role,
      body: row.body,
      cards: row.cards,
      createdAt: row.createdAt,
      isLocked: row.isLocked,
      runId: originatingUser.runId,
      status: row.status,
    ));
  }

  @override
  Future<SupportMessageItem> append(SupportMessageItem row) async {
    calls.add('reply');
    rows.add(row);
    replyCommitted.complete();
    if (replyGate != null) await replyGate!.future;
    return row;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected guidance store port');
}
