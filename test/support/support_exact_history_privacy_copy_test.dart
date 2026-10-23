import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Source assets only: no rootBundle, EasyLocalization, App or provider startup.
void main() {
  for (final language in ['en', 'ru']) {
    test(
      '$language privacy copy describes exact history and text approval boundaries',
      () async {
        final m =
            jsonDecode(
                  await File(
                    'assets/translations/$language.json',
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        final local = m['support_privacy_section_local_notice'] as String;
        final model = m['support_privacy_section_model_notice'] as String;
        final metadata = m['support_privacy_metadata_only'] as String;
        final russian = language == 'ru';
        for (final phrase
            in russian
                ? [
                    'только явно выбранные сообщения игровой истории и чата Астории',
                    'безопасные метаданные выбранного подключения',
                    'не разрешает передачу модели или включение в отчёт',
                    'карточки персонажей, память, лор, канон, переменные, вложения и диагностика пока недоступны',
                    'Переключатель не загружает содержимое',
                  ]
                : [
                    'Only explicitly selected game-history and Astoria chat-history messages',
                    'safe selected-connection metadata',
                    'does not permit model sharing or report inclusion',
                    'character cards, memory, lore, canon, variables, attachments and diagnostics remain unavailable',
                    'A toggle does not load content',
                  ]) {
          expect(local, contains(phrase));
        }
        for (final phrase
            in russian
                ? [
                    'только текстовый запрос явно выбранной модели',
                    'явного одобрения полного точного предварительного просмотра',
                    'История игровой сессии и история чата Астории имеют отдельные переключатели передачи',
                    'локальное чтение и включение в отчёт независимы',
                    'Ключи не включаются в текст запроса и не раскрываются Астории',
                    'инструменты и DCP пока недоступны',
                  ]
                : [
                    'Only text requests to the explicitly selected model',
                    'explicitly approving the complete exact preview',
                    'Game-session history and Astoria chat history have separate sharing toggles',
                    'local reading and report inclusion remain independent',
                    'Keys are not included in prompt text or exposed to Astoria',
                    'tools and DCP remain unavailable',
                  ]) {
          expect(model, contains(phrase));
        }
        expect(
          model,
          isNot(
            contains(
              russian
                  ? 'Запуск LLM и загрузка содержимого пока недоступны'
                  : 'LLM execution and content loading are unavailable',
            ),
          ),
        );
        expect(
          metadata,
          contains(
            russian
                ? 'В этом окне выбора только метаданные'
                : 'This picker contains metadata only',
          ),
        );
        expect(
          metadata,
          contains(
            russian
                ? 'это окно не загружает и не показывает содержимое'
                : 'this picker does not load or preview content',
          ),
        );
        expect(
          metadata,
          contains(
            russian
                ? 'не даёт права чтения или передачи'
                : 'grants no reading or sharing rights',
          ),
        );
        expect(
          m['support_privacy_right_modelGameHistory'],
          russian
              ? 'Передать историю игровой сессии'
              : 'Share game-session history',
        );
        expect(
          m['support_privacy_right_modelSupportHistory'],
          russian
              ? 'Передать историю чата Астории'
              : 'Share Astoria chat history',
        );
        expect(
          m['support_privacy_right_reportGameHistory'],
          russian
              ? 'Включить выбранную игровую историю в отчёт'
              : 'Include selected game history in a report',
        );
        expect(
          m['support_privacy_right_reportSupportHistory'],
          russian
              ? 'Включить выбранную историю Астории в отчёт'
              : 'Include selected Astoria history in a report',
        );
        expect(
          m['support_privacy_right_reportPersonalDataAttachments'],
          russian
              ? 'Включить выбранные личные данные и вложения в отчёт'
              : 'Include selected personal data and attachments in a report',
        );
        expect(
          m['support_privacy_section_report_notice'],
          russian
              ? 'Отчёт не создаётся и не отправляется переключателем. Экспорт и точный предварительный просмотр пока недоступны; согласие модели не является согласием на отчёт.'
              : 'Toggles neither create nor send reports. Export and exact preview are unavailable; model consent is not report consent.',
        );
        expect(
          m['support_privacy_section_changes_notice'],
          contains(
            russian
                ? 'Только выбор установленной темы поддерживает точное нативное применение и отдельно проверенный условный Undo'
                : 'Installed-theme selection alone supports exact native Apply and separately reviewed conditional Undo',
          ),
        );
        expect(
          m['support_privacy_section_changes_notice'],
          contains(
            russian
                ? 'Это предварительное право не подтверждает действие'
                : 'This prerequisite is not action approval',
          ),
        );
        expect(
          m['support_privacy_section_changes_notice'],
          contains(
            russian
                ? 'Режим темы, провайдер, Memory и все остальные изменения пока недоступны'
                : 'Theme mode, provider, Memory and all other changes remain unavailable',
          ),
        );
        expect(
          m['support_privacy_section_network_notice'],
          contains(
            russian
                ? 'Исполнитель проверок пока недоступен'
                : 'The test executor is unavailable',
          ),
        );
      },
    );
  }
}
