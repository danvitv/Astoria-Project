import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_lifecycle_test.dart' as fixtures;

ChatSession _largeChat() {
  final reasoning = 'retained Studio evidence Ж\n' * (512 * 1024);
  final variation = AgentSwipe(
    content: 'retained final variation',
    reasoning: reasoning,
    studioOutputs: const [
      {'id': 'ledger', 'name': 'Ledger', 'content': 'retained Studio output'},
    ],
    parentSwipeId: 0,
  );
  return fixtures
      .makeChat('large-chat')
      .copyWith(
        messages: [
          const ChatMessage(
            id: 'user-1',
            role: 'user',
            content: 'First message',
          ),
          ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: variation.content,
            reasoning: reasoning,
            swipes: const ['retained original variation'],
            agentSwipes: [variation],
            studioOutputs: variation.studioOutputs,
            swipesMeta: [
              {
                'agentSwipes': [variation.toJson()],
                'agentSwipeId': 0,
              },
            ],
          ),
          const ChatMessage(
            id: 'user-2',
            role: 'user',
            content: 'Latest message',
          ),
        ],
      );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'engine pushes and pulls a >30MiB chat without losing variations',
    () async {
      final chat = _largeChat();
      final expected = jsonEncode(chat.toJson());
      expect(utf8.encode(expected).length, greaterThan(maxSyncPayloadBytes));
      final sender = fixtures.SyncWorld();
      sender.cloud.requireEnsuredParentForUpload = true;
      await sender.chats.put(chat);
      await sender.engine.pushEntities(onProgress: (_) {});
      final manifest = await sender.manifestProvider.readLocalManifest();
      final entry = manifest.entries[entryKey('chat', chat.id)]!;
      final root = jsonDecode(sender.cloud.files[entry.path]!) as Map;
      expect(root['__syncPayload'], isTrue);
      expect(root['type'], 'chat');
      expect(root['jsonBytes'], greaterThan(maxSyncPayloadBytes));
      expect(
        sender.cloud.files.values.every(
          (raw) => utf8.encode(raw).length <= maxSyncPayloadBytes,
        ),
        isTrue,
      );

      final receiver = fixtures.SyncWorld();
      receiver.cloud.files.addAll(sender.cloud.files);
      await receiver.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (_) {},
      );
      final restored = await receiver.chats.getById(chat.id);
      expect(restored, isNotNull);
      expect(jsonEncode(restored!.toJson()), expected);
      expect(
        (await receiver.manifestProvider.readLocalManifest())
            .entries[entry.key]!
            .hash,
        entry.hash,
      );

      // A chat tombstone cleans only its own immutable parts, never another owner.
      final otherPath = '${entry.path}-other.parts/retained.b64';
      sender.cloud.files[otherPath] = 'other chat history';
      await SyncSerialization.deleteCloudFileIfExists(sender.cloud, entry);
      expect(sender.cloud.files.containsKey(entry.path), isFalse);
      expect(
        sender.cloud.files.keys.any(
          (path) => path.startsWith('${entry.path}.parts/'),
        ),
        isFalse,
      );
      expect(sender.cloud.files[otherPath], 'other chat history');
    },
  );

  test(
    'corrupt compressed chat is neither written nor accepted on pull',
    () async {
      final sender = fixtures.SyncWorld();
      final chat = fixtures
          .makeChat('corrupt-chat')
          .copyWith(
            messages: [
              ChatMessage(
                id: 'message',
                role: 'assistant',
                content: 'retained Ж ' * 65536,
              ),
            ],
          );
      await sender.chats.put(chat);
      await sender.engine.pushEntities(onProgress: (_) {});
      final entry = (await sender.manifestProvider.readLocalManifest())
          .entries[entryKey('chat', chat.id)]!;
      final root = jsonDecode(sender.cloud.files[entry.path]!) as Map;
      final partPath = '${entry.path}.parts/${root['chunks'][0]['hash']}.b64';
      final raw = sender.cloud.files[partPath]!;
      sender.cloud.files[partPath] =
          '${raw[0] == 'A' ? 'B' : 'A'}${raw.substring(1)}';

      final receiver = fixtures.SyncWorld();
      final original = fixtures.makeChat(chat.id);
      await receiver.chats.put(original);
      receiver.cloud.files.addAll(sender.cloud.files);
      await expectLater(
        receiver.engine.pullEntities(onProgress: (_) {}, onConflict: (_) {}),
        throwsA(isA<Exception>()),
      );
      expect(await receiver.chats.getById(chat.id), original);
      expect(
        (await receiver.manifestProvider.readLocalManifest()).entries
            .containsKey(entry.key),
        isFalse,
      );
    },
  );
}
