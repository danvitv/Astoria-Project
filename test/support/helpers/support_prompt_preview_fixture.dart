import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/shared/shell/nav_height_provider.dart';
import 'package:glaze_flutter/shared/shell/shell_header_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_font_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';

/// Standalone value-only host. No App, default DB, native fixture or bootstrap.
/// The production theme constructor is deliberately never invoked.
final class SupportPromptPreviewFixture {
  final attempts = <String>[];
  final navigatorKey = GlobalKey<NavigatorState>();
  late final container = ProviderContainer(
    observers: [_OnlyVisualProviders(block)],
    overrides: [
      appSettingsProvider.overrideWith(() => _PreviewSettings(block)),
      themeProvider.overrideWith((_) => _PreviewTheme(block)),
      sharedPreferencesProvider.overrideWith((_) => block('preferences')),
      effectiveBgImageBytesProvider.overrideWithValue(null),
      bgImageBytesProvider.overrideWith((_) => block('background bytes')),
      wallpaperBytesProvider.overrideWith((_) => block('wallpaper')),
      uiFontFamilyProvider.overrideWith((_) => block('font startup')),
      chatFontFamilyProvider.overrideWith((_) => block('chat font startup')),
      navHeightProvider.overrideWith((_) => 0),
      shellHeaderProvider.overrideWith(ShellHeaderRegistry.new),
    ],
  );

  Never block(String boundary) {
    attempts.add(boundary);
    throw StateError('Synthetic prompt preview boundary was crossed.');
  }

  Widget host(Widget child, {double scale = 1}) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      navigatorKey: navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff506080)),
        useMaterial3: true,
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: FlatBackdrop(
          color: Theme.of(context).colorScheme.surface,
          child: child!,
        ),
      ),
      home: Material(child: child),
    ),
  );

  Future<void> run(WidgetTester tester, Future<void> Function() body) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const channels = [
      'com.pichillilorenzo/flutter_headless_inappwebview',
      'com.pichillilorenzo/flutter_inappwebview',
      'com.pichillilorenzo/flutter_inappwebview_cookiemanager',
      'com.pichillilorenzo/flutter_inappwebview_environment',
      'flutter/platform_views',
      'plugins.flutter.io/url_launcher',
      'plugins.flutter.io/path_provider',
      'plugins.it_nomads.com/flutter_secure_storage',
      'plugins.flutter.io/shared_preferences',
      'plugins.flutter.io/shared_preferences_async',
      'plugins.flutter.io/google_sign_in',
      'dev.flutter.pigeon.SharedPreferencesApi.getAll',
      'dev.flutter.pigeon.SharedPreferencesApi.setString',
    ];
    for (final channel in channels) {
      messenger.setMockMessageHandler(channel, (_) => block('native $channel'));
    }
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.hasStrings':
          return <String, bool>{'value': false};
        case 'HapticFeedback.vibrate':
          return null; // Simulated selection haptics, no native delegation.
        case 'SystemChrome.setSystemUIOverlayStyle':
          return null; // Simulated route chrome, no native delegation.
        case 'SystemChrome.setApplicationSwitcherDescription':
          return null; // Simulated title/color acknowledgment, no native work.
        case 'SystemSound.play':
          return null; // Simulated framework feedback, no sound is played.
        case 'LiveText.isLiveTextInputAvailable':
          return false; // Boolean availability only; OCR input is not started.
        default:
          return block('platform ${call.method}');
      }
    });
    try {
      await HttpOverrides.runZoned(() async {
        try {
          // Resolve the explicit fake before the first widget evaluation. No
          // loading-state fallback can accidentally activate visual/native work.
          await container.read(appSettingsProvider.future);
          expect(
            container.read(appSettingsProvider).requireValue.batterySaver,
            true,
          );
          await body();
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          container.dispose();
          await tester.pump();
        }
      }, createHttpClient: (_) => block('HttpClient creation'));
    } finally {
      for (final channel in channels) {
        messenger.setMockMessageHandler(channel, null);
      }
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      expect(
        attempts,
        isEmpty,
        reason: 'No swallowed startup/action/I/O attempts',
      );
      expect(tester.takeException(), isNull);
    }
  }
}

class _PreviewSettings extends AsyncNotifier<AppSettings>
    implements AppSettingsNotifier {
  _PreviewSettings(this.block);
  final Never Function(String) block;

  @override
  Future<AppSettings> build() async => const AppSettings(
    batterySaver: true,
    batterySaverMode: BatterySaverMode.on,
    hapticFeedback: false,
    messageVibration: false,
    allowMessageScripts: false,
    showOurPicks: false,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      block('settings command ${invocation.memberName}');
}

class _PreviewTheme extends StateNotifier<ThemeSettings>
    implements ThemeNotifier {
  _PreviewTheme(this.block)
    : super(
        const ThemeSettings(
          activePreset: ThemePreset(
            id: 'synthetic-prompt-preview',
            name: 'Synthetic flat preview',
            elementOpacity: 1,
            elementBlur: 0,
            noiseOpacity: 0,
            bgBlur: 0,
            bgDim: 0,
            bgNoiseOpacity: 0,
            uiFontMode: 'system',
            chatFontMode: 'system',
          ),
          presets: [],
          ignoreCustomFont: true,
        ),
      );
  final Never Function(String) block;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      block('theme command ${invocation.memberName}');
}

final class _OnlyVisualProviders extends ProviderObserver {
  _OnlyVisualProviders(this.block);
  final Never Function(String) block;

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (![
      appSettingsProvider,
      themeProvider,
      effectiveBgImageBytesProvider,
      navHeightProvider,
      shellHeaderProvider,
    ].contains(context.provider)) {
      block('non-visual provider');
    }
  }
}
