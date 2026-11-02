import '../../../../core/credentials/secret_redactor.dart';
import '../../../../core/llm/transport/native_tool_types.dart';
import '../../models/support_app_action.dart' show SupportAppActionCode;
import 'support_diagnostic_metadata_finding.dart';

/// Passive run-local presentation, not an executor, parser or provenance store.
/// Record ONLY after the original ROOT and call/result correlation check, before
/// DCP/annotations. Retain finite facts, never result objects or private bodies.
/// Render at the original reply's FIFO settlement with its CURRENT redactor.
final class SupportDiagnosticPresentation {
  static const retainedReceipts = 8;
  static const footerCharacters = 8192;
  static const answerCharacters = NativeToolLimits.textCharacters;
  final _receipts = <_DiagnosticReceipt>[];
  var _received = 0, _evicted = 0;
  var _persisted = 0, _uncertain = 0, _navigation = 0, _unknownEffect = 0;
  bool _started = false, _failed = false;

  void start() => _started = true; // Attempted loop, never proof of a check.

  void record(NativeToolCall call, NativeToolResult result) {
    if (call.id != result.callId || call.name != result.name) return;
    _received++;
    final nativeOk = result.content['ok'];
    final ok = nativeOk == true;
    final reportedOk = switch (nativeOk) {
      true => 'true',
      false => 'false',
      _ => 'unknown',
    };
    _failed = _failed || !ok;
    final effect = switch (result.content['effect']) {
      'none' => 'none',
      'persisted' => 'persisted',
      'uncertain' => 'uncertain',
      'navigation' => 'navigation',
      _ => 'unknown',
    };
    switch (effect) {
      case 'persisted':
        _persisted++;
        break;
      case 'uncertain':
        _uncertain++;
        break;
      case 'navigation':
        _navigation++;
        break;
      case 'unknown':
        _unknownEffect++;
        break;
    }
    if (_receipts.length == retainedReceipts) {
      _evicted++;
      return; // Effect/failure accounting above is NEVER evicted.
    }
    final data = result.content['data'];
    final nativeCode = result.content['code'];
    final code = SupportAppActionCode.values.any((c) => c.name == nativeCode)
        ? nativeCode as String
        : 'unknown';
    final finding = ok && effect == 'none' && data is Map<String, Object?>
        ? SupportDiagnosticMetadataFinding.observe(
            call.name,
            call.arguments,
            data,
          )
        : null;
    _receipts.add(
      _DiagnosticReceipt(call.id, call.name, reportedOk, code, effect, finding),
    );
  }

  String present(
    String originalText, {
    required String settlementStatus,
    required SecretRedactor redactor,
  }) {
    final status = switch (settlementStatus) {
      'complete' => 'complete',
      'stopped' => 'stopped',
      'error' => 'error',
      'limited' => 'limited',
      _ => 'unknown',
    };
    // ToolOutcome replaces model prose with native factual text on these
    // branches. A Source-only/plain transport partial is STILL model narrative.
    final providerNarrative =
        !(_received > 0 &&
            (status != 'complete' ||
                _failed ||
                _persisted + _uncertain + _navigation + _unknownEffect > 0));
    var hidden = _evicted;
    final observations = <String>[];
    for (final receipt in _receipts) {
      final line = receipt.line;
      // Never replace an unsafe call ID with a different purported reference or
      // slice a secret literal. Omit the whole observation and report the gap.
      if (redactor.redactText(line) != line) {
        hidden++;
      } else {
        observations.add(line);
      }
    }
    final heading = providerNarrative
        ? '### Ответ модели — гипотезы и предложения (UNCONFIRMED)'
        : '### Нативное фактическое завершение запроса';
    var omittedNarrative = false;
    String footer() => [
      '---',
      '### Нативные наблюдения — не вывод модели',
      'Статус ответа: $status. '
          '${_started ? 'Диагностический цикл начат; это не доказательство выполненной проверки.' : 'executor_not_started: нативный диагностический цикл не запускался.'}',
      'Получено коррелированных квитанций: $_received. '
          'Область каждого наблюдения: this_tool_observation_only.',
      if (observations.isEmpty)
        '- Доступных наблюдений нет; проверка и её результат не подтверждены.'
      else
        ...observations,
      '### Гипотезы и недостающие доказательства',
      '- causalDiagnosis: insufficient_data. Метаданные не доказывают полную первопричину.',
      '- Полнота истории unknown; отсутствующие, усечённые (truncated) или '
          'вытесненные (evicted) данные не являются доказательством исправности.',
      '- Source4 payloads не интерпретируются этим блоком: содержимое, '
          'полнота и причины пропусков unknown; текст источников здесь не копируется.',
      if (hidden > 0)
        '- Не показано квитанций: $hidden (лимит или текущая редакция секретов); '
            'их ссылки и подробности unavailable.',
      if (omittedNarrative)
        '- Ответ модели целиком опущен из-за лимита размера; частичные строки не публикуются.',
      '### Предложенные и применённые исправления',
      '- Предложения модели: UNCONFIRMED; этот диагностический путь разрешает только чтение.',
      '- Фактические квитанции эффектов: persisted=$_persisted; uncertain=$_uncertain; '
          'navigation=$_navigation; unknown=$_unknownEffect. '
          '${_received == 0 ? 'Квитанций нет; отсутствие изменений не доказано.' : 'Остальные квитанции: effect=none; это не доказательство для непроверенных действий.'}',
      '- Следующий безопасный шаг: получить недостающие доказательства; '
          'исправление — отдельным обычным запросом с требуемым нативным подтверждением.',
    ].join('\n\n');
    var summary = footer();
    final prefix = '$heading\n\n';
    if (prefix.length + originalText.length + summary.length + 2 >
        answerCharacters) {
      // Existing factual settlement (including unexpected/uncertain effects)
      // wins over presentation. NEVER replace or conceal it for a footer.
      if (!providerNarrative) return originalText;
      omittedNarrative = true;
      summary = footer();
    }
    final generated = '$prefix$summary';
    if (summary.length > footerCharacters ||
        redactor.redactText(generated) != generated) {
      return originalText; // Presentation cannot defeat the current secret policy.
    }
    return '$prefix${omittedNarrative ? '' : '$originalText\n\n'}$summary';
  }
}

final class _DiagnosticReceipt {
  const _DiagnosticReceipt(
    this.id,
    this.tool,
    this.ok,
    this.code,
    this.effect,
    this.finding,
  );
  final String id, tool, ok, code, effect;
  final SupportDiagnosticMetadataFinding? finding;

  String get line {
    final observed = finding;
    return '- Evidence: `$id` / `$tool`; ok=$ok; code=$code; effect=$effect. '
        '${observed == null ? 'metadata_finding: unknown (не проверено этим блоком).' : '${observed.code}; confidence=confirmed_by_check; missingEvidence: ${observed.missing.join(', ')}.'}';
  }
}
