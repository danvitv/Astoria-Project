import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/memory_mode.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/settings/memory_capture_tab.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/settings/memory_settings_draft.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';

Future<void> _pumpLocalized(WidgetTester tester, Widget child) async {
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
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
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

  testWidgets('consolidation threshold is shown only for Memory + links', (
    tester,
  ) async {
    final linksDraft = MemorySettingsDraft.from(
      const MemoryBookSettings(memoryMode: memoryLinksMode),
      vectorThreshold: 0.6,
    );
    addTearDown(linksDraft.dispose);
    await _pumpLocalized(
      tester,
      Builder(
        builder: (context) => SingleChildScrollView(
          child: Column(
            children: MemoryCaptureSections(
              draft: linksDraft,
              customPrompts: const [],
              onChanged: () {},
              onViewPrompt: () {},
              onManagePrompts: () {},
            ).build(context),
          ),
        ),
      ),
    );
    expect(
      find.byKey(const Key('memory_consolidation_threshold')),
      findsOneWidget,
    );

    final ordinaryDraft = MemorySettingsDraft.from(
      const MemoryBookSettings(memoryMode: 'balanced'),
      vectorThreshold: 0.6,
    );
    addTearDown(ordinaryDraft.dispose);
    await _pumpLocalized(
      tester,
      Builder(
        builder: (context) => SingleChildScrollView(
          child: Column(
            children: MemoryCaptureSections(
              draft: ordinaryDraft,
              customPrompts: const [],
              onChanged: () {},
              onViewPrompt: () {},
              onManagePrompts: () {},
            ).build(context),
          ),
        ),
      ),
    );
    expect(
      find.byKey(const Key('memory_consolidation_threshold')),
      findsNothing,
    );
  });
}
