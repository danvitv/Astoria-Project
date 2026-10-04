import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

const _enabled = bool.fromEnvironment('CHAT_SYNTHETIC_PERF');
const _samples = 20;

/// Opt-in desktop diagnostic, not an Android frame-time or battery benchmark.
/// Uses the real repository and the production-style background DB executor.
void main() {
  for (final rich in [false, true]) {
    for (final count in [50, 500, 2000]) {
      test(
        'draft persistence: $count messages, rich=$rich',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'astoria_synthetic_',
          );
          final db = AppDatabase.forTesting(
            NativeDatabase.createInBackground(
              File('${directory.path}/synthetic.db'),
            ),
          );
          try {
            final repo = ChatRepo(db);
            final session = _session(count, rich: rich);
            final json = jsonEncode(
              session.messages.map((message) => message.toJson()).toList(),
            );
            await repo.put(session);
            for (var index = 0; index < 4; index++) {
              await repo.updateDraftIfMessageCount(
                sessionId: session.id,
                draft: 'warmup $index',
                expectedMessageCount: count,
              );
            }

            final saveTimes = <int>[];
            final heartbeatGaps = <int>[];
            final idleHeartbeatGaps = <int>[];
            final clock = Stopwatch()..start();
            var lastTick = clock.elapsedMicroseconds;
            var largestGap = 0;
            final heartbeat = Timer.periodic(const Duration(milliseconds: 1), (
              _,
            ) {
              final now = clock.elapsedMicroseconds;
              largestGap = max(largestGap, now - lastTick);
              lastTick = now;
            });
            try {
              for (var index = 0; index < _samples; index++) {
                // Establish a live event-loop tick before measuring each save.
                largestGap = 0;
                await Future<void>.delayed(const Duration(milliseconds: 5));
                idleHeartbeatGaps.add(largestGap);
                largestGap = 0;
                final watch = Stopwatch()..start();
                final saved = await repo.updateDraftIfMessageCount(
                  sessionId: session.id,
                  draft: 'Synthetic draft $index: следующая сцена.',
                  expectedMessageCount: count,
                );
                saveTimes.add(watch.elapsedMicroseconds);
                // Include any decode that just delayed the pending heartbeat.
                largestGap = max(
                  largestGap,
                  clock.elapsedMicroseconds - lastTick,
                );
                heartbeatGaps.add(largestGap);
                expect(saved, contains('Synthetic draft $index'));
              }
            } finally {
              heartbeat.cancel();
            }
            // Outside the measured path: the narrow write preserves history.
            expect((await repo.getById(session.id))?.messages.length, count);

            // Separate the real _toModel history-decoding operation from SQL /
            // isolate messaging. This is a diagnostic control, not an alternative
            // persistence implementation. Include ChatMessage conversion.
            List<ChatMessage> decode() => (jsonDecode(json) as List)
                .map(
                  (item) => ChatMessage.fromJson(item as Map<String, dynamic>),
                )
                .toList();
            for (var index = 0; index < 4; index++) {
              expect(decode().length, count);
            }
            final decodeTimes = <int>[];
            for (var index = 0; index < _samples; index++) {
              final watch = Stopwatch()..start();
              final messages = decode();
              decodeTimes.add(watch.elapsedMicroseconds);
              expect(messages.last.id, 'message-${count - 1}');
            }
            final result = {
              'scenario': 'draft',
              'host': Platform.operatingSystem,
              'dart': Platform.version.split(' ').first,
              'messages': count,
              'rich': rich,
              'historyUtf8Bytes': utf8.encode(json).length,
              'samples': _samples,
              'saveMs': _summary(saveTimes),
              'decodeMs': _summary(decodeTimes),
              'idleHeartbeatGapMs': _summary(idleHeartbeatGaps),
              'largestHeartbeatGapPerSaveMs': _summary(heartbeatGaps),
            };
            // ignore: avoid_print
            print('CHAT_SYNTHETIC ${jsonEncode(result)}');
          } finally {
            await db.close();
            await directory.delete(recursive: true);
          }
        },
        skip: !_enabled,
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }
  test(
    'draft with the app-wide session metadata subscription',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'astoria_synthetic_watch_',
      );
      final db = AppDatabase.forTesting(
        NativeDatabase.createInBackground(File('${directory.path}/watch.db')),
      );
      StreamSubscription<List<SessionMetadata>>? subscription;
      Timer? heartbeat;
      try {
        final repo = ChatRepo(db);
        final session = _session(2000, rich: true);
        await repo.put(session);
        await repo.put(_session(500, rich: true).copyWith(id: 'other'));
        // Device profiles exposed large session vars / last-message swipes,
        // which the first synthetic history fixture did not exercise.
        final payload = List.filled(20000, 'Unrelated Studio payload. ').join();
        for (var index = 0; index < 30; index++) {
          await repo.put(
            ChatSession(
              id: 'metadata-$index',
              characterId: 'synthetic-character',
              sessionIndex: index,
              sessionVars: {'sessionName': 'Fixture $index', 'state': payload},
              messages: [
                ChatMessage(
                  id: 'last',
                  role: 'assistant',
                  content: 'Preview',
                  swipes: [payload],
                  reasoning: payload,
                ),
              ],
            ),
          );
        }
        final ready = Completer<void>();
        var emissions = 0;
        subscription = repo.watchAllSessionMetadata().listen((metadata) {
          expect(metadata.length, 32);
          emissions++;
          if (!ready.isCompleted) ready.complete();
        });
        await ready.future;
        final gaps = <int>[];
        final saveTimes = <int>[];
        final clock = Stopwatch()..start();
        var lastTick = clock.elapsedMicroseconds;
        var largestGap = 0;
        heartbeat = Timer.periodic(const Duration(milliseconds: 1), (_) {
          final now = clock.elapsedMicroseconds;
          largestGap = max(largestGap, now - lastTick);
          lastTick = now;
        });
        for (var index = 0; index < _samples; index++) {
          largestGap = 0;
          final watch = Stopwatch()..start();
          await repo.updateDraftIfMessageCount(
            sessionId: session.id,
            draft: 'Subscribed draft $index',
            expectedMessageCount: 2000,
          );
          saveTimes.add(watch.elapsedMicroseconds);
          // Includes asynchronous metadata delivery, not just the write future.
          await Future<void>.delayed(const Duration(milliseconds: 30));
          gaps.add(max(largestGap, clock.elapsedMicroseconds - lastTick));
        }
        // Drain queued reads before reporting the total notification count.
        await repo.getAllSessionMetadata();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // ignore: avoid_print
        print(
          'CHAT_SYNTHETIC ${jsonEncode({
            'scenario': 'draft_with_metadata_watch',
            'host': Platform.operatingSystem,
            'messagesPerSession': [2000, 500],
            'largeMetadataSessions': 30,
            'rich': true,
            'samples': _samples,
            'metadataEmissions': emissions,
            'saveMs': _summary(saveTimes),
            'largestHeartbeatGapPerSaveMs': _summary(gaps),
          })}',
        );
      } finally {
        heartbeat?.cancel();
        await subscription?.cancel();
        await db.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Map<String, double> _summary(List<int> samples) {
  final sorted = [...samples]..sort();
  double percentile(double fraction) =>
      sorted[(fraction * sorted.length).ceil() - 1] / 1000;
  return {
    'p50': percentile(0.50),
    'p95': percentile(0.95),
    'max': sorted.last / 1000,
  };
}

ChatSession _session(int count, {required bool rich}) {
  final prose = List.filled(
    16,
    'Персонаж оглядел комнату и продолжил разговор. A measured scene, not a timed skip. ',
  ).join();
  return ChatSession(
    id: 'synthetic',
    characterId: 'synthetic-character',
    sessionIndex: 0,
    messages: [
      for (var index = 0; index < count; index++)
        ChatMessage(
          id: 'message-$index',
          role: index.isEven ? 'user' : 'assistant',
          content: '$index: $prose',
          timestamp: 1700000000000 + index,
          swipes: rich && index.isOdd
              ? [prose, '$prose alternative']
              : const [],
          reasoning: rich && index.isOdd ? prose.substring(0, 240) : null,
          studioOutputs: rich && index.isOdd
              ? [
                  {
                    'agentName': 'Controller',
                    'response': prose.substring(0, 400),
                  },
                ]
              : const [],
          agentSwipes: rich && index.isOdd
              ? [AgentSwipe(content: prose, kind: 'cleaned')]
              : const [],
          imagePath: rich && index % 10 == 0
              ? 'synthetic/image-$index.png'
              : null,
        ),
    ],
  );
}
