import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';

import 'support_model_provider_fixture.dart';

Future<void> expectStoppedProjection(
  ModelProviderFixture f,
  SupportModelRunResult result,
  SupportModelPreview preview,
  List<String> order,
) async {
  expect(result.accepted, isTrue);
  expect(result.saved, isTrue);
  final message = result.message!;
  final item = f.state.activeMessages.singleWhere(
    (m) => m.id == preview.replyMessageId,
  );
  final durable = (await f.repo.getMessageById(preview.replyMessageId))!;
  expect(message.status, 'stopped');
  expect(item.status, message.status);
  expect(item.body, message.text);
  expect(item.id, message.id);
  expect(item.sessionId, message.sessionId);
  expect(item.runId, preview.runId);
  expect(item.runId, message.runId);
  expect(item.createdAt.millisecondsSinceEpoch, message.createdAt);
  expect(item.cards, isEmpty);
  expect(durable.status, message.status);
  expect(durable.body, message.text);
  expect(durable.createdAt, message.createdAt);
  expect(f.state.activeMessages.map((m) => m.id), order);
  expect(f.bridge.view.busy, isFalse);
  expect(
    f.sql.writes.where(
      (sql) => sql.startsWith('UPDATE') && sql.contains('support_messages'),
    ),
    hasLength(1),
    reason: 'Display reconciliation must not settle the original DB twice.',
  );
  for (final feed in f.feeds) {
    expect(feed.map((m) => m.id).toSet().length, feed.length);
    final user = feed.indexWhere((m) => m.id == preview.userMessageId);
    final reply = feed.indexWhere((m) => m.id == preview.replyMessageId);
    if (reply >= 0) expect(user, inInclusiveRange(0, reply - 1));
  }
}
