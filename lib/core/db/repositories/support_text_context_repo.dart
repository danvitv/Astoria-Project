import 'package:drift/drift.dart';

import '../../credentials/secret_redactor.dart';
import '../../models/support_text_context.dart';
import '../../support/support_payload_cipher.dart';
import '../app_db.dart';
import 'support_repo.dart';

part 'support_text_context/support_text_reader.dart';
part 'support_text_context/roleplay_text_reader.dart';
part 'support_text_context/text_context_observation.dart';
part 'support_text_context/support_text_provenance_reader.dart';
part 'support_text_context/text_context_admission.dart';
part 'support_text_context/session_text_context.dart';
part 'support_text_context/session_history_boundary.dart';
part 'support_text_context/roleplay_session_text_reader.dart';
part 'support_text_context/support_session_text_reader.dart';
part 'support_text_context/support_compacted_text_reader.dart';

/// Trusted native-only structural/identity check, NOT origin rights or egress
/// approval. Must be pure, synchronous and bounded: no reads/writes/publication,
/// no retained facts/redactor and no arbitrary error formatting. False or throw
/// refuses the exact read. Called with CURRENT policy at load and revalidation,
/// including ROOT's final check. Never supply this callback from tools.
typedef SupportNativeProvenanceValidator =
    bool Function(
      String sessionId,
      SupportTextContextProvenance item,
      SecretRedactor currentRedactor,
    );

/// Owns bounded exact/whole-session text projections, never consent, UI state
/// or all-chat caches.
final class SupportTextContextRepo {
  SupportTextContextRepo({
    required AppDatabase db,
    required SupportPayloadCipher cipher,
    required SecretRedactor Function() currentRedactor,
    SupportTextAdmissionContract? admissionContract,
    SupportNativeProvenanceValidator? nativeProvenanceValidator,
  }) : _db = db,
       // Native dependencies stay private, as with the existing suppliers.
       // ignore: prefer_initializing_formals
       _nativeProvenanceValidator = nativeProvenanceValidator,
       // Keep the audited constructor contract private.
       // ignore: prefer_initializing_formals
       _admissionContract = admissionContract,
       // Preserve the public injection argument without exposing the supplier.
       // ignore: prefer_initializing_formals
       _currentRedactor = currentRedactor,
       _support = _SupportTextReader(db, cipher),
       _roleplay = _RoleplayTextReader(db);

  static const maxSelections = 512;
  static const maxSourceMessages = 2000;
  static const maxRoleplaySourceBytes = 2 * 1024 * 1024;
  static const maxTextChars = 65536;
  static const maxTextBytes = 4 * maxTextChars;
  static const maxIdentityChars = 256;
  // AEAD envelopes have fixed overhead plus base64 expansion. This bounds the
  // entire selected ciphertext projection, not 512 independent large blobs.
  static const maxSelectedEnvelopeChars =
      512 * 256 + 4 * ((maxTextBytes + 2) ~/ 3);

  final AppDatabase _db;
  final SecretRedactor Function() _currentRedactor;
  final _SupportTextReader _support;
  final _RoleplayTextReader _roleplay;
  final SupportTextAdmissionContract? _admissionContract;
  final SupportNativeProvenanceValidator? _nativeProvenanceValidator;
  // Private immutable read-to-target association. Keeps the exact session
  // available to the existing ROOT callsite without exporting native suppliers
  // or arbitrary reader observations. Expando does not retain discarded reads.
  final _nativeProvenanceSessions = Expando<String>();
  bool _admissionOwnerRevoked = false;

  Future<SupportTextContextSnapshot> loadSupport({
    required String sessionId,
    required List<String> messageIds,
  }) => _load(SupportTextContextSource.support, sessionId, messageIds);

