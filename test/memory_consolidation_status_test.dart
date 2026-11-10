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

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('durable statuses and initial scan expose only valid actions', (
    tester,
  ) async {
    var action = '';
    var scans = 0;
    MemoryConsolidationStatus status(String value) => MemoryConsolidationStatus(
      status: value,
      onReview: () => action = 'review',
      onRetry: () => action = 'retry',
      onCancel: () => action = 'cancel',
    );

    await _pump(
      tester,
      Column(
        children: [
          status('pending'),
          MemoryBooksActionsFab(
            onScanChat: () {},
            onAddEntry: () {},
            isReindexing: false,
            onReindex: () {},
            onDeleteIndexes: () {},
            onScanBook: () => scans++,
          ),
        ],
      ),
    );
    expect(find.byKey(const ValueKey('package-cancel')), findsOneWidget);
    expect(find.byKey(const ValueKey('package-review')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('package-cancel')));
    expect(action, 'cancel');

    expect(find.text('Scan book for event links'), findsNothing);
    await tester.tap(find.byType(MemoryBooksActionsFab));
    await tester.pumpAndSettle();
    expect(find.text('Scan book for event links'), findsOneWidget);
    await tester.tap(find.text('Scan book for event links'));
    await tester.pumpAndSettle();
    expect(scans, 1);

    await _pump(tester, status('review_pending'));
    expect(find.byKey(const ValueKey('package-review')), findsOneWidget);
    expect(find.byKey(const ValueKey('package-cancel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('package-review')));
    expect(action, 'review');

    await _pump(tester, status('failed'));
    expect(find.byKey(const ValueKey('package-retry')), findsOneWidget);
    expect(find.byKey(const ValueKey('package-review')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('package-retry')));
    expect(action, 'retry');
  });
}
