import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/chub_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/chub_legacy_credential_source.dart';
import 'package:glaze_flutter/core/credentials/credential_slot.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/preferences/saved_preferences_owner.dart';
import 'package:glaze_flutter/core/preferences/tracked_shared_preferences.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/features/catalog/chub_account_provider.dart';
import 'package:glaze_flutter/features/catalog/catalog_models.dart';
import 'package:glaze_flutter/features/catalog/catalog_provider.dart';
import 'package:glaze_flutter/features/catalog/services/chub_provider.dart';
import 'package:glaze_flutter/features/catalog/third_party_providers_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Existing legacy mock backing-store seam; no real preferences/native storage.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'fake_credential_storage.dart';

const _legacy = 'SYNTHETIC_CHUB_LEGACY_CANARY';
const _native = 'SYNTHETIC_CHUB_NATIVE_CANARY';
const _backup = 'SYNTHETIC_CHUB_BACKUP_CANARY';
const _key = PrivatePreferenceKeys.chubApiKey;
final _slot = CredentialSlot(domain: 'catalog.chub', id: 'account');

/// Same plugin test seam as the existing preferences ownership suite. Delays
/// expose actual backing writes separately from the optimistic legacy cache.
final class _Backing extends SharedPreferencesStorePlatform {
  _Backing(Map<String, Object> initial)
    : values = {for (final e in initial.entries) 'flutter.${e.key}': e.value};
  final Map<String, Object> values;
  final writes = <String>[];
  Future<void> Function()? beforeRemove;
  bool rejectWrites = false;
  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes.add(key);
    if (rejectWrites) return false;
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    writes.add(key);
    await beforeRemove?.call();
    if (rejectWrites) return false;
    values.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    writes.add('*');
    values.clear();
    return true;
  }
}

Future<void> _backed(
  Future<void> Function(TrackedSharedPreferences prefs, _Backing backing)
  body, {
  Map<String, Object> initial = const {
    _key: _legacy,
    'gz_chub_user_name': 'SYNTHETIC_CHUB_NAME',
    'gz_chub_nsfl': true,
  },
}) async {
  SharedPreferences.setMockInitialValues(initial);
  final previous = SharedPreferencesStorePlatform.instance;
  final backing = _Backing(initial);
  SharedPreferencesStorePlatform.instance = backing;
  try {
    final prefs = await TrackedSharedPreferences.getInstance();
    await body(prefs as TrackedSharedPreferences, backing);
  } finally {
    SharedPreferencesStorePlatform.instance = previous;
  }
}

