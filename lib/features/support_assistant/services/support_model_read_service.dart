part of 'support_model_service.dart';

/// ONLY pure decrypt reads are raced. Repository/SQL callbacks await
/// their normal completion, checkpoint before the next query, and unwind H.
final class _ModelReadOperation {
  _ModelReadOperation(this.service, this.isCurrent) {
    reader = SupportRepo(
      service._db,
      SupportPayloadCipher.readOnly(
        delegate: service._writeCipher,
        gate: (decryptPure) => pure(decryptPure),
      ),
    );
    history = SupportTextContextRepo(
      db: service._db,
      cipher: SupportPayloadCipher.readOnly(
        delegate: service._writeCipher,
        gate: (decryptPure) => pure(decryptPure),
      ),
      currentRedactor: () => service._redaction.redactor,
      admissionContract: service._admissionContract,
      nativeProvenanceValidator: SupportModelNativeProvenanceValidator.validate,
    );
    timer = service._scheduleTimer(
      service._deadline,
      () => cancel(SupportModelRefusal.deadline),
    );
  }
  final SupportModelService service;
  final bool Function() isCurrent;
  final token = CancelToken();
  late final SupportRepo reader;
  late final SupportTextContextRepo history;
  late final Timer timer;
  SupportModelRefusal reason = SupportModelRefusal.none;

  bool current() {
    try {
      return !token.isCancelled && isCurrent();
    } catch (_) {
      return false;
    }
  }

  void check() {
    if (!current()) {
      throw _ModelRefused(
        reason == SupportModelRefusal.none ? SupportModelRefusal.stale : reason,
      );
    }
  }

  void cancel(SupportModelRefusal why) {
    if (reason == SupportModelRefusal.none) reason = why;
    if (!token.isCancelled) token.cancel();
  }

  void close() => timer.cancel();

  Future<T> checked<T>(
    Future<T> Function() work, [
    void Function()? checkpoint,
  ]) async {
    check();
    checkpoint?.call();
    final result = await work();
    check();
    checkpoint?.call();
    return result;
  }

  Future<T> pure<T>(Future<T> Function() work) async {
    check();
    final result = Completer<T>();
    var open = true;
    void refuse() {
      if (open && !result.isCompleted) {
        result.completeError(
          const SupportCipherException(SupportCipherFailure.invalidContext),
        );
      }
    }

    final budget = service._scheduleTimer(service._readDeadline, () {
      cancel(SupportModelRefusal.deadline);
      refuse();
    });
    // These handlers consume BOTH late outcomes. No SQL/reader continuation is
    // attached to the underlying pure future. Strings are not cached/published.
    unawaited(
      Future<T>.sync(work).then<void>(
        (value) {
          if (open && !result.isCompleted) {
            if (current()) {
              result.complete(value);
            } else {
              refuse();
            }
          }
        },
        onError: (Object _, StackTrace _) {
          refuse();
        },
      ),
    );
    unawaited(token.whenCancel.then((_) => refuse()));
    try {
      final value = await result.future;
      check();
      return value;
    } finally {
      open = false;
      budget.cancel();
    }
  }

  Future<SupportPermissionPreferences> policy(
    String id, [
    void Function()? checkpoint,
  ]) async {
    final parent = await checked(() => reader.getSessionById(id), checkpoint);
    if (parent == null || parent.isLocked) {
      _refuse(SupportModelRefusal.unavailable);
    }
    final block = await checked(
      () =>
          reader.getContextBlockById(const SupportPermissionCodec().idFor(id)),
      checkpoint,
    );
    return const SupportPermissionCodec().decode(id, block);
  }

  Future<SupportAssistantSettings> settings(
    String id, [
    void Function()? checkpoint,
  ]) async {
    final parent = await checked(() => reader.getSessionById(id), checkpoint);
    if (parent == null || parent.isLocked) {
      _refuse(SupportModelRefusal.unavailable);
    }
    const codec = SupportWorkspaceSettingsCodec();
    final block = await checked(
      () => reader.getContextBlockById(codec.idFor(id)),
      checkpoint,
    );
    if (block != null &&
        (block.id != codec.idFor(id) ||
            block.sessionId != id ||
            block.protectedFactsJson.length > 65536)) {
      _refuse(SupportModelRefusal.unavailable);
    }
    return codec.decode(block);
  }
}

final class _ModelRefused implements Exception {
  const _ModelRefused(this.reason);
  final SupportModelRefusal reason;
  @override
  String toString() => 'Support model operation unavailable.';
}

Never _refuse(SupportModelRefusal reason) => throw _ModelRefused(reason);

String _safeText(SecretRedactor current, String text, int maximum) {
  if (text.length > maximum) _refuse(SupportModelRefusal.tooLarge);
  if (utf8.decode(utf8.encode(text)) != text) {
    _refuse(SupportModelRefusal.unsafe);
  }
  final safe = current
      .withKnownSecrets(
        const [],
        // The text bound is checked above. Do not accidentally exhaust the
        // retained secret policy when checking a short ID against a long key.
        maxInputLength: maximum > current.maxInputLength
            ? maximum
            : current.maxInputLength,
        maxOutputLength: maximum,
      )
      .redactText(text);
  if (safe.contains(SecretRedactor.limited) || safe.length > maximum) {
    _refuse(SupportModelRefusal.tooLarge);
  }
  return safe;
}
