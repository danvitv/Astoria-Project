import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_bottom_sheet.dart';
import 'support_action_strip.dart';

/// Informational only: there is no report preparation/export/transfer backend.
Future<void> showSupportReportStatus(BuildContext context) async {
  await GlazeBottomSheet.show<void>(
    context,
    title: 'Репорт разработчику',
    child: const Padding(
      padding: EdgeInsets.all(16),
      child: Text(
        'Подготовка, экспорт и отправка репорта пока недоступны. '
        'Файл не создан, ничего не отправлено.\n\n'
        'Передача разработчику будет отдельным действием: сначала точный '
        'просмотр включённых данных. Ты решаешь, включать ли нужную историю, '
        'названия сессий и личное содержимое, и явно подтверждаешь передачу. '
        'Отмена означает, что передача не состоится. Общий доступ ассистента '
        'к данным не является согласием на репорт.',
      ),
    ),
  );
}

class SupportReportStatusAction extends StatelessWidget {
  const SupportReportStatusAction({super.key});

  @override
  Widget build(BuildContext context) => SupportActionTile(
    key: const ValueKey('support_panel_report_action'),
    icon: Icons.description_outlined,
    label: 'Репорт: недоступен',
    tooltip: 'Экспорт и передача пока недоступны. Узнать правила передачи',
    onTap: () => showSupportReportStatus(context),
  );
}
