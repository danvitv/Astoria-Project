import 'dart:convert';

import 'package:drift/native.dart';
import 'package:drift/src/runtime/data_class.dart' show Value;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_event_registry_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/memory_event_registry_view.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';

const _sessionId = 'registry-session';

/// Ordered chat messages the session holds. Story positions are indexes
/// into this list, 1-based — the ids themselves carry no numbers. Each
/// message carries the ledger clock stamp of its scene (`time`), as the
/// Studio Ledger writes them.
Future<void> _seedChat(AppDatabase db) async {
  final messages = [
    ChatMessage(
      id: 'message-211',
      role: 'assistant',
      content: 'scene one',
      swipeId: 1,
      agentSwipeId: 2,
      time: '05.04.2026 · RP_Day 0 · 19:45',
    ),
    ChatMessage(
      id: 'message-225',
      role: 'assistant',
      content: 'scene one end',
      swipeId: 1,
      agentSwipeId: 2,
      // Later stamp on the same scene's last message: the event must show
      // the FIRST stamp ("when it was given"), not this one.
      time: '05.04.2026 · RP_Day 1 · 08:30',
    ),
    ChatMessage(
      id: 'message-360',
      role: 'assistant',
      content: 'scene later',
      swipeId: 1,
      agentSwipeId: 2,
      time: '18.05.2026 · RP_Day 12 · 21:00',
    ),
  ];
  await db
      .into(db.chatSessions)
      .insert(
        ChatSessionsCompanion.insert(
          sessionId: _sessionId,
          characterId: 'registry-character',
          sessionIndex: 0,
          messagesJson: jsonEncode([
            for (final message in messages) message.toJson(),
          ]),
        ),
      );
}

Future<void> _seed(AppDatabase db) async {
  await db
      .into(db.memoryEventRows)
      .insert(
        MemoryEventRowsCompanion.insert(
          id: 'event-open',
          sessionId: _sessionId,
          branchId: _sessionId,
          kind: 'promise',
          description: 'Chisato returns to Sumida by 22:00.',
          state: 'open',
          // Accepted later than event-done, but its sources cover earlier
          // messages: story order must beat acceptance order.
          acceptedAt: 5,
          createdAt: 5,
        ),
      );
  await db
      .into(db.memoryEventRows)
      .insert(
        MemoryEventRowsCompanion.insert(
          id: 'event-done',
          sessionId: _sessionId,
          branchId: _sessionId,
          kind: 'result',
          description: 'The key was returned.',
          state: 'completed',
          acceptedAt: 2,
          createdAt: 2,
        ),
      );
  await db
      .into(db.memoryEventSourceRows)
      .insert(
        MemoryEventSourceRowsCompanion.insert(
          id: 'source-open',
          eventId: 'event-open',
          sessionId: _sessionId,
          branchId: _sessionId,
          memoryEntryId: 'mem-1',
          revisionId: 'mem-1:r1',
          fingerprint: 'fp-1',
          messageIdsJson: Value('["message-211","message-225"]'),
        ),
      );
  await db
      .into(db.memoryEventSourceRows)
      .insert(
        MemoryEventSourceRowsCompanion.insert(
          id: 'source-done',
          eventId: 'event-done',
          sessionId: _sessionId,
          branchId: _sessionId,
          memoryEntryId: 'mem-2',
          revisionId: 'mem-2:r1',
          fingerprint: 'fp-2',
          messageIdsJson: Value('["message-360"]'),
        ),
      );
  await db
      .into(db.memoryEventLinkRows)
      .insert(
        MemoryEventLinkRowsCompanion.insert(
          id: 'link-1',
          sessionId: _sessionId,
          branchId: _sessionId,
          fromEventId: 'event-open',
          toEventId: 'event-done',
          relation: 'fulfills',
          acceptedAt: 3,
        ),
      );
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      child: Builder(
        builder: (context) => MaterialApp(
          locale: context.locale,
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          theme: AppTheme.dark(
            const ThemePreset(id: 'default', name: 'Default'),
          ),
          home: Scaffold(body: child),
        ),
      ),
    ),
  );
  for (var i = 0; i < 32; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  // One testWidgets with re-pumps, mirroring the sibling harness: separate
  // testWidgets in one file never let the second EasyLocalization asset
  // load settle (the load future hangs on the retired test binding).
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('registry view lists accepted events and their links', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _seed(db);
    await _seedChat(db);

    await _pump(
      tester,
      MemoryEventRegistryView(
        sessionId: _sessionId,
        branchId: _sessionId,
        repo: MemoryEventRegistryRepo(db),
        messages: [
          ChatMessage(
            id: 'message-211',
            role: 'assistant',
            content: 'scene one',
            swipeId: 1,
            agentSwipeId: 2,
            time: '05.04.2026 · RP_Day 0 · 19:45',
          ),
          ChatMessage(
            id: 'message-225',
            role: 'assistant',
            content: 'scene one end',
            swipeId: 1,
            agentSwipeId: 2,
            time: '05.04.2026 · RP_Day 1 · 08:30',
          ),
          ChatMessage(
            id: 'message-360',
            role: 'assistant',
            content: 'scene later',
            swipeId: 1,
            agentSwipeId: 2,
            time: '18.05.2026 · RP_Day 12 · 21:00',
          ),
        ],
      ),
    );

    // Summary counts both kinds of registry rows.
    expect(find.text('2 events · 1 links'), findsOneWidget);

    // The seeded link joins both events into one story chain.
    expect(find.text('Chain 1 · 2 events'), findsOneWidget);

    // Event tiles show localized kind · state titles with a message-range +
    // description preview subtitle; ranges are 1-based positions in the
    // session's ordered messages (the ids carry no meaningful numbers).
    expect(find.text('Promise · Open'), findsOneWidget);
    expect(find.text('Result · Completed'), findsOneWidget);
    expect(
      find.textContaining('Messages 1–2 · Chisato returns'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Message 3 · The key was returned.'),
      findsOneWidget,
    );
    // Scene date = the FIRST ledger stamp among the event's source
    // messages ("when it was given"), so the later stamp on message-225
    // must not win — that is the §10.1 Chisato fence.
    expect(
      find.textContaining('scene 05.04.2026 · RP_Day 0 · 19:45'),
      findsOneWidget,
    );
    expect(
      find.textContaining('scene 05.04.2026 · RP_Day 1 · 08:30'),
      findsNothing,
    );
    expect(
      find.textContaining('scene 18.05.2026 · RP_Day 12 · 21:00'),
      findsOneWidget,
    );
    expect(
      find.text('Chisato returns to Sumida by 22:00.').hitTestable(),
      findsNothing,
    );

    // Story order beats acceptance order: event-open was accepted later but
    // covers earlier messages, so its tile sits above event-done.
    expect(
      tester.getTopLeft(find.text('Promise · Open')).dy,
      lessThan(tester.getTopLeft(find.text('Result · Completed')).dy),
    );

    await tester.tap(find.text('Promise · Open'));
    await tester.pumpAndSettle();
    expect(
      find.text('Chisato returns to Sumida by 22:00.').hitTestable(),
      findsOneWidget,
    );
    // The acceptance date moved into the expanded tile; the scene clock
    // stays in the subtitle.
    expect(
      find.textContaining('accepted 01.01.1970').hitTestable(),
      findsOneWidget,
    );

    // Link tile names the relation and both endpoints (80-char snippets).
    expect(find.text('Fulfils an earlier event'), findsOneWidget);
    expect(
      find.textContaining('Chisato returns to Sumida by 22:00. →'),
      findsOneWidget,
    );
  });
}