  /// Exact native current USER, never an ancestor/history loader. Large source
  /// conversations do not enlarge this single-row projection.
  Future<SupportTextContextSnapshot> loadCurrentInput({
    required String sessionId,
    required String messageId,
  }) => _load(SupportTextContextSource.support, sessionId, [
    messageId,
  ], boundedSuffix: true);

  Future<SupportTextContextSnapshot> loadRoleplay({
    required String sessionId,
    required List<String> messageIds,
  }) => _load(SupportTextContextSource.roleplay, sessionId, messageIds);

  Future<SupportTextContextSnapshot> _load(
    SupportTextContextSource source,
    String sessionId,
    List<String> messageIds, {
    bool boundedSuffix = false,
  }) async {
    try {
      if (_admissionOwnerRevoked) {
        _fail(SupportTextContextFailure.unavailable);
      }
      final ids = _selection(sessionId, messageIds);
      final before = await _stamp();
      final read = await _read(
        source,
        sessionId,
        ids,
        boundedSuffix: boundedSuffix,
      );
      final after = await _stamp();
      if (before != after) _fail(SupportTextContextFailure.stale);
      final messages = _sanitize(read, sessionId, ids);
      final provenance = _provenance(read);
      return _OwnedTextSnapshot(
        this,
        source,
        sessionId,
        ids,
        messages,
        provenance,
        read,
        after,
        boundedSuffix: boundedSuffix,
      );
    } on SupportTextContextException {
      rethrow;
    } catch (_) {
      _fail(SupportTextContextFailure.unavailable);
    }
  }

  /// True only for this repo's unchanged native observation and current
  /// sanitization. Failure permanently revokes this snapshot (observed ABA).
  ///
  /// Conservatively invalidates on *any* database write, including unrelated
  /// writes/rolled-back writes. This is intentional: no schema revision exists
  /// for detecting identical-content delete/recreate or edit/restore ABA.
  /// The caller still must fence authorization and mutation after this await.
  Future<bool> revalidate(SupportTextContextSnapshot snapshot) =>
      _revalidate(snapshot);

  Future<bool> _revalidate(
    SupportTextContextSnapshot snapshot, {
    void Function()? checkpoint,
  }) async {
    if (snapshot is! _OwnedTextSnapshot ||
        !identical(snapshot._owner, this) ||
        snapshot._revoked ||
        _admissionOwnerRevoked) {
      return false;
    }
    try {
      final before = await _stamp();
      checkpoint?.call();
      if (before != snapshot._stamp) return snapshot._revoke();
      final whole = snapshot._wholeSession;
      final result = whole == null
          ? (
              await _read(
                snapshot.source,
                snapshot.sessionId,
                snapshot.messageIds,
                checkpoint: checkpoint,
                boundedSuffix: snapshot._boundedSuffix,
              ),
              snapshot.messageIds,
            )
          : await _readSession(whole, checkpoint: checkpoint);
      final (read, ids) = result;
      checkpoint?.call();
      final after = await _stamp();
      checkpoint?.call();
      if (after != snapshot._stamp ||
          !_sameIds(ids, snapshot.messageIds) ||
          !read._same(snapshot._observation)) {
        return snapshot._revoke();
      }
      final messages = _sanitize(read, snapshot.sessionId, ids);
      if (!_sameMessages(messages, snapshot.messages)) {
        return snapshot._revoke();
      }
      _provenance(read); // Current secret registry must cover native facts too.
      return !snapshot._revoked;
    } catch (_) {
      return snapshot._revoke();
    }
  }

  Future<_TextRead> _read(
    SupportTextContextSource source,
    String sessionId,
    List<String> ids, {
    void Function()? checkpoint,
    bool boundedSuffix = false,
  }) {
    final read = _db.transaction(
      () => source == SupportTextContextSource.support
          ? _support.read(
              sessionId,
              ids,
              checkpoint: checkpoint,
              boundedSuffix: boundedSuffix,
            )
          : _roleplay.read(sessionId, ids, checkpoint: checkpoint),
    );
    if (_nativeProvenanceValidator == null) return read;
    return read.then((value) {
      _nativeProvenanceSessions[value] = sessionId;
      return value;
    });
  }

