import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_provider.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../models/support_permission_preferences.dart';
import '../state/support_native_provider.dart';
import '../state/support_theme_provider.dart';
import 'support_theme_screen_controller.dart';
import 'support_theme_sheet.dart';

/// Installed-theme native entry, independent of model/recipient configuration.
/// Ordinary theme_setup navigation remains a separate escape hatch.
class SupportThemeEntry extends ConsumerStatefulWidget {
  const SupportThemeEntry({super.key});

  @override
  SupportThemeEntryState createState() => SupportThemeEntryState();
}

class SupportThemeEntryState extends ConsumerState<SupportThemeEntry> {
  SupportThemeScreenController? _displayed;
  final _owners = <SupportThemeScreenController>[];
  Object _lifetime = Object();
  bool _open = false;

  /// Contextual chat cards use the SAME emitted native theme owner as the header.
  Future<void> open() async {
    if (!mounted || _open) return;
    final original = _displayed;
    if (original != null && original.current) {
      return _show(original);
    }
    _open = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const _PermissionSheet(),
      );
    } finally {
      _open = false;
    }
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(themeProvider, (_, _) => _displayed?.themeChanged());
  }

  @override
  void deactivate() {
    _lifetime = Object();
    _displayed?.retire();
    super.deactivate();
  }

  @override
  void dispose() {
    for (final owner in _owners) {
      owner.dispose();
    }
    _owners.clear();
    super.dispose();
  }

  Future<void> _show(SupportThemeScreenController original) async {
    if (!mounted || _open || !identical(original, _displayed)) return;
    _open = true;
    // Modal dependencies and original owner are captured before the first await.
    try {
      await showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => SupportThemeSheet(controller: original),
      );
    } finally {
      original.retire();
      if (_owners.remove(original)) original.dispose();
      _open = false;
      if (mounted) setState(() => _displayed = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(supportNativeViewProvider);
    final allowed =
        view.themeSelected &&
        view.rights.any(
          (right) =>
              right.right == SupportPermission.readSafeSettings &&
              right.enabled,
        );
    // In the default-OFF graph, do not evaluate action/theme observation owners.
    // The permission instruction is passive and requires no configured model.
    if (!allowed) {
      _displayed?.retire();
      return IconButton(
        key: const ValueKey('support_theme_open'),
        tooltip: 'support_theme_title'.tr(),
        icon: const Icon(Icons.palette_outlined),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => const _PermissionSheet(),
        ),
      );
    }
    final binding = ref.watch(supportThemeUiBindingProvider);
    ref.watch(supportThemePresentationProvider);
    ref.listen(supportThemeUiBindingProvider, (previous, next) {
      if (!identical(previous, next)) {
        _displayed?.retire();
        _lifetime = Object();
      }
    });
    final anchor = view.displayedIntent;
    final old = _displayed;
    if (!_open &&
        anchor != null &&
        (old == null ||
            old.intent == null ||
            !old.current ||
            !identical(old.binding, binding))) {
      old?.retire();
      if (old != null && _owners.remove(old)) old.dispose();
      final lifetime = _lifetime;
      final owner = SupportThemeScreenController(
        binding: binding,
        displayedIntent: anchor,
        isUiCurrent: () => mounted && identical(lifetime, _lifetime),
      );
      _displayed = owner;
      _owners.add(owner);
    }
    final original = _displayed;
    return IconButton(
      key: const ValueKey('support_theme_open'),
      tooltip: 'support_theme_title'.tr(),
      icon: const Icon(Icons.palette_outlined),
      onPressed: original == null || _open ? null : () => _show(original),
    );
  }
}

class _PermissionSheet extends StatelessWidget {
  const _PermissionSheet();

  @override
  Widget build(BuildContext context) => SheetView(
    title: 'support_theme_title'.tr(),
    showBack: true,
    onBack: () => Navigator.of(context).pop(),
    body: Builder(
      builder: (bodyContext) => ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(bodyContext).top + 12,
          16,
          MediaQuery.paddingOf(bodyContext).bottom + 24,
        ),
        children: [Text('support_theme_permissions'.tr())],
      ),
    ),
  );
}
