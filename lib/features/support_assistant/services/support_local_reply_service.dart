import '../../../core/utils/id_generator.dart';
import '../../../core/credentials/api_connection_metadata.dart';
import '../models/support_workspace_models.dart';

/// Explanatory offline responses only. No transport, repair or export claims.
class SupportLocalReplyService {
  const SupportLocalReplyService();
  String topicForText(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('тем') || lower.contains('theme')) return 'theme_setup';
    if (lower.contains('ключ') ||
        lower.contains('api') ||
        lower.contains('провайдер')) {
      return 'provider_setup';
    }
    if (lower.contains('memory') || lower.contains('памят')) {
      return 'memory_books_setup';
    }
    if (lower.contains('report') || lower.contains('репорт')) {
      return 'support_report';
    }
    return 'help';
  }

  SupportMessageItem reply(
    String sessionId,
    String topic,
    ApiConnectionMetadata? connection,
  ) {
    const disclaimer = 'Сетевые запросы и исправления не выполнялись.';
    final cards = <SupportCard>[];
    String body;
    switch (topic) {
      case 'theme_setup':
        body = 'Выбери оформление в настройках приложения. $disclaimer';
        cards.add(
          const SetupActionCard(
            topicId: 'theme_setup',
            title: 'Настройки оформления',
            description:
                'Инструкция; текущая тема не считывалась и не менялась.',
            steps: [
              'Открой настройки оформления.',
              'Выбери одну из доступных тем и режим dark/light.',
              'Проверь читаемость интерфейса.',
            ],
            primaryActionLabel: 'Открыть настройки',
          ),
        );
      case 'provider_setup':
        body =
            'API-ключ не вставляй в чат. Введи его в настройках подключения. Профиль не создавался. $disclaimer';
        cards.add(
          SetupActionCard(
            topicId: 'provider_setup',
            title: 'Настройка провайдера',
            description:
                'Выбери провайдера, протокол, endpoint и модель в настройках API.',
            steps: const [
              'Открой настройки API.',
              'Добавь или выбери подключение.',
              'Введи ключ в предназначенное для него поле.',
            ],
            primaryActionLabel: 'Открыть настройки',
            credentialMetadata: connection?.llmCredential,
          ),
        );
      case 'memory_books_setup':
        body =
            'Параметры Memory Books настраиваются в ролевой сессии; настройки помощника независимы. $disclaimer';
        cards.add(
          const SetupActionCard(
            topicId: 'memory_books_setup',
            title: 'Настройки Memory Books',
            description:
                'Инструкция без чтения ролевой переписки или изменения памяти.',
            steps: [
              'Открой нужную ролевую сессию.',
              'Открой настройки Memory Books.',
              'Проверь область действия, бюджет и модель генерации.',
            ],
            primaryActionLabel: 'Открыть настройки',
          ),
        );
      case 'connection_diagnostics':
        body = 'Показаны только метаданные выбранного подключения. $disclaimer';
        cards.add(
          DiagnosticCheckCard(
            checkId: 'selected-connection-metadata',
            title: 'Метаданные подключения',
            summary: connection == null
                ? 'Подключение не выбрано или отсутствует.'
                : 'Это конфигурация, не доказательство работоспособности API.',
            status: SupportCheckStatus.missingEvidence,
            findings: connection == null
                ? const []
                : [
                    'Подключение: ${connection.displayName}',
                    'Протокол: ${connection.protocol}',
                    'Endpoint: ${connection.endpoint}',
                    'Ключ настроен: ${connection.configured}; символов: ${connection.characterCount}',
                  ],
          ),
        );
      case 'support_report':
        body =
            'Экспорт репорта пока недоступен. Файл не создан и не зашифрован. $disclaimer';
        cards.add(
          SupportReportCard(
            reportId: generateId(),
            summary: 'Информация о будущем экспорте, не готовый репорт.',
            fileName: '',
          ),
        );
      default:
        body =
            'Могу объяснить настройки или показать метаданные выбранного подключения. Генерация через LLM пока недоступна. $disclaimer';
        cards.add(
          const QuickActionChipsCard(
            title: 'Локальная помощь',
            subtitle: 'Без сетевых запросов и автоматических изменений',
          ),
        );
    }
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
