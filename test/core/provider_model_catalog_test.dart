import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/credentials/provider_models_endpoint.dart';
import 'package:glaze_flutter/core/llm/provider_model_catalog.dart';
import 'package:glaze_flutter/core/state/native_provider_runtime.dart';

import 'native_provider_transport_fixture.dart'
    show nativeTransportRow, nativeTransportProtocols;
import 'native_provider_fixture.dart';
import 'provider_model_catalog_fixture.dart';

const _key = 'SYNTHETIC_CATALOG_KEY_72';
void main() {
  for (final protocol in nativeTransportProtocols) {
    for (final native in [false, true]) {
      test(
        '$protocol ${native ? "vault" : "legacy"}: one authenticated catalog GET',
        () async {
          final h = ModelCatalogHarness(
            nativeTransportRow(protocol).copyWith(apiKey: native ? '' : _key),
          );
          addTearDown(h.close);
          if (native) {
            NativeProviderDestinationApproval? approval;
            if (protocol == 'custom_chat_completion') {
              approval = h.native.policy.confirmCustomDestination(
                h.native.policy.reviewCustomDestination(
                  connection: h.native.reference().connection,
                  purposes: const {NativeProviderPurpose.roleplay},
                  lifetime: h.native.lifetime,
                ),
              );
            }
            await h.native.store(secret: _key, destinationApproval: approval);
          }
          if (protocol == 'gemini') {
            h.response = jsonEncode({
              'models': [
                {'name': 'models/provider-next'},
                {'name': 'models/provider-first'},
                {'name': 'models/provider-next'},
              ],
            });
          }
          expect(await h.fetch(), ['provider-first', 'provider-next']);
          final wire = h.requests.single;
          expect(wire.method, 'GET');
          expect(wire.data, isNull);
          expect(
            wire.uri,
            providerModelsEndpoint(Uri.parse(h.native.row.endpoint), protocol),
          );
          expect(wire.uri.toString(), isNot(contains(_key)));
          expect(wire.followRedirects, isFalse);
          expect(wire.maxRedirects, 0);
          final header = switch (protocol) {
            'gemini' => 'x-goog-api-key',
            'anthropic' => 'x-api-key',
            _ => 'Authorization',
          };
          expect(
            wire.headers[header],
            protocol == 'gemini' || protocol == 'anthropic'
                ? _key
                : 'Bearer $_key',
          );
          expect(h.adapters.single.closed, isTrue);
          if (native) expect(h.native.row.apiKey, isEmpty);
        },
      );
    }
  }
  test('custom OpenRouter prefix is not rewritten to a standard host', () async {
    final h = ModelCatalogHarness(
      nativeTransportRow('openrouter').copyWith(
        endpoint:
            'https://custom.synthetic.example/company/api/v1/chat/completions',
        apiKey: _key,
      ),
    );
    addTearDown(h.close);
    await h.fetch();
    expect(
      h.requests.single.uri.toString(),
      'https://custom.synthetic.example/company/api/v1/models',
    );
  });
  test(
    'actual runtime exposes its same-vault catalog; no generation permission is granted',
    () async {
      final h = ModelCatalogHarness(nativeTransportRow('openai'));
      addTearDown(h.close);
      await h.native.store(secret: _key);
      final revisions = ConnectionRevisionRegistry();
      final root = NativeProviderRuntime(
        vault: h.native.genericVault,
        redaction: h.native.redaction,
        revisions: revisions,
        readSavedConnection: (_) async => h.native.row,
        adapterFactory: h.adapter,
        isOriginalRoot: () => h.current,
      );
      addTearDown(() {
        root.dispose();
        revisions.dispose();
      });
      expect(
        await root.models.fetchModelIds(
          connectionId: h.native.row.id,
          isCurrent: () => h.current,
          cancelToken: CancelToken(),
        ),
        ['provider-first', 'provider-next'],
      );
      expect(h.requests.single.method, 'GET');
    },
  );
  test(
    'catalog credential binding is GET-only and cannot grant a generation POST',
    () async {
      final h = ModelCatalogHarness(nativeTransportRow('openai'));
      addTearDown(h.close);
      await h.native.store(secret: _key);
      var invoked = false;
      final broker = NativeProviderCredentialBroker(
        credentials: h.native.credentials,
        transport: (binding, secret) async {
          invoked = true;
          expect(secret, _key);
          expect(binding.method, 'GET');
          binding.requireModelListRequest(
            uri: binding.modelsEndpoint,
            method: 'GET',
          );
          expect(
            () => binding.requireModelListRequest(
              uri: binding.modelsEndpoint,
              method: 'POST',
            ),
            throwsA(isA<NativeProviderException>()),
          );
          expect(
            () => binding.requireModelListRequest(
              uri: Uri.parse('https://other.example/v1/models'),
              method: 'GET',
            ),
            throwsA(isA<NativeProviderException>()),
          );
          expect(
            () => binding.requireFinalRequest(
              uri: Uri.parse(h.native.row.endpoint),
              method: 'POST',
              protocol: binding.route.protocol,
              purpose: binding.purpose,
              model: h.native.row.model,
              stream: true,
            ),
            throwsA(isA<NativeProviderException>()),
          );
        },
      );
      await broker.dispatchModelList(
        h.native.reference(),
        isCurrent: () => true,
      );
      expect(invoked, isTrue);
    },
  );
  for (final prepared in [false, true]) {
    test(
      '${prepared ? "prepared native" : "legacy"} public catalog has no borrowed key',
      () async {
        final h = ModelCatalogHarness(nativeTransportRow('openai'));
        addTearDown(h.close);
        if (prepared) await h.native.markPrepared();
        await h.fetch();
        expect(h.requests.single.headers.containsKey('Authorization'), isFalse);
      },
    );
  }
  for (final value in ['', '{broken record']) {
    test(
      'corrupt native record never borrows the legacy row key ($value)',
      () async {
        final h = ModelCatalogHarness(
          nativeTransportRow('openai').copyWith(apiKey: _key),
        );
        addTearDown(h.close);
        h.native.storage.values[h.native.nativeStorageKey] = value;
        await expectLater(
          h.fetch(),
          throwsA(isA<ProviderModelCatalogException>()),
        );
        expect(h.requests, isEmpty);
      },
    );
  }
  test(
    'retirement inside adapter construction refuses the final GET',
    () async {
      final h = ModelCatalogHarness(
        nativeTransportRow('openai').copyWith(apiKey: _key),
      );
      addTearDown(h.close);
      h.onFactory = () => h.current = false;
      await expectLater(
        h.fetch(),
        throwsA(isA<ProviderModelCatalogException>()),
      );
      expect(h.requests, isEmpty);
      expect(h.adapters.single.closed, isTrue);
    },
  );
  test(
    'response after retirement never returns options to a replacement UI',
    () async {
      final h = ModelCatalogHarness(
        nativeTransportRow('openai').copyWith(apiKey: _key),
      );
      addTearDown(h.close);
      final entered = Completer<void>(), release = Completer<void>();
      h.beforeResponse = () {
        entered.complete();
        return release.future;
      };
      final outcome = expectLater(
        h.fetch(),
        throwsA(isA<ProviderModelCatalogException>()),
      );
      await entered.future;
      h.current = false;
      release.complete();
      await outcome;
      expect(h.requests, hasLength(1));
      expect(h.adapters.single.closed, isTrue);
    },
  );
  test(
    'errors and redirects are fixed refusals, never generation fallbacks',
    () async {
      for (final status in [302, 401, 404, 429, 500]) {
        final h = ModelCatalogHarness(
          nativeTransportRow('openai').copyWith(apiKey: _key),
        );
        h.status = status;
        h.response = _key;
        try {
          await expectLater(
            h.fetch(),
            throwsA(
              isA<ProviderModelCatalogException>().having(
                (e) => e.toString(),
                'fixed error',
                isNot(contains(_key)),
              ),
            ),
          );
          expect(h.requests, hasLength(1));
          expect(h.adapters.single.closed, isTrue);
        } finally {
          h.close();
        }
      }
    },
  );
}
