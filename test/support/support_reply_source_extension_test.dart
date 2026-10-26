import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';

import 'helpers/support_guarded_reply_fixture.dart';

void main() {
  late GuardedReplyFixture f;
  late SupportMessage user;
  late SupportReplyReservation pending;
  setUp(() async {
    f = GuardedReplyFixture();
    await f.seed();
    user = (await f.repo.appendCurrentUser(
      message: const SupportMessage(
        id: 'synthetic-origin-user',
        sessionId: 'synthetic-original-session',
        role: 'user',
        body: 'Synthetic current question',
        runId: 'synthetic-run',
        status: 'complete',
        createdAt: 4,
      ),
      isCurrent: f.isCurrent,
    ))!;
    final preparing = (await f.repo.reserveOrderedReply(
      message: GuardedReplyFixture.message,
      originatingUser: user,
      provenanceJson: _facts(user),
      isCurrent: f.isCurrent,
    ))!;
    final message = (await f.repo.settleReply(
      expected: preparing,
      status: 'pending',
      isCurrent: f.isCurrent,
    ))!;
    pending = (message: message, provenance: preparing.provenance);
  });
  tearDown(() => f.close());

  Future<SupportReplySourceObservation> observe() async =>
      (await f.repo.readReplyForSourceExtension(
        expected: pending,
        originatingUser: user,
        isCurrent: f.isCurrent,
      ))!;
  Future<SupportReplyReservation?> extend(
    SupportReplySourceObservation observation, {
    String? facts,
  }) => f.repo.extendReplySources(
    expected: observation,
    provenanceJson: facts ?? _facts(user, disclosures: [_disclosure()]),
    isCurrent: f.isCurrent,
  );

  test(
    'only protected metadata changes; exact new reservation settles; original observation cannot replay',
    () async {
      final observation = await observe(), beforeReply = await f.replyRow();
      final next = (await extend(observation))!;
      expect(next.message, pending.message);
      expect(await f.replyRow(), beforeReply);
      final decoded = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
        next.provenance.protectedFactsJson,
      ).recipe!;
      expect(decoded.toolDisclosures!.single.sourceId, 'synthetic-game');
      expect(decoded.currentUserMessageId, user.id);
      expect(decoded.originalRanges, isEmpty);
      expect(await extend(observation), isNull);
      expect(
        await f.repo.settleReply(
          expected: pending,
          status: 'complete',
          body: 'stale',
          isCurrent: f.isCurrent,
        ),
        isNull,
      );
      final settled = await f.repo.settleReply(
        expected: next,
        status: 'complete',
        body: 'Synthetic result',
        isCurrent: f.isCurrent,
      );
      expect(settled!.body, 'Synthetic result');
    },
  );

  test(
    'append retains every old disclosure and cannot replace/drop/reorder or mutate header',
    () async {
      final first = (await extend(await observe()))!;
      pending = first;
      final secondObservation = await observe();
      final before = await f.rows();
      for (final facts in [
        _facts(user, disclosures: []),
        _facts(user, disclosures: [_disclosure(source: 'other')]),
        _facts(
          user,
          disclosures: [
            _disclosure(),
            _disclosure(source: 'other'),
          ],
          runId: 'different-run',
        ),
        _facts(
          user,
          disclosures: [
            _disclosure(),
            _disclosure(source: 'other'),
          ],
          ranges: [
            SupportModelSourceRange(
              domain: SupportModelSourceDomain.game,
              sessionId: 'undeclared',
              orderedMessageIds: ['id'],
            ),
          ],
        ),
      ]) {
        expect(await extend(secondObservation, facts: facts), isNull);
      }
      expect(await f.rows(), before);
      final next = (await extend(
        secondObservation,
        facts: _facts(
          user,
          disclosures: [
            _disclosure(),
            _disclosure(source: 'other'),
          ],
        ),
      ))!;
      expect(
        SupportModelProvenanceCodec.decodeFromEncryptedStorage(
          next.provenance.protectedFactsJson,
        ).recipe!.toolDisclosures!.map((d) => d.sourceId),
        ['synthetic-game', 'other'],
      );
    },
  );

  test(
    'wrong original owner database refuses without source/provenance writes',
    () async {
      final observation = await observe();
      final other = GuardedReplyFixture();
      addTearDown(other.close);
      await other.seed();
      final before = await other.rows();
      expect(
        await other.repo.extendReplySources(
          expected: observation,
          provenanceJson: _facts(user, disclosures: [_disclosure()]),
          isCurrent: () => true,
        ),
        isNull,
      );
      expect(await other.rows(), before);
    },
  );

  test(
    'changed parent/origin/raw ciphertext or terminal status refuses exact stale custody',
    () async {
      final observation = await observe();
      await f.repo.renameSession(
        sessionId: user.sessionId,
        title: 'Changed parent',
      );
      final before = await f.rows();
      expect(await extend(observation), isNull);
      expect(await f.rows(), before);
      final fresh = await observe();
      // Reencrypt identical plaintext: raw ciphertext expectations still reject.
      await f.repo.putContextBlock(pending.provenance);
      final afterReencrypt = await f.rows();
      expect(await extend(fresh), isNull);
      expect(await f.rows(), afterReencrypt);
      final terminal = await observe();
      await f.repo.settleReply(
        expected: pending,
        status: 'stopped',
        isCurrent: f.isCurrent,
      );
      final terminalRows = await f.rows();
      expect(await extend(terminal), isNull);
      expect(await f.rows(), terminalRows);
    },
  );

  test(
    'changed origin or later user refuses without a generic context/body setter',
    () async {
      final observation = await observe();
      await f.repo.putMessage(user.copyWith(body: 'Changed question'));
      expect(await extend(observation), isNull);
      await f.repo.putMessage(user);
      final fresh = await observe();
      await f.repo.appendMessage(
        SupportMessage(
          id: 'later-user',
          sessionId: user.sessionId,
          role: 'user',
          body: 'Synthetic later turn',
          createdAt: pending.message.createdAt + 1,
        ),
      );
      final before = await f.rows();
      expect(await extend(fresh), isNull);
      expect(await f.rows(), before);
    },
  );

  for (final boundary in ['encrypt', 'write', 'readback']) {
    test(
      'lost original ownership at $boundary rolls back encrypted provenance extension',
      () async {
        final observation = await observe(), before = await f.rows();
        if (boundary == 'encrypt') {
          f.primitive.afterEncrypt = (aad) async {
            if (aad.contains('protected_facts_ciphertext')) f.current = false;
          };
        } else if (boundary == 'write') {
          f.sql.afterWrite = (sql) async {
            if (sql.contains('support_context_blocks')) f.current = false;
          };
        } else {
          var wrote = false;
          f.sql.afterWrite = (sql) async {
            if (sql.contains('support_context_blocks')) wrote = true;
          };
          f.sql.afterSelect = (sql) async {
            if (wrote && sql.contains('support_context_blocks'))
              f.current = false;
          };
        }
        expect(await extend(observation), isNull);
        f.sql.afterWrite = null;
        f.sql.afterSelect = null;
        f.primitive.afterEncrypt = null;
        expect(await f.rows(), before);
      },
    );
  }
}

SupportModelToolDisclosure _disclosure({String source = 'synthetic-game'}) =>
    SupportModelToolDisclosure(
      domain: SupportModelToolDisclosureDomain.game,
      sourceId: source,
      orderedSourceIds: ['synthetic-active'],
      snapshotDigest: List.filled(64, 'a').join(),
    );

String _facts(
  SupportMessage user, {
  List<SupportModelToolDisclosure>? disclosures,
  String runId = 'synthetic-run',
  List<SupportModelSourceRange> ranges = const [],
}) => SupportModelProvenanceCodec.encodeForEncryptedStorage(
  SupportModelProvenance(
    supportSessionId: user.sessionId,
    replyMessageId: GuardedReplyFixture.message.id,
    runId: runId,
    currentUserMessageId: user.id,
    originalRanges: ranges,
    directReplies: const [],
    currentConversationMessageIds: const [],
    toolDisclosures: disclosures,
  ),
);
