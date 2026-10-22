import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/db/repositories/support_consent_selection_repo.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';

import 'support_native_fixture.dart';

/// Overrides BEFORE any workspace/settings/view evaluation. Real memory-only
/// AEAD/store/controller, fake vault, no default database or native startup.
List<Override> nativeWidgetOverrides(
  NativeFixture fixture, {
  SupportNativeConsentController? controller,
}) => [
  appDbProvider.overrideWithValue(fixture.database.db),
  supportRepoProvider.overrideWithValue(fixture.database.repoB),
  supportPayloadCipherProvider.overrideWithValue(fixture.database.cipher),
  credentialVaultProvider.overrideWith(
    (_) => throw StateError('Unexpected native vault startup'),
  ),
  secretRedactorProvider.overrideWith(() => _WidgetRedactor(fixture.redactor)),
  apiConfigRepoProvider.overrideWithValue(fixture.api),
  supportPermissionStoreProvider.overrideWithValue(fixture.database.a),
  supportNativeRuntimeProvider.overrideWithValue(fixture.runtime),
  supportNativeConsentControllerProvider.overrideWithValue(
    controller ?? fixture.controller,
  ),
  supportConsentSelectionRepoProvider.overrideWithValue(
    SupportConsentSelectionRepo(
      db: fixture.database.db,
      supportRepo: fixture.database.repoB,
      currentRedactor: () => fixture.redactor,
    ),
  ),
];

class _WidgetRedactor extends SecretRedactorNotifier {
  _WidgetRedactor(this.redactor);
  final SecretRedactor redactor;
  @override
  SecretRedactor build() => redactor;
}

/// The legacy real-notifier UI test already owns memory DB/cipher/vault. Reuse
/// those exact ports instead of allocating a second database during its pump.
List<Override> memoryNativeWidgetOverrides(AppDatabase db, SupportRepo repo) {
  final redactor = SecretRedactor();
  final permissions = SupportPermissionStore(repo);
  final selector = SupportConsentSelectionRepo(
    db: db,
    supportRepo: repo,
    currentRedactor: () => redactor,
  );
  final runtime = SupportNativeRuntime(
    permissions: permissions,
    resolveRecipient: (_) async => const SupportRecipientUnavailable(
      SupportRecipientUnavailableReason.selectionMissing,
    ),
    loadSelectedConnection: (_, _) async =>
        throw StateError('Denied selected loader'),
    configurationRevision: () => 1,
    configurationStable: () => true,
  );
  final controller = SupportNativeConsentController(
    runtime: runtime,
    readMessages: (source, id, offset) =>
        source == SupportConsentSelectionSource.support
        ? selector.listSupportMessages(sessionId: id, offset: offset)
        : selector.listRoleplayMessages(sessionId: id, offset: offset),
  );
  return [
    appDbProvider.overrideWithValue(db),
    supportRepoProvider.overrideWithValue(repo),
    supportPayloadCipherProvider.overrideWith(
      (_) => throw StateError('Unexpected cipher startup'),
    ),
    credentialVaultProvider.overrideWith(
      (_) => throw StateError('Unexpected native vault startup'),
    ),
    secretRedactorProvider.overrideWith(() => _WidgetRedactor(redactor)),
    supportPermissionStoreProvider.overrideWithValue(permissions),
    supportConsentSelectionRepoProvider.overrideWithValue(selector),
    supportNativeConsentControllerProvider.overrideWithValue(controller),
    supportNativeRuntimeProvider.overrideWith((ref) {
      ref.onDispose(runtime.dispose);
      return runtime;
    }),
  ];
}

/// Old presentation-only fixtures need no seeded session. Empty runtime is
/// explicitly unavailable; never fall back to production permissions/providers.
class NativeWidgetIsolation extends StatefulWidget {
  const NativeWidgetIsolation({
    super.key,
    required this.child,
    required this.overrides,
  });
  final Widget child;
  final List<Override> Function(NativeFixture fixture) overrides;
  @override
  State<NativeWidgetIsolation> createState() => _IsolationState();
}

class _IsolationState extends State<NativeWidgetIsolation> {
  final fixture = NativeFixture();
  @override
  void dispose() {
    unawaited(fixture.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      ...nativeWidgetOverrides(fixture),
      ...widget.overrides(fixture),
    ],
    child: localizedNativeScope(widget.child),
  );
}

class NativeWidgetAppSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

/// Reads only committed translation assets, not application initialization.
class NativeWidgetTranslations extends AssetLoader {
  const NativeWidgetTranslations();
  static final _translations = <String, Map<String, dynamic>>{};
  static Future<void> preload() async {
    for (final language in ['ru', 'en']) {
      _translations[language] =
          jsonDecode(
                await rootBundle.loadString(
                  'assets/translations/$language.json',
                ),
              )
              as Map<String, dynamic>;
    }
  }

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      _translations[locale.languageCode]!;
}

Future<void> initializeNativeWidgetLocalization() async {
  SharedPreferences.setMockInitialValues({});
  await EasyLocalization.ensureInitialized();
  await NativeWidgetTranslations.preload();
}

Widget localizedNativeScope(Widget child) => EasyLocalization(
  supportedLocales: const [Locale('ru'), Locale('en')],
  startLocale: const Locale('ru'),
  saveLocale: false,
  path: 'committed-translations',
  assetLoader: const NativeWidgetTranslations(),
  child: Builder(
    builder: (context) => Localizations(
      locale: context.locale,
      delegates: context.localizationDelegates,
      child: child,
    ),
  ),
);

Widget localizedNativeWidget(Widget child, {String language = 'ru'}) =>
    EasyLocalization(
      supportedLocales: const [Locale('ru'), Locale('en')],
      startLocale: Locale(language),
      saveLocale: false,
      path: 'committed-translations',
      assetLoader: const NativeWidgetTranslations(),
      child: Builder(
        builder: (context) => MaterialApp(
          locale: context.locale,
          supportedLocales: context.supportedLocales,
          localizationsDelegates: context.localizationDelegates,
          home: Material(child: child),
        ),
      ),
    );
