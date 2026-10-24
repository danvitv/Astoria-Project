import '../../../core/llm/transport/private_text_outcome.dart';

/// Fixed native presentation only. None of these values grants data/send rights.
enum SupportModelRefusal {
  none,
  busy,
  stale,
  cancelled,
  deadline,
  noModel,
  recipientRequired,
  unavailable,
  unsupported,
  unsafe,
  tooLarge,
  historyDenied,
  lineageUnavailable,
  appendFailed,
  reservationFailed,
  settlementFailed;

  String get label => switch (this) {
    none => '',
    busy => 'Предыдущая отправка ещё не завершена.',
    stale => 'Контекст отправки изменился. Повтори отправку.',
    cancelled => 'Отправка остановлена.',
    deadline => 'Время ожидания истекло. Запрос остановлен.',
    noModel =>
      'Модель не выбрана. Доступна отдельная локальная помощь без сети.',
    recipientRequired =>
      'Для внешних источников отдельно подтверди выбранного получателя.',
    unsupported =>
      'Это подключение не поддерживает безопасный текстовый SSE-запрос.',
    unsafe => 'Текст или параметры нельзя безопасно отправить.',
    tooLarge => 'Текст или выбранный контекст превышает допустимый размер.',
    historyDenied =>
      'Для всей выбранной истории нужны отдельные разрешения чтения и отправки.',
    lineageUnavailable =>
      'Происхождение выбранного ответа недоступно или выбрано не полностью.',
    appendFailed => 'Сообщение не сохранено. Черновик оставлен.',
    reservationFailed =>
      'Сообщение сохранено, но ответ подготовить не удалось.',
    settlementFailed =>
      'Сообщение сохранено, но результат ответа сохранить не удалось.',
    unavailable => 'Данные выбранной сессии или подключения недоступны.',
  };
}

enum SupportModelPhase {
  preparing,
  preview,
  waiting,
  activity,
  settling,
  settled,
}

/// Only sanitized, durable text. No cards, request, config, key or provenance.
final class SupportModelMessage {
  const SupportModelMessage({
    required this.id,
    required this.sessionId,
    required this.runId,
    required this.role,
    required this.text,
    required this.status,
    required this.createdAt,
  });
  final String id, sessionId, runId, role, text, status;
  final int createdAt;
  @override
  String toString() => 'SupportModelMessage';
}

final class SupportModelPreviewText {
  const SupportModelPreviewText({required this.role, required this.text});
  final String role, text;
  @override
  String toString() => 'SupportModelPreviewText';
}

/// Exact body-only current conversation emitted by the native view at Send.
/// Display authority only: no origin, source permission, keys or serializer.
final class SupportModelConversationMessage {
  const SupportModelConversationMessage({
    required this.id,
    required this.role,
    required this.text,
  });
  final String id, role, text;
}

final class SupportModelRunResult {
  const SupportModelRunResult({
    required this.accepted,
    required this.saved,
    required this.reason,
    this.message,
    this.outcome,
  });
  final bool accepted, saved;
  final SupportModelRefusal reason;
  final SupportModelMessage? message;
  final PrivateTextOutcome? outcome;
  @override
  String toString() => 'SupportModelRunResult';
}
