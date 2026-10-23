import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';

import 'native_provider_consumer_memory_fixture.dart';

const _messages = [
  ChatMessage(
    id: 'm1',
    role: 'user',
    content: 'Synthetic history',
    timestamp: 1,
  ),
];
const _draft = MemoryDraft(id: 'draft', messageIds: ['m1']);

Future<MemoryDraft> _generate(
  NativeMemoryConsumerFixture f, {
  PipelineSettings pipeline = const PipelineSettings(),
  CancelToken? token,
}) => f.own(
  f.generator().generate(
    draft: _draft,
    settings: const MemoryBookSettings(),
    pipeline: pipeline,
    messages: _messages,
    charId: 'character',
    sessionId: 'original-session',
    sessionVars: const {},
    cancelToken: token,
  ),
);

Future<void> _withFixture(
  Future<void> Function(NativeMemoryConsumerFixture fixture) body,
) async {
  final isolation = NativeRoleplayIsolation();
  await isolation.run(() async {
    final f = NativeMemoryConsumerFixture(isolation);
    try {
      await body(f);
    } finally {
      await f.close();
    }
  });
}

void main() {
  test(
    'actual settings MemoryDraftGenerator prepares source before prompt and wire',
    () => _withFixture((f) async {
      await f.source.wire.store(purposes: {NativeProviderPurpose.memoryBooks});
      f.source.wire.response = nativeTransportJson('openai');
      f.source.wire.contentType = 'application/json';
      f.character.beforeRead = () async {
        expect(f.source.wire.wires, isEmpty);
        expect(f.source.wire.legacy.requests, isEmpty);
      };
      final result = await _generate(f, token: CancelToken());
      expect(result.content, contains('Visible text'));
      expect(result.sourceManifest, isNotNull);
      expect(f.source.wire.wires.length, 1);
      expect(
        f.source.wire.wires.single.headers.values.join(),
        contains(nativeCanary),
      );
      expect(
        f.source.wire.wires.single.body.toString(),
        isNot(contains(nativeCanary)),
      );
    }),
  );

  test(
    'actual Memory model override refuses BEFORE reading prompt sources',
    () => _withFixture((f) async {
      await f.source.wire.store(purposes: {NativeProviderPurpose.memoryBooks});
      const globals = PipelineSettings();
      final pipeline = globals.copyWith(
        memoryBookApi: globals.memoryBookApi.copyWith(
          generationModel: 'unbound-memory-model',
        ),
      );
      await expectLater(
        _generate(f, pipeline: pipeline),
        throwsNative(NativeProviderFailure.denied),
      );
      expect(f.character.reads, 0);
      expect(f.source.wire.wires, isEmpty);
    }),
  );

  test(
    'held Memory API-source read plus ABA cannot late-mint auth',
    () => _withFixture((f) async {
      await f.source.wire.store(purposes: {NativeProviderPurpose.memoryBooks});
      final gate = f.newGate();
      f.beforeApiRead = gate.hold;
      final pending = _generate(f);
      await f.waitUntilGateEntered(gate, pending);
      f.source.wire.core.ordinaryMutation();
      f.source.wire.core.ordinaryMutation();
      gate.release();
      await expectLater(pending, throwsNative(NativeProviderFailure.stale));
      expect(f.character.reads, 0);
      expect(f.source.wire.wires, isEmpty);
    }),
  );

  for (final change in ['stop', 'session', 'ordinary', 'rotation']) {
    test(
      'Memory prompt-source await revalidates original scope: $change',
      () => _withFixture((f) async {
        await f.source.wire.store(
          purposes: {NativeProviderPurpose.memoryBooks},
        );
        final gate = f.newGate();
        f.character.beforeRead = gate.hold;
        final token = CancelToken();
        final pending = _generate(f, token: token);
        await f.waitUntilGateEntered(gate, pending);
        if (change == 'stop') token.cancel();
        if (change == 'session') f.source.sessionId = 'replacement';
        if (change == 'ordinary') f.source.wire.core.ordinaryMutation();
        if (change == 'rotation') {
          await f.source.wire.store(
            purposes: {NativeProviderPurpose.memoryBooks},
          );
        }
        gate.release();
        await expectLater(pending, throwsNative(NativeProviderFailure.stale));
        expect(f.source.wire.wires, isEmpty);
      }),
    );
  }
}
