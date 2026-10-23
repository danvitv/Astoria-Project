import '../models/support_model_view.dart';
import '../services/support_model_service.dart' show SupportModelPreview;
import '../../../core/llm/transport/private_text_outcome.dart';

export '../models/support_model_view.dart';
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
  });
  final SupportModelPhase? phase;
  final SupportModelRefusal reason;
  final bool busy, accepted, saved;
  final SupportModelPreview? preview;
  final PrivateTextStatus? status;
  final PrivateTextDispatch dispatch;
  final PrivateTextReason transportReason;
  final String? runId, sessionId;

  bool isActiveRun(String? id, String session) =>
      busy && runId != null && id == runId && session == sessionId;

  String get label {
    if (reason != SupportModelRefusal.none) return reason.label;
    return switch (phase) {
      SupportModelPhase.preparing => 'Подготовка сообщения…',
      SupportModelPhase.preview => 'Проверь точный текст перед отправкой.',
      SupportModelPhase.waiting => 'Ожидание ответа модели…',
      SupportModelPhase.activity => 'Получение ответа модели…',
      SupportModelPhase.settling => 'Сохранение результата…',
      SupportModelPhase.settled => switch (status) {
        PrivateTextStatus.complete => 'Ответ сохранён.',
        PrivateTextStatus.stopped => 'Отправка остановлена.',
        PrivateTextStatus.partial =>
          'Сохранён неполный ответ; запрос завершился с ошибкой.',
        PrivateTextStatus.limited =>
          'Ответ ограничен; сохранён доступный безопасный текст.',
        PrivateTextStatus.error => 'Запрос завершился без полного ответа.',
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
