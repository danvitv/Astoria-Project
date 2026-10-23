import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';

import 'native_provider_transport_fixture.dart';

void main() {
  test(
    'chat and memory jobs share the actual credential owner, never callback/cancel state',
    () async {
      final h = NativeTransportHarness('openai');
      await h.store(
        purposes: {
          NativeProviderPurpose.roleplay,
          NativeProviderPurpose.memoryBooks,
        },
      );
      final bodies = <String, StreamController<Uint8List>>{};
      var chatListened = false;
      var memoryListened = false;
      final chatBody = StreamController<Uint8List>(
        onListen: () => chatListened = true,
      );
      final memoryBody = StreamController<Uint8List>(
        onListen: () => memoryListened = true,
      );
      final entered = Completer<void>();
      h.respond = (wire) async {
        final name =
            (wire.body['messages'] as List).single['content'] as String;
        bodies[name] = name == 'chat' ? chatBody : memoryBody;
        if (bodies.length == 2) entered.complete();
        return ResponseBody(
          bodies[name]!.stream,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/event-stream'],
          },
        );
      };
      final chatToken = CancelToken();
      final memoryToken = CancelToken();
      final chatUpdates = <String>[];
      final memoryUpdates = <String>[];
      final chatComplete = <String>[];
      final memoryComplete = <String>[];
      Future<void>? chat;
      Future<void>? memory;
      try {
        chat = h.factory
            .pick('openai')
            .stream(
              request: h.request(
                messages: const [
                  {'role': 'user', 'content': 'chat'},
                ],
              ),
              cancelToken: chatToken,
              onUpdate: (text, _) => chatUpdates.add(text),
              onComplete: (text, _, {rawResponseJson}) =>
                  chatComplete.add(text),
            );
        memory = h.factory
            .pick('openai')
            .stream(
              request: h.request(
                purpose: NativeProviderPurpose.memoryBooks,
                messages: const [
                  {'role': 'user', 'content': 'memory'},
                ],
              ),
              cancelToken: memoryToken,
              onUpdate: (text, _) => memoryUpdates.add(text),
              onComplete: (text, _, {rawResponseJson}) =>
                  memoryComplete.add(text),
            );
        await entered.future;
        chatToken.cancel();
        bodies['memory']!.add(
          Uint8List.fromList(
            utf8.encode(
              nativeTransportSse(
                'openai',
                text: 'memory owned ',
                reasoning: '',
              ),
            ),
          ),
        );
        await Future.wait([chat, memory]);
        expect(h.wires, hasLength(2));
        expect(chatComplete, isEmpty);
        expect(chatUpdates, isEmpty);
        expect(memoryComplete, ['memory owned ']);
        expect(memoryUpdates.join(), 'memory owned ');
        expect(memoryToken.isCancelled, isFalse);
        expect(h.adapters.every((adapter) => adapter.closed), isTrue);
      } finally {
        chatToken.cancel();
        memoryToken.cancel();
        try {
          await Future.wait<void>([?chat, ?memory]);
        } finally {
          // An early failure can leave a single-subscription body unlistened.
          // Drain only those unused streams so awaited close can also settle.
          final chatDrain = chatListened ? null : chatBody.stream.drain<void>();
          final memoryDrain = memoryListened
              ? null
              : memoryBody.stream.drain<void>();
          await Future.wait<void>([
            chatBody.close(),
            memoryBody.close(),
            ?chatDrain,
            ?memoryDrain,
          ]);
        }
      }
    },
  );

  for (final enabled in [true, false]) {
    test(
      'even disabled native-row extras/auth mutations are conflicting ($enabled)',
      () async {
        final h = NativeTransportHarness('openai');
        await h.store();
        h.core.row = h.core.row.copyWith(
          extraRequestParameters: [
            ExtraRequestParameter(
              key: 'headers.Authorization',
              value: nativeCanary,
              enabled: enabled,
            ),
          ],
        );
        final auth = h.core.reference();
        final request = ChatTransportRequest.fromApiConfig(
          h.core.row,
          savedConnectionAuth: auth,
          messages: const [
            {'role': 'user', 'content': 'safe'},
          ],
        );
        await h.run(input: request);
        expect(h.wires, isEmpty);
        expect(h.legacy.requests, isEmpty);
        expect(h.errors, hasLength(1));
        expect(h.errors.single.toString(), isNot(contains(nativeCanary)));
      },
    );
  }
}
