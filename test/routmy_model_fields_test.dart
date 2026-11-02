import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/image_routmy_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/image_openrouter_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/image_novelai_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/image_naistera_credential_owner.dart';
import 'package:glaze_flutter/core/preferences/saved_preferences_owner.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_connection_service.dart';
import 'package:glaze_flutter/features/image_gen/widgets/model_fields.dart';
import 'package:glaze_flutter/features/image_gen/widgets/openrouter_fields.dart';
import 'package:glaze_flutter/features/image_gen/widgets/image_openrouter_key_field.dart';
import 'package:glaze_flutter/features/image_gen/widgets/image_novelai_key_field.dart';
import 'package:glaze_flutter/features/image_gen/widgets/image_naistera_key_field.dart';
import 'package:glaze_flutter/features/image_gen/widgets/image_gen_sheet.dart';
import 'package:glaze_flutter/features/image_gen/widgets/rows.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';
import 'package:glaze_flutter/shared/widgets/glaze_bottom_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'credentials/fake_credential_storage.dart';

final class _ImageCatalogAdapter implements HttpClientAdapter {
  final entered = Completer<void>();
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (!entered.isCompleted) entered.complete();
    return ResponseBody.fromString(
      '{"models":[{"id":"futureImage",'
      '"name":"SYNTHETIC_UI_CATALOG_LABEL","references":false}]}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final imageType in [
    ImageGenApiType.routmy,
    ImageGenApiType.openrouter,
    ImageGenApiType.novelai,
    ImageGenApiType.naistera,
  ]) {
    for (final policyChange in ['coordinator B', 'bare replacement']) {
      testWidgets(
        '${imageType.name} actual open native picker observes $policyChange without local A registration',
        (tester) async {
          const alias = 'SYNTHETIC_OPEN_PICKER_ALIAS';
          const publicModel = 'openai/gpt-image-2';
          const lateModel = 'image/SYNTHETIC_OPEN_PICKER_ALIAS';
          SharedPreferences.setMockInitialValues({});
          final prefs = await TrackedSharedPreferences.getInstance();
          final original = SecretRedactionCoordinator();
          final previousSink = activeErrorRedactor;
          activeErrorRedactor = original.redactor;
          // B uses the real process-wide sink lease, but A remains the mounted local
          // coordinator and owner. Its secretRedactorProvider does not emit here.
          final currentContainer = ProviderContainer();
          final current = currentContainer.read(
            secretRedactionCoordinatorProvider,
          );
          final vault = CredentialVault(
            storage: FakeCredentialStorage(),
            buildChannel: 'dev',
          );
          final preferences = Completer<SharedPreferences>().future;
          final routmyOwner = ImageRoutmyCredentialOwner(
            vault: vault,
            redaction: original,
            originalPreferences: preferences,
          );
          final openRouterOwner = ImageOpenRouterCredentialOwner(
            vault: vault,
            redaction: original,
            originalPreferences: preferences,
          );
          final novelAiOwner = ImageNovelAiCredentialOwner(
            vault: vault,
            redaction: original,
            originalPreferences: preferences,
          );
          final naisteraOwner = ImageNaisteraCredentialOwner(
            vault: vault,
            redaction: original,
            originalPreferences: preferences,
          );
          final guard = imageType == ImageGenApiType.routmy
              ? routmyOwner.capturePublicTextGuard()
              : imageType == ImageGenApiType.openrouter
              ? openRouterOwner.capturePublicTextGuard()
              : imageType == ImageGenApiType.naistera
              ? naisteraOwner.capturePublicTextGuard()
              : novelAiOwner.capturePublicTextGuard();
          final container = ProviderContainer(
            overrides: [
              sharedPreferencesProvider.overrideWith((ref) async => prefs),
              secretRedactionCoordinatorProvider.overrideWithValue(original),
              imageRoutmyCredentialOwnerProvider.overrideWithValue(routmyOwner),
              imageOpenRouterCredentialOwnerProvider.overrideWithValue(
                openRouterOwner,
              ),
              imageNovelAiCredentialOwnerProvider.overrideWithValue(
                novelAiOwner,
              ),
              imageNaisteraCredentialOwnerProvider.overrideWithValue(
                naisteraOwner,
              ),
            ],
          );
          addTearDown(() {
            container.dispose();
            routmyOwner.dispose();
            openRouterOwner.dispose();
            novelAiOwner.dispose();
            naisteraOwner.dispose();
            currentContainer.dispose();
            original.dispose();
            activeErrorRedactor = previousSink;
          });
          String? selected;
          late BuildContext homeContext;
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                home: Scaffold(
                  body: Builder(
                    builder: (context) {
                      homeContext = context;
                      return TextButton(
                        onPressed: () => showImageGenOptions<String>(
                          context,
                          title: 'Image models',
                          items: const [publicModel, lateModel],
                          labelBuilder: (model) =>
                              guard(model) ? model : 'Model unavailable',
                          isSelected: (_) => false,
                          onSelected: (model) => selected = model,
                          isPublicText: guard,
                        ),
                        child: const Text('Open models'),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open models'));
          await tester.pumpAndSettle();
          expect(find.text(lateModel), findsOneWidget);
          BottomSheetCardItem nativeCard(String label) {
            final row = tester.widget(
              find.ancestor(
                of: find.text(label),
                matching: find.byWidgetPredicate(
                  (widget) => widget.runtimeType.toString() == '_CardRow',
                ),
              ),
            );
            // Retain the actual native selection, not GestureDetector's setState
            // wrapper: the private row itself is disposed by the policy repaint.
            return (row as dynamic).item as BottomSheetCardItem;
          }

          final retainedTap = nativeCard(lateModel).onTap;
          final retainedPublicTap = nativeCard(publicModel).onTap;
          final localBefore = container.read(secretRedactorProvider);
          if (policyChange == 'coordinator B') {
            current.registerSecret(alias);
          } else {
            activeErrorRedactor = SecretRedactor(knownSecrets: const [alias]);
          }
          expect(
            identical(container.read(secretRedactorProvider), localBefore),
            isTrue,
          );
          expect(
            identical(
              container.read(imageRoutmyCredentialOwnerProvider),
              routmyOwner,
            ),
            isTrue,
          );
          expect(
            identical(
              container.read(imageOpenRouterCredentialOwnerProvider),
              openRouterOwner,
            ),
            isTrue,
          );
          expect(
            identical(
              container.read(imageNovelAiCredentialOwnerProvider),
              novelAiOwner,
            ),
            isTrue,
          );
          // Invoke the old visible row before the next frame disposes it: selection
          // denial is synchronous, independently of the reactive repaint.
          retainedTap();
          expect(selected, isNull);
          await tester.pumpAndSettle();
          expect(find.text(lateModel), findsNothing);
          expect(
            tester
                .widgetList<Text>(find.byType(Text))
                .any((text) => (text.data ?? '').contains(alias)),
            isFalse,
          );
          expect(find.text(publicModel), findsOneWidget);
          retainedTap();
          expect(selected, isNull);
          // A retained callback must not pop a foreign route above this exact sheet.
          unawaited(
            Navigator.of(homeContext).push<void>(
              MaterialPageRoute(
                builder: (_) => const Scaffold(body: Text('Unrelated route')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          retainedPublicTap();
          await tester.pumpAndSettle();
          expect(find.text('Unrelated route'), findsOneWidget);
          expect(selected, isNull);
          Navigator.of(homeContext).pop();
          await tester.pumpAndSettle();
          await tester.tap(find.text(publicModel));
          await tester.pumpAndSettle();
          expect(selected, publicModel);
          expect(find.text('Image models'), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'unprotected image dropdown keeps its ordinary selection behavior',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await TrackedSharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWith((ref) async => prefs),
        ],
      );
      addTearDown(container.dispose);
      String? selected;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showImageGenOptions<String>(
                    context,
                    title: 'Quality',
                    items: const ['standard', 'high'],
                    labelBuilder: (value) => value,
                    isSelected: (value) => value == 'standard',
                    onSelected: (value) => selected = value,
                  ),
                  child: const Text('Open quality'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open quality'));
      await tester.pumpAndSettle();
      expect(find.text('standard'), findsOneWidget);
      await tester.tap(find.text('high'));
      await tester.pumpAndSettle();
      expect(selected, 'high');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'OpenRouter native model row rejects whole ORIGINAL and CURRENT aliases before update',
    () {
      const originalKey = 'SYNTHETIC_OR_MODEL_UI:KEY/+%?';
      const laterKey = 'SYNTHETIC_OR_MODEL_UI_LATE:KEY/+%?';
      final redaction = SecretRedactionCoordinator()
        ..registerSecret(originalKey);
      final current = SecretRedactionCoordinator();
      final owner = ImageOpenRouterCredentialOwner(
        vault: CredentialVault(
          storage: FakeCredentialStorage(),
          buildChannel: 'dev',
        ),
        redaction: redaction,
        originalPreferences: Completer<SharedPreferences>().future,
      );
      final previousSink = activeErrorRedactor;
      addTearDown(() {
        activeErrorRedactor = previousSink;
        owner.dispose();
        redaction.dispose();
        current.dispose();
      });
      ImageGenSettings? update;
      List<Widget> fields(String model) => buildOpenRouterModelFields(
        ImageGenSettings(openrouter: OpenRouterImageSettings(model: model)),
        isPublicText: owner.capturePublicTextGuard(),
        isFetching: false,
        onFetchModels: () {},
        onUpdate: (value) => update = value,
        showOptions:
            <T>({
              required title,
              required items,
              required labelBuilder,
              required isSelected,
              required onSelected,
            }) {},
      );
      final original =
          fields('image/${Uri.encodeComponent(originalKey)}').first
              as ImageGenTextFieldItem;
      expect(original.value, isEmpty);
      final row =
          fields('google/gemini-2.5-flash-image').first
              as ImageGenTextFieldItem;
      current.registerSecret(laterKey);
      activeErrorRedactor = current.redactor;
      row.onChanged('image/${Uri.encodeComponent(laterKey)}');
      expect(update, isNull);
      row.onChanged('public/image-model');
      expect(update!.openrouter.model, 'public/image-model');
      expect(update!.openrouter.apiKey, isEmpty);
    },
  );

  testWidgets(
    'native OpenRouter key draft is never prefilled/revealed and Set/Clear bypass ordinary DTO saves',
    (tester) async {
      const legacy = 'SYNTHETIC_OR_UI_LEGACY';
      const replacement = 'SYNTHETIC_OR_UI_REPLACEMENT';
      const endpoint = 'https://synthetic-or-ui.invalid/custom/v1';
      SharedPreferences.setMockInitialValues({
        'gz_imggen_settings': jsonEncode({
          'apiType': 'openrouter',
          'openrouter': {'endpoint': endpoint, 'apiKey': legacy},
        }),
      });
      final prefs = await TrackedSharedPreferences.getInstance();
      final storage = FakeCredentialStorage();
      final vault = CredentialVault(storage: storage, buildChannel: 'dev');
      final redaction = SecretRedactionCoordinator();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWith((ref) async => prefs),
          credentialVaultProvider.overrideWithValue(vault),
          secretRedactionCoordinatorProvider.overrideWithValue(redaction),
        ],
      );
      addTearDown(() {
        container.dispose();
        redaction.dispose();
      });
      final original = prefs.getString('gz_imggen_settings');
      final loaded = await container.read(imageGenSettingsProvider.future);
      expect(loaded.openrouter.apiKey, isEmpty);
      var admissions = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ImageOpenRouterKeyField(
                endpoint: endpoint,
                onAdmission: () => admissions++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      MenuFieldItem field() =>
          tester.widget<MenuFieldItem>(find.byType(MenuFieldItem));
      expect(field().controller.text, isEmpty);
      expect(field().obscure, isTrue);
      expect(find.byIcon(Icons.visibility_outlined), findsNothing);
      expect(find.text(legacy), findsNothing);
      await tester.enterText(find.byType(TextField), replacement);
      await tester.tap(find.byTooltip('Replace key'));
      await tester.pumpAndSettle();
      expect(field().controller.text, isEmpty);
      expect(admissions, 1);
      expect(
        container.read(imageOpenRouterAuthProvider).value!.verifiedCommit,
        isTrue,
      );
      expect(
        container.read(imageOpenRouterAuthProvider).value!.configured,
        isTrue,
      );
      expect(
        container.read(imageGenSettingsProvider).value!.openrouter.apiKey,
        isEmpty,
      );
      expect(
        (jsonDecode(
              storage.values.values.firstWhere((value) => value.isNotEmpty),
            )
            as Map)['key'],
        replacement,
      );
      await tester.tap(find.byTooltip('Clear protected key'));
      await tester.pumpAndSettle();
      expect(admissions, 2);
      expect(field().controller.text, isEmpty);
      expect(
        container.read(imageOpenRouterAuthProvider).value!.verifiedCommit,
        isTrue,
      );
      expect(
        container.read(imageOpenRouterAuthProvider).value!.configured,
        isFalse,
      );
      expect(prefs.getString('gz_imggen_settings'), original);
      expect(storage.values.values, contains(''));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'native Naistera blank key Set/Clear preserves raw key and unknown settings',
    (tester) async {
      const legacy = 'SYNTHETIC_NAISTERA_UI_LEGACY';
      const replacement = 'SYNTHETIC_NAISTERA_UI_REPLACEMENT';
      SharedPreferences.setMockInitialValues({
        'gz_imggen_settings': jsonEncode({
          'apiType': 'naistera',
          'naisteraApiKey': legacy,
          'futurePrivate': {'keep': true},
        }),
      });
      final prefs = await TrackedSharedPreferences.getInstance();
      final storage = FakeCredentialStorage();
      final redaction = SecretRedactionCoordinator();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWith((ref) async => prefs),
          credentialVaultProvider.overrideWithValue(
            CredentialVault(storage: storage, buildChannel: 'dev'),
          ),
          secretRedactionCoordinatorProvider.overrideWithValue(redaction),
        ],
      );
      addTearDown(() {
        container.dispose();
        redaction.dispose();
      });
      final original = prefs.getString('gz_imggen_settings');
      expect(
        (await container.read(imageGenSettingsProvider.future)).naisteraApiKey,
        isEmpty,
      );
      var admissions = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ImageNaisteraKeyField(onAdmission: () => admissions++),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      MenuFieldItem field() =>
          tester.widget<MenuFieldItem>(find.byType(MenuFieldItem));
      expect(field().controller.text, isEmpty);
      expect(field().obscure, isTrue);
      expect(find.byIcon(Icons.visibility_outlined), findsNothing);
      expect(find.text(legacy), findsNothing);
      await tester.enterText(find.byType(TextField), replacement);
      await tester.tap(find.byTooltip('Replace key'));
      await tester.pumpAndSettle();
      expect(admissions, 1);
      expect(field().controller.text, isEmpty);
      expect(
        container.read(imageNaisteraAuthProvider).value!.verifiedCommit,
        isTrue,
      );
      expect(
        container.read(imageGenSettingsProvider).value!.naisteraApiKey,
        isEmpty,
      );
      expect(
        (jsonDecode(storage.values.values.single) as Map)['key'],
        replacement,
      );
      await tester.tap(find.byTooltip('Clear protected key'));
      await tester.pumpAndSettle();
      expect(admissions, 2);
      expect(
        container.read(imageNaisteraAuthProvider).value!.configured,
        isFalse,
      );
      expect(
        container.read(imageNaisteraAuthProvider).value!.verifiedCommit,
        isTrue,
      );
      expect(storage.values.values.single, isEmpty);
      expect(prefs.getString('gz_imggen_settings'), original);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final replaceSink in [false, true])
    testWidgets(
      'Naistera actual sheet scalar gesture keeps denied model/catalog raw (CURRENT=$replaceSink)',
      (tester) async {
        const alias = 'SYNTHETIC_NAISTERA_PRIVATE_LABEL';
        final model = 'model/${Uri.encodeComponent(alias)}';
        SharedPreferences.setMockInitialValues({
          'gz_imggen_settings': jsonEncode({
            'enabled': true,
            'apiType': 'naistera',
            'naisteraApiKey': 'SYNTHETIC_NAISTERA_SCALAR_KEY',
            'naisteraModel': model,
            'naisteraModels': [
              {'id': model, 'name': alias, 'references': true},
            ],
            'futurePrivate': {'keep': true},
          }),
        });
        final prefs = await TrackedSharedPreferences.getInstance();
        final redaction = SecretRedactionCoordinator();
        final previous = activeErrorRedactor;
        activeErrorRedactor = redaction.redactor;
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWith((ref) async => prefs),
            credentialVaultProvider.overrideWithValue(
              CredentialVault(
                storage: FakeCredentialStorage(),
                buildChannel: 'dev',
              ),
            ),
            secretRedactionCoordinatorProvider.overrideWithValue(redaction),
          ],
        );
        addTearDown(() {
          container.dispose();
          redaction.dispose();
          activeErrorRedactor = previous;
        });
        // The original native preferences/vault producer must settle in its
        // real IO zone before the full settings sheet is mounted.
        await tester.runAsync(
          () => container.read(imageGenSettingsProvider.future),
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: ImageGenSheet())),
          ),
        );
        await tester.pumpAndSettle();
        if (replaceSink)
          activeErrorRedactor = SecretRedactor(knownSecrets: const [alias]);
        else
          redaction.registerSecret(alias);
        await tester.pumpAndSettle();
        expect(
          container.read(imageGenSettingsProvider).value!.naisteraModel,
          isEmpty,
        );
        expect(
          container.read(imageGenSettingsProvider).value!.naisteraModels,
          isEmpty,
        );
        expect(find.text(alias), findsNothing);
        expect(find.text(model), findsNothing);
        final enabledSwitch = find.descendant(
          of: find
              .ancestor(
                of: find.text('section_image_gen'),
                matching: find.byType(Row),
              )
              .first,
          matching: find.byType(Switch),
        );
        expect(enabledSwitch.hitTestable(), findsOneWidget);
        expect(tester.widget<Switch>(enabledSwitch).value, isTrue);
        await tester.runAsync(() => tester.tap(enabledSwitch));
        await tester.pumpAndSettle();
        final stored =
            jsonDecode(prefs.getString('gz_imggen_settings')!) as Map;
        expect(stored['enabled'], isFalse);
        expect(stored['naisteraModel'], model);
        expect(stored['naisteraModels'], [
          {'id': model, 'name': alias, 'references': true},
        ]);
        expect(stored['futurePrivate'], {'keep': true});
        expect(stored['naisteraApiKey'], 'SYNTHETIC_NAISTERA_SCALAR_KEY');
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

  test(
    'Naistera public HTTP catalog survives original queued settings CAS',
    () async {
      const key = 'gz_imggen_settings';
      const account = 'SYNTHETIC_NAISTERA_UI_CATALOG_ACCOUNT';
      const label = 'SYNTHETIC_UI_CATALOG_LABEL';
      SharedPreferences.setMockInitialValues({
        key: jsonEncode({
          'enabled': true,
          'apiType': 'naistera',
          'naisteraApiKey': account,
          'futurePrivate': {'keep': true},
        }),
      });
      final prefs = await TrackedSharedPreferences.getInstance();
      final redaction = SecretRedactionCoordinator();
      final previous = activeErrorRedactor;
      activeErrorRedactor = redaction.redactor;
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWith((ref) async => prefs),
          credentialVaultProvider.overrideWithValue(
            CredentialVault(
              storage: FakeCredentialStorage(),
              buildChannel: 'dev',
            ),
          ),
          secretRedactionCoordinatorProvider.overrideWithValue(redaction),
        ],
      );
      final adapter = _ImageCatalogAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
        container.dispose();
        redaction.dispose();
        dio.close();
        activeErrorRedactor = previous;
      });
      final loaded = await container.read(imageGenSettingsProvider.future);
      final owner = container.read(imageNaisteraCredentialOwnerProvider);
      final custody = owner.captureGuard();
      final lifetime = owner.captureAuthPublicationGuard();
      final catalog = await ImageGenConnectionService(
        dio: dio,
        naisteraCredentials: owner,
      ).fetchNaisteraModels(loaded);
      expect(custody(), isTrue);
      expect(
        adapter.requests.single.uri.toString(),
        'https://naistera.org/api/models',
      );
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer $account',
      );
      expect(adapter.requests.single.followRedirects, isFalse);
      final raw = prefs.getString(key);
      final occupied = SavedPreferencesWrites.serializeImageRoutmy(
        () => gate.future,
      );
      final pending = container
          .read(imageGenSettingsProvider.notifier)
          .save(
            loaded.copyWith(naisteraModels: catalog),
            ownsNaisteraCatalog: lifetime,
          );
      expect(SavedPreferencesOwner.process.pendingKeys, contains(key));
      expect(prefs.getString(key), raw);
      gate.complete();
      await occupied;
      await pending;
      final saved = jsonDecode(prefs.getString(key)!) as Map;
      expect(saved['naisteraModels'], [
        {'id': 'futureImage', 'name': label, 'references': false},
      ]);
      expect(saved['naisteraApiKey'], account);
      expect(saved['futurePrivate'], {'keep': true});
      expect(
        container
            .read(imageGenSettingsProvider)
            .value!
            .naisteraModels
            .single
            .name,
        label,
      );
      expect(lifetime(), isTrue);
      expect(custody(), isFalse); // Own write retires its pre-write read lease.
      expect(SavedPreferencesOwner.process.pendingKeys, isNot(contains(key)));
      expect(container.exists(appDbProvider), isFalse);
    },
  );

  for (final latePolicy in [false, true])
    testWidgets(
      'Naistera real HTTP catalog -> queued native settings -> original picker (late policy=$latePolicy)',
      (tester) async {
        const key = 'gz_imggen_settings';
        const account = 'SYNTHETIC_NAISTERA_UI_CATALOG_ACCOUNT';
        const label = 'SYNTHETIC_UI_CATALOG_LABEL';
        SharedPreferences.setMockInitialValues({
          key: jsonEncode({
            'enabled': true,
            'apiType': 'naistera',
            'naisteraApiKey': account,
            'futurePrivate': {'keep': true},
          }),
        });
        final prefs = await TrackedSharedPreferences.getInstance();
        final storage = FakeCredentialStorage();
        final redaction = SecretRedactionCoordinator();
        final previous = activeErrorRedactor;
        activeErrorRedactor = redaction.redactor;
        final container = ProviderContainer(
          overrides: [
            // The Naistera catalog never consumes a shared LLM configuration.
            // Keep this image-only fixture from bootstrapping the persona/API DB.
            activeApiConfigProvider.overrideWithValue(null),
            sharedPreferencesProvider.overrideWith((ref) async => prefs),
            credentialVaultProvider.overrideWithValue(
              CredentialVault(storage: storage, buildChannel: 'dev'),
            ),
            secretRedactionCoordinatorProvider.overrideWithValue(redaction),
          ],
        );
        final adapter = _ImageCatalogAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
          container.dispose();
          redaction.dispose();
          dio.close();
          activeErrorRedactor = previous;
        });
        await tester.runAsync(
          () => container.read(imageGenSettingsProvider.future),
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(body: ImageGenSheet(connectionDio: dio)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final raw = prefs.getString(key);
        late final Future<void> occupied;
        await tester.runAsync(() async {
          occupied = SavedPreferencesWrites.serializeImageRoutmy(
            () => gate.future,
          );
        });
        final refresh = find.byIcon(Icons.refresh).first;
        await Scrollable.ensureVisible(tester.element(refresh), alignment: 0.5);
        await tester.pumpAndSettle();
        expect(refresh.hitTestable(), findsOneWidget);
        await tester.runAsync(() => tester.tap(refresh));
        for (
          var i = 0;
          i < 20 && !SavedPreferencesOwner.process.pendingKeys.contains(key);
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
        expect(adapter.entered.isCompleted, isTrue);
        expect(SavedPreferencesOwner.process.pendingKeys, contains(key));
        expect(
          adapter.requests.single.uri.toString(),
          'https://naistera.org/api/models',
        );
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer $account',
        );
        expect(adapter.requests.single.followRedirects, isFalse);
        expect(prefs.getString(key), raw);
        if (latePolicy) redaction.registerSecret(label);
        await tester.runAsync(() async {
          // The pending-key assertion above witnesses the original catalog
          // write already queued behind our gate. Await that same FIFO, not
          // merely its predecessor: widget idle is not persistence settlement.
          final catalogSettled = SavedPreferencesWrites.serializeImageRoutmy(
            () async {},
          );
          gate.complete();
          await occupied;
          await catalogSettled;
        });
        await tester.pumpAndSettle();
        if (latePolicy) {
          expect(prefs.getString(key), raw);
          expect(
            container.read(imageGenSettingsProvider).value!.naisteraModels,
            isEmpty,
          );
          expect(find.text(label), findsNothing);
          expect(find.text('futureImage'), findsNothing);
        } else {
          final saved = jsonDecode(prefs.getString(key)!) as Map;
          expect(saved['naisteraModels'], [
            {'id': 'futureImage', 'name': label, 'references': false},
          ]);
          expect(saved['naisteraApiKey'], account);
          expect(saved['futurePrivate'], {'keep': true});
          expect(
            container
                .read(imageGenSettingsProvider)
                .value!
                .naisteraModels
                .single
                .name,
            label,
          );
          expect(find.text('futureImage'), findsOneWidget);
          expect(find.text('futureImage').hitTestable(), findsOneWidget);
          await tester.runAsync(() => tester.tap(find.text('futureImage')));
          await tester.pumpAndSettle();
          expect(
            container.read(imageGenSettingsProvider).value!.naisteraModel,
            'futureImage',
          );
          expect(
            (jsonDecode(prefs.getString(key)!) as Map)['naisteraModel'],
            'futureImage',
          );
          expect(find.text(label), findsOneWidget);
        }
        expect(container.exists(appDbProvider), isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

  testWidgets(
    'native NovelAI blank key Set/Clear never hydrates/reveals or saves a DTO',
    (tester) async {
      const legacy = 'SYNTHETIC_NAI_UI_LEGACY';
      const replacement = 'SYNTHETIC_NAI_UI_REPLACEMENT';
      const endpoint = 'https://synthetic-nai-ui.invalid/custom';
      SharedPreferences.setMockInitialValues({
        'gz_imggen_settings': jsonEncode({
          'apiType': 'novelai',
          'novelai': {'endpoint': endpoint, 'apiKey': legacy},
        }),
      });
      final prefs = await TrackedSharedPreferences.getInstance();
      final storage = FakeCredentialStorage();
      final redaction = SecretRedactionCoordinator();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWith((ref) async => prefs),
          credentialVaultProvider.overrideWithValue(
            CredentialVault(storage: storage, buildChannel: 'dev'),
          ),
          secretRedactionCoordinatorProvider.overrideWithValue(redaction),
        ],
      );
      addTearDown(() {
        container.dispose();
        redaction.dispose();
      });
      final original = prefs.getString('gz_imggen_settings');
      final loaded = await container.read(imageGenSettingsProvider.future);
      expect(loaded.novelai.apiKey, isEmpty);
      var admissions = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ImageNovelAiKeyField(
                endpoint: endpoint,
                model: loaded.novelai.model,
                onAdmission: () => admissions++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      MenuFieldItem field() =>
          tester.widget<MenuFieldItem>(find.byType(MenuFieldItem));
      expect(field().controller.text, isEmpty);
      expect(field().obscure, isTrue);
      expect(find.byIcon(Icons.visibility_outlined), findsNothing);
      expect(find.text(legacy), findsNothing);
      await tester.enterText(find.byType(TextField), replacement);
      await tester.tap(find.byTooltip('Replace key'));
      await tester.pumpAndSettle();
      expect(field().controller.text, isEmpty);
      expect(admissions, 1);
      expect(
        container.read(imageNovelAiAuthProvider).value!.verifiedCommit,
        isTrue,
      );
      expect(
        container.read(imageNovelAiAuthProvider).value!.configured,
        isTrue,
      );
      expect(
        container.read(imageGenSettingsProvider).value!.novelai.apiKey,
        isEmpty,
      );
      expect(
        (jsonDecode(storage.values.values.single) as Map)['key'],
        replacement,
      );
      await tester.tap(find.byTooltip('Clear protected key'));
      await tester.pumpAndSettle();
      expect(admissions, 2);
      expect(field().controller.text, isEmpty);
      expect(
        container.read(imageNovelAiAuthProvider).value!.configured,
        isFalse,
      );
      expect(
        container.read(imageNovelAiAuthProvider).value!.verifiedCommit,
        isTrue,
      );
      expect(storage.values.values.single, '');
      expect(prefs.getString('gz_imggen_settings'), original);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final replaceSink in [false, true]) {
    testWidgets(
      'NovelAI actual sheet Steps preserves denied model and untouched leaves (CURRENT=$replaceSink)',
      (tester) async {
        const model = 'nai-diffusion-4-full';
        const negative = 'SYNTHETIC_NAI_HIDDEN_NEGATIVE';
        const sampler = 'k_euler';
        const endpoint = 'https://synthetic-nai-sheet.invalid/custom';
        SharedPreferences.setMockInitialValues({
          'gz_imggen_settings': jsonEncode({
            'enabled': true,
            'apiType': 'novelai',
            'novelai': {
              'apiKey': 'SYNTHETIC_NAI_RETAINED_KEY',
              'endpoint': endpoint,
              'model': model,
              'negativePrompt': negative,
              'sampler': sampler,
              'steps': 28,
              'futurePrivateLeaf': {'keep': true},
            },
          }),
        });
        final prefs = await TrackedSharedPreferences.getInstance();
        final storage = FakeCredentialStorage();
        final redaction = SecretRedactionCoordinator();
        final current = SecretRedactionCoordinator();
        final previousSink = activeErrorRedactor;
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWith((ref) async => prefs),
            credentialVaultProvider.overrideWithValue(
              CredentialVault(storage: storage, buildChannel: 'dev'),
            ),
            secretRedactionCoordinatorProvider.overrideWithValue(redaction),
          ],
        );
        addTearDown(() {
          activeErrorRedactor = previousSink;
          container.dispose();
          redaction.dispose();
          current.dispose();
        });
        final loaded = await container.read(imageGenSettingsProvider.future);
        expect(loaded.novelai.model, model);
        expect(loaded.novelai.negativePrompt, negative);
        final original =
            jsonDecode(prefs.getString('gz_imggen_settings')!) as Map;
        final protected = Map<String, String>.from(storage.values);
        tester.view.physicalSize = const Size(1200, 2200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: ImageGenSheet())),
          ),
        );
        await tester.pumpAndSettle();
        final policy = replaceSink ? current : redaction;
        for (final alias in [model, negative, sampler])
          policy.registerSecret(alias);
        if (replaceSink) activeErrorRedactor = current.redactor;
        await tester.pumpAndSettle();
        final steps = find.descendant(
          of: find.byWidgetPredicate(
            (widget) =>
                widget is ImageGenTextFieldItem && widget.label == 'Steps',
          ),
          matching: find.byType(TextField),
        );
        expect(steps, findsOneWidget);
        await tester.enterText(steps, '31');
        await tester.pumpAndSettle();
        final saved = jsonDecode(prefs.getString('gz_imggen_settings')!) as Map;
        expect(saved['novelai'], {
          ...(original['novelai'] as Map),
          'steps': 31,
        });
        expect(storage.values, protected);
        expect(
          container.read(imageGenSettingsProvider).value!.novelai.model,
          isEmpty,
        );
        expect(
          container
              .read(imageGenSettingsProvider)
              .value!
              .novelai
              .negativePrompt,
          isEmpty,
        );
        for (final field in tester.widgetList<TextField>(
          find.byType(TextField),
        )) {
          final text = field.controller?.text ?? '';
          expect(text, isNot(contains(negative)));
          expect(text, isNot(contains(model)));
        }
        // An explicit public model choice remains a model edit, not a projection.
        final public = container.read(imageGenSettingsProvider).value!;
        await tester.runAsync(
          () => container
              .read(imageGenSettingsProvider.notifier)
              .save(
                public.copyWith(
                  novelai: public.novelai.copyWith(model: 'nai-diffusion-3'),
                ),
              ),
        );
        final afterChoice =
            jsonDecode(prefs.getString('gz_imggen_settings')!) as Map;
        expect(afterChoice['novelai'], {
          ...(original['novelai'] as Map),
          'steps': 31,
          'model': 'nai-diffusion-3',
        });
        expect(storage.values, protected);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test('Seedream hides the ignored quality selector', () {
    final seedream = buildRoutmyModelFields(
      const ImageGenSettings(routmyModel: 'bytedance/seedream-5.0-pro'),
      isPublicText: (_) => true,
      isFetching: false,
      onFetchModels: () {},
      onUpdate: (_) {},
      showOptions:
          <T>({
            required title,
            required items,
            required labelBuilder,
            required isSelected,
            required onSelected,
          }) {},
    );
    final generic = buildRoutmyModelFields(
      const ImageGenSettings(routmyModel: 'meta/muse-spark-1.1'),
      isPublicText: (_) => true,
      isFetching: false,
      onFetchModels: () {},
      onUpdate: (_) {},
      showOptions:
          <T>({
            required title,
            required items,
            required labelBuilder,
            required isSelected,
            required onSelected,
          }) {},
    );

    expect(seedream, hasLength(3));
    expect(generic, hasLength(4));
  });

  test(
    'original model rows and deferred picker labels/selections consult native public-text custody',
    () {
      const originalKey = 'SYNTHETIC_MODEL_UI:KEY/+%?';
      const laterKey = 'SYNTHETIC_MODEL_UI_LATE:KEY/+%?';
      final redaction = SecretRedactionCoordinator()
        ..registerSecret(originalKey);
      final owner = ImageRoutmyCredentialOwner(
        vault: CredentialVault(
          storage: FakeCredentialStorage(),
          buildChannel: 'dev',
        ),
        redaction: redaction,
        // Public-text validation neither resolves preferences nor opens the vault.
        originalPreferences: Completer<SharedPreferences>().future,
      );
      final previousSink = activeErrorRedactor;
      final current = SecretRedactionCoordinator();
      addTearDown(() {
        activeErrorRedactor = previousSink;
        owner.dispose();
        redaction.dispose();
        current.dispose();
      });
      final lateId = 'gpt-image-${Uri.encodeComponent(laterKey)}';
      List<String>? pickerItems;
      String Function(String)? pickerLabel;
      void Function(String)? pickerSelect;
      ImageGenSettings? update;
      final fields = buildRoutmyModelFields(
        ImageGenSettings(
          routmyModel: 'gpt-image-$originalKey',
          routmyModels: [
            RoutmyModelInfo(id: 'gpt-image-$originalKey'),
            RoutmyModelInfo(
              id: 'gpt-image-encoded-name',
              name: Uri.encodeComponent(originalKey),
            ),
            const RoutmyModelInfo(
              id: 'openai/gpt-image-2',
              name: 'GPT Image 2',
            ),
            RoutmyModelInfo(id: lateId),
          ],
        ),
        isPublicText: owner.capturePublicTextGuard(),
        isFetching: false,
        onFetchModels: () {},
        onUpdate: (value) => update = value,
        showOptions:
            <T>({
              required String title,
              required List<T> items,
              required String Function(T) labelBuilder,
              required bool Function(T) isSelected,
              required void Function(T) onSelected,
            }) {
              pickerItems = items.cast<String>();
              pickerLabel = (value) => labelBuilder(value as T);
              pickerSelect = (value) => onSelected(value as T);
            },
      );
      final row = fields.first as Row;
      final selector =
          (row.children.first as Expanded).child as MenuSelectorItem;
      expect(selector.currentValue, 'Model unavailable');
      selector.onTap();
      expect(pickerItems, ['openai/gpt-image-2', lateId]);
      expect(pickerLabel!('openai/gpt-image-2'), 'GPT Image 2');
      // The picker is already constructed; no recapture from a replacement JSON.
      current.registerSecret(laterKey);
      activeErrorRedactor = current.redactor;
      expect(pickerLabel!(lateId), 'Model unavailable');
      pickerSelect!(lateId);
      expect(update, isNull);
      pickerSelect!('openai/gpt-image-2');
      expect(update?.routmyModel, 'openai/gpt-image-2');
      expect(update?.routmyModels.map((model) => model.id), [
        'openai/gpt-image-2',
      ]);
    },
  );
}
