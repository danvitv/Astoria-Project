import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/features/cloud_sync/widgets/sync_conflict_diagnostics_panel.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(batterySaver: true);
}

const _safeReport =
    'Conflict #1 (character)\nDiffering fields: description\n'
    'Conflict #2 (chat)\nDiffering fields: messages';
const _runKey = Key('sync-diagnostics-run');
const _copyKey = Key('sync-diagnostics-copy');

Future<void> _pumpPanel(
  WidgetTester tester, {
  required Future<String> Function() runner,
  VoidCallback? onBack,
  bool syncBusy = false,
  Size size = const Size(800, 900),
  Locale locale = const Locale('en'),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // All persisted settings are mocked; the real sync provider is never read.
  final prefs = await SharedPreferences.getInstance();
  await tester.runAsync(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(_Settings.new),
          themeProvider.overrideWith(
            (_) => ThemeNotifier(storage: ThemePresetStorage(prefs)),
          ),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('en'), Locale('ru')],
          path: 'assets/translations',
          startLocale: locale,
          fallbackLocale: const Locale('en'),
          child: Builder(
            builder: (context) => MaterialApp(
              theme: ThemeData.dark(),
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: SyncConflictDiagnosticsPanel(
                runner: runner,
                onBack: onBack ?? () {},
                syncBusy: syncBusy,
              ),
            ),
          ),
        ),
      ),
    );
    // Asset localization uses real asynchronous I/O, outside the fake clock.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  });
  await tester.pumpAndSettle();
}

Future<void> _press(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pump();
}

void main() {
  final clipboardWrites = <String>[];
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clipboardWrites.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardWrites.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('synchronous duplicate taps start one read and show busy', (
    tester,
  ) async {
    final pending = Completer<String>();
    var calls = 0;
    await _pumpPanel(
      tester,
      runner: () {
        calls++;
        return pending.future;
      },
    );
    final button = tester.widget<GlazeActionButton>(find.byKey(_runKey));
    button.onTap!();
    button.onTap!();
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<GlazeActionButton>(find.byKey(_runKey)).busy, isTrue);
    expect(find.byKey(const Key('sync-diagnostics-report')), findsNothing);
    expect(clipboardWrites, isEmpty);
    pending.complete(_safeReport);
    await tester.pumpAndSettle();
    expect(tester.widget<GlazeActionButton>(find.byKey(_runKey)).busy, isFalse);
    expect(find.text(_safeReport), findsOneWidget);
  });

  testWidgets('safe report is selectable and copied only by explicit press', (
    tester,
  ) async {
    await _pumpPanel(tester, runner: () async => _safeReport);
    expect(clipboardWrites, isEmpty);
    await _press(tester, _runKey);
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(clipboardWrites, isEmpty);
    await _press(tester, _copyKey);
    await tester.pumpAndSettle();
    expect(clipboardWrites, [_safeReport]);
    expect(find.text('Safe report copied.'), findsOneWidget);
  });

  testWidgets('runner error shows fixed label, never exception canary', (
    tester,
  ) async {
    const canary = 'PRIVATE_CARD_ID_HASH_VALUE_CANARY';
    await _pumpPanel(tester, runner: () async => throw StateError(canary));
    await _press(tester, _runKey);
    await tester.pumpAndSettle();
    expect(find.textContaining(canary), findsNothing);
    expect(
      find.text(
        'Could not complete diagnostics. No conflict changes were made.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(_copyKey), findsNothing);
    expect(clipboardWrites, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clipboard failure uses fixed label without raw details', (
    tester,
  ) async {
    await _pumpPanel(tester, runner: () async => _safeReport);
    await _press(tester, _runKey);
    await tester.pumpAndSettle();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'PRIVATE_CLIPBOARD_CANARY');
          }
          return null;
        });
    await _press(tester, _copyKey);
    await tester.pumpAndSettle();
    expect(find.text('Could not copy the report.'), findsOneWidget);
    expect(find.textContaining('PRIVATE_CLIPBOARD_CANARY'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late error after dispose is consumed without UI writes', (
    tester,
  ) async {
    final pending = Completer<String>();
    await _pumpPanel(tester, runner: () => pending.future);
    await _press(tester, _runKey);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(StateError('PRIVATE_DISPOSED_CANARY'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(clipboardWrites, isEmpty);
  });

  for (final fail in [false, true]) {
    testWidgets(
      'dismiss pending read discards late ${fail ? 'error' : 'result'}',
      (tester) async {
        final pending = Completer<String>();
        var backs = 0;
        await _pumpPanel(
          tester,
          runner: () => pending.future,
          onBack: () => backs++,
        );
        await _press(tester, _runKey);
        tester.widget<SheetView>(find.byType(SheetView)).onBack!();
        expect(backs, 1);
        // Even while the route is animating out, closed state rejects late work.
        if (fail) {
          pending.completeError(StateError('PRIVATE_LATE_ERROR'));
        } else {
          pending.complete(_safeReport);
        }
        await tester.pump();
        expect(find.text(_safeReport), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(clipboardWrites, isEmpty);
      },
    );
  }

  testWidgets('completion after dispose cannot publish into reopened panel', (
    tester,
  ) async {
    final pending = Completer<String>();
    await _pumpPanel(tester, runner: () => pending.future);
    await _press(tester, _runKey);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpPanel(tester, runner: () async => 'Conflict #1 (persona)');
    pending.complete(_safeReport);
    await tester.pumpAndSettle();
    expect(find.text(_safeReport), findsNothing);
    expect(find.byKey(_copyKey), findsNothing);
    expect(tester.takeException(), isNull);
    expect(clipboardWrites, isEmpty);
  });

  testWidgets('sync busy disables diagnostic runner', (tester) async {
    var calls = 0;
    await _pumpPanel(
      tester,
      syncBusy: true,
      runner: () async {
        calls++;
        return _safeReport;
      },
    );
    expect(tester.widget<GlazeActionButton>(find.byKey(_runKey)).onTap, isNull);
    await _press(tester, _runKey);
    expect(calls, 0);
    expect(
      find.text('Wait for the current sync operation to finish.'),
      findsOneWidget,
    );
  });

  for (final width in [360.0, 1200.0]) {
    testWidgets('localized report scrolls without overflow at width $width', (
      tester,
    ) async {
      final report = List.generate(
        80,
        (i) =>
            'Conflict #${i + 1} (character)\n'
            'Differing fields: description, firstMessage, alternateGreetings',
      ).join('\n');
      await _pumpPanel(
        tester,
        size: Size(width, 800),
        locale: const Locale('ru'),
        runner: () async => report,
      );
      expect(find.text('Диагностика конфликтов'), findsOneWidget);
      await _press(tester, _runKey);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(_copyKey),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(SheetView)).height.isFinite, isTrue);
      expect(tester.takeException(), isNull);
      expect(clipboardWrites, isEmpty);
    });
  }

  test('diagnostic translation keys exist in both locales', () {
    for (final language in ['en', 'ru']) {
      final translations =
          jsonDecode(
                File('assets/translations/$language.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      for (final key in [
        'title',
        'privacy',
        'run',
        'running',
        'copy',
        'copied',
        'error',
        'copy_error',
        'sync_busy',
      ]) {
        expect(translations['sync_diagnostics_$key'], isA<String>());
      }
    }
  });
}