  Future<(int, int)> _stamp() async {
    // Same-connection mutation counter plus other-connection commit counter.
    // Only numbers are observed; no unrelated table content is loaded.
    final stamp = await _db
        .customSelect(
          'SELECT total_changes() AS changes, data_version AS version FROM pragma_data_version',
        )
        .getSingle();
    return (stamp.read<int>('changes'), stamp.read<int>('version'));
  }

  List<String> _selection(String sessionId, List<String> messageIds) {
    final redactor = _currentRedactor();
    if (!_identity(sessionId, redactor) ||
        messageIds.isEmpty ||
        messageIds.length > maxSelections) {
      _fail(SupportTextContextFailure.invalidSelection);
    }
    final ids = List<String>.unmodifiable(messageIds);
    if (ids.toSet().length != ids.length ||
        ids.any((id) => !_identity(id, redactor))) {
      _fail(SupportTextContextFailure.invalidSelection);
    }
    return ids;
  }

  List<SupportTextContextMessage> _sanitize(
    _TextRead read,
    String sessionId,
    List<String> ids,
  ) {
    final redactor = _currentRedactor().withKnownSecrets(
      const [],
      maxInputLength: maxTextChars,
      maxOutputLength: maxTextChars,
    );
    if (!_identity(sessionId, redactor) ||
        ids.any((id) => !_identity(id, redactor))) {
      _fail(SupportTextContextFailure.unavailable);
    }
    final characterId = read._header['character_id'];
    final groupId = read._header['variant_group_id'];
    final variantOrder = read._header['variant_order'];
    if ((characterId is String && !_identity(characterId, redactor)) ||
        (groupId is String &&
            groupId.isNotEmpty &&
            !_identity(groupId, redactor)) ||
        (variantOrder is int && (variantOrder < 0 || variantOrder > 1000000))) {
      _fail(SupportTextContextFailure.unavailable);
    }
    final messages = <SupportTextContextMessage>[];
    var chars = 0;
    var bytes = 0;
    for (final body in read._bodies) {
      chars += body._text.length;
      bytes += _textBytes(body._text);
      if (chars > maxTextChars || bytes > maxTextBytes) {
        _fail(SupportTextContextFailure.limited);
      }
      final safe = redactor.redactText(body._text);
      // A limit marker is a refusal, not a silently substituted history body.
      if (safe.contains(SecretRedactor.limited)) {
        _fail(SupportTextContextFailure.limited);
      }
      messages.add(SupportTextContextMessage(role: body._role, text: safe));
    }
    if (messages.fold<int>(0, (n, m) => n + m.text.length) > maxTextChars ||
        messages.fold<int>(0, (n, m) => n + _textBytes(m.text)) >
            maxTextBytes) {
      _fail(SupportTextContextFailure.limited);
    }
    return List.unmodifiable(messages);
  }

  List<SupportTextContextProvenance> _provenance(_TextRead read) {
    final redactor = _currentRedactor().withKnownSecrets(
      const [],
      maxInputLength: maxTextChars,
      maxOutputLength: maxTextChars,
    );
    for (final item in read._provenance) {
      if (item.runId != null && !_identity(item.runId!, redactor)) {
        _fail(SupportTextContextFailure.unavailable);
      }
      final facts = item.dedicatedFactsJson;
      if (facts != null) {
        final validator = _nativeProvenanceValidator;
        final sessionId = _nativeProvenanceSessions[read];
        final valid = validator == null
            ? redactor.redactText(facts) == facts
            : sessionId != null && validator(sessionId, item, redactor);
        if (!valid) _fail(SupportTextContextFailure.unavailable);
      }
    }
    return read._provenance;
  }

  @override
  String toString() => 'SupportTextContextRepo';
}
