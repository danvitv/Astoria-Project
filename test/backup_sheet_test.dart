import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Override the existing plugin's platform store to test delayed preference I/O.
// Test-only use of its transitive interface avoids adding a runtime dependency.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:glaze_flutter/core/services/backup/backup_secrets.dart';
import 'package:glaze_flutter/core/services/backup_service.dart';
import 'package:glaze_flutter/features/backup/backup_provider.dart';
import 'package:glaze_flutter/features/backup/backup_screen.dart';
import 'package:glaze_flutter/shared/widgets/glaze_switch.dart';

import 'helpers/pump_localized.dart';

/// Without EasyLocalization `.tr()` returns the key, which is what these
/// assertions read: the question is *which* string the button asks for.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// The sheet reads the backup service only from its button callbacks, so a
  /// future that never completes is enough to hold the screen in "exporting"
  /// — `_performExport` flips the flag before it awaits.
  Future<void> pumpSheet(
    WidgetTester tester, {
    required bool fromOnboarding,
    Future<BackupService>? service,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backupServiceProvider.overrideWith(
            (ref) => service ?? Completer<BackupService>().future,
          ),
        ],
        child: MaterialApp(home: BackupScreen(fromOnboarding: fromOnboarding)),
      ),
    );
    await tester.pump();
  }

  group('#111 — a fresh install has nothing to export', () {
    testWidgets('the onboarding sheet offers import only', (tester) async {
      await pumpSheet(tester, fromOnboarding: true);
      expect(find.text('menu_import'), findsWidgets);
      // Both the section title and the button label ask for this key, so
      // zero of them is the whole section gone, hint and separator included.
      expect(find.text('menu_export'), findsNothing);
      expect(find.byType(GlazeSwitch), findsNothing);
    });

    testWidgets('the settings sheet still offers both', (tester) async {
      await pumpSheet(tester, fromOnboarding: false);
      expect(find.text('menu_import'), findsWidgets);
      expect(find.text('menu_export'), findsWidgets);
    });
  });

  group('#24 — the export button announced an import', () {
    testWidgets('exporting says it is preparing an export', (tester) async {
      await pumpSheet(tester, fromOnboarding: false);
      await tester.tap(find.text('menu_export').last);
      await tester.pump();

      expect(find.text('backup_progress_preparing_export'), findsOneWidget);
      expect(
        find.text('backup_progress_preparing'),
        findsNothing,
        reason: 'that string says "Preparing import..."',
      );
    });

    test('the two progress strings really do say different things', () {
      for (final locale in ['en', 'ru']) {
        final map =
            jsonDecode(
                  File('assets/translations/$locale.json').readAsStringSync(),
                )
                as Map<String, dynamic>;
        final import = map['backup_progress_preparing'] as String;
        final export = map['backup_progress_preparing_export'] as String;
        expect(export, isNotEmpty, reason: locale);
        expect(export, isNot(import), reason: locale);
      }
      // And the English pair says which is which, so the fix is not two
      // identical strings under two keys.
      final en =
          jsonDecode(File('assets/translations/en.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(en['backup_progress_preparing'], contains('import'));
      expect(en['backup_progress_preparing_export'], contains('export'));
    });
  });

  group('#684 — export credentials are an explicit, remembered choice', () {
    bool choice(WidgetTester tester) =>
        tester.widget<GlazeSwitch>(find.byType(GlazeSwitch)).value;

    testWidgets('defaults off and shows the restore explanation', (
      tester,
    ) async {
      final service = _RecordingBackupService();
      await pumpSheet(
        tester,
        fromOnboarding: false,
        service: Future.value(service),
      );
      expect(choice(tester), isFalse);
      expect(find.text('backup_include_api_keys'), findsOneWidget);
      expect(
        find.text('backup_include_api_keys_desc', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.text('menu_export').last);
      await tester.pump();
      expect(service.choices, [false]);
    });

    testWidgets('hydrates the remembered choice', (tester) async {
      SharedPreferences.setMockInitialValues({
        BackupSecrets.includeApiKeysPrefKey: true,
      });
      await pumpSheet(tester, fromOnboarding: false);
      expect(choice(tester), isTrue);
    });

    testWidgets('remembers the latest tap when reopened', (tester) async {
      await pumpSheet(tester, fromOnboarding: false);
      await tester.tap(find.byType(GlazeSwitch));
      await tester.pump();
      expect(choice(tester), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(BackupSecrets.includeApiKeysPrefKey), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpSheet(tester, fromOnboarding: false);
      expect(choice(tester), isTrue);
      await tester.tap(find.byType(GlazeSwitch));
      await tester.pump();
      expect(prefs.getBool(BackupSecrets.includeApiKeysPrefKey), isFalse);
    });

    testWidgets('late hydration cannot overwrite a user tap', (tester) async {
      final store = _DelayedPreferences();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = store;
      await pumpSheet(tester, fromOnboarding: false);
      await tester.tap(find.byType(GlazeSwitch));
      await tester.pump();
      store.load.complete({
        'flutter.${BackupSecrets.includeApiKeysPrefKey}': false,
      });
      await tester.pump();
      expect(choice(tester), isTrue);
      expect(
        store.values['flutter.${BackupSecrets.includeApiKeysPrefKey}'],
        true,
      );
    });

    testWidgets('an export snapshots choice and disables the switch', (
      tester,
    ) async {
      final serviceReady = Completer<BackupService>();
      final service = _RecordingBackupService();
      service.exportResult = Completer<String>();
      await pumpSheet(
        tester,
        fromOnboarding: false,
        service: serviceReady.future,
      );
      await tester.tap(find.byType(GlazeSwitch));
      await tester.pump();
      await tester.tap(find.text('menu_export').last);
      await tester.pump();
      expect(
        tester.widget<GlazeSwitch>(find.byType(GlazeSwitch)).onChanged,
        isNull,
      );
      await tester.tap(find.byType(GlazeSwitch));
      await tester.pump();
      expect(choice(tester), isTrue);
      serviceReady.complete(service);
      await tester.pump();
      expect(service.choices, [true]);
      service.exportResult!.complete('');
      await tester.pump();
      expect(
        tester.widget<GlazeSwitch>(find.byType(GlazeSwitch)).onChanged,
        isNotNull,
      );
    });

    testWidgets('export start blocks hydration even after export finishes', (
      tester,
    ) async {
      final store = _DelayedPreferences();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = store;
      final service = _RecordingBackupService();
      await pumpSheet(
        tester,
        fromOnboarding: false,
        service: Future.value(service),
      );
      await tester.tap(find.text('menu_export').last);
      await tester.pump();
      expect(service.choices, [false]);
      store.load.complete({
        'flutter.${BackupSecrets.includeApiKeysPrefKey}': true,
      });
      await tester.pump();
      expect(choice(tester), isFalse);
    });

    testWidgets('late preference hydration is safe after disposal', (
      tester,
    ) async {
      final store = _DelayedPreferences();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = store;
      await pumpSheet(tester, fromOnboarding: false);
      await tester.pumpWidget(const SizedBox.shrink());
      store.load.complete({
        'flutter.${BackupSecrets.includeApiKeysPrefKey}': true,
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('disposal before service hydration does not start export', (
      tester,
    ) async {
      final ready = Completer<BackupService>();
      final service = _RecordingBackupService();
      await pumpSheet(tester, fromOnboarding: false, service: ready.future);
      await tester.tap(find.text('menu_export').last);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      ready.complete(service);
      await tester.pump();
      expect(service.choices, isEmpty);
      expect(tester.takeException(), isNull);
    });

    test(
      'English and Russian copy names account/cloud tokens and retention',
      () {
        for (final locale in ['en', 'ru']) {
          final copy =
              jsonDecode(
                    File('assets/translations/$locale.json').readAsStringSync(),
                  )
                  as Map<String, dynamic>;
          final label = copy['backup_include_api_keys'] as String;
          final description = copy['backup_include_api_keys_desc'] as String;
          expect(label, contains('API'));
          expect(label, contains(locale == 'en' ? 'account' : 'аккаунт'));
          expect(label, contains(locale == 'en' ? 'cloud' : 'облака'));
          expect(
            description,
            contains(locale == 'en' ? 'this device' : 'этого устройства'),
          );
          expect(
            description,
            contains(
              locale == 'en'
                  ? 'matching connections'
                  : 'совпадающие подключения',
            ),
          );
          expect(
            description,
            contains(locale == 'en' ? 'keys again' : 'повторный ввод'),
          );
        }
      },
    );
  });

  for (final locale in ['en', 'ru']) {
    testWidgets('localized $locale export controls fit a narrow screen', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
        const BackupScreen(),
        locale: Locale(locale),
        surfaceSize: const Size(360, 800),
        overrides: [
          backupServiceProvider.overrideWith(
            (ref) => Completer<BackupService>().future,
          ),
        ],
      );
      // Give the real translation asset load time to finish after switching
      // locales; the shared helper's zero-duration pumps can beat filesystem IO.
      for (
        var attempt = 0;
        attempt < 8 && find.byType(GlazeSwitch).evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        });
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.byType(GlazeSwitch), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

class _RecordingBackupService implements BackupService {
  final List<bool> choices = [];
  Completer<String>? exportResult;

  @override
  Future<String> exportBackup({bool includeApiKeys = false}) {
    choices.add(includeApiKeys);
    return exportResult?.future ?? Future.value('');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedPreferences extends SharedPreferencesStorePlatform {
  final load = Completer<Map<String, Object>>();
  final values = <String, Object>{};

  @override
  Future<Map<String, Object>> getAll() => load.future;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    values.clear();
    return true;
  }
}
