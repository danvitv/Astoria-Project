import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_font_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

/// Value-only actual-feed host. No App, default DB or startup fixture is used.
final class SupportMessageListPassivityFixture {
  SupportMessageListPassivityFixture({SecretRedactor? redactor})
    : redaction = SecretRedactionCoordinator(redactor: redactor);

  final SecretRedactionCoordinator redaction;
  final attempts = <String>[];
  final localAssetLoads = <String>[];
  final simulatedPlatformCalls = <String>[];
  late final container = ProviderContainer(
    observers: [_OnlyFeedVisualProviders(block)],
    overrides: [
      // Pure real owner only: bypass production capture/error sink leases.
      // Keep the actual reactive SecretRedactorNotifier, not an identity fake.
      secretRedactionCoordinatorProvider.overrideWithValue(redaction),
      appSettingsProvider.overrideWith(() => _FeedSettings(block)),
      themeProvider.overrideWith((_) => _FeedTheme(block)),
      sharedPreferencesProvider.overrideWith((_) => block('preferences')),
      effectiveBgImageBytesProvider.overrideWithValue(null),
      bgImageBytesProvider.overrideWith((_) => block('background bytes')),
      wallpaperBytesProvider.overrideWith((_) => block('wallpaper')),
      uiFontFamilyProvider.overrideWith((_) => block('font startup')),
      chatFontFamilyProvider.overrideWith((_) => block('chat font startup')),
    ],
  );

  Never block(String boundary) {
    attempts.add(boundary);
    throw StateError('Synthetic feed passivity boundary was crossed.');
  }

  Widget host(Widget child, {double scale = 1}) => UncontrolledProviderScope(
    container: container,
    child: DefaultAssetBundle(
      bundle: _TrustedWelcomeBundle(block, localAssetLoads),
      child: MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff506080)),
          useMaterial3: true,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Material(child: child),
      ),
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
      'flutter/assets',
      'plugins.flutter.io/url_launcher',
      'plugins.flutter.io/url_launcher_windows',
      'plugins.flutter.io/path_provider',
      'plugins.flutter.io/path_provider_windows',
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
          simulatedPlatformCalls.add(call.method);
          return <String, bool>{'value': false};
        case 'LiveText.isLiveTextInputAvailable':
          simulatedPlatformCalls.add(call.method);
          return false; // Availability only; no OCR/input starts.
        case 'HapticFeedback.vibrate':
        case 'SystemSound.play':
        case 'SystemChrome.setSystemUIOverlayStyle':
        case 'SystemChrome.setApplicationSwitcherDescription':
          simulatedPlatformCalls.add(call.method);
          return null; // Explicit framework feedback/chrome simulation only.
        default:
          return block('platform ${call.method}');
      }
    });
    try {
      await HttpOverrides.runZoned(() async {
        try {
          // Fake state is resolved before evaluating any production widget;
          // ThemeNotifier's storage-starting constructor is never invoked.
          await container.read(appSettingsProvider.future);
          expect(
            container.read(appSettingsProvider).requireValue.batterySaver,
            true,
          );
          final preset = container.read(themeProvider).activePreset;
          expect(preset.elementBlur, 0);
          expect(preset.noiseOpacity, 0);
          expect(
            identical(
              container.read(secretRedactorProvider),
              redaction.redactor,
            ),
            isTrue,
          );
          await body();
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          try {
            container.dispose();
          } finally {
            redaction.dispose();
          }
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
        reason: 'No swallowed startup, resource, plugin or action attempts',
      );
      expect(tester.takeException(), isNull);
    }
  }
}

class _FeedSettings extends AsyncNotifier<AppSettings>
    implements AppSettingsNotifier {
  _FeedSettings(this.block);
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

class _FeedTheme extends StateNotifier<ThemeSettings> implements ThemeNotifier {
  _FeedTheme(this.block)
    : super(
        const ThemeSettings(
          activePreset: ThemePreset(
            id: 'synthetic-feed-passivity',
            name: 'Synthetic flat feed',
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

final class _OnlyFeedVisualProviders extends ProviderObserver {
  _OnlyFeedVisualProviders(this.block);
  final Never Function(String) block;

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (![
      appSettingsProvider,
      themeProvider,
      effectiveBgImageBytesProvider,
      secretRedactionCoordinatorProvider,
      secretRedactorProvider,
    ].contains(context.provider)) {
      block('non-feed-visual provider');
    }
  }
}

/// Only the two hard-coded welcome avatars are allowed, never a prose resource.
final class _TrustedWelcomeBundle extends CachingAssetBundle {
  _TrustedWelcomeBundle(this.block, this.loads);
  final Never Function(String) block;
  final List<String> loads;

  @override
  Future<ByteData> load(String key) async {
    loads.add(key);
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage(<String, Object?>{})!;
    }
    if (key == 'assets/logos/astoria-sticker.png' ||
        key == 'assets/logos/astoria.png') {
      // Declared local 1x1 PNG surrogate; no real bundled/user file is opened.
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      );
      return ByteData.sublistView(Uint8List.fromList(bytes));
    }
    return block('undeclared local asset');
  }
}
