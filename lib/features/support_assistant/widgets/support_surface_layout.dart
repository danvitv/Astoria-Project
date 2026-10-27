import 'package:flutter/material.dart';

/// One header row inside SheetView's title slot. The stock sheet back target is
/// 40px; Astoria supplies its own 48px control without changing shared chrome.
class SupportSheetTitle extends StatelessWidget {
  const SupportSheetTitle({
    super.key,
    required this.title,
    required this.onBack,
    this.backKey,
    this.titleKey,
  });
  final String title;
  final VoidCallback onBack;
  final Key? backKey;
  final Key? titleKey;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton(
        key: backKey,
        tooltip: 'Назад',
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        icon: const Icon(Icons.arrow_back, size: 20),
        onPressed: onBack,
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          title,
          key: titleKey,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    ],
  );
}

/// SheetView supplies header padding to the whole body, even when only the
/// preview scrolls. Reserve that top once, and keep decisions above the IME.
class SupportSheetDecisionBody extends StatelessWidget {
  const SupportSheetDecisionBody({
    super.key,
    required this.content,
    required this.footer,
  });
  final Widget content;
  final Widget footer;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: content,
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            MediaQuery.paddingOf(context).bottom + 12,
          ),
          child: footer,
        ),
      ],
    ),
  );
}

/// SheetView owns keyboard lift; only its supplied header/nav padding belongs
/// in the scroll content. Embedded desktop panels deliberately opt out of top.
EdgeInsets supportSurfacePadding(
  BuildContext context, {
  bool sheetHosted = true,
  double horizontal = 0,
  double top = 12,
  double bottom = 24,
}) {
  final inset = MediaQuery.paddingOf(context);
  return EdgeInsets.fromLTRB(
    horizontal,
    top + (sheetHosted ? inset.top : 0),
    horizontal,
    bottom + inset.bottom,
  );
}

/// Kit controls with non-nullable handlers still need honest unavailable UI.
/// This does not replace their original intent/callback guards.
class SupportControlAvailability extends StatelessWidget {
  const SupportControlAvailability({
    super.key,
    required this.enabled,
    required this.child,
  });
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    enabled: enabled,
    child: ExcludeFocus(
      excluding: !enabled,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Opacity(opacity: enabled ? 1 : 0.45, child: child),
      ),
    ),
  );
}
