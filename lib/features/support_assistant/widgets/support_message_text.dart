import '../models/support_workspace_models.dart';
import '../services/support_message_display_projection.dart';
import '../state/support_model_run_view.dart';

/// The same safe body is used for rendering and explicit clipboard copying.
/// Cards, raw errors and hidden credential values are not text sources.
String supportDisplayedMessageText(
  SupportMessageItem message,
  SupportMessageDisplayProjection display,
  SupportModelRunView run,
) {
  final safe = display.project(message.body);
  if (message.isLocked ||
      message.role != SupportMessageRole.assistant ||
      message.status != 'error' ||
      safe.trim().isNotEmpty) {
    return safe;
  }
  final reason = run.settledDiagnostic(message.runId, message.sessionId);
  return reason.isNotEmpty
      ? reason
      : 'Модель не вернула текст ответа. Причина для сохранённого сообщения '
            'недоступна. Можно перегенерировать последний ответ; действия приложения '
            'при этом не повторяются.';
}
