import 'package:flutter/material.dart';

import '../../../shared/widgets/sheet_view.dart';
import 'support_action_strip.dart';
import 'support_source_preparation_sheet.dart';
import 'support_surface_layout.dart';

/// Mounted only behind the existing experimental gate. Navigation is not grant.
class SupportSourcePreparationEntry extends StatefulWidget {
  const SupportSourcePreparationEntry({super.key});

  @override
  State<SupportSourcePreparationEntry> createState() => _EntryState();
}

class _EntryState extends State<SupportSourcePreparationEntry> {
  bool _open = false;

  Future<void> _show() async {
    if (_open) return;
    setState(() => _open = true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => SheetView(
          title: 'Локальная подготовка источников',
          showBack: false,
          titleWidget: SupportSheetTitle(
            title: 'Локальная подготовка источников',
            onBack: () => Navigator.of(sheetContext).pop(),
          ),
          onBack: () => Navigator.of(sheetContext).pop(),
          body: const SupportSourcePreparationSheet(),
        ),
      );
    } finally {
      if (mounted) setState(() => _open = false);
    }
  }

  @override
  Widget build(BuildContext context) => SupportActionTile(
    key: const ValueKey('support_local_source_preparation'),
    icon: Icons.manage_search_rounded,
    label: 'Источники',
    tooltip: 'Подготовить историю для навигации — без передачи модели',
    selected: _open,
    onTap: _open ? null : _show,
  );
}
