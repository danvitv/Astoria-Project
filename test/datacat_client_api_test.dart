import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_slot.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/datacat_account_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/datacat_account_legacy_source.dart';
import 'package:glaze_flutter/core/credentials/datacat_account_preferences.dart';
import 'package:glaze_flutter/core/credentials/datacat_installation_owner.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/preferences/saved_preferences_owner.dart';
import 'package:glaze_flutter/core/preferences/tracked_shared_preferences.dart';
import 'package:glaze_flutter/features/catalog/catalog_models.dart';
import 'package:glaze_flutter/features/catalog/services/catalog_http.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_cards.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_account.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_account_transport.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_client.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_discovery.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_errors.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_models.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_sort.dart';
import 'package:glaze_flutter/features/catalog/services/datacat/datacat_verification.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Synthetic plugin seam only; never touches native preferences.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'credentials/fake_credential_storage.dart';

final class _InstallationBacking extends SharedPreferencesStorePlatform {
  final values = <String, Object>{};
  final writes = <String>[];
  Future<void> Function()? beforeWrite;
  bool reject = false, throwWrite = false;
  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes.add(key);
    await beforeWrite?.call();
    values[key] = value; // False/throw deliberately does NOT prove rollback.
    if (throwWrite) throw StateError('SYNTHETIC_PRIVATE_INSTALLATION_FAILURE');
    return !reject;
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

/// Answers every catalog request from [reply] and keeps what was asked.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.reply);

