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
            'Для Memory Books сначала выбери ролевую сессию и рассмотри нужный доступ здесь. Настройки помощника независимы; чтение и изменение памяти этим ответом не реализуются. $disclaimer';
        cards.add(
          const SetupActionCard(
            topicId: 'memory_books_setup',
            title: 'Настройки Memory Books',
            description:
                'Инструкция без чтения ролевой переписки или изменения памяти.',
            steps: [
              'Выбери ролевую сессию через карточку ниже.',
              'Рассмотри отдельное разрешение на ролевые данные.',
              'Доступность чтения и настройки Memory Books проверяется отдельно.',
            ],
            primaryActionLabel: 'О настройках памяти',
          ),
        );
      case 'connection_diagnostics':
        body =
            'Это общая инструкция. Приватные результаты, если чтение разрешено, доступны только в текущей нативной панели. $disclaimer';
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
            'Это отдельная локальная помощь, не ответ модели. Нужные настройки и доступ можно рассмотреть прямо в чате. Разрешения — только предпосылки: чтение, запрос модели и изменения требуют своих нативных проверок; отправка — review получателя и точного prompt. $disclaimer';
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
