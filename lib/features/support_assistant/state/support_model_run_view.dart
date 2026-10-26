import '../models/support_model_view.dart';
import '../models/support_model_tool_activity.dart';
import '../services/support_model_service.dart' show SupportModelPreview;
import '../../../core/llm/transport/private_text_outcome.dart';

export '../models/support_model_view.dart';
export '../models/support_model_tool_activity.dart';
export '../../../core/llm/transport/private_text_outcome.dart';

/// Payload-free activity plus the exact sanitized native preview. No tools,
/// configuration, credential, context reader or serialized approval authority.
final class SupportModelRunView {
  const SupportModelRunView({
    this.phase,
    this.reason = SupportModelRefusal.none,
    this.busy = false,
    this.accepted = false,
    this.saved = false,
    this.preview,
    this.status,
    this.dispatch = PrivateTextDispatch.notAdmitted,
    this.transportReason = PrivateTextReason.none,
    this.runId,
    this.sessionId,
    this.usage,
    this.compacted = false,
    this.isCompaction = false,
    this.toolActivities = const [],
  });
  final SupportModelPhase? phase;
  final SupportModelRefusal reason;
  final bool busy, accepted, saved;
  final SupportModelPreview? preview;
  final PrivateTextStatus? status;
  final PrivateTextDispatch dispatch;
  final PrivateTextReason transportReason;
  final String? runId, sessionId;
  final ProviderTokenUsage? usage;
  final bool compacted, isCompaction;
  final List<SupportModelToolActivity> toolActivities;

  bool hasToolActivitiesFor(String? id, String session) =>
      id != null &&
      id == runId &&
      session == sessionId &&
      toolActivities.isNotEmpty;

  bool isActiveRun(String? id, String session) =>
      busy && runId != null && id == runId && session == sessionId;

  /// Only the current exact settled attempt can explain its durable row. Old
  /// restored rows get a generic fallback, never a guessed provider diagnosis.
  String settledDiagnostic(String? id, String session) =>
      !busy &&
          saved &&
          accepted &&
          phase == SupportModelPhase.settled &&
          id != null &&
          id == runId &&
          session == sessionId &&
          (status == PrivateTextStatus.error ||
              status == PrivateTextStatus.partial)
      ? _failureExplanation
      : '';

  String get _failureExplanation => switch (transportReason) {
    PrivateTextReason.httpStatus =>
      'Сервис модели отклонил запрос. Проверь выбранное подключение и модель.',
    PrivateTextReason.transport || PrivateTextReason.admittedFailed =>
      'Не удалось завершить соединение с сервисом модели. Проверь подключение.',
    PrivateTextReason.deadline =>
      'Время ожидания ответа модели истекло. Можно попробовать ещё раз.',
    PrivateTextReason.malformed ||
    PrivateTextReason.unexpectedEof ||
    PrivateTextReason.providerError =>
      'Сервис модели вернул ошибку или неполный ответ. Можно попробовать ещё раз.',
    PrivateTextReason.denied || PrivateTextReason.notCurrent =>
      'Отправка не разрешена или её контекст изменился. Проверь текущие настройки.',
    PrivateTextReason.invalidRequest || PrivateTextReason.unsupported =>
      'Выбранное подключение не поддержало этот запрос. Проверь модель и настройки.',
    PrivateTextReason.providerLimit ||
    PrivateTextReason.outputLimit ||
    PrivateTextReason.wireLimit ||
    PrivateTextReason.sanitationLimit =>
      'Ответ остановлен безопасным ограничением. Полный текст не получен.',
    PrivateTextReason.cancelled => 'Отправка остановлена.',
    PrivateTextReason.none =>
      'Модель не вернула полный ответ. Точная причина недоступна.',
  };

  String get label {
    if (reason != SupportModelRefusal.none) return reason.label;
    return switch (phase) {
      SupportModelPhase.preparing => 'Подготовка сообщения…',
      SupportModelPhase.compacting => 'Сжатие старого контекста моделью…',
      SupportModelPhase.preview => 'Проверь точный текст перед отправкой.',
      SupportModelPhase.waiting =>
        toolActivities.isEmpty
            ? 'Ожидание ответа модели…'
            : 'Ожидание ответа модели после вызовов инструментов…',
      SupportModelPhase.activity =>
        toolActivities.isEmpty
            ? 'Получение ответа модели…'
            : toolActivities.last.label,
      SupportModelPhase.settling => 'Сохранение результата…',
      SupportModelPhase.settled =>
        isCompaction && compacted
            ? 'Контекст сжат. Вся история сохранена.'
            : switch (status) {
                PrivateTextStatus.complete => 'Ответ сохранён.',
                PrivateTextStatus.stopped => 'Отправка остановлена.',
                PrivateTextStatus.partial =>
                  'Сохранён неполный ответ; запрос завершился с ошибкой.',
                PrivateTextStatus.limited =>
                  'Ответ ограничен; сохранён доступный безопасный текст.',
                PrivateTextStatus.error => _failureExplanation,
                null => '',
              },
      null => '',
    };
  }

  @override
  String toString() => 'SupportModelRunView';
}

final class SupportModelUiPreparation {
  const SupportModelUiPreparation({required this.reason, this.preview});
  final SupportModelRefusal reason;
  final SupportModelPreview? preview;
  @override
  String toString() => 'SupportModelUiPreparation';
}
