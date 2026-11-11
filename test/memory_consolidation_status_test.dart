import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/features/chat/widgets/memory/memory_books_toolbar.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/memory_consolidation_status.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      child: ProviderScope(
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
    ),
  );
  for (var i = 0; i < 32; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

MemoryConsolidationQueueItem _item(
  String id,
  String status, {
  int index = 1,
  int sourceCount = 10,
  String? lastError,
  int attemptCount = 0,
}) => MemoryConsolidationQueueItem(
  jobId: id,
  status: status,
  index: index,
  sourceCount: sourceCount,
  lastError: lastError,
  attemptCount: attemptCount,
);

void main() {
  // One testWidgets with re-pumps, mirroring the file's original harness:
  // separate testWidgets in one file never let the second EasyLocalization
  // asset load settle (the load future hangs on the retired test binding),
  // so translated-text assertions only work inside a single test body.
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('durable queue exposes every package, cause and safe actions', (
    tester,
  ) async {
    // Empty queue renders nothing.
    await _pump(tester, const MemoryConsolidationStatus(items: []));
    expect(find.text('Memory event packages'), findsNothing);

    // Full queue: one row per package, localized state, machine cause,
    // attempt count after retries, completed summary, and per-row actions.
    String? reviewed;
    String? retried;
    String? diagnosed;
    String? cancelled;
    await _pump(
      tester,
      SingleChildScrollView(
        child: MemoryConsolidationStatus(
          items: [
            _item('job-review', 'review_pending', index: 1),
            _item(
              'job-failed',
              'failed',
              index: 2,
              lastError: 'package_generation_failed',
              attemptCount: 2,
            ),
            _item('job-running', 'running', index: 3),
            _item(
              'job-stale',
              'cancelled',
              index: 4,
              sourceCount: 3,
              lastError: 'source_context_changed',
            ),
          ],
          completedCount: 1,
          onReview: (id) => reviewed = id,
          onRetry: (id) => retried = id,
          onCopyDiagnostics: (id) => diagnosed = id,
          onCancel: (id) => cancelled = id,
        ),
      ),
    );

    expect(find.text('Memory event packages'), findsOneWidget);
    expect(find.textContaining('Package 1 · 10 memories'), findsOneWidget);
    expect(find.textContaining('Package 2 · 10 memories'), findsOneWidget);
    expect(find.textContaining('Package 3 · 10 memories'), findsOneWidget);
    expect(find.textContaining('Package 4 · 3 memories'), findsOneWidget);
    expect(find.text('1 completed'), findsOneWidget);
    // Localized durable causes, never raw machine strings.
    expect(find.textContaining('awaiting review'), findsOneWidget);
    expect(
      find.textContaining('failed · attempt 2 · model could not build'),
      findsOneWidget,
    );
    expect(
      find.textContaining('memory book changed during processing'),
      findsOneWidget,
    );
    // Repeated model failure surfaces the slot-switch hint.
    expect(
      find.textContaining('switch the consolidation API slot'),
      findsOneWidget,
    );

    // Per-row actions keyed by job id, one per state.
    expect(
      find.byKey(const ValueKey('package-review-job-review')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('package-retry-job-failed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('package-diagnostics-job-failed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('package-cancel-job-running')),
      findsOneWidget,
    );
    // Cancelled rows offer no action — a fresh scan re-covers them.
    expect(
      find.byKey(const ValueKey('package-cancel-job-stale')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('package-review-job-review')));
    expect(reviewed, 'job-review');
    await tester.tap(find.byKey(const ValueKey('package-retry-job-failed')));
    expect(retried, 'job-failed');
    await tester.tap(
      find.byKey(const ValueKey('package-diagnostics-job-failed')),
    );
    expect(diagnosed, 'job-failed');
    await tester.tap(find.byKey(const ValueKey('package-cancel-job-running')));
    expect(cancelled, 'job-running');

    // Initial scan stays in the actions menu, not the queue.
    var scans = 0;
    await _pump(
      tester,
      MemoryBooksActionsFab(
        onScanChat: () {},
        onAddEntry: () {},
        isReindexing: false,
        onReindex: () {},
        onDeleteIndexes: () {},
        onScanBook: () => scans++,
      ),
    );
    expect(find.text('Scan book for event links'), findsNothing);
    await tester.tap(find.byType(MemoryBooksActionsFab));
    await tester.pumpAndSettle();
    expect(find.text('Scan book for event links'), findsOneWidget);
    await tester.tap(find.text('Scan book for event links'));
    await tester.pumpAndSettle();
    expect(scans, 1);
  });
}
