import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_broker.dart';
import 'package:glaze_flutter/core/credentials/credential_route.dart';
import 'package:glaze_flutter/core/credentials/credential_slot.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';

import 'fake_credential_storage.dart';

void main() {
  const canary = 'BROKER_TEST_ONLY_CANARY';
  final slot = CredentialSlot(domain: 'llm', id: 'connection-1');
  final route = CredentialRoute(
    endpoint: 'https://provider.example/v1/chat/completions',
    protocol: CredentialProtocol.openAiChatCompletions,
    purpose: CredentialPurpose.chat,
  );
  late FakeCredentialStorage storage;
  late CredentialVault vault;

  setUp(() async {
    storage = FakeCredentialStorage();
    vault = CredentialVault(storage: storage, buildChannel: 'dev');
    await vault.store(slot, canary);
  });

  test('only constructor-injected native transport receives secret', () async {
    var sent = 0;
    final broker = CredentialBroker(
      vault: vault,
      approve: (candidate, destination) async =>
          candidate == slot && destination == route,
      transport: (destination, secret) async {
        expect(destination, route);
        expect(secret, canary);
        sent++;
      },
    );
    final handle = await broker.bind(slot, route);
    expect(handle.toString(), 'CredentialHandle');
    expect((await broker.metadata(handle)).characterCount, canary.length);
    await broker.dispatch(handle, route: route);
    expect(sent, 1);
    expect(broker.toString(), isNot(contains(canary)));
  });

  test(
    'host/path/protocol/purpose changes deny before any vault read/send',
    () async {
      var sent = false;
      final broker = CredentialBroker(
        vault: vault,
        approve: (_, destination) async => destination == route,
        transport: (_, _) async {
          sent = true;
        },
      );
      final handle = await broker.bind(slot, route);
      final reads = storage.reads;
      for (final changed in [
        CredentialRoute(
          endpoint: 'https://attacker.example/v1/chat/completions',
          protocol: route.protocol,
          purpose: route.purpose,
        ),
        CredentialRoute(
          endpoint: 'https://provider.example/other',
          protocol: route.protocol,
          purpose: route.purpose,
        ),
        CredentialRoute(
          endpoint: route.endpoint.toString(),
          protocol: CredentialProtocol.custom,
          purpose: route.purpose,
        ),
        CredentialRoute(
          endpoint: route.endpoint.toString(),
          protocol: route.protocol,
          purpose: CredentialPurpose.modelDiscovery,
        ),
      ]) {
        await expectLater(
          broker.dispatch(handle, route: changed),
          throwsA(
            isA<CredentialBrokerException>().having(
              (e) => e.failure,
              'failure',
              CredentialBrokerFailure.denied,
            ),
          ),
        );
        await expectLater(
          broker.bind(slot, changed),
          throwsA(isA<CredentialBrokerException>()),
        );
      }
      expect(storage.reads, reads);
      expect(sent, isFalse);
    },
  );

  test(
    'native approval receives exact slot/route and creates separate capability',
    () async {
      final approved = Completer<bool>();
      final secondSlot = CredentialSlot(domain: 'llm', id: 'other');
      final other = CredentialRoute(
        endpoint: 'https://custom.example/chat',
        protocol: CredentialProtocol.custom,
        purpose: CredentialPurpose.assistant,
      );
      var approvalCalls = 0;
      final broker = CredentialBroker(
        vault: vault,
        approve: (candidate, destination) {
          expect(candidate, secondSlot);
          expect(destination, other);
          approvalCalls++;
          return approved.future;
        },
        transport: (_, _) async {},
      );
      final binding = broker.bind(secondSlot, other);
      expect(approvalCalls, 1);
      expect(storage.reads, 1); // initial store readback only
      approved.complete(true);
      final handle = await binding;
      expect((await broker.metadata(handle)).configured, isFalse);
    },
  );

  test(
    'revocation during delayed vault read prevents late native send',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var sent = false;
      storage.beforeRead = () async {
        entered.complete();
        await release.future;
      };
      final broker = CredentialBroker(
        vault: vault,
        approve: (_, _) async => true,
        transport: (_, _) async {
          sent = true;
        },
      );
      final handle = await broker.bind(slot, route);
      final dispatch = broker.dispatch(handle, route: route);
      final assertion = expectLater(
        dispatch,
        throwsA(
          isA<CredentialBrokerException>().having(
            (error) => error.failure,
            'failure',
            CredentialBrokerFailure.revoked,
          ),
        ),
      );
      await entered.future;
      broker.revoke(handle);
      release.complete();
      await assertion;
      expect(sent, isFalse);
    },
  );

  test(
    'revocation/cross-broker handle cannot reuse approved capability',
    () async {
      CredentialBroker makeBroker() => CredentialBroker(
        vault: vault,
        approve: (_, _) async => true,
        transport: (_, _) async => fail('must not send'),
      );
      final broker = makeBroker();
      final handle = await broker.bind(slot, route);
      await expectLater(
        makeBroker().dispatch(handle, route: route),
        throwsA(isA<CredentialBrokerException>()),
      );
      broker.revoke(handle);
      await expectLater(
        broker.metadata(handle),
        throwsA(isA<CredentialBrokerException>()),
      );
      await expectLater(
        broker.dispatch(handle, route: route),
        throwsA(isA<CredentialBrokerException>()),
      );
    },
  );

  test(
    'revocation during metadata read does not publish stale metadata',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      storage.beforeRead = () async {
        entered.complete();
        await release.future;
      };
      final broker = CredentialBroker(
        vault: vault,
        approve: (_, _) async => true,
        transport: (_, _) async {},
      );
      final handle = await broker.bind(slot, route);
      final assertion = expectLater(
        broker.metadata(handle),
        throwsA(isA<CredentialBrokerException>()),
      );
      await entered.future;
      broker.revoke(handle);
      release.complete();
      await assertion;
    },
  );

  test(
    'slot revocation during vault read reports revoked without sending',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      storage.beforeRead = () async {
        entered.complete();
        await release.future;
      };
      final broker = CredentialBroker(
        vault: vault,
        approve: (_, _) async => true,
        transport: (_, _) async => fail('must not send'),
      );
      final handle = await broker.bind(slot, route);
      final assertion = expectLater(
        broker.dispatch(handle, route: route),
        throwsA(
          isA<CredentialBrokerException>().having(
            (e) => e.failure,
            'failure',
            CredentialBrokerFailure.revoked,
          ),
        ),
      );
      await entered.future;
      broker.revokeSlot(slot);
      release.complete();
      await assertion;
    },
  );

  test('non-revocation vault/transport failures remain unavailable', () async {
    final broker = CredentialBroker(
      vault: vault,
      approve: (_, _) async => true,
      transport: (_, _) async {
        throw StateError(canary);
      },
    );
    final handle = await broker.bind(slot, route);
    final unavailable = throwsA(
      isA<CredentialBrokerException>().having(
        (e) => e.failure,
        'failure',
        CredentialBrokerFailure.unavailable,
      ),
    );
    await expectLater(broker.dispatch(handle, route: route), unavailable);
    storage.readError = StateError(canary);
    await expectLater(broker.dispatch(handle, route: route), unavailable);
  });

  test(
    'approval, vault and transport secret-bearing exceptions stay opaque',
    () async {
      final denied = CredentialBroker(
        vault: vault,
        approve: (_, _) async {
          throw StateError(canary);
        },
        transport: (_, _) async {},
      );
      await expectLater(
        denied.bind(slot, route),
        throwsA(predicate((Object e) => !e.toString().contains(canary))),
      );
      final broker = CredentialBroker(
        vault: vault,
        approve: (_, _) async => true,
        transport: (_, _) async {
          throw StateError(canary);
        },
      );
      final handle = await broker.bind(slot, route);
      await expectLater(
        broker.dispatch(handle, route: route),
        throwsA(predicate((Object e) => !e.toString().contains(canary))),
      );
      storage.readError = StateError(canary);
      await expectLater(
        broker.metadata(handle),
        throwsA(predicate((Object e) => !e.toString().contains(canary))),
      );
    },
  );

  test(
    'slot revocation invalidates all its handles but not unrelated slots',
    () async {
      final broker = CredentialBroker(
        vault: vault,
        approve: (_, _) async => true,
        transport: (_, _) async {},
      );
      final first = await broker.bind(slot, route);
      final second = await broker.bind(slot, route);
      final otherSlot = CredentialSlot(domain: 'llm', id: 'other');
      final other = await broker.bind(otherSlot, route);
      broker.revokeSlot(CredentialSlot(domain: slot.domain, id: slot.id));
      for (final handle in [first, second]) {
        await expectLater(
          broker.metadata(handle),
          throwsA(
            isA<CredentialBrokerException>().having(
              (e) => e.failure,
              'failure',
              CredentialBrokerFailure.revoked,
            ),
          ),
        );
      }
      expect((await broker.metadata(other)).configured, isFalse);
      final rebound = await broker.bind(slot, route);
      expect((await broker.metadata(rebound)).configured, isTrue);
    },
  );

  test('slot epoch rejects approvals that finish after revocation', () async {
    for (final outcome in [true, false, null]) {
      final approval = Completer<bool>();
      final broker = CredentialBroker(
        vault: vault,
        approve: (_, _) => approval.future,
        transport: (_, _) async => fail('must not send'),
      );
      final pending = broker.bind(slot, route);
      final assertion = expectLater(
        pending,
        throwsA(
          isA<CredentialBrokerException>().having(
            (e) => e.failure,
            'failure',
            CredentialBrokerFailure.revoked,
          ),
        ),
      );
      broker.revokeSlot(slot);
      if (outcome == null) {
        approval.completeError(StateError(canary));
      } else {
        approval.complete(outcome);
      }
      await assertion;
    }
  });

  test('other-slot revocation does not cancel pending approval', () async {
    final approval = Completer<bool>();
    final broker = CredentialBroker(
      vault: vault,
      approve: (_, _) => approval.future,
      transport: (_, _) async {},
    );
    final pending = broker.bind(slot, route);
    broker.revokeSlot(CredentialSlot(domain: 'llm', id: 'other'));
    approval.complete(true);
    expect((await broker.metadata(await pending)).configured, isTrue);
  });

  test(
    'routes reject ambiguous/credential-bearing URLs without echoing input',
    () {
      for (final endpoint in [
        'http://provider.example/chat',
        'https://$canary@provider.example/chat',
        'https://provider.example/chat?key=$canary',
        'https://provider.example/chat#$canary',
        'https://',
        'https://provider.example/%zz$canary',
        'https://provider.example/ bad',
        'https://provider.example/v1/chat?',
        'https://provider.example/v1/chat#',
        'https://provider.example/v1/../chat',
        'https://provider.example/v1/./chat',
        'https://provider.example/v1//chat',
        'https://provider.example//',
        'https://provider.example/v1/%2e%2e/chat',
        'https://provider.example/v1/%2E/chat',
        'https://provider.example/v1/%2f/chat',
      ]) {
        expect(
          () => CredentialRoute(
            endpoint: endpoint,
            protocol: route.protocol,
            purpose: route.purpose,
          ),
          throwsA(predicate((Object e) => !e.toString().contains(canary))),
        );
      }
    },
  );
}