ChubCredentialOwner _owner(
  CredentialVault vault,
  TrackedSharedPreferences prefs,
  SecretRedactionCoordinator redaction,
) => ChubCredentialOwner(
  vault: vault,
  redaction: redaction,
  originalPreferences: Future.value(prefs),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeCredentialStorage storage;
  late CredentialVault vault;
  late SecretRedactionCoordinator redaction;
  setUp(() {
    storage = FakeCredentialStorage();
    vault = CredentialVault(storage: storage, buildChannel: 'dev');
    redaction = SecretRedactionCoordinator();
    addTearDown(redaction.dispose);
  });

  test(
    'verified original import preserves legacy/name/NSFL and native headers',
    () async {
      await _backed((prefs, backing) async {
        final owner = _owner(vault, prefs, redaction);
        final account = await owner.load();
        expect(account.authenticated, true);
        expect(account.userName, isNull);
        expect(account.lastKnownUserName, 'SYNTHETIC_CHUB_NAME');
        expect(account.nsfl, true);
        expect(storage.values.values, [_legacy]);
        expect(backing.writes, isEmpty);
        expect(prefs.getString(_key), _legacy);
        await owner.withApiKey((key) async {
          final headers = chubHeaders(apiKey: key);
          expect(headers['CH-API-KEY'], _legacy);
          expect(headers['samwise'], _legacy);
        });
        expect(redaction.redactor.redactText(_legacy), '[REDACTED]');
        expect(account.toString(), isNot(contains(_legacy)));
        expect(SavedPreferencesKeys.families.length, 5);
        expect(SavedPreferencesKeys.all, isNot(contains(_key)));
        expect(PrivatePreferenceKeys.tracked, contains(_key));
      });
    },
  );

  for (final existing in [_native, '']) {
    test(
      'existing ${existing.isEmpty ? 'empty' : 'native'} vault value is not absence',
      () async {
        await _backed((prefs, backing) async {
          await vault.store(_slot, existing);
          storage.operations.clear();
          final owner = _owner(vault, prefs, redaction);
          final account = await owner.load();
          expect(account.authenticated, existing.isNotEmpty);
          expect(account.userName, isNull);
          expect(account.lastKnownUserName, 'SYNTHETIC_CHUB_NAME');
          expect(account.nsfl, true);
          expect(storage.values.values, [existing]);
          expect(storage.operations, isNot(contains('write')));
          expect(backing.writes, isEmpty);
          await owner.withApiKey((key) async {
            expect(key, existing.isEmpty ? isNull : existing);
          });
        });
      },
    );
  }

  for (final legacy in ['', '   ']) {
    test(
      'legacy empty/whitespace semantics are preserved exactly: ${legacy.length}',
      () async {
        await _backed((prefs, backing) async {
          final account = await _owner(vault, prefs, redaction).load();
          expect(account.authenticated, legacy.isNotEmpty);
          expect(storage.values.values, [legacy]);
          expect(prefs.getString(_key), legacy);
          expect(backing.writes, isEmpty);
        }, initial: {_key: legacy});
      },
    );
  }

  test(
    'failed vault read is unavailable, never plaintext/anonymous fallback',
    () async {
      await _backed((prefs, backing) async {
        storage.readError = StateError('SYNTHETIC_STORAGE_FAILURE $_legacy');
        final owner = _owner(vault, prefs, redaction);
        final account = await owner.load();
        expect(account.unavailable, true);
        expect(account.authenticated, false);
        expect(account.userName, isNull);
        expect(account.lastKnownUserName, 'SYNTHETIC_CHUB_NAME');
        expect(account.nsfl, true);
        var called = false;
        await expectLater(
          owner.withApiKey((_) async => called = true),
          throwsA(isA<CredentialVaultException>()),
        );
        expect(called, false);
        expect(storage.values, isEmpty);
        expect(storage.operations, isNot(contains('write')));
        expect(backing.writes, isEmpty);
        expect(prefs.getString(_key), _legacy);
      });
    },
  );

  for (final dropped in [false, true]) {
    test(
      'failed/unequal vault import never retires original plaintext: $dropped',
      () async {
        await _backed((prefs, backing) async {
          if (dropped) {
            storage.dropWrites = true;
          } else {
            storage.writeError = StateError('SYNTHETIC_WRITE_FAILURE $_legacy');
          }
          final account = await _owner(vault, prefs, redaction).load();
          expect(account.unavailable, true);
          expect(prefs.getString(_key), _legacy);
          expect(backing.values['flutter.$_key'], _legacy);
          expect(backing.writes, isEmpty);
          expect(storage.operations, isNot(contains('delete')));
        });
      },
    );
  }

  test(
    'queued native vault replacement wins import without overwrite',
    () async {
      await _backed((prefs, backing) async {
        final entered = Completer<void>(), release = Completer<void>();
        storage.beforeRead = () async {
          if (storage.reads == 1) {
            entered.complete();
            await release.future;
          }
        };
        final owner = _owner(vault, prefs, redaction);
        final loading = owner.load();
        await entered.future;
        final replacing = vault.store(_slot, _native);
        release.complete();
        await replacing;
        final account = await loading;
        expect(account.authenticated, true);
        expect(storage.values.values, [_native]);
        expect(storage.operations.where((op) => op == 'write').length, 1);
        expect(backing.writes, isEmpty);
      });
    },
  );

  for (final boundary in ['slot entry', 'absence read']) {
    for (final retired in ['native owner', 'original lease']) {
      test('legacy import refuses $retired retirement at $boundary', () async {
        await _backed((prefs, backing) async {
          final entered = Completer<void>(), release = Completer<void>();
          storage.beforeRead = () async {
            if (storage.reads == 1) {
              entered.complete();
              await release.future;
            }
          };
          final source = ChubLegacyCredentialSource(Future.value(prefs));
          var current = true;
          final blocked = boundary == 'slot entry'
              ? vault.metadata(_slot)
              : null;
          if (blocked != null) await entered.future;
          final importing = source.importIfAbsent(
            vault: vault,
            slot: _slot,
            redaction: redaction,
            isCurrent: () => current,
          );
          final refused = expectLater(
            importing,
            throwsA(isA<CredentialVaultAdmissionDenied>()),
          );
          if (blocked == null) {
            await entered.future;
          } else {
            await pumpEventQueue(); // Import is queued behind the vault read.
          }
          Future<bool>? replacing;
          if (retired == 'native owner') {
            current = false;
          } else {
            replacing = prefs.setString(
              _key,
              _legacy,
            ); // Same-value ABA intent.
          }
          release.complete();
          await blocked;
          await refused;
          if (replacing != null) expect(await replacing, true);
          expect(storage.values, isEmpty);
          expect(storage.operations, ['read']);
          expect(prefs.getString(_key), _legacy);
          expect(backing.values['flutter.$_key'], _legacy);
        });
      });
    }
  }

  for (final logout in [false, true]) {
    test(
      'new ${logout ? 'logout' : 'setter'} fences an already admitted import',
      () async {
        await _backed((prefs, backing) async {
          final entered = Completer<void>(), release = Completer<void>();
          var first = true;
          storage.beforeWrite = () async {
            if (first) {
              first = false;
              entered.complete();
              await release.future;
            }
          };
          final owner = _owner(vault, prefs, redaction);
          final loading = owner.load();
          final observed = expectLater(
            loading,
            throwsA(isA<CredentialVaultAdmissionDenied>()),
          );
          await entered.future;
          final mutation = logout ? owner.logout() : owner.setApiKey(_native);
          release.complete();
          await observed;
          final account = await mutation;
          expect(account.authenticated, !logout);
          expect(storage.values.values, [logout ? '' : _native]);
          expect(prefs.getString(_key), _legacy);
          expect(storage.operations, isNot(contains('delete')));
          final recreated = _owner(vault, prefs, redaction);
          expect((await recreated.load()).authenticated, !logout);
          expect(storage.values.values, [logout ? '' : _native]);
        });
      },
    );
  }

  test(
    'post-secure commit resets the catalog account scope despite failed metadata',
    () async {
      await _backed(
        (prefs, backing) async {
          final owner = _owner(vault, prefs, redaction);
          final container = ProviderContainer(
            overrides: [chubCredentialOwnerProvider.overrideWithValue(owner)],
          );
          addTearDown(container.dispose);
          final account = container.read(chubAccountProvider.notifier);
          await account.setApiKey(_native, userName: 'OLD_NAME');
          container.read(thirdPartyProvidersProvider);
          await pumpEventQueue();
          final pending = <Completer<CatalogSearchResult>>[];
          final catalogProvider =
              StateNotifierProvider<CatalogNotifier, CatalogState>(
                (ref) => CatalogNotifier(
                  ref,
                  fetchOverride: (provider) {
                    expect(provider, CatalogProvider.chub);
                    final result = Completer<CatalogSearchResult>();
                    pending.add(result);
                    return result.future;
                  },
                ),
              );
          final catalog = container.read(catalogProvider.notifier);
          await pumpEventQueue();
          expect(pending, hasLength(1));
          pending.first.complete(
            CatalogSearchResult(
              characters: [
                const CatalogItem(id: 'old-account', name: 'OLD_ACCOUNT'),
              ],
              total: 10,
            ),
          );
          await pumpEventQueue();
          final oldPage = catalog.loadMore();
          expect(pending, hasLength(2));
          final entered = Completer<void>(), release = Completer<void>();
          backing.beforeRemove = () async {
            entered.complete();
            await release.future;
          };
          backing.rejectWrites = true;
          final changing = account.setApiKey(_backup);
          final metadataIssue = expectLater(
            changing,
            throwsA(isA<ChubAccountMetadataException>()),
          );
          await entered.future;
          await pumpEventQueue();
          expect(pending, hasLength(3));
          expect(container.read(catalogProvider).results, isEmpty);
          pending[1].complete(
            CatalogSearchResult(
              characters: [
                const CatalogItem(id: 'old-late-page', name: 'OLD_LATE_PAGE'),
              ],
              total: 10,
            ),
          );
          await oldPage;
          expect(container.read(catalogProvider).results, isEmpty);
          pending[2].complete(
            CatalogSearchResult(
              characters: [
                const CatalogItem(id: 'new-account', name: 'NEW_ACCOUNT'),
              ],
              total: 1,
            ),
          );
          release.complete();
          await metadataIssue;
          await pumpEventQueue();
          expect(
            container.read(catalogProvider).results.map((item) => item.id),
            ['new-account'],
          );
          expect(container.read(chubAccountProvider).metadataUnavailable, true);
        },
        initial: {
          _key: _legacy,
          'gz_chub_user_name': 'SYNTHETIC_CHUB_NAME',
          'gz_chub_nsfl': true,
          'gz_catalog_provider': 'chub',
          'gz_disabled_third_party_providers': <String>[],
        },
      );
    },
  );

  test(
    'setter before original preference hydration supersedes the old load',
    () async {
      await _backed((prefs, backing) async {
        final producer = Completer<SharedPreferences>();
        final owner = ChubCredentialOwner(
          vault: vault,
          redaction: redaction,
          originalPreferences: producer.future,
        );
        final loading = owner.load();
        final observed = expectLater(
          loading,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        final setting = owner.setApiKey('  $_native  ', userName: ' NEW_NAME ');
        producer.complete(prefs);
        await observed;
        final account = await setting;
        expect(account.authenticated, true);
        expect(account.userName, 'NEW_NAME');
        expect(account.nsfl, true);
        expect(storage.values.values, [_native]);
        expect(prefs.getString(_key), _legacy);
      });
    },
  );

  test(
    'tracked backup during import preserves its newer legacy material',
    () async {
      await _backed((prefs, backing) async {
        final entered = Completer<void>(), release = Completer<void>();
        storage.beforeWrite = () async {
          entered.complete();
          await release.future;
        };
        final owner = _owner(vault, prefs, redaction);
        final loading = owner.load();
        await entered.future;
        // The existing backup importer surrounds acquisition with this intent.
        final backup = SavedPreferencesWrites.run([
          _key,
        ], () => prefs.setString(_key, _backup));
        expect(backing.writes, isEmpty);
        release.complete();
        expect((await loading).unavailable, true);
        expect(await backup, true);
        expect(backing.values['flutter.$_key'], _backup);
        expect(prefs.getString(_key), _backup);
        expect(storage.values.values, [_legacy]);
        expect(
          await owner.retireLegacyWithNativeConsent(confirmed: true),
          false,
        );
        expect(backing.values['flutter.$_key'], _backup);
      });
    },
  );

  test(
    'same-value ABA retires the original legacy lease permanently',
    () async {
      await _backed((prefs, backing) async {
        final owner = _owner(vault, prefs, redaction);
        await owner.load();
        await prefs.setString(_key, _backup);
        await prefs.setString(_key, _legacy);
        expect(
          await owner.retireLegacyWithNativeConsent(confirmed: true),
          false,
        );
        expect(prefs.getString(_key), _legacy);
        expect(backing.writes, isNot(contains('*')));
      });
    },
  );

  for (final logoutLast in [false, true]) {
    test(
      'simultaneous setter/logout honors the newest native admission: $logoutLast',
      () async {
        await _backed((prefs, backing) async {
          final owner = _owner(vault, prefs, redaction);
          final first = logoutLast ? owner.setApiKey(_native) : owner.logout();
          final observed = expectLater(
            first,
            throwsA(isA<CredentialVaultAdmissionDenied>()),
          );
          final last = logoutLast ? owner.logout() : owner.setApiKey(_native);
          await observed;
          final account = await last;
          expect(account.authenticated, !logoutLast);
          expect(storage.values.values, [logoutLast ? '' : _native]);
          expect(prefs.getString(_key), _legacy);
          expect(storage.operations.where((op) => op == 'write').length, 1);
        });
      },
    );
  }

  test(
    'null/blank native clear preserves NSFL but cannot revive legacy on reload',
    () async {
      await _backed((prefs, backing) async {
        final owner = _owner(vault, prefs, redaction);
        await owner.load();
        final cleared = await owner.setApiKey('   ');
        expect(cleared.authenticated, false);
        expect(cleared.userName, isNull);
        expect(cleared.nsfl, true);
        expect(storage.values.values, ['']);
        expect(prefs.getString(_key), _legacy);
        final recreated = _owner(vault, prefs, redaction);
        expect((await recreated.load()).authenticated, false);
        expect((await recreated.setApiKey(null)).nsfl, true);
      });
    },
  );

  test(
    'key replacement without a name clears attribution, startup is only last-known',
    () async {
      await _backed((prefs, backing) async {
        final owner = _owner(vault, prefs, redaction);
        final named = await owner.setApiKey(_native, userName: 'BOUND_NAME');
        expect(named.userName, 'BOUND_NAME');
        expect(named.lastKnownUserName, isNull);
        final startup = await _owner(vault, prefs, redaction).load();
        expect(startup.userName, isNull);
        expect(startup.lastKnownUserName, 'BOUND_NAME');
        final replacement = await owner.setApiKey(_backup);
        expect(replacement.userName, isNull);
        expect(replacement.lastKnownUserName, isNull);
        expect(replacement.nsfl, true);
        expect(prefs.getString('gz_chub_user_name'), isNull);
      });
    },
  );

  for (final logout in [false, true]) {
    test(
      'verified ${logout ? 'logout' : 'replacement'} publishes before failed metadata, without rollback',
      () async {
        await _backed((prefs, backing) async {
          final owner = _owner(vault, prefs, redaction);
          await owner.setApiKey(_native, userName: 'OLD_BOUND_NAME');
          final container = ProviderContainer(
            overrides: [chubCredentialOwnerProvider.overrideWithValue(owner)],
          );
          addTearDown(container.dispose);
          final notifier = container.read(chubAccountProvider.notifier);
          await pumpEventQueue();
          expect(container.read(chubAccountProvider).isLoggedIn, true);
          final entered = Completer<void>(), release = Completer<void>();
          backing.beforeRemove = () async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          };
          backing.rejectWrites = true;
          final mutation = logout
              ? notifier.logout()
              : notifier.setApiKey(_backup);
          final issue = expectLater(
            mutation,
            throwsA(isA<ChubAccountMetadataException>()),
          );
          await entered.future;
          final committed = container.read(chubAccountProvider);
          expect(committed.isLoggedIn, !logout);
          expect(committed.userName, isNull);
          expect(committed.lastKnownUserName, isNull);
          expect(committed.nsfl, !logout);
          expect(committed.authRevision, 2);
          expect(storage.values.values, [logout ? '' : _backup]);
          release.complete();
          await issue;
          final settled = container.read(chubAccountProvider);
          expect(settled.isLoggedIn, !logout);
          expect(settled.metadataUnavailable, true);
          expect(settled.credentialUnavailable, false);
          expect(settled.userName, isNull);
          expect(settled.lastKnownUserName, isNull);
          expect(backing.values['flutter.gz_chub_user_name'], 'OLD_BOUND_NAME');
          expect(prefs.getString(_key), _legacy);
          expect(storage.operations, isNot(contains('delete')));
          await notifier.withApiKey(
            (key) async => expect(key, logout ? isNull : _backup),
          );
        });
      },
    );
  }

  test('saved-JSON CAS cannot bypass the private Chub writer FIFO', () async {
    await _backed((prefs, backing) async {
      final lease = prefs.store.owner.capture([_key], store: prefs.store);
      final result = await prefs.compareAndSetString(
        key: _key,
        expectedRaw: _legacy,
        value: _backup,
        expected: lease,
        isCurrent: () => true,
      );
      expect(result.started, false);
      expect(result.receipt, isNull);
      expect(backing.writes, isEmpty);
      expect(prefs.getString(_key), _legacy);
    });
  });

  test(
    'raw/untracked preference injection cannot authorize legacy import',
    () async {
      await _backed((prefs, backing) async {
        final owner = ChubCredentialOwner(
          vault: vault,
          redaction: redaction,
          originalPreferences: Future.value(prefs.delegate),
        );
        await expectLater(
          owner.load(),
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        expect(storage.values, isEmpty);
        expect(backing.writes, isEmpty);
      });
    },
  );

  test(
    'native registration is synchronous and survives a failed replacement',
    () async {
      await _backed((prefs, backing) async {
        final owner = _owner(vault, prefs, redaction);
        await owner.load();
        storage.writeError = StateError('SYNTHETIC_FAILURE $_native');
        final saving = owner.setApiKey(_native);
        expect(
          redaction.redactor.redactText('$_legacy $_native'),
          '[REDACTED] [REDACTED]',
        );
        await expectLater(saving, throwsA(isA<CredentialVaultException>()));
        expect(storage.values.values, [_legacy]);
        expect(backing.writes, isEmpty);
      });
    },
  );

  test(
    'false preference acknowledgement is not saved import evidence',
    () async {
      await _backed((prefs, backing) async {
        backing.rejectWrites = true;
        expect(await prefs.setString(_key, _backup), false);
        final account = await _owner(vault, prefs, redaction).load();
        expect(account.unavailable, true);
        expect(storage.values, isEmpty);
        expect(backing.values['flutter.$_key'], _legacy);
      });
    },
  );

  test('original store retirement cannot revive through store ABA', () async {
    await _backed((prefs, backing) async {
      final owner = _owner(vault, prefs, redaction);
      final original = prefs.store;
      original.owner.attach(Object());
      original.owner.attach(original.actualStore, trustedPlugin: true);
      expect(original.current, false);
      await expectLater(
        owner.load(),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      expect(storage.values, isEmpty);
      expect(backing.writes, isEmpty);
    });
  });

  test('late producer cannot adopt a replacement preference store', () async {
    await _backed((prefs, backing) async {
      final producer = Completer<SharedPreferences>();
      final owner = ChubCredentialOwner(
        vault: vault,
        redaction: redaction,
        originalPreferences: producer.future,
      );
      final loading = owner.load();
      SharedPreferences.setMockInitialValues({_key: _backup});
      final replacement = await TrackedSharedPreferences.getInstance();
      producer.complete(replacement);
      final account = await loading;
      expect(account.unavailable, true);
      expect(storage.values, isEmpty);
      expect(backing.writes, isEmpty);
    });
  });

  test(
    'explicit exact retirement removes only the original key, not account metadata',
    () async {
      await _backed((prefs, backing) async {
        final owner = _owner(vault, prefs, redaction);
        await owner.load();
        expect(
          await owner.retireLegacyWithNativeConsent(confirmed: false),
          false,
        );
        expect(backing.writes, isEmpty);
        expect(
          await owner.retireLegacyWithNativeConsent(confirmed: true),
          true,
        );
        expect(prefs.getString(_key), isNull);
        expect(backing.writes, ['flutter.$_key']);
        expect(prefs.getString('gz_chub_user_name'), 'SYNTHETIC_CHUB_NAME');
        expect(prefs.getBool('gz_chub_nsfl'), true);
        expect(storage.values.values, [_legacy]);
        expect(storage.operations, isNot(contains('delete')));
      });
    },
  );

  test(
    'native/legacy mismatch refuses retirement without any remove',
    () async {
      await _backed((prefs, backing) async {
        await vault.store(_slot, _native);
        final owner = _owner(vault, prefs, redaction);
        await owner.load();
        expect(
          await owner.retireLegacyWithNativeConsent(confirmed: true),
          false,
        );
        expect(backing.writes, isEmpty);
        expect(prefs.getString(_key), _legacy);
      });
    },
  );

  test(
    'a delayed original remove cannot erase a queued backup setter',
    () async {
      await _backed((prefs, backing) async {
        final owner = _owner(vault, prefs, redaction);
        await owner.load();
        final entered = Completer<void>(), release = Completer<void>();
        backing.beforeRemove = () async {
          entered.complete();
          await release.future;
        };
        final retirement = owner.retireLegacyWithNativeConsent(confirmed: true);
        await entered.future;
        final backup = prefs.setString(_key, _backup);
        expect(backing.values['flutter.$_key'], _legacy);
        release.complete();
        expect(await retirement, false);
        expect(await backup, true);
        expect(backing.values['flutter.$_key'], _backup);
        expect(prefs.getString(_key), _backup);
        expect(storage.values.values, [_legacy]);
      });
    },
  );

  test(
    'disposed native setter settles verified backend write, never rollback deletes',
    () async {
      await _backed((prefs, backing) async {
        final owner = _owner(vault, prefs, redaction);
        final entered = Completer<void>(), release = Completer<void>();
        storage.beforeWrite = () async {
          entered.complete();
          await release.future;
        };
        final setting = owner.setApiKey(_native, userName: 'NEW_NAME');
        final observed = expectLater(
          setting,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        owner.dispose();
        release.complete();
        await observed;
        expect(storage.values.values, [_native]);
        expect(storage.operations.last, 'read');
        expect(backing.writes, isEmpty);
        expect(redaction.redactor.redactText(_native), '[REDACTED]');
      });
    },
  );

  test(
    'setter admission is rechecked inside the actual vault slot FIFO',
    () async {
      await _backed((prefs, backing) async {
        final owner = _owner(vault, prefs, redaction);
        final entered = Completer<void>(), release = Completer<void>();
        storage.beforeRead = () async {
          if (storage.reads == 1) {
            entered.complete();
            await release.future;
          }
        };
        final blocked = vault.metadata(_slot);
        await entered.future;
        final setting = owner.setApiKey(_native);
        final observed = expectLater(
          setting,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await pumpEventQueue();
        final loggingOut = owner.logout();
        release.complete();
        await blocked;
        await observed;
        await loggingOut;
        expect(storage.values.values, ['']);
        expect(storage.operations.where((op) => op == 'write').length, 1);
      });
    },
  );

  test(
    'in-flight native consumption does not block logout or publish stale results',
    () async {
      await _backed((prefs, backing) async {
        final owner = _owner(vault, prefs, redaction);
        await owner.load();
        final entered = Completer<void>(), release = Completer<void>();
        final consuming = owner.withApiKey((key) async {
          expect(key, _legacy);
          entered.complete();
          await release.future;
          return 7;
        });
        final observed = expectLater(
          consuming,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        await entered.future;
        final account = await owner.logout();
        expect(account.authenticated, false);
        expect(storage.values.values, ['']);
        release.complete();
        await observed;
      });
    },
  );

  test(
    'provider state never holds a key; stale load cannot repaint a setter/logout',
    () async {
      SharedPreferences.setMockInitialValues({_key: _legacy});
      final container = ProviderContainer(
        overrides: [credentialStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(chubAccountProvider.notifier);
      await notifier.setApiKey(_native, userName: 'NEW_NAME');
      await pumpEventQueue();
      expect(container.read(chubAccountProvider).isLoggedIn, true);
      expect(container.read(chubAccountProvider).userName, 'NEW_NAME');
      await notifier.logout();
      await pumpEventQueue();
      final account = container.read(chubAccountProvider);
      expect(account.isLoggedIn, false);
      expect(account.userName, isNull);
      expect(account.nsfl, false);
      expect(account.toString(), isNot(contains(_native)));
      expect(storage.values.values, ['']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_key), _legacy);
    },
  );
}
