import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';
import 'package:glaze_flutter/features/catalog/catalog_models.dart';
import 'package:glaze_flutter/features/catalog/chub_account_provider.dart';
import 'package:glaze_flutter/features/catalog/services/catalog_http.dart';
import 'package:glaze_flutter/features/catalog/services/chub_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'credentials/fake_credential_storage.dart';

/// Answers every catalog request from [reply], and keeps what was asked.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.reply);

  final FutureOr<({int status, String body})> Function(RequestOptions options)
  reply;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final answer = await reply(options);
    return ResponseBody.fromString(
      answer.body,
      answer.status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String? _header(RequestOptions options, String name) =>
    options.headers[name]?.toString();

const _emptySearch = '{"nodes":[],"data":{"nodes":[],"count":0}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Chub tag account ownership', () {
    const tags = '{"nodes":[{"topics":["SYNTHETIC_TAG"]}]}';
    setUp(resetChubTagCache);
    tearDown(resetChubTagCache);

    test(
      'account guard, not just cache epoch, stops the next request/publication',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        final adapter = _ScriptedAdapter((_) async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
          return (status: 200, body: tags);
        });
        setCatalogHttpAdapter(adapter);
        var current = true;
        final fetching = fetchChubTags(
          apiKey: 'SYNTHETIC_OLD_AUTH',
          isCurrent: () => current,
        );
        await entered.future;
        current = false; // Deliberately do NOT change the cache epoch.
        release.complete();
        expect(await fetching, isEmpty);
        expect(adapter.requests, hasLength(1));
        expect(getCachedChubTags(), isEmpty);
        current = true;
        expect(await fetchChubTags(isCurrent: () => current), isNotEmpty);
        final count = adapter.requests.length;
        current = false;
        expect(await fetchChubTags(isCurrent: () => current), isEmpty);
        expect(adapter.requests, hasLength(count));
      },
    );

    for (final logout in [false, true]) {
      test(
        'native ${logout ? 'logout' : 'setter'} admission clears tags without an active catalog',
        () async {
          SharedPreferences.setMockInitialValues({});
          final storage = FakeCredentialStorage();
          final container = ProviderContainer(
            overrides: [credentialStorageProvider.overrideWithValue(storage)],
          );
          addTearDown(container.dispose);
          final account = container.read(chubAccountProvider.notifier);
          await account.setApiKey('SYNTHETIC_OLD_AUTH');
          final adapter = _ScriptedAdapter((_) => (status: 200, body: tags));
          setCatalogHttpAdapter(adapter);
          await account.withApiKeyGuarded(
            (key, current) => fetchChubTags(apiKey: key, isCurrent: current),
          );
          expect(getCachedChubTags(), isNotEmpty);
          final entered = Completer<void>(), release = Completer<void>();
          storage.beforeWrite = () async {
            entered.complete();
            await release.future;
          };
          final mutation = logout
              ? account.logout()
              : account.setApiKey('SYNTHETIC_NEW_AUTH');
          expect(
            getCachedChubTags(),
            isEmpty,
            reason: 'Admission invalidates before secure commit/metadata/UI',
          );
          await entered.future;
          release.complete();
          await mutation;
          expect(getCachedChubTags(), isEmpty);
        },
      );
    }

    test(
      'native logout fences a real guarded multi-request tag consumer',
      () async {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer(
          overrides: [
            credentialStorageProvider.overrideWithValue(
              FakeCredentialStorage(),
            ),
          ],
        );
        addTearDown(container.dispose);
        final account = container.read(chubAccountProvider.notifier);
        await account.setApiKey('SYNTHETIC_OLD_AUTH');
        final entered = Completer<void>(), release = Completer<void>();
        final adapter = _ScriptedAdapter((_) async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
          return (status: 200, body: tags);
        });
        setCatalogHttpAdapter(adapter);
        final fetching = account.withApiKeyGuarded(
          (key, current) => fetchChubTags(apiKey: key, isCurrent: current),
        );
        final refused = expectLater(
          fetching,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        await account.logout();
        release.complete();
        await refused;
        expect(adapter.requests, hasLength(1));
        expect(getCachedChubTags(), isEmpty);
      },
    );
  });

  group('catalog HTTP secret publication', () {
    test(
      'debug body/URL and thrown HTTP error use the publication-time redactor',
      () async {
        const secret = 'SYNTHETIC_HTTP_SECRET_CANARY';
        const lateSecret = 'SYNTHETIC_LATE_HTTP_VALUE';
        final coordinator = SecretRedactionCoordinator();
        final previousRedactor = activeErrorRedactor,
            previousPrint = debugPrint;
        final logs = <String>[];
        activeErrorRedactor = coordinator.redactor;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) logs.add(message);
        };
        addTearDown(() {
          activeErrorRedactor = previousRedactor;
          debugPrint = previousPrint;
          coordinator.dispose();
        });
        final entered = Completer<void>(), release = Completer<void>();
        final adapter = _ScriptedAdapter((_) async {
          entered.complete();
          await release.future;
          return (
            status: 401,
            body: '${List.filled(490, 'x').join()}$secret $lateSecret',
          );
        });
        setCatalogHttpAdapter(adapter);
        final request = catalogGet(
          'https://api.chub.ai/$secret?token=$secret',
          chubHeaders(apiKey: secret),
        );
        DioException? caught;
        final observed = request.then<void>(
          (_) => fail('Expected HTTP failure'),
          onError: (Object error) {
            expect(error, isA<DioException>());
            caught = error as DioException;
          },
        );
        await entered.future;
        coordinator.registerSecret(secret);
        coordinator.registerSecret(lateSecret);
        activeErrorRedactor = coordinator.redactor;
        release.complete();
        await observed;
        final error = caught!;
        expect(catalogErrorStatus(error), 401);
        expect(error.toString(), isNot(contains(secret)));
        expect(error.response?.data, isNot(contains(secret)));
        expect(error.response?.data, isNot(contains(lateSecret)));
        expect(error.response?.data, contains('[REDACTED]'));
        expect(error.requestOptions.uri.toString(), isNot(contains(secret)));
        expect(error.requestOptions.uri.hasQuery, false);
        expect(error.requestOptions.headers, isEmpty);
        expect(error.error, isNull);
        expect(logs.join(), isNot(contains('SYNTHETIC_HTTP')));
        expect(logs.join(), contains('HTTP 401'));
      },
    );

    for (final replaced in [false, true]) {
      test(
        'retired request redactor cannot expose original auth: $replaced',
        () async {
          const originalSecret = 'SYNTHETIC_RETIRED_HTTP_AUTH';
          const lateSecret = 'SYNTHETIC_REPLACEMENT_HTTP_VALUE';
          final original = SecretRedactionCoordinator();
          final replacement = SecretRedactionCoordinator();
          final previousRedactor = activeErrorRedactor,
              previousPrint = debugPrint;
          final logs = <String>[];
          debugPrint = (String? message, {int? wrapWidth}) {
            if (message != null) logs.add(message);
          };
          addTearDown(() {
            activeErrorRedactor = previousRedactor;
            debugPrint = previousPrint;
            original.dispose();
            replacement.dispose();
          });
          original.registerSecret(originalSecret);
          activeErrorRedactor = original.redactor;
          final entered = Completer<void>(), release = Completer<void>();
          setCatalogHttpAdapter(
            _ScriptedAdapter((_) async {
              entered.complete();
              await release.future;
              return (
                status: 401,
                body: '$originalSecret ${replaced ? lateSecret : ''}',
              );
            }),
          );
          final pending = catalogGet(
            'https://api.chub.ai/search',
            chubHeaders(apiKey: originalSecret),
          );
          DioException? caught;
          final joined = pending.then<void>(
            (_) => fail('Expected HTTP failure'),
            onError: (Object error) {
              caught = error as DioException;
            },
          );
          await entered.future;
          original.dispose();
          replacement.registerSecret(lateSecret);
          activeErrorRedactor = replaced ? replacement.redactor : null;
          release.complete();
          await joined;
          expect(catalogErrorStatus(caught!), 401);
          expect(caught!.response?.data, contains('[REDACTED]'));
          expect(
            '${caught!}${caught!.response?.data}${logs.join()}',
            isNot(contains(originalSecret)),
          );
          if (replaced) {
            expect(
              '${caught!}${caught!.response?.data}${logs.join()}',
              isNot(contains(lateSecret)),
            );
          }
          expect(caught!.requestOptions.headers, isEmpty);
        },
      );
    }

    test(
      'arbitrary transport exception causes cannot escape as raw errors',
      () async {
        const secret = 'SYNTHETIC_ADAPTER_ERROR_CANARY';
        setCatalogHttpAdapter(
          _ScriptedAdapter((_) => throw StateError(secret)),
        );
        await expectLater(
          catalogGet('https://api.chub.ai/search', chubHeaders(apiKey: secret)),
          throwsA(
            predicate(
              (Object error) =>
                  error is DioException &&
                  error.error == null &&
                  !error.toString().contains(secret) &&
                  error.requestOptions.headers.isEmpty,
            ),
          ),
        );
      },
    );
  });

  group('Chub requests carry the account key when one is set', () {
    test('search sends CH-API-KEY and samwise', () async {
      final adapter = _ScriptedAdapter(
        (_) => (status: 200, body: _emptySearch),
      );
      setCatalogHttpAdapter(adapter);

      await chubSearch(apiKey: 'secret-key');

      final request = adapter.requests.single;
      expect(_header(request, 'CH-API-KEY'), 'secret-key');
      expect(_header(request, 'samwise'), 'secret-key');
    });

    test('search stays anonymous without a key', () async {
      final adapter = _ScriptedAdapter(
        (_) => (status: 200, body: _emptySearch),
      );
      setCatalogHttpAdapter(adapter);

      await chubSearch();

      final request = adapter.requests.single;
      expect(request.headers.containsKey('CH-API-KEY'), isFalse);
      expect(request.headers.containsKey('samwise'), isFalse);
      expect(_header(request, 'Referer'), 'https://chub.ai/');
    });

    test('a blank key is treated as no key', () async {
      final adapter = _ScriptedAdapter(
        (_) => (status: 200, body: _emptySearch),
      );
      setCatalogHttpAdapter(adapter);

      await chubSearch(apiKey: '');

      expect(
        adapter.requests.single.headers.containsKey('CH-API-KEY'),
        isFalse,
      );
    });

    test('the character detail carries the key too', () async {
      final adapter = _ScriptedAdapter(
        (_) => (status: 200, body: '{"node":{"name":"x"}}'),
      );
      setCatalogHttpAdapter(adapter);

      await chubGetCharacter('creator/card', apiKey: 'secret-key');

      expect(_header(adapter.requests.single, 'CH-API-KEY'), 'secret-key');
    });
  });

  group('Chub search parameters', () {
    test('the Chub-only filters ride along as query parameters', () async {
      final adapter = _ScriptedAdapter(
        (_) => (status: 200, body: _emptySearch),
      );
      setCatalogHttpAdapter(adapter);

      await chubSearch(
        filters: const CatalogFilters(
          nsfw: true,
          nsfwOnly: true,
          requireImages: true,
          requireLore: true,
          requireCustomPrompt: true,
          requireExampleDialogues: true,
          requireAlternateGreetings: true,
          recommendedVerified: true,
          excludeMine: true,
          inclusiveOr: true,
          minAiRating: 4,
          minTags: 12,
        ),
      );

      final q = adapter.requests.single.uri.queryParameters;
      expect(q['nsfw_only'], 'true');
      expect(q['require_images'], 'true');
      expect(q['require_lore'], 'true');
      expect(q['require_custom_prompt'], 'true');
      expect(q['require_example_dialogues'], 'true');
      expect(q['require_alternate_greetings'], 'true');
      expect(q['recommended_verified'], 'true');
      expect(q['exclude_mine'], 'true');
      expect(q['inclusive_or'], 'true');
      expect(q['min_ai_rating'], '4');
      expect(q['min_tags'], '12');
    });

    test('off filters are left out of the query', () async {
      final adapter = _ScriptedAdapter(
        (_) => (status: 200, body: _emptySearch),
      );
      setCatalogHttpAdapter(adapter);

      await chubSearch();

      final q = adapter.requests.single.uri.queryParameters;
      expect(q.containsKey('require_images'), isFalse);
      expect(q.containsKey('min_ai_rating'), isFalse);
      expect(q.containsKey('min_tags'), isFalse);
    });

    test('the account NSFL opt-in forces the nsfl parameter on', () async {
      final adapter = _ScriptedAdapter(
        (_) => (status: 200, body: _emptySearch),
      );
      setCatalogHttpAdapter(adapter);

      await chubSearch(accountNsfl: true);

      expect(adapter.requests.single.uri.queryParameters['nsfl'], 'true');
    });

    test('total comes from the nested count', () async {
      final adapter = _ScriptedAdapter(
        (_) => (
          status: 200,
          body: '{"data":{"nodes":[],"count":12345,"cursor":"next"}}',
        ),
      );
      setCatalogHttpAdapter(adapter);

      final result = await chubSearch();

      expect(result.total, 12345);
      expect(result.hasMore, isTrue);
    });
  });

  group('Chub timeline feed', () {
    test('the timeline sort hits the timeline endpoint, not search', () async {
      final adapter = _ScriptedAdapter(
        (_) => (
          status: 200,
          body:
              '{"data":{"nodes":[{"name":"Card","fullPath":"a/card",'
              '"topics":["NSFW","Fantasy"],"tagline":"t","nTokens":100,'
              '"nChats":5}],"count":20}}',
        ),
      );
      setCatalogHttpAdapter(adapter);

      final result = await chubSearch(
        page: 3,
        filters: const CatalogFilters(sort: 'timeline'),
      );

      final request = adapter.requests.single;
      expect(request.uri.path, '/api/timeline/v1');
      expect(request.uri.queryParameters['page'], '3');
      expect(request.uri.queryParameters['count'], 'false');
      expect(result.characters.single.name, 'Card');
      expect(result.hasMore, isTrue);
    });

    test('the timeline carries the account key and the nsfw filter', () async {
      final adapter = _ScriptedAdapter(
        (_) => (status: 200, body: '{"data":{"nodes":[]}}'),
      );
      setCatalogHttpAdapter(adapter);

      await chubSearch(
        apiKey: 'secret-key',
        filters: const CatalogFilters(sort: 'timeline', nsfw: true),
      );

      final q = adapter.requests.single.uri.queryParameters;
      expect(q['nsfw'], 'true');
      expect(_header(adapter.requests.single, 'CH-API-KEY'), 'secret-key');
    });

    test('an empty timeline page ends the feed', () async {
      final adapter = _ScriptedAdapter(
        (_) => (status: 200, body: '{"data":{"nodes":[]}}'),
      );
      setCatalogHttpAdapter(adapter);

      final result = await chubSearch(
        filters: const CatalogFilters(sort: 'timeline'),
      );

      expect(result.characters, isEmpty);
      expect(result.hasMore, isFalse);
    });
  });

  group('Chub account storage', () {
    test('the key and display name persist, and logout clears them', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        ],
      );
      addTearDown(container.dispose);
      container.read(chubAccountProvider);
      // Let the async prefs load settle before mutating.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final notifier = container.read(chubAccountProvider.notifier);

      expect(container.read(chubAccountProvider).isLoggedIn, isFalse);

      await notifier.setApiKey('  abc  ', userName: 'neo');

      await notifier.withApiKey((key) async => expect(key, 'abc'));
      expect(container.read(chubAccountProvider).userName, 'neo');
      expect(container.read(chubAccountProvider).isLoggedIn, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gz_chub_api_key'), isNull);
      expect(prefs.getString('gz_chub_user_name'), 'neo');

      await notifier.logout();

      expect(container.read(chubAccountProvider).isLoggedIn, isFalse);
      expect(prefs.getString('gz_chub_api_key'), isNull);
      expect(prefs.getString('gz_chub_user_name'), isNull);
    });

    test('setUserName leaves the stored key alone', () async {
      SharedPreferences.setMockInitialValues({'gz_chub_api_key': 'abc'});
      final container = ProviderContainer(
        overrides: [
          credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        ],
      );
      addTearDown(container.dispose);
      container.read(chubAccountProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await container.read(chubAccountProvider.notifier).setUserName('trinity');

      await container
          .read(chubAccountProvider.notifier)
          .withApiKey((key) async => expect(key, 'abc'));
      expect(container.read(chubAccountProvider).userName, 'trinity');
    });

    test(
      'the NSFL opt-in persists, survives a key change, clears on logout',
      () async {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer(
          overrides: [
            credentialStorageProvider.overrideWithValue(
              FakeCredentialStorage(),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(chubAccountProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final notifier = container.read(chubAccountProvider.notifier);
        final prefs = await SharedPreferences.getInstance();

        await notifier.setApiKey('abc');
        await notifier.setNsfl(true);

        expect(container.read(chubAccountProvider).nsfl, isTrue);
        expect(prefs.getBool('gz_chub_nsfl'), isTrue);

        // Replacing the key must not drop the account-level preference.
        await notifier.setApiKey('def');
        expect(container.read(chubAccountProvider).nsfl, isTrue);

        await notifier.logout();
        expect(container.read(chubAccountProvider).nsfl, isFalse);
        expect(prefs.getBool('gz_chub_nsfl'), isNull);
      },
    );
  });
}
