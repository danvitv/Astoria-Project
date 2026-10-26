part of '../support_repo.dart';

/// Original pending-row custody, never reconstructed from provenance JSON or
/// restored DTOs. Captures the exact parent, user, encrypted reply and context.
final class SupportReplySourceObservation {
  SupportReplySourceObservation._(
    this._owner,
    this._parent,
    this._userRow,
    this._row,
    this._context,
    this.reservation,
    this.originatingUser,
  );
  final _SupportGuardedReplyStore _owner;
  final SupportSessionRow _parent;
  final SupportMessageRow _userRow, _row;
  final SupportContextBlockRow _context;
  final SupportReplyReservation reservation;
  final SupportMessage originatingUser;
  bool _consumed = false;
  @override
  String toString() => 'SupportReplySourceObservation';
}

/// Only historical source metadata can be appended to protected provenance.
/// No generic body/context setter, model plaintext output, ROOT writes or grants.
extension _SupportReplySourceStore on _SupportGuardedReplyStore {
  Future<SupportReplySourceObservation?> readReplyForSourceExtension(
    SupportReplyReservation expected,
    SupportMessage user,
    bool Function() current,
  ) => _transaction(current, () async {
    final reply = expected.message, block = expected.provenance;
    _require(
      _sourcePending(expected) &&
          messages.nativeInput.user(user) &&
          user.sessionId == reply.sessionId &&
          user.createdAt < reply.createdAt,
    );
    _ReplySourceHeader.validate(block.protectedFactsJson, expected, user.id);
    final parent = await _checked(_parent(reply.sessionId, current), current);
    final origin = await _checked(
      messages.nativeInput.matchUser(user, current),
      current,
    );
    final row = await _checked(messages.row(reply.id), current);
    final context = await _checked(_contextRow(block.id), current);
    _require(
      row != null && context != null && row.sessionId == reply.sessionId,
    );
    _require(await _checked(_message(row!, current), current) == reply);
    _require(await _checked(_provenance(context!, current), current) == block);
    await _checked(_replyTail(reply, current), current);
    await _checked(
      _unchanged(parent, reply.id, block.id, row, context, current),
      current,
    );
    _require(
      await _checked(messages.nativeInput.userRow(user), current) == origin,
    );
    return SupportReplySourceObservation._(
      this,
      parent,
      origin,
      row,
      context,
      expected,
      user,
    );
  });

  bool _sourcePending(SupportReplyReservation expected) =>
      _reply(expected.message) &&
      expected.message.status == 'pending' &&
      expected.message.body.isEmpty &&
      _regenerationBlock(expected.provenance, expected.message);

  Future<SupportReplyReservation?> extendReplySources(
    SupportReplySourceObservation expected,
    String provenanceJson,
    bool Function() current,
  ) => _transaction(current, () async {
    _require(
      identical(expected._owner, this) &&
          !expected._consumed &&
          _sourcePending(expected.reservation),
    );
    final reply = expected.reservation.message,
        block = expected.reservation.provenance;
    _ReplySourceHeader.requireAppend(
      block.protectedFactsJson,
      provenanceJson,
      expected.reservation,
      expected.originatingUser.id,
    );
    Future<void> same() async {
      _requireCurrent(current);
      _require(!expected._consumed);
      await _checked(
        _unchanged(
          expected._parent,
          reply.id,
          block.id,
          expected._row,
          expected._context,
          current,
        ),
        current,
      );
      _require(
        await _checked(
              messages.nativeInput.userRow(expected.originatingUser),
              current,
            ) ==
            expected._userRow,
      );
      await _checked(_replyTail(reply, current), current);
    }

    await _checked(same(), current);
    _require(
      await _checked(_message(expected._row, current), current) == reply,
    );
    _require(
      await _checked(_provenance(expected._context, current), current) == block,
    );
    final facts = await _checked(
      cipher.encrypt(
        plaintext: provenanceJson,
        table: 'support_context_blocks',
        rowId: block.id,
        sessionId: block.sessionId,
        field: 'protected_facts_ciphertext',
      ),
      current,
    );
    await _checked(same(), current);
    final count = await _checked(
      (db.update(db.supportContextBlocks)..where(
            (t) =>
                t.id.equals(block.id) &
                t.sessionId.equals(block.sessionId) &
                t.protectedFactsCiphertext.equals(
                  expected._context.protectedFactsCiphertext,
                ),
          ))
          .write(
            SupportContextBlocksCompanion(
              protectedFactsCiphertext: Value(facts),
            ),
          ),
      current,
    );
    _require(count == 1);
    final written = await _checked(_contextRow(block.id), current);
    _require(
      written != null &&
          written ==
              expected._context.copyWith(protectedFactsCiphertext: facts),
    );
    final next = block.copyWith(protectedFactsJson: provenanceJson);
    final durable = await _checked(_provenance(written!, current), current);
    _require(durable == next);
    await _checked(
      _unchanged(
        expected._parent,
        reply.id,
        block.id,
        expected._row,
        written,
        current,
      ),
      current,
    );
    _require(
      await _checked(
            messages.nativeInput.userRow(expected.originatingUser),
            current,
          ) ==
          expected._userRow,
    );
    await _checked(_replyTail(reply, current), current);
    _requireCurrent(current);
    // The exact new reservation refreshes settlement and ROOT expectations.
    // Consumption occurs only after durable readback, never before encryption.
    expected._consumed = true;
    return (message: reply, provenance: durable);
  });
}

