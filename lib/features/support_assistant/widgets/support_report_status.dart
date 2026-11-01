import 'package:flutter/material.dart';

import 'support_action_strip.dart';
import 'support_report_sheet.dart';

/// Existing setup/root actions open an actual NEW native preview/save flow.
Future<void> showSupportReportStatus(BuildContext context) =>
    showSupportReportSheet(context);

class SupportReportStatusAction extends StatelessWidget {
  const SupportReportStatusAction({super.key});

  @override
  Widget build(BuildContext context) => SupportActionTile(
    key: const ValueKey('support_panel_report_action'),
    icon: Icons.description_outlined,
    label: 'Подготовить репорт',
    tooltip:
        'Точный просмотр, исключение блоков и локальное зашифрованное сохранение',
    onTap: () => showSupportReportStatus(context),
  );
}
