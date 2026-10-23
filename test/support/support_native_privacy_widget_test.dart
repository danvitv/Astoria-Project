import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_group.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_panel.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_history_selection_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/shared/widgets/glaze_switch.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/support_legacy_history_widget_driver.dart';
import 'helpers/support_native_fixture.dart';
import 'helpers/support_native_widget_fixture.dart';
import 'synthetic_consent_selection_fixture.dart';

Future<void> _pump(
  WidgetTester tester,
  NativeFixture f, {
  String language = 'ru',
  bool panel = false,
  bool legacyHistory = false,
}) async {
  final privacy = panel
      ? const SupportSettingsPanel()
      : ListView(children: const [SupportPrivacyGroup()]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeWidgetOverrides(f),
        appSettingsProvider.overrideWith(NativeWidgetAppSettings.new),
        if (panel) supportWorkspaceProvider.overrideWith(_PanelWorkspace.new),
        if (panel) supportConnectionsProvider.overrideWithValue(const []),
      ],
      child: localizedNativeWidget(
        legacyHistory
            ? SupportLegacyHistoryWidgetDriver(child: privacy)
            : privacy,
        language: language,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _tap(tester, 'support_privacy_group');
}

class _PanelWorkspace extends SupportWorkspaceNotifier {
  @override
  SupportWorkspaceState build() => const SupportWorkspaceState(
    activeSessionId: NativeFixture.id,
    settings: SupportAssistantSettings(
      apiConfigId: 'synthetic-connection',
      modelId: 'synthetic-model',
    ),
    isLoading: false,
  );
}

Future<void> _show(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .last,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await _show(tester, key);
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.runAsync(() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  });
  await tester.pumpAndSettle();
}

GlazeSwitch _switch(WidgetTester tester, String permission) =>
    tester.widget<GlazeSwitch>(
      find.descendant(
        of: find.byKey(ValueKey('support_privacy_$permission')),
        matching: find.byType(GlazeSwitch),
      ),
    );

Future<void> _grant(
  WidgetTester tester,
  String permission,
  bool enabled,
) async {
  _switch(tester, permission).onChanged!(enabled);
  await tester.runAsync(() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  });
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester) async {
  await _tap(tester, 'support_privacy_recipient');
  await _tap(tester, 'support_privacy_review_confirm');
}

Future<void> _openLegacyHistory(
  WidgetTester tester,
  NativeFixture f,
  SupportConsentSelectionSource source,
) async {
  final settingsReads = f.settingsReads;
  final apiIds = [...f.api.ids];
  await _tap(tester, 'support_legacy_history_${source.name}');
  expect(find.byType(SupportHistorySelectionSheet), findsOneWidget);
  expect(f.settingsReads, settingsReads);
  expect(f.api.ids, apiIds);
  expect(f.api.bulkReads, 0);
  expect(f.selectedLoads, 0);
  expect(f.runtime.recipientConfirmed, false);
  for (final canary in [
    NativeFixture.canary,
    SyntheticConsentSelectionFixture.bodyCanary,
    SyntheticConsentSelectionFixture.cardCanary,
    SyntheticConsentSelectionFixture.reasoningCanary,
    SyntheticConsentSelectionFixture.pathCanary,
    'SYNTHETIC_PERMISSION_CANARY history',
  ]) {
    expect(find.textContaining(canary), findsNothing);
  }
}

Future<void> _saveLegacyHistory(WidgetTester tester) async {
  final driver = tester.state<SupportLegacyHistoryWidgetDriverState>(
    find.byType(SupportLegacyHistoryWidgetDriver),
  );
  final calls = driver.selectionCalls;
  await _tap(tester, 'support_privacy_select_messages');
  expect(await _native(tester, () => driver.completion!), true);
  expect(driver.selectionCalls, calls + 1);
  expect(find.byType(SupportHistorySelectionSheet), findsNothing);
}

Future<void> _backLegacyHistory(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(SheetView),
      matching: find.byIcon(Icons.arrow_back),
    ),
  );
  await tester.pumpAndSettle();
}

