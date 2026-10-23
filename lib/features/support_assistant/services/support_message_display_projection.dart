import '../../../core/credentials/secret_redactor.dart';

/// Pure, current-policy projection of one whole passive feed body.
///
/// Construct once per feed build from its immutable policy snapshot. This owns
/// neither credentials nor stored messages and never authorizes an action.
final class SupportMessageDisplayProjection {
  SupportMessageDisplayProjection({required SecretRedactor redactor})
    : _redactor = redactor.withKnownSecrets(
        const [],
        maxInputLength: maxTextLength,
        maxOutputLength: maxTextLength,
      );

  static const maxTextLength = 65536;
  static const tooLong = 'Текст сообщения недоступен: превышен лимит длины.';
  static const unavailable =
      'Текст сообщения недоступен: не удалось безопасно отобразить.';

  final SecretRedactor _redactor;

  String project(String body) {
    if (body.length > maxTextLength) return tooLong;
    try {
      final safe = _redactor.redactText(body);
      // Limits can occur inside JSON or URL output, not just as a whole result.
      // Never paint a partial result or fall back to the original body.
      if (safe.length > maxTextLength ||
          safe.contains(SecretRedactor.limited)) {
        return unavailable;
      }
      return safe;
    } catch (_) {
      // Error objects and their formatting are not a display source.
      return unavailable;
    }
  }
}
