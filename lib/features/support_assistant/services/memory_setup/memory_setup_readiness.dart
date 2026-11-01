part of 'memory_setup_service.dart';

/// Grounded local prerequisites, deliberately not a live end-to-end verdict.
final class MemorySetupReadiness {
  const MemorySetupReadiness(this.steps);
  final List<String> steps;
}

extension MemorySetupReadinessReader on MemorySetupService {
  Future<MemorySetupReadiness?> readiness() async {
    final checkpoint = _checkpoint;
    final ticket = books.captureSetupTicket();
    bool source() => _sourceCurrent(checkpoint) && ticket.current;
    if (!source() || !await _fresh()) return null;
    final session = await chats.getById(_targetId!);
    if (!source() || session == null) return null;
    final observed = await books.observeForControl(_targetId!);
    if (!source()) return null;
    final book = observed?.book;
    if (book == null)
      return const MemorySetupReadiness([
        'Книга отсутствует или её данные недоступны. Сначала примени сессионный план.',
      ]);
    final rows = await catalog.getBySessionId(_targetId!);
    if (!source()) return null;
    final prefs = preferences;
    Map<String, dynamic>? global, pipeline;
    if (prefs != null) {
      final lease = prefs.store.owner.capture([
        'memorySettings',
        'pipelineSettings',
      ], store: prefs.store);
      if (lease.current) {
        global = _rawDocument(
          prefs.getString('memorySettings'),
          MemorySetupScope.automation,
        );
        pipeline = _rawDocument(
          prefs.getString('pipelineSettings'),
          MemorySetupScope.draftConnection,
        );
        if (!lease.current) {
          global = null;
          pipeline = null;
        }
      }
    }
    final interval = global?['autoCreateInterval'] is int
        ? global!['autoCreateInterval'] as int
        : 15;
    final lag = global?['autoCreateLagMessages'] is int
        ? global!['autoCreateLagMessages'] as int
        : 4;
    final plan = MemoryDraftPlanner.plan(
      book: book,
      messages: session.messages,
      interval: interval,
      lagMessages: lag,
      source: 'scan_chat',
      nowMillis: 0,
    );
    final pendingGeneration = book.pendingDrafts
        .where((d) => d.status == 'pending_generation')
        .length;
    final pendingApproval = book.pendingDrafts
        .where((d) => d.status == 'pending_approval')
        .length;
    final active = book.entries
        .where(
          (e) =>
              e.status == 'active' &&
              MemoryEntryRevisions.isUsable(e) &&
              e.content.trim().isNotEmpty &&
              e.source != 'agentic' &&
              e.source != 'studio_ledger' &&
              (e.sourceManifest == null ||
                  e.sourceManifest!.validate(e.messageIds, session.messages) ==
                      MemorySourceValidity.verified),
        )
        .toList();
    final catalogCount = rows
        .where((r) => active.any((e) => e.id == r.memoryEntryId))
        .length;
    final s = book.settings;
    final slot = pipeline == null
        ? null
        : _slot(pipeline, MemorySetupScope.draftConnection);
    final generationSource = slot?['generationSource'] ?? 'current';
    final id = slot?['apiConfigId'];
    final steps = <String>[
      plan.drafts.isEmpty
          ? 'Диапазон: сейчас нет полного непокрытого диапазона (лаг $lag, блок $interval).'
          : 'Диапазон: ${plan.drafts.length} локально подходящих блоков; Scan ещё не запускался.',
      'Черновики: $pendingGeneration ожидают генерации; ошибки и регенерация проверяются в Memory Books.',
      pipeline == null
          ? 'LLM: сохранённый глобальный слот недоступен; нужна проверка в настройках подключений.'
           : generationSource == 'custom'
          ? 'LLM: используется ранее сохранённый custom-слот; доступность и ключ не проверены.'
          : id is String && id.isNotEmpty
          ? 'LLM: выбран сохранённый слот; доступность и ключ не проверены.'
          : 'LLM: используется текущий нативный слот; подключение и ключ не проверены.',
      'Утверждение: $pendingApproval ожидают явного Approve. Генерация не активирует запись.',
      'Активные записи: ${active.length}; соответствующих строк локального каталога: $catalogCount.',
      if (!s.enabled)
        'Блокер: сессионная память отключена.'
      else if (global == null || global['enabled'] == false)
        'Блокер: глобальная память отключена либо её сохранённое состояние недоступно.'
      else if (s.maxInjectedTokens == null ||
          s.maxInjectedTokens! <= 0 ||
          s.maxInjectedEntries <= 0)
        'Бюджет: точный положительный лимит инъекции не настроен.'
      else if (s.injectionTarget == 'macro')
        'Инъекция: требуется {{memory}} в реально используемом промпте; наличие макроса здесь не проверено.'
      else if (active.isEmpty)
        'Инъекция: ещё нет утверждённых активных записей.'
      else if (s.vectorSearchEnabled && global['vectorSearchEnabled'] != true)
        'Семантика: глобальный vector gate не включён или его сохранённое состояние недоступно.'
      else if (s.vectorSearchEnabled)
        'Семантика: модель embeddings, учётные данные и актуальные векторы не проверены; keyword-путь остаётся отдельным.'
      else
        'Локальные предпосылки keyword-инъекции настроены: ${s.maxInjectedEntries} записей / ${s.maxInjectedTokens} токенов. Это не проверка следующего живого запроса.',
      if (global == null)
        'Автоматика: сохранённые глобальные настройки недоступны.'
      else if (global['enabled'] == false)
        'Автоматика: глобальная память отключена.'
      else if (global['autoCreateEnabled'] == false)
        'Автоматика: ручной режим; Scan/Generate/Approve запускаются пользователем.'
      else if (global['autoGenerateEnabled'] == true)
        'Автоматика: последующие подходящие ходы могут создавать платные LLM-черновики, всегда до явного Approve.'
      else
        'Автоматика: последующие подходящие ходы создают пустые черновики, не активные записи.',
      'Deep сейчас имеет локальные возможности Balanced. Консолидация не изменена. Сетевые проверки не запускались.',
      'Наличие сохранённого ключа — только метаданные. Право memoryBooks и маршрут проверяет настоящий генератор при отдельном пользовательском Generate, не этот мастер.',
    ];
    return source()
        ? MemorySetupReadiness(List.unmodifiable(steps))
        : null;
  }
}