  final FutureOr<({int status, String body})> Function(
    RequestOptions options,
    int index,
  )
  reply;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final pending = reply(options, requests.length);
    requests.add(options);
    final answer = await pending;
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

String _json(Object value) => jsonEncode(value);

/// A `/characters` page carrying one summary.
Map<String, Object?> _page({
  int total = 1,
  bool hasMore = false,
  int nextOffset = 1,
}) => {
  'characters': [
    {
      'id': 'char-1',
      'name': 'Yixuan',
      'chatName': 'Yi',
      'description': 'a body',
      'avatarUrl': 'https://cdn.example/a.png',
      'sourceKind': 'janitor',
      'nsfw': true,
      'totalTokens': 1200,
      'tags': [
        {'name': 'fantasy'},
        'noir',
      ],
      'creator': {
        'id': 'creator-id',
        'ref': 'saucepan:creator-uuid',
        'sourceKind': 'saucepan',
        'name': 'Someone',
      },
      'stats': {'chats': 7, 'messages': 42, 'messagesPerChat': 6.0},
    },
  ],
  'paging': {
    'limit': 24,
    'offset': 0,
    'total': total,
    'hasMore': hasMore,
    'nextOffset': nextOffset,
  },
};

/// `/capabilities` as the contract documents it.
const _capabilities =
    '{"success":true,"apiVersion":"v1",'
    '"features":{"listing":true,"tagBrowsing":true,"social":true},'
    '"paging":{"defaultPageSize":24,"maxPageSize":24},'
    '"securityCheck":{"enabled":true,"hosted":true}}';

/// `/capabilities` as the live deployment answers it: the documented fields
/// plus the advertised verification actions and lease lifetime.
const _liveCapabilities =
    '{"success":true,"apiVersion":"v1",'
    '"features":{"listing":true,"tagBrowsing":true,"social":true},'
    '"paging":{"defaultPageSize":24,"maxPageSize":24},'
    '"securityCheck":{"enabled":true,"hosted":true,'
    '"actions":["character-import"],"leaseTtlSeconds":1800,'
    '"maxUniqueCharacters":20}}';

String? _header(RequestOptions options, String name) =>
    options.headers[name]?.toString();

/// Serves capabilities, then whatever [reply] says for everything else.
_ScriptedAdapter _serve(
  ({int status, String body}) Function(RequestOptions options, int index) reply,
) {
  return _ScriptedAdapter((options, index) {
    if (options.uri.path.endsWith('/capabilities')) {
      return (status: 200, body: _capabilities);
    }
    return reply(options, index);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'gz_dc_device': 'install-1234567890',
    });
    setDatacatClientId('client-abc');
    resetDatacatCapabilities();
    resetDatacatTags();
    DatacatLeaseStore.instance.invalidate();
  });

  tearDown(() => setDatacatClientId(null));

  group('every scoped request identifies the integration', () {
    test('the client id rides along, the installation id does not', () async {
      final adapter = _serve(
        (options, index) => (status: 200, body: _json(_page())),
      );
      setCatalogHttpAdapter(adapter);

      await datacatFetchCharacters();

      final listing = adapter.requests.last;
      expect(_header(listing, 'X-Datacat-Client-Id'), 'client-abc');
      // Discovery is anonymous. Sending the installation id would hand DataCat
      // a stable identifier for browsing that browsing does not need.
      expect(_header(listing, 'X-Datacat-Installation-Id'), isNull);
      expect(_header(listing, 'Authorization'), isNull);
    });

    test('a build with no key says so instead of calling', () async {
      setDatacatClientId('');
      final adapter = _serve((options, index) => (status: 200, body: '{}'));
      setCatalogHttpAdapter(adapter);

      await expectLater(
        datacatFetchCharacters(),
        throwsA(
          isA<DatacatApiException>().having(
            (e) => e.code,
            'code',
            'client_id_missing',
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
    });
  });

  group('a listing asks for what the filters mean', () {
    test('browse and search are one endpoint', () async {
      final adapter = _serve(
        (options, index) => (status: 200, body: _json(_page())),
      );
      setCatalogHttpAdapter(adapter);

      await datacatFetchCharacters(query: 'wizard of the north');

      final uri = adapter.requests.last.uri;
      expect(uri.path, '/api/client/v1/characters');
      expect(uri.queryParameters['search'], 'wizard of the north');
      expect(uri.queryParameters['sort'], 'fresh');
    });

    test('NSFW off is the blocked adult tag, not a flag of our own', () async {
      final adapter = _serve(
        (options, index) => (status: 200, body: _json(_page())),
      );
      setCatalogHttpAdapter(adapter);

      await datacatFetchCharacters(filters: const CatalogFilters(nsfw: false));
      expect(adapter.requests.last.uri.queryParameters['blockedTagIds'], '2');

      await datacatFetchCharacters(filters: const CatalogFilters(nsfw: true));
      expect(
        adapter.requests.last.uri.queryParameters.containsKey('blockedTagIds'),
        isFalse,
      );
    });

    test('a windowed sort goes to the fresh feed and pages its window', () async {
      final adapter = _serve(
        (options, index) => (
          status: 200,
          body: _json({
            'success': true,
            'sortBy': 'score',
            'windows': {
              'thisWeek': _page(),
              'last24h': {
                'characters': <Object?>[],
                'paging': <String, Object?>{},
              },
            },
          }),
        ),
      );
      setCatalogHttpAdapter(adapter);

      final result = await datacatFetchCharacters(
        offset: 48,
        // NSFW on, so the windowed feed's own filtering keeps the fixture row:
        // what this test is about is where the request goes, not what is
        // dropped from it.
        filters: const CatalogFilters(
          sort: 'score',
          window: 'week',
          nsfw: true,
        ),
      );

      final uri = adapter.requests.last.uri;
      expect(uri.path, '/api/client/v1/fresh');
      expect(uri.queryParameters['sort'], 'score');
      // The caller's single cursor lands on the window that was asked for, and
      // the other window stays at its start.
      expect(uri.queryParameters['offsetWeek'], '48');
      expect(uri.queryParameters['offset24'], '0');
      expect(result.characters.single.name, 'Yixuan');
    });

    test('the fresh feed is asked for nothing it does not accept', () async {
      final adapter = _serve(
        (options, index) => (
          status: 200,
          body: _json({
            'windows': {'last24h': _page()},
          }),
        ),
      );
      setCatalogHttpAdapter(adapter);

      await datacatFetchCharacters(
        filters: const CatalogFilters(
          sort: 'fresh',
          window: '24h',
          nsfw: true,
          tagIds: [12, 44],
        ),
      );

      // This endpoint takes a sort and the two offsets and nothing else.
      // Sending tag parameters it does not document risks a 400 and filters
      // nothing even when it does not.
      final query = adapter.requests.last.uri.queryParameters;
      expect(
        query.keys,
        unorderedEquals(<String>['sort', 'limit', 'offset24', 'offsetWeek']),
      );
    });

    test('a window the server cannot filter is filtered here', () async {
      final adapter = _serve(
        (options, index) => (
          status: 200,
          body: _json({
            'windows': {
              'last24h': {
                'characters': [
                  {'id': 'a', 'name': 'Adult', 'nsfw': true},
                  {'id': 'b', 'name': 'Tame', 'nsfw': false},
                ],
                'paging': {'hasMore': true, 'nextOffset': 2},
              },
            },
          }),
        ),
      );
      setCatalogHttpAdapter(adapter);

      final result = await datacatFetchCharacters(
        filters: const CatalogFilters(
          sort: 'fresh',
          window: '24h',
          nsfw: false,
        ),
      );

      // The reader turned adult content off; a feed the server will not filter
      // must not smuggle it back in.
      expect(result.characters.map((c) => c.name), ['Tame']);
      // The cursor stays the server's, so the next page still starts where it
      // said rather than where the shortened list ends.
      expect(result.nextOffset, 2);
      expect(result.hasMore, isTrue);
    });

    test('paging follows the server cursor, not the page number', () async {
      final adapter = _serve(
        (options, index) => (
          status: 200,
          body: _json(_page(total: 99, hasMore: true, nextOffset: 37)),
        ),
      );
      setCatalogHttpAdapter(adapter);

      final result = await datacatFetchCharacters();

      expect(result.hasMore, isTrue);
      expect(result.nextOffset, 37);
    });
  });

  group('a summary becomes a catalog row', () {
    test(
      'the adult chip comes from the flag, and the creator keeps its ref',
      () async {
        final adapter = _serve(
          (options, index) => (status: 200, body: _json(_page())),
        );
        setCatalogHttpAdapter(adapter);

        final item = (await datacatFetchCharacters()).characters.single;

        expect(item.name, 'Yixuan');
        expect(item.tokens, 1200);
        expect(item.chatCount, 7);
        expect(item.messageCount, 42);
        expect(item.nsfw, isTrue);
        // Derived from `nsfw`, not prepended from a tag the row may not carry.
        expect(item.tags, containsAll(<String>['NSFW', 'fantasy', 'noir']));
        expect(item.tags, isNot(contains('SFW')));
        // The creator screen is opened by ref; the raw id would lose the
        // `saucepan:` prefix that says which library to look in.
        expect(item.creatorRef, 'saucepan:creator-uuid');
        expect(item.creatorId, 'creator-id');
        expect(item.sourceKind, 'janitor');
      },
    );
  });

  group('a sort a user saved before the migration still means something', () {
    test('the folded keys split back into a field and a window', () {
      const legacy = <String, (String, DatacatWindow)>{
        'recent': ('fresh', DatacatWindow.all),
        'score_week': ('score', DatacatWindow.thisWeek),
        'score_24h': ('score', DatacatWindow.last24h),
        'chat_count_week': ('chat_count', DatacatWindow.thisWeek),
        'chat_count_24h': ('chat_count', DatacatWindow.last24h),
      };
      legacy.forEach((key, expected) {
        final resolved = DatacatSort.resolve(CatalogFilters(sort: key));
        expect(resolved.field, expected.$1, reason: key);
        expect(resolved.window, expected.$2, reason: key);
      });
    });

    test('migrating rewrites the stored filters once', () {
      final migrated = DatacatSort.migrate(
        const CatalogFilters(sort: 'chat_count_24h'),
      );
      expect(migrated.sort, 'chat_count');
      expect(migrated.window, '24h');
      // Already-migrated filters are left alone.
      expect(DatacatSort.migrate(migrated).sort, 'chat_count');
    });

    test('an unknown sort falls back rather than being sent through', () {
      expect(
        DatacatSort.resolve(const CatalogFilters(sort: 'nonsense')).field,
        'fresh',
      );
    });

    test(
      'a current field keeps its window even when a legacy key shares its name',
      () {
        // `fresh` is both today's sort field and yesterday's windowless label.
        // Read as the label it would pin the feed to all-time and throw away the
        // window the user chose.
        final resolved = DatacatSort.resolve(
          const CatalogFilters(sort: 'fresh', window: '24h'),
        );
        expect(resolved.field, 'fresh');
        expect(resolved.window, DatacatWindow.last24h);
        expect(
          DatacatSort.migrate(
            const CatalogFilters(sort: 'fresh', window: '24h'),
          ).window,
          '24h',
        );
      },
    );
  });

  group('a protected transfer spends a lease', () {
    test('the lease header is what the card request carries', () async {
      final adapter = _serve(
        (options, index) => (
          status: 200,
          body: _json({
            'data': {
              'name': 'Yixuan',
              'description': 'a body',
              'first_mes': 'hi',
            },
          }),
        ),
      );
      setCatalogHttpAdapter(adapter);

      final card = await datacatFetchCard(
        'char-1',
        withAvatar: false,
        obtainLease: () async => 'lease-1',
      );

      expect(card.charData.name, 'Yixuan');
      final transfer = adapter.requests.last;
      expect(_header(transfer, 'X-Datacat-Verification-Lease'), 'lease-1');
      // The installation id rides along, undocumented but mandatory: a
      // transfer carrying the lease alone is refused exactly like one carrying
      // no lease at all, so dropping this header silently breaks every import.
      expect(
        _header(transfer, 'X-Datacat-Installation-Id'),
        'install-1234567890',
      );
    });

    test(
      'one lease covers the next character without verifying again',
      () async {
        var challenges = 0;
        final adapter = _serve(
          (options, index) => (
            status: 200,
            body: _json({
              'data': {'name': 'Yixuan'},
            }),
          ),
        );
        setCatalogHttpAdapter(adapter);

        Future<String?> obtain() async {
          challenges++;
          DatacatLeaseStore.instance.store(
            'lease-1',
            DateTime.now().add(const Duration(minutes: 5)),
          );
          return 'lease-1';
        }

        await datacatFetchCard(
          'char-1',
          withAvatar: false,
          obtainLease: obtain,
        );
        await datacatFetchCard(
          'char-2',
          withAvatar: false,
          obtainLease: obtain,
        );

        expect(challenges, 1);
      },
    );

    test('the budget is counted in characters, and runs out', () {
      final store = DatacatLeaseStore.instance;
      store.store('lease-1', DateTime.now().add(const Duration(minutes: 5)));

      for (var i = 0; i < datacatLeaseCharacterBudget; i++) {
        expect(store.leaseFor('char-$i'), 'lease-1');
        store.noteUsed('char-$i');
      }

      // A character already transferred under this lease costs nothing more.
      expect(store.leaseFor('char-0'), 'lease-1');
      // A new one does, and there is nothing left.
      expect(store.leaseFor('char-new'), isNull);
    });

    test('an expired lease is not offered', () {
      final store = DatacatLeaseStore.instance;
      store.store('lease-1', DateTime.now().add(const Duration(seconds: 1)));
      expect(store.leaseFor('char-1'), isNull);
    });

    test('the server decides how many characters a lease covers', () {
      final store = DatacatLeaseStore.instance;
      store.store(
        'lease-1',
        DateTime.now().add(const Duration(minutes: 5)),
        maxUniqueCharacters: 2,
      );

      store.noteUsed('char-1');
      store.noteUsed('char-2');
      expect(store.leaseFor('char-3'), isNull);
      expect(store.remainingBudget, 0);
    });

    test('a refusal to verify is reported as needing verification', () async {
      final adapter = _serve((options, index) => (status: 200, body: '{}'));
      setCatalogHttpAdapter(adapter);

      await expectLater(
        datacatFetchCard(
          'char-1',
          withAvatar: false,
          obtainLease: () async => null,
        ),
        throwsA(
          isA<DatacatApiException>().having(
            (e) => e.verificationRequired,
            'verificationRequired',
            isTrue,
          ),
        ),
      );
    });
  });

  group('a Character Card V2 body reads as a card', () {
    test('the envelope is unwrapped and the greetings fold together', () {
      final card = datacatCardToCharacterData({
        'spec': 'chara_card_v2',
        'data': {
          'name': 'Yixuan',
          'description': 'the definition',
          'personality': 'warm',
          'scenario': 'a tavern',
          'first_mes': 'hello',
          'alternate_greetings': ['second', 'third'],
          'creator_notes': 'the blurb',
          'tags': ['noir'],
          'creator': 'Someone',
        },
      });

      expect(card.name, 'Yixuan');
      // No source-dependent guessing left: the definition is the definition
      // and the blurb stays out of it.
      expect(card.description, 'the definition');
      expect(card.creatorNotes, 'the blurb');
      expect(card.firstMes, 'hello');
      expect(card.alternateGreetings, ['second', 'third']);
      expect(card.tags, ['noir']);
    });

    test('a body wrapped under `card` reads the same', () {
      final card = datacatCardToCharacterData({
        'card': {
          'data': {'name': 'Yixuan', 'first_mes': 'hi'},
        },
      });
      expect(card.name, 'Yixuan');
      expect(card.firstMes, 'hi');
    });
  });

  group('a failure says what it was', () {
    test('a structured error keeps its code and message', () async {
      final adapter = _serve(
        (options, index) => (
          status: 403,
          body: _json({
            'success': false,
            // The machine code travels in `error`; `message` is the sentence.
            'error': 'verification_required',
            'message': 'Human verification required',
            'accountState': 'unlinked',
            'verificationRequired': true,
            'verification': {'action': 'character_transfer'},
          }),
        ),
      );
      setCatalogHttpAdapter(adapter);

      await expectLater(
        datacatFetchCharacters(),
        throwsA(
          isA<DatacatApiException>()
              .having((e) => e.status, 'status', 403)
              .having((e) => e.code, 'code', 'verification_required')
              .having(
                (e) => e.message,
                'message',
                'Human verification required',
              )
              .having(
                (e) => e.verificationAction,
                'action',
                'character_transfer',
              )
              .having((e) => e.accountState, 'accountState', 'unlinked'),
        ),
      );
    });

    test(
      'a body that is not the documented shape still reports its status',
      () async {
        final adapter = _serve(
          (options, index) => (status: 502, body: '<html>bad gateway</html>'),
        );
        setCatalogHttpAdapter(adapter);

        await expectLater(
          datacatFetchCharacters(),
          throwsA(
            isA<DatacatApiException>().having((e) => e.status, 'status', 502),
          ),
        );
      },
    );
  });

  group('linked-account credential custody (synthetic plugin/HTTP only)', () {
    const legacy = '  SYNTHETIC_DATACAT_ACCOUNT_LEGACY  ';
    const native = 'SYNTHETIC_DATACAT_ACCOUNT_NATIVE';
    const returned = 'SYNTHETIC_DATACAT_ACCOUNT_RETURNED';
    const device = 'install-1234567890';
    const initial = <String, Object>{
      'gz_dc_user_token': legacy,
      'gz_dc_device': device,
      'gz_dc_user_name': 'SYNTHETIC_NAME',
      'gz_dc_scopes': ['community:write'],
      'gz_dc_token': 'SYNTHETIC_ANONYMOUS_UNTOUCHED',
      'SYNTHETIC_UNKNOWN_SIBLING': 'PRESERVED',
    };
    final slot = CredentialSlot(domain: 'catalog.datacat', id: 'account');
    late TrackedSharedPreferences prefs;
    late FakeCredentialStorage storage;
    late CredentialVault vault;
    late SecretRedactionCoordinator redaction;
    late DatacatAccountCredentialOwner credentials;

    DatacatAccountCredentialOwner owner(Future<SharedPreferences> original) =>
        DatacatAccountCredentialOwner(
          vault: vault,
          redaction: redaction,
          originalPreferences: original,
        );
    Map<String, Object?> snapshot() => {
      for (final key in prefs.getKeys()) key: prefs.get(key),
    };
    Map<String, dynamic> protected() =>
        jsonDecode(storage.values.values.single) as Map<String, dynamic>;
    DatacatAccountService service(_ScriptedAdapter adapter) {
      final account = DatacatAccountService(
        credentials: credentials,
        transport: DatacatAccountTransport(
          redaction: redaction,
          dio: Dio()..httpClientAdapter = adapter,
        ),
      );
      addTearDown(account.dispose);
      return account;
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues(initial);
      prefs =
          await TrackedSharedPreferences.getInstance()
              as TrackedSharedPreferences;
      storage = FakeCredentialStorage();
      vault = CredentialVault(storage: storage, buildChannel: 'dev');
      redaction = SecretRedactionCoordinator();
      credentials = owner(Future.value(prefs));
      addTearDown(credentials.dispose);
      addTearDown(redaction.dispose);
    });

    test(
      'private registration and original exact pair survive migration without prefs writes',
      () async {
        expect(
          DatacatAccountPreferences.keys.every(
            PrivatePreferenceKeys.tracked.contains,
          ),
          true,
        );
        expect(SavedPreferencesKeys.families.length, 5);
        expect(
          SavedPreferencesKeys.all.intersection(DatacatAccountPreferences.keys),
          isEmpty,
        );
        final before = snapshot();
        final account = await credentials.load();
        expect(account.authenticated, true);
        expect(account.displayName, 'SYNTHETIC_NAME');
        expect(account.scopes, ['community:write']);
        expect(account.toString(), isNot(contains(legacy)));
        expect(protected()['token'], legacy);
        expect(protected()['device'], device);
        expect(snapshot(), before);
        expect(redaction.redactor.redactText(legacy), '[REDACTED]');
        await credentials.withAccount((token, binding, summary, current) async {
          expect(token, legacy);
          expect(binding, device);
          expect(current(), true);
        });
      },
    );

    test(
      'first explicit link births one acknowledged installation through native account transport',
      () async {
        SharedPreferences.setMockInitialValues({});
        prefs =
            await TrackedSharedPreferences.getInstance()
                as TrackedSharedPreferences;
        credentials = owner(Future.value(prefs));
        addTearDown(credentials.dispose);
        String? born;
        final adapter = _ScriptedAdapter((options, index) {
          final body = jsonDecode(options.data as String) as Map;
          final installation = body['installationId'] as String;
          expect(installation, matches(r'^[a-f0-9-]{36}$'));
          expect(
            prefs.getString(DatacatAccountPreferences.device),
            installation,
          );
          expect(_header(options, 'Authorization'), isNull);
          if (index == 0) {
            born = installation;
            return (
              status: 201,
              body: _json({
                'linkId': 'SYNTHETIC_LINK',
                'deviceCode': 'SYNTHETIC_DEVICE_CODE',
                'authorizationUriComplete':
                    'https://datacat.run/link?code=SYNTHETIC_CODE',
                'interval': 1,
              }),
            );
          }
          expect(installation, born);
          return (status: 200, body: _json({'accessToken': returned}));
        });
        final account = service(adapter);
        expect(adapter.requests, isEmpty);
        expect(storage.operations, isEmpty);
        expect(prefs.getKeys(), isEmpty);
        expect((await account.link()).authenticated, true);
        expect(protected()['device'], born);
        expect(protected()['token'], returned);
        expect(prefs.getKeys(), {DatacatAccountPreferences.device});
        expect(adapter.requests, hasLength(2));
        expect((await account.load()).authenticated, true);
        expect(prefs.getString(DatacatAccountPreferences.device), born);
      },
    );

    test(
      'same-vault captured account tombstone during second absence read fences first link',
      () async {
        SharedPreferences.setMockInitialValues({});
        final previous = SharedPreferencesStorePlatform.instance;
        final backing = _InstallationBacking();
        SharedPreferencesStorePlatform.instance = backing;
        addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
        prefs =
            await TrackedSharedPreferences.getInstance()
                as TrackedSharedPreferences;
        final original = Future<SharedPreferences>.value(prefs);
        credentials = owner(original);
        addTearDown(credentials.dispose);
        final entered = Completer<void>(), release = Completer<void>();
        storage.beforeRead = () async {
          // Linked load takes presence + metadata; installation then reads the
          // account slot followed by the SECOND secure absence (anonymous) slot.
          if (storage.reads == 4) {
            entered.complete();
            await release.future;
          }
        };
        final adapter = _ScriptedAdapter((_, _) => (status: 200, body: '{}'));
        final transport = DatacatAccountTransport(
          redaction: redaction,
          dio: Dio()..httpClientAdapter = adapter,
        );
        addTearDown(transport.dispose);
        var links = 0;
        final refused = expectLater(
          credentials.link((device, current, commit) async {
            links++;
            await transport.request(
              'POST',
              '/account-links',
              body: {'installationId': device},
              isCurrent: current,
            );
          }),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        try {
          await entered.future;
          final guard = credentials.captureAuthGuard();
          expect(guard(), true);
          await credentials.forgetRevoked(isCurrent: guard);
          expect(storage.values.values, ['']);
          expect(storage.operations.where((op) => op == 'write'), hasLength(1));
          expect(backing.writes, isEmpty);
          expect(adapter.requests, isEmpty);
          expect(links, 0);
        } finally {
          release.complete();
          await refused;
        }
        expect(prefs.getKeys(), isEmpty);
        expect(backing.writes, isEmpty);
        expect(adapter.requests, isEmpty);
        expect(links, 0);
      },
    );

    for (final throws in [false, true]) {
      test(
        'invoked first-link device ${throws ? 'throw' : 'false'} is unknown despite native retirement',
        () async {
          SharedPreferences.setMockInitialValues({});
          final previous = SharedPreferencesStorePlatform.instance;
          final entered = Completer<void>(), release = Completer<void>();
          final backing = _InstallationBacking()
            ..reject = !throws
            ..throwWrite = throws
            ..beforeWrite = () async {
              entered.complete();
              await release.future;
            };
          SharedPreferencesStorePlatform.instance = backing;
          addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
          prefs =
              await TrackedSharedPreferences.getInstance()
                  as TrackedSharedPreferences;
          final original = Future<SharedPreferences>.value(prefs);
          credentials = owner(original);
          addTearDown(credentials.dispose);
          final adapter = _ScriptedAdapter((_, _) => (status: 200, body: '{}'));
          final unknown = expectLater(
            service(adapter).link(),
            throwsA(isA<DatacatInstallationWriteUnverified>()),
          );
          await entered.future;
          credentials.dispose();
          release.complete();
          await unknown;
          credentials = owner(original);
          addTearDown(credentials.dispose);
          await expectLater(
            service(adapter).link(),
            throwsA(isA<CredentialVaultAdmissionDenied>()),
          );
          expect(backing.writes, [
            'flutter.${DatacatAccountPreferences.device}',
          ]);
          expect(backing.values.keys, [
            'flutter.${DatacatAccountPreferences.device}',
          ]);
          expect(adapter.requests, isEmpty);
          expect(storage.values, isEmpty);
        },
      );
    }

    test(
      'explicit native link preserves exact inherited invalid installation instead of repairing it',
      () async {
        const invalid = ' inherited installation with spaces ';
        SharedPreferences.setMockInitialValues({
          DatacatAccountPreferences.device: invalid,
        });
        prefs =
            await TrackedSharedPreferences.getInstance()
                as TrackedSharedPreferences;
        credentials = owner(Future.value(prefs));
        addTearDown(credentials.dispose);
        final adapter = _ScriptedAdapter((_, _) => (status: 200, body: '{}'));
        await expectLater(
          service(adapter).link(),
          throwsA(isA<CredentialVaultException>()),
        );
        expect(prefs.getString(DatacatAccountPreferences.device), invalid);
        expect(prefs.getKeys(), {DatacatAccountPreferences.device});
        expect(adapter.requests, isEmpty);
        expect(storage.values, isEmpty);
        expect(storage.operations, isNot(contains('write')));
      },
    );

    for (final datacatGate in [false, true]) {
      for (final reload in [false, true]) {
        test(
          'whole-store ${reload ? 'reload' : 'clear'} reserves DataCat and sibling FIFOs before await: $datacatGate',
          () async {
            final entered = Completer<void>(), release = Completer<void>();
            final serialize = datacatGate
                ? DatacatAccountPreferences.serialize<void>
                : SavedPreferencesWrites.serializeChub<void>;
            final blocked = serialize(() async {
              entered.complete();
              await release.future;
            });
            await entered.future;
            final earlier = reload ? prefs.reload() : prefs.clear();
            final key = datacatGate
                ? PrivatePreferenceKeys.saucepanToken
                : DatacatAccountPreferences.token;
            final later = prefs.setString(key, returned);
            final drained = Future.wait<void>([
              blocked,
              earlier.then<void>((_) {}),
              later.then<void>((_) {}),
            ]);
            try {
              expect(prefs.getString(key), isNot(returned));
              release.complete();
              await drained;
              expect(await later, true);
              expect(prefs.getString(key), returned);
            } finally {
              if (!release.isCompleted) release.complete();
              await drained;
            }
          },
        );
      }
    }

    test(
      'saved JSON CAS cannot mutate any linked DataCat private key',
      () async {
        final before = snapshot();
        for (final key in DatacatAccountPreferences.keys) {
          final lease = SavedPreferencesOwner.process.capture([
            key,
          ], store: prefs.store);
          final result = await prefs.compareAndSetString(
            key: key,
            expectedRaw: null,
            value: returned,
            expected: lease,
            isCurrent: () => true,
          );
          expect(result.started, false);
          expect(result.accepted, false);
          expect(result.receipt, isNull);
        }
        expect(snapshot(), before);
      },
    );

    for (final tombstone in [false, true]) {
      test(
        'existing secure ${tombstone ? 'empty tombstone' : 'pair'} is never overwritten',
        () async {
          final saved = tombstone
              ? ''
              : _json({
                  'version': 1,
                  'token': native,
                  'device': device,
                  'name': 'NATIVE_NAME',
                  'scopes': ['community:write'],
                });
          await vault.store(slot, saved);
          storage.operations.clear();
          final account = await credentials.load();
          expect(account.authenticated, !tombstone);
          expect(storage.values.values.single, saved);
          expect(storage.operations, isNot(contains('write')));
          expect(snapshot(), initial);
        },
      );
    }

    test(
      'failed secure read never admits plaintext or anonymous HTTP',
      () async {
        storage.readError = StateError('PRIVATE_FAILURE $legacy');
        expect((await credentials.load()).unavailable, true);
        final adapter = _ScriptedAdapter(
          (_, _) => (status: 200, body: '{"comments":[]}'),
        );
        await expectLater(
          service(
            adapter,
          ).communityRequest('GET', '/characters/fixture/community'),
          throwsA(isA<CredentialVaultException>()),
        );
        expect(adapter.requests, isEmpty);
        expect(storage.values, isEmpty);
        expect(storage.operations, isNot(contains('write')));
        expect(snapshot(), initial);
      },
    );

    test(
      'failed import readback never retires or deletes the original plaintext',
      () async {
        storage.dropWrites = true;
        expect((await credentials.load()).unavailable, true);
        expect(storage.values, isEmpty);
        expect(storage.operations, isNot(contains('delete')));
        expect(snapshot(), initial);
      },
    );

    test(
      'private FIFO and same-value backup ABA retire original migration admission',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        storage.beforeRead = () async {
          if (storage.reads == 1) {
            entered.complete();
            await release.future;
          }
        };
        final source = DatacatAccountLegacySource(Future.value(prefs));
        final copying = source.importIfAbsent(
          vault: vault,
          slot: slot,
          redaction: redaction,
          isCurrent: () => true,
        );
        final refused = expectLater(
          copying,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        final replacing = prefs.setString(
          DatacatAccountPreferences.token,
          returned,
        );
        // The facade's optimistic setter must also wait for physical custody.
        expect(prefs.getString(DatacatAccountPreferences.token), legacy);
        release.complete();
        await refused;
        expect(await replacing, true);
        expect(storage.values, isEmpty);
        await prefs.setString(DatacatAccountPreferences.token, legacy);
        await expectLater(
          source.importIfAbsent(
            vault: vault,
            slot: slot,
            redaction: redaction,
            isCurrent: () => true,
          ),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
      },
    );

    test(
      'invoked migration settles original readback before queued binding backup',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        storage.beforeWrite = () async {
          entered.complete();
          await release.future;
        };
        final source = DatacatAccountLegacySource(Future.value(prefs));
        final copying = source.importIfAbsent(
          vault: vault,
          slot: slot,
          redaction: redaction,
          isCurrent: () => true,
        );
        final refused = expectLater(
          copying,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        final replacing = prefs.setString(
          DatacatAccountPreferences.device,
          'OTHER-install-1234567890',
        );
        expect(prefs.getString(DatacatAccountPreferences.device), device);
        release.complete();
        await refused;
        expect(await replacing, true);
        expect(protected()['token'], legacy);
        expect(protected()['device'], device);
        expect(storage.operations.last, 'read');
        expect((await owner(Future.value(prefs)).load()).unavailable, true);
        expect(
          prefs.getString(DatacatAccountPreferences.device),
          'OTHER-install-1234567890',
        );
        expect(storage.operations, isNot(contains('delete')));
      },
    );

    test('late producer cannot adopt a replacement store', () async {
      final producer = Completer<SharedPreferences>();
      final retained = owner(producer.future);
      addTearDown(retained.dispose);
      final loading = retained.load();
      final refused = expectLater(
        loading,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      SharedPreferences.setMockInitialValues({
        'gz_dc_user_token': returned,
        'gz_dc_device': device,
      });
      producer.complete(await TrackedSharedPreferences.getInstance());
      await refused;
      expect(storage.values, isEmpty);
    });

    for (final unlinkLast in [false, true]) {
      test(
        'newest setter/unlink admission owns protected final state: $unlinkLast',
        () async {
          final first = unlinkLast
              ? credentials.setToken(native, installationId: device)
              : credentials.unlink((_, _, _) async {});
          final refused = expectLater(
            first,
            throwsA(isA<CredentialVaultAdmissionDenied>()),
          );
          final last = unlinkLast
              ? credentials.unlink((_, _, _) async {})
              : credentials.setToken(native, installationId: device);
          await refused;
          expect((await last).authenticated, !unlinkLast);
          if (unlinkLast) {
            expect(storage.values.values.single, '');
          } else {
            expect(protected()['token'], native);
            expect(protected()['device'], device);
          }
          expect(snapshot(), initial);
          expect(
            (await owner(Future.value(prefs)).load()).authenticated,
            !unlinkLast,
          );
        },
      );
    }

    test(
      'native submitted token aliases are covered even when binding is rejected',
      () async {
        final setting = credentials.setToken(
          '  $native  ',
          installationId: 'OTHER-install-1234567890',
        );
        expect(redaction.redactor.redactText(native), '[REDACTED]');
        expect(redaction.redactor.redactText('  $native  '), '[REDACTED]');
        await expectLater(
          setting,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        expect(storage.values, isEmpty);
        expect(snapshot(), initial);
      },
    );

    test(
      'setter rechecks newest admission at actual vault FIFO acquisition',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        storage.beforeRead = () async {
          if (storage.reads == 1) {
            entered.complete();
            await release.future;
          }
        };
        final blocking = vault.metadata(slot);
        await entered.future;
        final setting = credentials.setToken(native, installationId: device);
        final refused = expectLater(
          setting,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await pumpEventQueue();
        final unlinking = credentials.unlink((_, _, _) async {});
        release.complete();
        await blocking;
        await refused;
        await unlinking;
        expect(storage.values.values.single, '');
        expect(snapshot(), initial);
      },
    );

    test('old approved link never overrides a newer local unlink', () async {
      final entered = Completer<void>(), release = Completer<void>();
      final linking = credentials.link((binding, current, commit) async {
        expect(binding, device);
        entered.complete();
        await release.future;
        await commit(returned, 'RETURNED_NAME', ['community:write']);
      });
      final refused = expectLater(
        linking,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      await credentials.unlink((_, _, _) async {});
      release.complete();
      await refused;
      expect(storage.values.values.single, '');
      expect(redaction.redactor.redactText(returned), '[REDACTED]');
      expect(snapshot(), initial);
    });

    test(
      'a newer owner on the same vault supersedes an old graph link before commit',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        final linking = credentials.link((binding, current, commit) async {
          entered.complete();
          await release.future;
          await commit(returned, 'OLD_GRAPH_NAME', ['community:write']);
        });
        final refused = expectLater(
          linking,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        final newer = owner(Future.value(prefs));
        addTearDown(newer.dispose);
        await newer.setToken(
          native,
          installationId: device,
          name: 'NEW_GRAPH_NAME',
        );
        release.complete();
        await refused;
        expect(protected()['token'], native);
        expect(protected()['name'], 'NEW_GRAPH_NAME');
        expect(snapshot(), initial);
      },
    );

    test(
      'account HTTP uses original ephemeral pair; errors cover original/current/returned aliases',
      () async {
        final adapter = _ScriptedAdapter((options, _) {
          expect(_header(options, 'Authorization'), 'Bearer $legacy');
          expect(_header(options, 'X-Datacat-Installation-Id'), device);
          expect(options.followRedirects, false);
          redaction.registerSecret(native);
          return (
            status: 403,
            body: _json({
              'access_token': returned,
              'error': 'ACCOUNT_DENIED',
              'message': 'DENIED ${legacy.trim()} $native $returned',
            }),
          );
        });
        await expectLater(
          service(adapter).communityRequest(
            'POST',
            '/characters/fixture/community/kudos',
            body: {'giftKey': 'SYNTHETIC_GIFT'},
            requiredAccount: true,
          ),
          throwsA(
            isA<DatacatApiException>()
                .having((e) => e.status, 'status', 403)
                .having(
                  (e) => e.message,
                  'safe message',
                  'DENIED [REDACTED] [REDACTED] [REDACTED]',
                ),
          ),
        );
        expect(adapter.requests, hasLength(1));
        expect(redaction.redactor.redactText(returned), '[REDACTED]');
        expect(snapshot(), initial);
      },
    );

    test(
      'status revocation stores a verified tombstone without remote revoke or prefs cleanup',
      () async {
        final adapter = _ScriptedAdapter(
          (options, _) => (
            status: 401,
            body: _json({'error': 'ACCOUNT_REVOKED', 'message': 'Revoked'}),
          ),
        );
        expect((await service(adapter).status()).linked, false);
        expect(storage.values.values.single, '');
        expect(adapter.requests.single.method, 'GET');
        expect(snapshot(), initial);
      },
    );

    for (final state in <Object?>[
      null,
      '',
      'future_state',
      'anonymous',
      false,
      7,
      <String>[],
    ]) {
      test(
        'HTTP 200 unknown/malformed status preserves the original protected account: $state',
        () async {
          final saved = _json({
            'version': 1,
            'token': native,
            'device': device,
            'name': 'NATIVE_NAME',
            'scopes': ['community:write'],
          });
          await vault.store(slot, saved);
          await credentials.load();
          storage.operations.clear();
          final adapter = _ScriptedAdapter((options, _) {
            expect(_header(options, 'Authorization'), 'Bearer $native');
            return (
              status: 200,
              body: _json({
                'success': true,
                'account': {'displayName': 'Example'},
                if (state != null) 'accountState': state,
              }),
            );
          });
          final status = await service(adapter).status();
          expect(
            status.linked,
            true,
            reason: 'Unavailable status is not a successful logout',
          );
          expect(status.loggedIn, true);
          expect(status.credentialUnavailable, true);
          expect(status.displayName, 'NATIVE_NAME');
          expect(status.scopes, ['community:write']);
          expect(storage.values.values.single, saved);
          expect(storage.operations, isNot(contains('write')));
          expect(storage.operations, isNot(contains('delete')));
          expect((await credentials.load()).authenticated, true);
          expect(adapter.requests.single.method, 'GET');
          expect(snapshot(), initial);
        },
      );
    }

    test(
      'HTTP 200 original unlinked state is affirmative local revocation evidence',
      () async {
        final adapter = _ScriptedAdapter(
          (_, _) => (
            status: 200,
            body: _json({'success': true, 'accountState': 'unlinked'}),
          ),
        );
        final status = await service(adapter).status();
        expect(status.linked, false);
        expect(status.credentialUnavailable, false);
        expect(storage.values.values.single, '');
        expect(adapter.requests.single.method, 'GET');
        expect(snapshot(), initial);
      },
    );

    for (final success in <Object?>[null, false, 'true']) {
      test(
        'HTTP 200 unlinked without affirmative success preserves the protected account: $success',
        () async {
          await credentials.load();
          final original = storage.values.values.single;
          storage.operations.clear();
          final adapter = _ScriptedAdapter(
            (_, _) => (
              status: 200,
              body: _json({
                'accountState': 'unlinked',
                if (success != null) 'success': success,
              }),
            ),
          );
          final status = await service(adapter).status();
          expect(status.linked, true);
          expect(status.credentialUnavailable, true);
          expect(storage.values.values.single, original);
          expect(storage.operations, isNot(contains('write')));
          expect(snapshot(), initial);
        },
      );
    }

    test(
      'failed unlink tombstone readback never publishes a successful logout',
      () async {
        await credentials.load();
        final original = storage.values.values.single;
        storage.dropWrites = true;
        final adapter = _ScriptedAdapter((_, _) => (status: 204, body: ''));
        await expectLater(
          service(adapter).unlink(),
          throwsA(isA<CredentialVaultException>()),
        );
        expect(storage.values.values.single, original);
        expect(snapshot(), initial);
        expect(storage.operations, isNot(contains('delete')));
      },
    );

    test('stale remote unlink cannot erase the newest native token', () async {
      final entered = Completer<void>(), release = Completer<void>();
      final adapter = _ScriptedAdapter((options, _) async {
        expect(options.method, 'DELETE');
        entered.complete();
        await release.future;
        return (status: 204, body: '');
      });
      final account = service(adapter);
      final unlinking = account.unlink();
      final refused = expectLater(
        unlinking,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await entered.future;
      await account.setToken(
        native,
        installationId: device,
        name: 'NATIVE_NAME',
      );
      release.complete();
      await refused;
      expect(protected()['token'], native);
      expect(protected()['device'], device);
      expect(snapshot(), initial);
    });

    test(
      'link protocol retains original device through start/exchange and never stores plaintext',
      () async {
        final adapter = _ScriptedAdapter((options, index) {
          final body = jsonDecode(options.data as String) as Map;
          expect(body['installationId'], device);
          expect(body['clientName'], datacatClientName);
          expect(_header(options, 'Authorization'), isNull);
          if (index == 0)
            return (
              status: 201,
              body: _json({
                'linkId': 'SYNTHETIC_LINK',
                'deviceCode': 'SYNTHETIC_DEVICE_CODE',
                'authorizationUriComplete':
                    'https://datacat.run/link?code=SYNTHETIC_CODE',
                'interval': 1,
              }),
            );
          expect(body['deviceCode'], 'SYNTHETIC_DEVICE_CODE');
          expect(
            options.uri.path,
            endsWith('/account-links/SYNTHETIC_LINK/token'),
          );
          return (
            status: 200,
            body: _json({
              'accessToken': returned,
              'accountState': 'logged_in',
              'account': {'displayName': 'LINKED_NAME'},
              'scopes': ['community:write'],
            }),
          );
        });
        DatacatAccountApproval? published;
        final account = await service(adapter).link(
          onFlow: (approval) {
            published = approval;
            expect(
              approval.uri,
              'https://datacat.run/link?code=SYNTHETIC_CODE',
            );
            expect(approval.canPublish, true);
            expect(approval.canNavigate(approval.uri), true);
            expect(approval.canNavigate('https://other.example/link'), false);
            expect(
              approval.canNavigate(
                'https://datacat.run/link?code=SYNTHETIC_DEVICE_CODE',
              ),
              false,
            );
          },
        );
        expect(published, isA<DatacatAccountApproval>());
        expect(account.authenticated, true);
        expect(account.displayName, 'LINKED_NAME');
        expect(account.scopes, ['community:write']);
        expect(protected()['token'], returned);
        expect(protected()['device'], device);
        expect(snapshot(), initial);
        expect(
          redaction.redactor.redactText('SYNTHETIC_DEVICE_CODE'),
          '[REDACTED]',
        );
      },
    );
    for (final polling in <Object?>[
      731904,
      true,
      [731904],
      {'code': 731904},
      null,
    ]) {
      test(
        'link start rejects malformed polling code $polling before approval or exchange',
        () async {
          await credentials.load();
          final original = storage.values.values.single;
          storage.operations.clear();
          final adapter = _ScriptedAdapter((_, index) {
            expect(
              index,
              0,
              reason: 'Malformed polling codes cannot start exchange',
            );
            return (
              status: 201,
              body: _json({
                'linkId': 'SYNTHETIC_LINK',
                'deviceCode': polling,
                'userCode': '$polling',
                'authorizationUriComplete':
                    'https://datacat.run/link?code=${Uri.encodeComponent('$polling')}',
                'interval': 1,
              }),
            );
          });
          final flows = <DatacatAccountApproval>[];
          await expectLater(
            service(adapter).link(onFlow: flows.add),
            throwsA(isA<DatacatApiException>()),
          );
          expect(flows, isEmpty);
          expect(adapter.requests, hasLength(1));
          expect(storage.values.values.single, original);
          expect(storage.operations, isNot(contains('write')));
          expect(snapshot(), initial);
        },
      );
    }
    for (final echoed in [
      'polling URL',
      'encoded polling URL',
      'whole polling URL',
      'polling user code',
      'original account URL',
      'current account code',
    ]) {
      test(
        'link start rejects $echoed before any approval/navigation callback or exchange',
        () async {
          await credentials.load();
          final original = storage.values.values.single;
          storage.operations.clear();
          final polling = echoed == 'whole polling URL'
              ? 'https://datacat.run/link?code=SYNTHETIC_PUBLIC_APPROVAL'
              : 'SYNTHETIC_PRIVATE_POLLING/CODE';
          final adapter = _ScriptedAdapter((_, index) {
            expect(
              index,
              0,
              reason:
                  'Unsafe public approval must never start a token exchange',
            );
            redaction.registerSecret(native);
            final uri = switch (echoed) {
              'polling URL' => 'https://datacat.run/link?code=$polling',
              'encoded polling URL' =>
                'https://datacat.run/link?code=${Uri.encodeComponent(polling)}',
              'whole polling URL' => polling,
              'original account URL' =>
                'https://datacat.run/link?code=${Uri.encodeComponent(legacy.trim())}',
              _ => 'https://datacat.run/link?code=SYNTHETIC_PUBLIC_APPROVAL',
            };
            final code = switch (echoed) {
              'polling user code' => polling,
              'current account code' => native,
              _ => 'SYNTHETIC_PUBLIC_APPROVAL',
            };
            return (
              status: 201,
              body: _json({
                'linkId': 'SYNTHETIC_LINK',
                'deviceCode': polling,
                'authorizationUriComplete': uri,
                'userCode': code,
                'interval': 1,
              }),
            );
          });
          final flows = <DatacatAccountApproval>[];
          final navigation = <String>[];
          await expectLater(
            service(adapter).link(
              onFlow: (approval) {
                flows.add(approval);
                navigation.add(approval.uri);
              },
            ),
            throwsA(isA<DatacatApiException>()),
          );
          expect(flows, isEmpty);
          expect(navigation, isEmpty);
          expect(adapter.requests, hasLength(1));
          expect(storage.values.values.single, original);
          expect(storage.operations, isNot(contains('write')));
          expect(snapshot(), initial);
        },
      );
    }

    test(
      'approval-only DTO preserves public fields and rechecks new secrets/original owner',
      () async {
        const code = 'SYNTHETIC_PUBLIC_APPROVAL';
        final entered = Completer<void>(), release = Completer<void>();
        DatacatAccountApproval? published;
        final adapter = _ScriptedAdapter((_, index) async {
          if (index == 0)
            return (
              status: 201,
              body: _json({
                'linkId': 'SYNTHETIC_LINK',
                'deviceCode': 'SYNTHETIC_PRIVATE_POLLING',
                'authorizationUriComplete':
                    'https://datacat.run/link?code=$code',
                'userCode': code,
                'expiresIn': 600,
                'interval': 1,
              }),
            );
          entered.complete();
          await release.future;
          return (status: 200, body: _json({'accessToken': returned}));
        });
        final account = service(adapter);
        final linking = account.link(
          onFlow: (approval) {
            published = approval;
            expect(approval.userCode, code);
            expect(approval.expiresIn, const Duration(minutes: 10));
            expect(approval.canPublish, true);
            expect(approval.canNavigate(approval.uri), true);
          },
        );
        final refused = expectLater(
          linking,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        try {
          final approval = published!;
          redaction.registerSecret('SYNTHETIC_NEW_ACCOUNT_SECRET');
          expect(
            approval.canNavigate(
              'https://datacat.run/link?code=SYNTHETIC_NEW_ACCOUNT_SECRET',
            ),
            false,
          );
          expect(approval.canPublish, true);
          await account.setToken(native, installationId: device);
          expect(approval.canPublish, false);
          expect(approval.canNavigate(approval.uri), false);
          release.complete();
          await refused;
          expect(protected()['token'], native);
          expect(snapshot(), initial);
        } finally {
          if (!release.isCompleted) release.complete();
          await refused;
        }
      },
    );
  });

  group('the live deployment is not the vendored contract', () {
    test(
      'the challenge is started with the action capabilities advertises',
      () async {
        // The contract says `character_transfer`; the server rejects that and
        // names its own. Reading the list is what survives the next rename.
        final adapter = _ScriptedAdapter((options, index) {
          if (options.uri.path.endsWith('/capabilities')) {
            return (
              status: 200,
              body: _liveCapabilities.replaceFirst(
                '"character-import"',
                '"renamed-again"',
              ),
            );
          }
          return (
            status: 201,
            body: _json({
              'verificationId': 'v-1',
              'deviceCode': 'secret',
              'verificationUriComplete':
                  'https://datacat.run/client-verify?id=v-1',
              'expiresIn': 300,
              'interval': 3,
            }),
          );
        });
        setCatalogHttpAdapter(adapter);

        await startDatacatVerification();

        final started = adapter.requests.last;
        expect(started.uri.path, endsWith('/verifications'));
        expect(jsonDecode(started.data as String)['action'], 'renamed-again');
      },
    );

    test(
      'an unsolved challenge answers 428, and the poll keeps waiting',
      () async {
        // The contract documents 409. Live uses 428 VERIFICATION_PENDING, which a
        // 409-only check reads as fatal and throws the user's solve away.
        final adapter = _ScriptedAdapter((options, index) {
          if (options.uri.path.endsWith('/capabilities')) {
            return (status: 200, body: _liveCapabilities);
          }
          if (index == 0) {
            return (
              status: 428,
              body: _json({
                'success': false,
                'error': 'VERIFICATION_PENDING',
                'message': 'Waiting for the DataCat security check.',
              }),
            );
          }
          return (
            status: 200,
            body: _json({
              'success': true,
              'leaseToken': 'dcv1v_lease',
              'expiresAt': DateTime.now()
                  .add(const Duration(minutes: 30))
                  .toUtc()
                  .toIso8601String(),
              'maxUniqueCharacters': 20,
            }),
          );
        });
        setCatalogHttpAdapter(adapter);

        final lease = await awaitDatacatLease(
          const DatacatDeviceFlow(
            id: 'v-1',
            deviceCode: 'secret',
            uri: 'https://datacat.run/client-verify?id=v-1',
            interval: Duration(milliseconds: 5),
          ),
        );

        expect(lease, 'dcv1v_lease');
        expect(DatacatLeaseStore.instance.leaseFor('char-1'), 'dcv1v_lease');
      },
    );

    test(
      'a lease that states a duration rather than an instant still lives',
      () async {
        // The success body was never observed against live, so both spellings
        // have to work — reading neither would leave the lease a 5-minute stub.
        final adapter = _ScriptedAdapter((options, index) {
          if (options.uri.path.endsWith('/capabilities')) {
            return (status: 200, body: _liveCapabilities);
          }
          return (
            status: 200,
            body: _json({'leaseToken': 'dcv1v_lease', 'expiresIn': 1800}),
          );
        });
        setCatalogHttpAdapter(adapter);

        await awaitDatacatLease(
          const DatacatDeviceFlow(
            id: 'v-1',
            deviceCode: 'secret',
            uri: 'https://datacat.run/client-verify?id=v-1',
            interval: Duration(milliseconds: 5),
          ),
        );

        expect(DatacatLeaseStore.instance.leaseFor('char-1'), 'dcv1v_lease');
      },
    );

    test('a revoked client id is not answered by verifying again', () async {
      // Live reports an unapproved client id as a 403 — the same status a
      // retired lease uses. Only one of the two is worth a challenge.
      DatacatLeaseStore.instance.store(
        'dcv1v_stale',
        DateTime.now().add(const Duration(minutes: 30)),
      );
      final adapter = _serve(
        (options, index) => (
          status: 403,
          body: _json({
            'success': false,
            'error': 'CLIENT_API_CLIENT_NOT_APPROVED',
            'message': 'This client is not approved or has been revoked.',
          }),
        ),
      );
      setCatalogHttpAdapter(adapter);

      var asked = false;
      await expectLater(
        datacatFetchCard(
          'char-1',
          obtainLease: () async {
            asked = true;
            return 'dcv1v_fresh';
          },
        ),
        throwsA(
          isA<DatacatApiException>().having(
            (e) => e.isClientNotApproved,
            'clientNotApproved',
            true,
          ),
        ),
      );
      expect(asked, isFalse);
    });
  });
}
