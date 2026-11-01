import '../../../core/utils/id_generator.dart';
import '../models/support_workspace_models.dart';
import 'support_guidance_planner.dart';

/// Explanatory offline responses only. No transport, repair or export claims.
class SupportLocalReplyService {
  const SupportLocalReplyService();
  static const _guidance = SupportGuidancePlanner();
  String topicForText(String text) {
    final lower = text.toLowerCase();
    final targets = _guidance.targetsFor(text: text);
    if (targets.contains(SupportGuidanceTarget.themeSetup)) {
      return 'theme_setup';
    }
    if (RegExp(
      r'диагност|diagnos|последн[а-я]* сесси|recent sessions',
    ).hasMatch(lower)) {
      return 'diagnostics';
    }
    if (targets.contains(SupportGuidanceTarget.providerSetup)) {
      return 'provider_setup';
    }
    if ((targets.isEmpty ||
            targets.contains(SupportGuidanceTarget.reportGameHistory) ||
            targets.contains(SupportGuidanceTarget.reportSupportHistory) ||
            targets.contains(
              SupportGuidanceTarget.reportPersonalDataAttachments,
            )) &&
        (lower.contains('report') ||
            lower.contains('репорт') ||
            lower.contains('отчёт') ||
            lower.contains('отчет') ||
            lower.contains('экспорт'))) {
      return 'support_report';
    }
    if (targets.contains(SupportGuidanceTarget.readGameData) &&
        (lower.contains('memory') || lower.contains('памят'))) {
      return 'memory_books_setup';
    }
    return 'help';
  }

  SupportMessageItem reply(String sessionId, String topic, {String? text}) {
    const disclaimer = 'Сетевые запросы и исправления не выполнялись.';
    final cards = <SupportCard>[];
    final targets = _guidance.targetsFor(text: text, topic: topic);
    String body;
    switch (topic) {
      case 'diagnostics':
        body =
            'Опиши проблему и отправь вопрос выбранной модели. С единым доступом к данным '
            'Астория сама находит нужные сессии и сохранённые настройки через подключённые инструменты. '
            'Этот локальный ответ данные не читал и причины ошибки не устанавливал. $disclaimer';
      case 'theme_setup':
        body =
            'Нужные область и доступ можно рассмотреть прямо здесь. Затем нативный процесс покажет точный план темы для подтверждения. $disclaimer';
        cards.add(
          const SetupActionCard(
            topicId: 'theme_setup',
            title: 'Настройки оформления',
            description:
                'Тема сейчас не считывалась и не менялась. Нативный план потребует отдельного подтверждения.',
            steps: [
              'Рассмотри область оформления и необходимые разрешения в карточках ниже.',
              'Выбери тему и режим в нативном процессе.',
              'Проверь точный план и отдельно подтверди изменение.',
            ],
            primaryActionLabel: 'Подготовить план темы',
          ),
        );
      case 'provider_setup':
        body =
            'API-ключ не вставляй в чат. Область и доступ можно рассмотреть здесь, а ключ ввести только в защищённое нативное поле. Профиль не создавался. $disclaimer';
        cards.add(
          const SetupActionCard(
            topicId: 'provider_setup',
            title: 'Настройка провайдера',
            description:
                'Нативный процесс настройки подключения покажет точные изменения до подтверждения; это не тест API.',
            steps: [
              'Рассмотри область подключений и необходимые разрешения в карточках ниже.',
              'Выбери профиль или подготовь новый в нативном процессе.',
              'Введи ключ в защищённое поле и отдельно подтверди точный план.',
            ],
            primaryActionLabel: 'Подготовить подключение',
          ),
        );
      case 'memory_books_setup':
        body =
            'Открой нативный мастер Memory Books: выбери уже загруженную ролевую сессию и ответь на пять вопросов. Для чтения нужен единый доступ к данным, а каждый точный план требует отдельного подтверждения. Этот ответ ничего не меняет. $disclaimer';
        cards.add(
          const SetupActionCard(
            topicId: 'memory_books_setup',
            title: 'Настройки Memory Books',
            description:
                'Пять вопросов, точные независимые планы и безопасный обзор Undo. Генерация не запускается автоматически.',
            steps: [
              'Разреши чтение, затем выбери реальную загруженную ролевую сессию.',
              'Выбери автоматику, профиль, бюджет, подключение и поиск.',
              'Отдельно проверь и подтверди сессионный и каждый глобальный план.',
            ],
            primaryActionLabel: 'Открыть мастер памяти',
          ),
        );
      case 'connection_diagnostics':
        body =
            'Это локальная инструкция, не результат проверки. Единый доступ к данным позволяет выбранной модели читать безопасные метаданные через подключённые инструменты, но не API-ключи. Сохранённый ключ не доказывает его работоспособность. $disclaimer';
        cards.add(
          DiagnosticCheckCard(
            checkId: 'selected-connection-metadata',
            title: 'Метаданные подключения',
            summary:
                'Данные подключения в историю не включены; проверка API не выполнялась.',
            status: SupportCheckStatus.missingEvidence,
            findings: const [],
          ),
        );
      case 'support_report':
        body =
            'Открой отдельный нативный просмотр репорта: проверь данные, исключи лишние блоки и подтверди локальное зашифрованное сохранение. Этот ответ файл не создавал; автоматической отправки разработчику нет. $disclaimer';
        cards.add(
          SupportReportCard(
            reportId: generateId(),
            summary: 'Открыть просмотр и подготовить репорт; файл ещё не сохранён.',
            fileName: '',
          ),
        );
      default:
        body =
            'Это отдельная локальная помощь, не ответ модели. «Отправить» сразу передаёт вопрос и видимый текущий диалог выбранной модели. Другие чаты и приватные источники доступны подключённым инструментам с единым согласием на чтение данных; изменения и тесты подключений требуют отдельного нативного подтверждения. $disclaimer';
        if (targets.isEmpty) {
          cards.add(
            const QuickActionChipsCard(
              title: 'Локальная помощь',
              subtitle: 'Без сетевых запросов и автоматических изменений',
            ),
          );
        }
    }
    cards.addAll(targets.map((target) => SupportGuidanceCard(target: target)));
    return SupportMessageItem(
      id: generateId(),
      sessionId: sessionId,
      role: SupportMessageRole.assistant,
      body: body,
      cards: List.unmodifiable(cards),
      createdAt: DateTime.now().toUtc(),
    );
  }
}