/// Native structural header guard independent of feature codecs. The caller
/// still validates the feature codec and original native lease before this API.
abstract final class _ReplySourceHeader {
  static Never bad() => throw const _SupportReplyRefused();
  static Map<String, Object?> object(Object? value, Set<String> keys) {
    if (value is! Map<String, Object?> ||
        value.length != keys.length ||
        value.keys.any((key) => !keys.contains(key)))
      bad();
    return value;
  }

  static List<Object?> array(Object? value, int max) {
    if (value is! List<Object?> || value.length > max) bad();
    return value;
  }

  static void ids(Object? value, {int max = 512, bool empty = false}) {
    final list = array(value, max), seen = <String>{};
    if (!empty && list.isEmpty) bad();
    for (final id in list) {
      if (!SupportSourceJson.identity(id) || !seen.add(id as String)) bad();
    }
  }

  static Map<String, Object?> validate(
    String raw,
    SupportReplyReservation expected,
    String userId,
  ) {
    try {
      final parsed = SupportSourceJson.decode(raw);
      if (parsed is! Map<String, Object?>) bad();
      final v = parsed['version'];
      if (v is! int || !const [2, 3, 4].contains(v)) bad();
      final checkpoint =
          v == 3 || (v == 4 && parsed.containsKey('compactedThroughMessageId'));
      final root = object(parsed, {
        'marker',
        'version',
        'supportSessionId',
        'replyMessageId',
        'runId',
        'currentUserMessageId',
        'originalRanges',
        'directReplies',
        'currentConversationMessageIds',
        if (checkpoint) 'compactedThroughMessageId',
        if (v == 4) 'toolDisclosures',
      });
      if (root['marker'] != 'support.model_provenance' ||
          root['supportSessionId'] != expected.message.sessionId ||
          root['replyMessageId'] != expected.message.id ||
          root['runId'] != expected.message.runId ||
          root['currentUserMessageId'] != userId)
        bad();
      for (final key in [
        'supportSessionId',
        'replyMessageId',
        'runId',
        'currentUserMessageId',
      ]) {
        if (!SupportSourceJson.identity(root[key])) bad();
      }
      ids(root['currentConversationMessageIds'], empty: true);
      final conversation = root['currentConversationMessageIds'] as List;
      if (conversation.contains(userId) ||
          conversation.contains(expected.message.id))
        bad();
      if (checkpoint &&
          !SupportSourceJson.identity(root['compactedThroughMessageId']))
        bad();
      final ranges = array(root['originalRanges'], 128),
          references = array(root['directReplies'], 128);
      if (ranges.length + references.length > 128) bad();
      final rangeKeys = <String>{}, referenceKeys = <String>{};
      var occurrences = 0;
      for (final item in ranges) {
        final range = object(item, const {
          'domain',
          'sessionId',
          'orderedMessageIds',
        });
        if (!const ['support', 'game'].contains(range['domain']) ||
            !SupportSourceJson.identity(range['sessionId']) ||
            !rangeKeys.add(jsonEncode([range['domain'], range['sessionId']])))
          bad();
        ids(range['orderedMessageIds']);
        occurrences += (range['orderedMessageIds'] as List).length;
        if (occurrences > 4096) bad();
      }
      for (final item in references) {
        final ref = object(item, const {'sessionId', 'messageId', 'runId'});
        if (ref.values.any((v) => !SupportSourceJson.identity(v)) ||
            !referenceKeys.add(
              jsonEncode([ref['sessionId'], ref['messageId']]),
            ))
          bad();
      }
      if (v == 4) {
        final seen = <String>{};
        for (final item in array(root['toolDisclosures'], 16)) {
          final disclosure = object(item, const {
            'domain',
            'sourceId',
            'orderedSourceIds',
            'snapshotDigest',
          });
          if (!const ['game', 'studioPreset'].contains(disclosure['domain']) ||
              !SupportSourceJson.identity(disclosure['sourceId']) ||
              disclosure['snapshotDigest'] is! String ||
              !RegExp(
                r'^[0-9a-f]{64}$',
              ).hasMatch(disclosure['snapshotDigest'] as String))
            bad();
          ids(disclosure['orderedSourceIds'], max: 16);
          final sourceIds = disclosure['orderedSourceIds'] as List;
          if (disclosure['domain'] == 'studioPreset' &&
              (sourceIds.length != 1 ||
                  sourceIds.single != disclosure['sourceId']))
            bad();
          if (!seen.add(
            jsonEncode([
              disclosure['domain'],
              disclosure['sourceId'],
              disclosure['snapshotDigest'],
            ]),
          ))
            bad();
        }
      }
      return root;
    } catch (_) {
      bad();
    }
  }

  static void requireAppend(
    String oldRaw,
    String nextRaw,
    SupportReplyReservation expected,
    String userId,
  ) {
    final old = validate(oldRaw, expected, userId),
        next = validate(nextRaw, expected, userId);
    if (next['version'] != 4) bad();
    final oldItems = old['toolDisclosures'] as List? ?? const [],
        nextItems = next['toolDisclosures'] as List;
    if (nextItems.length <= oldItems.length) bad();
    for (var i = 0; i < oldItems.length; i++) {
      if (jsonEncode(oldItems[i]) != jsonEncode(nextItems[i])) bad();
    }
    final oldHeader = Map<String, Object?>.of(old)
      ..remove('version')
      ..remove('toolDisclosures');
    final nextHeader = Map<String, Object?>.of(next)
      ..remove('version')
      ..remove('toolDisclosures');
    if (oldHeader.length != nextHeader.length ||
        oldHeader.keys.any(
          (key) =>
              !nextHeader.containsKey(key) ||
              jsonEncode(oldHeader[key]) != jsonEncode(nextHeader[key]),
        ))
      bad();
  }
}