Future<T> _native<T>(
  WidgetTester tester,
  Future<T> Function() operation,
) async {
  var done = false;
  T? result;
  Object? error;
  unawaited(
    operation().then(
      (value) {
        result = value;
        done = true;
      },
      onError: (Object e) {
        error = e;
        done = true;
      },
    ),
  );
  // Drive both the widget clock and real SQLite/AEAD callbacks to a measured
  // completion, rather than awaiting a future trapped in the fake widget clock.
  for (var i = 0; !done && i < 100; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (error != null) throw error!;
  expect(done, true, reason: 'Synthetic native operation completed');
  return result as T;
}

Future<SupportPermissionPreferences> _policy(
  WidgetTester tester,
  NativeFixture f,
) => _native(
  tester,
  () async => (await f.database.b.readForNative(NativeFixture.id)).preferences!,
);

Future<void> _game(
  NativeFixture f, {
  int count = 4,
  String id = 'game-session',
  bool hidden = false,
}) async {
  final db = f.database.db;
  await db
      .into(db.characters)
      .insert(
        CharactersCompanion.insert(
          charId: '$id-character',
          name: 'Синтетический персонаж ${'длинное имя ' * 15}',
          variantName: const Value('Вариант'),
          hidden: Value(hidden),
        ),
      );
  final rows = List.generate(
    count,
    (i) => SyntheticConsentSelectionFixture.message(
      'game-$i',
      role: i.isEven ? 'user' : 'assistant',
      hidden: i == 1,
    ),
  );
  await db
      .into(db.chatSessions)
      .insert(
        ChatSessionsCompanion.insert(
          sessionId: id,
          characterId: '$id-character',
          sessionIndex: 2,
          messagesJson: jsonEncode(rows),
        ),
      );
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await NativeWidgetTranslations.preload();
  });
  late NativeFixture f;
  setUp(() async {
    f = NativeFixture();
    await f.seed();
  });
  tearDown(() => f.close());

  for (final width in [236.0, 360.0]) {
    testWidgets(
      'actual privacy group fits RU at $width and defaults all 14 off',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _pump(tester, f, panel: true);
        expect(find.text('Передать историю игровой сессии'), findsOneWidget);
        expect(find.text('Передать историю чата Астории'), findsOneWidget);
        expect(find.text('Выбрать игровую сессию для доступа'), findsOneWidget);
        expect(
          find.text('Выбрать текущую сессию Астории для доступа'),
          findsOneWidget,
        );
        expect(
          find.text(
            'Выбрано ссылок на сообщения: игровая сессия — 0; чат Астории — 1.',
          ),
          findsOneWidget,
        );
        for (final right in SupportPermission.values) {
          expect(_switch(tester, right.name).value, false);
        }
        await tester.ensureVisible(
          find.byKey(
            const ValueKey('support_privacy_reportPersonalDataAttachments'),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(f.selectedLoads, 0);
        expect(f.api.bulkReads, 0);
      },
    );
  }

  testWidgets('English keys use actual translations', (tester) async {
    await _pump(tester, f, language: 'en');
    expect(find.text('Share game-session history'), findsOneWidget);
    expect(find.text('Share Astoria chat history'), findsOneWidget);
    expect(find.text('Choose a roleplay session for access'), findsOneWidget);
    expect(
      find.text('Choose the current Astoria session for access'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Selected message references: game session — 0; Astoria chat — 1.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'opening/cancelling recipient never confirms or loads assistant data',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pump(tester, f);
      final before = await f.database.preserved();
      await _tap(tester, 'support_privacy_recipient');
      expect(f.runtime.recipientConfirmed, false);
      expect(find.text('Synthetic selected connection'), findsOneWidget);
      expect(find.text('synthetic-model'), findsOneWidget);
      expect(find.textContaining('https://'), findsNothing);
      expect(find.textContaining(NativeFixture.canary), findsNothing);
      expect(
        find.textContaining('конечный провайдер OpenRouter не проверены'),
        findsOneWidget,
      );
      await _tap(tester, 'support_privacy_review_cancel');
      expect(f.runtime.recipientConfirmed, false);
      expect(await f.database.preserved(), before);
      expect(f.selectedLoads, 0);
      expect(f.api.bulkReads, 0);
    },
  );

  testWidgets(
    'explicit recipient unlocks independent native model/report/local/change/network rights',
    (tester) async {
      await _pump(tester, f);
      final before = await f.database.preserved();
      await _confirm(tester);
      expect(f.runtime.recipientConfirmed, true);
      await _grant(tester, 'modelSupportHistory', true);
      var p = await _policy(tester, f);
      expect(p.grants, {SupportPermission.modelSupportHistory});
      expect(_switch(tester, 'reportSupportHistory').value, false);
      expect(_switch(tester, 'readSafeSettings').value, false);
      await _grant(tester, 'reportSupportHistory', true);
      await _grant(tester, 'readSafeSettings', true);
      await _grant(tester, 'confirmedSettingsChanges', true);
      await _grant(tester, 'confirmedConnectionTests', true);
      p = await _policy(tester, f);
      expect(p.grants, {
        SupportPermission.modelSupportHistory,
        SupportPermission.reportSupportHistory,
        SupportPermission.readSafeSettings,
        SupportPermission.confirmedSettingsChanges,
        SupportPermission.confirmedConnectionTests,
      });
      await _grant(tester, 'reportSupportHistory', false);
      expect(_switch(tester, 'modelSupportHistory').value, true);
      expect(await f.database.preserved(), before);
      expect(f.selectedLoads, 0);
    },
  );

  testWidgets(
    'unsupported loaders are really disabled even after recipient review',
    (tester) async {
      await _pump(tester, f);
      await _confirm(tester);
      for (final right in [
        'readGameData',
        'readDiagnostics',
        'modelGameData',
        'modelPromptProviderSnippets',
        'modelAttachments',
        'reportPersonalDataAttachments',
      ]) {
        expect(_switch(tester, right).onChanged, isNull);
      }
      expect(find.textContaining('Выбор установленной темы'), findsOneWidget);
      expect(f.selectedLoads, 0);
    },
  );

  testWidgets(
    'legacy exact-message compatibility preserves native order and omits hidden body data',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _game(f);
      await _game(f, id: 'hidden-session', hidden: true);
      await _pump(tester, f, legacyHistory: true);
      final before = await f.database.preserved();
      await _openLegacyHistory(
        tester,
        f,
        SupportConsentSelectionSource.roleplay,
      );
      expect(
        find.byKey(const ValueKey('support_privacy_session_hidden-session')),
        findsNothing,
      );
      await _tap(tester, 'support_privacy_session_game-session');
      expect(tester.widget<SheetView>(find.byType(SheetView)).showBack, true);
      expect(tester.getSize(find.byType(SheetView)).height.isFinite, true);
      expect(
        find.textContaining('пропущено скрытых/недоступных: 1'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('support_privacy_message_game-1')),
        findsNothing,
      );
      await _show(tester, 'support_privacy_message_game-0');
      expect(find.text('Сообщение 1 · пользователь'), findsOneWidget);
      expect(find.text('Сообщение 3 · пользователь'), findsOneWidget);
      for (final canary in [
        SyntheticConsentSelectionFixture.bodyCanary,
        SyntheticConsentSelectionFixture.cardCanary,
        SyntheticConsentSelectionFixture.reasoningCanary,
      ]) {
        expect(find.textContaining(canary), findsNothing);
      }
      await _tap(tester, 'support_privacy_message_game-3');
      await _tap(tester, 'support_privacy_message_game-0');
      await _saveLegacyHistory(tester);
      final p = await _policy(tester, f);
      expect(p.scope!.gameSessionId, 'game-session');
      expect(p.scope!.gameHistory!.messageIds, ['game-0', 'game-3']);
      expect(p.scope!.gameHistoryExtent, SupportHistoryExtent.selectedMessages);
      expect(p.grants, isEmpty);
      expect(f.runtime.recipientConfirmed, false);
      expect(await f.database.preserved(), before);
      expect(f.selectedLoads, 0);
    },
  );

  testWidgets(
    'legacy exact-message pagination replaces checks, never silently unions pages',
    (tester) async {
      await _game(f, count: 103);
      await _pump(tester, f, legacyHistory: true);
      await _openLegacyHistory(
        tester,
        f,
        SupportConsentSelectionSource.roleplay,
      );
      await _tap(tester, 'support_privacy_session_game-session');
      await _tap(tester, 'support_privacy_message_game-0');
      await _tap(tester, 'support_privacy_next_messages');
      expect(
        find.textContaining('отметки предыдущей страницы сняты'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('support_privacy_message_game-0')),
        findsNothing,
      );
      await _tap(tester, 'support_privacy_message_game-102');
      await _saveLegacyHistory(tester);
      final p = await _policy(tester, f);
      expect(p.scope!.gameHistory!.messageIds, ['game-102']);
      expect(p.scope!.gameHistoryExtent, SupportHistoryExtent.selectedMessages);
      expect(p.grants, isEmpty);
      expect(f.runtime.recipientConfirmed, false);
      expect(f.selectedLoads, 0);
      expect(f.api.bulkReads, 0);
    },
  );

  testWidgets(
    'legacy exact-message cancel/back grants nothing and empty selection clears only that source',
    (tester) async {
      await _game(f);
      await _pump(tester, f, legacyHistory: true);
      final before = await _policy(tester, f);
      await _openLegacyHistory(
        tester,
        f,
        SupportConsentSelectionSource.roleplay,
      );
      await _tap(tester, 'support_privacy_session_game-session');
      await _tap(tester, 'support_privacy_message_game-0');
      await _backLegacyHistory(tester);
      expect(
        find.byKey(const ValueKey('support_privacy_session_game-session')),
        findsOneWidget,
      );
      await _backLegacyHistory(tester);
      final driver = tester.state<SupportLegacyHistoryWidgetDriverState>(
        find.byType(SupportLegacyHistoryWidgetDriver),
      );
      expect(await _native(tester, () => driver.completion!), isNull);
      expect(driver.selectionCalls, 0);
      var p = await _policy(tester, f);
      expect(p.scope!.sameAs(before.scope), true);
      await _openLegacyHistory(
        tester,
        f,
        SupportConsentSelectionSource.support,
      );
      expect(
        find.byKey(const ValueKey('support_privacy_message_synthetic-message')),
        findsOneWidget,
      );
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        false,
      );
      await _saveLegacyHistory(tester);
      p = await _policy(tester, f);
      expect(p.scope!.supportHistory, isNull);
      expect(p.scope!.safeCategories, {SupportSafeCategory.connections});
      expect(p.grants, isEmpty);
      expect(f.runtime.recipientConfirmed, false);
    },
  );

  for (final change in [
    'session ABA',
    'settings ABA',
    'scope',
    'cancel',
    'lifetime',
  ]) {
    testWidgets('recipient sheet rejects stale $change confirmation', (
      tester,
    ) async {
      await _pump(tester, f);
      await _tap(tester, 'support_privacy_recipient');
      switch (change) {
        case 'session ABA':
          f.runtime.selectSession('other');
          f.runtime.selectSession(NativeFixture.id);
        case 'settings ABA':
          final settle = f.runtime.beginSettingsChange();
          settle();
        case 'scope':
          await _native(tester, () async {
            final review = await f.controller.prepareReview();
            await f.controller.selectConnections(review!, false);
          });
        case 'cancel':
          f.controller.cancelReview();
        case 'lifetime':
          f.runtime.selectSession(NativeFixture.id, force: true);
      }
      await tester.pumpAndSettle();
      await _show(tester, 'support_privacy_review_confirm');
      final button = tester.widget<GlazeActionButton>(
        find.byKey(const ValueKey('support_privacy_review_confirm')),
      );
      expect(button.onTap, isNull);
      expect(f.runtime.recipientConfirmed, false);
      await _tap(tester, 'support_privacy_review_cancel');
      expect(f.runtime.recipientConfirmed, false);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'legacy exact-message preparation after disposal cannot publish or write',
    (tester) async {
      final delayed = Completer<SupportConsentMessagePage>();
      final entered = Completer<void>();
      f.messagesPort = (_, _, _) {
        if (!entered.isCompleted) entered.complete();
        return delayed.future;
      };
      await _pump(tester, f, legacyHistory: true);
      final row = await f.database.row();
      final before = await f.database.preserved();
      // pumpAndSettle cannot finish while the loader's progress indicator runs.
      await _show(tester, 'support_legacy_history_support');
      await tester.tap(
        find.byKey(const ValueKey('support_legacy_history_support')),
      );
      await _native(tester, () => entered.future);
      expect(find.byType(SupportHistorySelectionSheet), findsOneWidget);
      expect(f.settingsReads, 0);
      expect(f.api.ids, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      delayed.complete(
        SupportConsentMessagePage(
          source: SupportConsentSelectionSource.support,
          sessionId: NativeFixture.id,
          items: [],
          status: SupportConsentSelectionStatus.available,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(f.runtime.recipientConfirmed, false);
      expect(await f.database.row(), row);
      expect(await f.database.preserved(), before);
      expect(f.selectedLoads, 0);
      expect(f.api.bulkReads, 0);
    },
  );

  testWidgets(
    'legacy exact-message choice initializes missing deny policy without granting rights',
    (tester) async {
      final row = await f.database.row();
      await (f.database.db.delete(
        f.database.db.supportContextBlocks,
      )..where((t) => t.id.equals(row!.id))).go();
      await _native(tester, () => f.runtime.refresh(resolve: false));
      await _pump(tester, f, legacyHistory: true);
      for (final right in SupportPermission.values) {
        expect(_switch(tester, right.name).value, false);
      }
      expect(await f.database.row(), isNull);
      final before = await f.database.preserved();
      await _openLegacyHistory(
        tester,
        f,
        SupportConsentSelectionSource.support,
      );
      expect(await f.database.row(), isNull);
      await _tap(tester, 'support_privacy_message_synthetic-message');
      await _saveLegacyHistory(tester);
      final selected = await _policy(tester, f);
      expect(selected.scope!.supportHistory!.messageIds, ['synthetic-message']);
      expect(
        selected.scope!.supportHistoryExtent,
        SupportHistoryExtent.selectedMessages,
      );
      expect(selected.scope!.safeCategories, isEmpty);
      expect(selected.grants, isEmpty);
      expect(f.runtime.recipientConfirmed, false);
      // The current Privacy category toggle remains a real independent control.
      final committed = Completer<void>();
      final stop = f.runtime.listen(() {
        if (f.controller.view.connectionsSelected &&
            f.runtime.pending == 0 &&
            !committed.isCompleted) {
          committed.complete();
        }
      });
      addTearDown(stop);
      _switch(tester, 'connections_scope').onChanged!(true);
      await _native(tester, () => committed.future);
      await tester.pumpAndSettle();
      final p = await _policy(tester, f);
      expect(p.scope!.safeCategories, {SupportSafeCategory.connections});
      expect(p.scope!.supportHistory!.messageIds, ['synthetic-message']);
      expect(p.grants, isEmpty);
      expect(await f.database.preserved(), before);
      expect(f.selectedLoads, 0);
      expect(f.api.bulkReads, 0);
    },
  );

  testWidgets(
    'deleted current support session stays unavailable with no reset or source substitution',
    (tester) async {
      await _native(
        tester,
        () => f.database.repoB.deleteSession(NativeFixture.id),
      );
      await _native(tester, () => f.runtime.refresh());
      await _pump(tester, f);
      expect(
        find.textContaining('Разрешения текущей сессии недоступны'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('support_privacy_recovery')),
        findsNothing,
      );
      final button = tester.widget<GlazeActionButton>(
        find.byKey(const ValueKey('support_privacy_support_scope')),
      );
      expect(button.onTap, isNull);
      expect(_switch(tester, 'confirmedSettingsChanges').onChanged, isNull);
    },
  );

  testWidgets(
    'legacy exact-message locked metadata cannot mint a choice or clear another source',
    (tester) async {
      f.messagesPort = (source, id, offset) async => SupportConsentMessagePage(
        source: source,
        sessionId: id,
        items: [],
        status: SupportConsentSelectionStatus.parentLocked,
      );
      await _pump(tester, f, legacyHistory: true);
      final before = await _policy(tester, f);
      await _openLegacyHistory(
        tester,
        f,
        SupportConsentSelectionSource.support,
      );
      expect(
        find.textContaining('Метаданные недоступны или выбор устарел'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('support_privacy_select_messages')),
        findsNothing,
      );
      await _backLegacyHistory(tester);
      final driver = tester.state<SupportLegacyHistoryWidgetDriverState>(
        find.byType(SupportLegacyHistoryWidgetDriver),
      );
      expect(await _native(tester, () => driver.completion!), isNull);
      expect(driver.selectionCalls, 0);
      expect((await _policy(tester, f)).scope!.sameAs(before.scope), true);
      expect(f.selectedLoads, 0);
    },
  );

  testWidgets(
    'pending ordinary settings change disables every native right without changing generation state',
    (tester) async {
      await _pump(tester, f);
      final settle = f.runtime.beginSettingsChange();
      await tester.pumpAndSettle();
      for (final right in SupportPermission.values) {
        expect(_switch(tester, right.name).onChanged, isNull);
      }
      settle();
      await tester.pumpAndSettle();
      expect(_switch(tester, 'confirmedSettingsChanges').onChanged, isNotNull);
      expect(f.selectedLoads, 0);
    },
  );

  testWidgets(
    'corrupt permission recovery is explicit, cancel preserves history and policy',
    (tester) async {
      await _native(tester, () async {
        await f.database.corrupt();
        await f.runtime.refresh();
      });
      await _pump(tester, f);
      final row = await f.database.row();
      final history = await f.database.preserved();
      expect(_switch(tester, 'confirmedSettingsChanges').onChanged, isNull);
      await _tap(tester, 'support_privacy_recovery');
      await _tap(tester, 'support_privacy_review_cancel');
      expect(await f.database.row(), row);
      await _tap(tester, 'support_privacy_recovery');
      await _tap(tester, 'support_privacy_review_confirm');
      expect((await _policy(tester, f)).grants, isEmpty);
      expect(await f.database.preserved(), history);
      expect(f.runtime.recipientConfirmed, false);
    },
  );

  testWidgets('stale recovery cannot reset a substituted healthy policy', (
    tester,
  ) async {
    await _native(tester, () async {
      await f.database.corrupt();
      await f.runtime.refresh();
    });
    await _pump(tester, f);
    await _tap(tester, 'support_privacy_recovery');
    await _native(
      tester,
      () => f.database.b.recoverToDenyFromNative(
        NativeFixture.id,
        confirmed: true,
        isCurrent: () => true,
      ),
    );
    final healthy = await f.database.row();
    await _tap(tester, 'support_privacy_review_confirm');
    expect(await f.database.row(), healthy);
    expect(
      find.textContaining('Не удалось применить нативный выбор'),
      findsOneWidget,
    );
  });

  testWidgets('locked policy has no reset or enabled grant controls', (
    tester,
  ) async {
    // Unreadable encrypted permission ciphertext, while the session is readable.
    final row = await f.database.row();
    await (f.database.db.update(
      f.database.db.supportContextBlocks,
    )..where((t) => t.id.equals(row!.id))).write(
      const SupportContextBlocksCompanion(
        protectedFactsCiphertext: Value('synthetic-locked'),
      ),
    );
    await _native(tester, () => f.runtime.refresh());
    await _pump(tester, f);
    expect(
      find.byKey(const ValueKey('support_privacy_recovery')),
      findsNothing,
    );
    expect(_switch(tester, 'confirmedSettingsChanges').onChanged, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'native write failure stays safe, controls recover, no exception text is displayed',
    (tester) async {
      await _pump(tester, f);
      f.database.primitive.afterEncrypt = (_) async =>
          throw StateError(NativeFixture.canary);
      await _grant(tester, 'confirmedSettingsChanges', true);
      expect(
        find.textContaining('Не удалось применить нативный выбор'),
        findsOneWidget,
      );
      expect(find.textContaining(NativeFixture.canary), findsNothing);
      expect(_switch(tester, 'confirmedSettingsChanges').value, false);
      f.database.primitive.afterEncrypt = null;
      await _grant(tester, 'confirmedSettingsChanges', true);
      expect(_switch(tester, 'confirmedSettingsChanges').value, true);
    },
  );

  testWidgets(
    'transient native inspection disappears immediately and never becomes chat payload',
    (tester) async {
      await _pump(tester, f);
      await _grant(tester, 'readSafeSettings', true);
      final before = await f.database.preserved();
      expect(
        await _native(
          tester,
          () =>
              f.runtime.inspectSelectedConnection(NativeFixture.id, () => true),
        ),
        true,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('support_privacy_transient_inspection')),
        findsOneWidget,
      );
      expect(find.textContaining('символов:'), findsOneWidget);
      expect(find.textContaining(NativeFixture.canary), findsNothing);
      await _grant(tester, 'readSafeSettings', false);
      expect(
        find.byKey(const ValueKey('support_privacy_transient_inspection')),
        findsNothing,
      );
      expect(await f.database.preserved(), before);
      expect(f.selectedLoads, 1);
      expect(f.api.bulkReads, 0);
    },
  );

  testWidgets(
    'typed grant persistence is per support session, not a recipient auto-confirm',
    (tester) async {
      await _pump(tester, f);
      await _grant(tester, 'confirmedSettingsChanges', true);
      await f.database.repoB.createSession(
        const SupportSession(
          id: 'other',
          title: 'Other',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      f.runtime.selectSession('other');
      await _native(tester, () => f.runtime.refresh());
      await tester.pumpAndSettle();
      expect(_switch(tester, 'confirmedSettingsChanges').value, false);
      f.runtime.selectSession(NativeFixture.id);
      await _native(tester, () => f.runtime.refresh());
      await tester.pumpAndSettle();
      expect(_switch(tester, 'confirmedSettingsChanges').value, true);
      expect(f.runtime.recipientConfirmed, false);
    },
  );

  testWidgets(
    'registry begin/settle clears transient data; reopening observes native reconfirmation without losing independent rights',
    (tester) async {
      final stop = f.revisions.subscribe(f.runtime.invalidateConfiguration);
      addTearDown(stop);
      await _pump(tester, f);
      await _confirm(tester);
      await _grant(tester, 'readSafeSettings', true);
      await _grant(tester, 'modelSupportHistory', true);
      await _grant(tester, 'reportSupportHistory', true);
      await _native(
        tester,
        () => f.runtime.inspectSelectedConnection(NativeFixture.id, () => true),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('support_privacy_transient_inspection')),
        findsOneWidget,
      );
      final settle = f.revisions.beginMutation();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('support_privacy_transient_inspection')),
        findsNothing,
      );
      expect(_switch(tester, 'modelSupportHistory').onChanged, isNull);
      settle();
      await tester.pumpWidget(const SizedBox.shrink());
      await _pump(tester, f);
      expect(_switch(tester, 'modelSupportHistory').value, false);
      expect(_switch(tester, 'reportSupportHistory').value, true);
      expect(_switch(tester, 'readSafeSettings').value, true);
      expect(f.runtime.recipientConfirmed, false);
      expect(
        find.byKey(const ValueKey('support_privacy_transient_inspection')),
        findsNothing,
      );
    },
  );
}
