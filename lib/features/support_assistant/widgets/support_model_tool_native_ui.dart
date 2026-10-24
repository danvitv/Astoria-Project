import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../models/support_app_action_context.dart';
import '../models/support_model_tool_ui_ports.dart';

/// Actual original-screen UI. Route changes latch a revision, including A→B→A.
/// No model-selected path, generic approval callback or Send confirmation.
final class SupportModelToolNativeUi
    implements SupportAppConfirmationPort, SupportAppNavigationPort {
  SupportModelToolNativeUi({
    required this.context,
    required this.isOriginalUiCurrent,
  }) : _router = GoRouter.of(context) {
    _location = _router.routeInformationProvider.value.uri;
    _router.routeInformationProvider.addListener(_observeRoute);
  }
  final BuildContext context;
  final bool Function() isOriginalUiCurrent;
  final GoRouter _router;
  late Uri _location;
  int _revision = 0;
  bool _alive = true;
  final _pending = <void Function()>{};

  SupportModelToolUiPorts get ports =>
      SupportModelToolUiPorts(confirmation: this, navigation: this);

  bool get _current => _alive && context.mounted && isOriginalUiCurrent();
  bool get isCurrent => _current;

  void _observeRoute() {
    final next = _router.routeInformationProvider.value.uri;
    if (next == _location) return;
    _location = next;
    _revision++;
    _alive = false;
    for (final close in List.of(_pending)) {
      close();
    }
  }

  @override
  Future<SupportAppConfirmationLease?> confirm(
    SupportAppConfirmationRequest request,
  ) async {
    if (!_current || !request.current) return null;
    final revision = _revision, location = _location;
    bool original() =>
        _current && _revision == revision && _location == location;
    var open = true, decided = false;
    SupportAppConfirmationLease? accepted;
    BuildContext? sheetContext;
    void close() {
      if (!open) return;
      open = false;
      final ctx = sheetContext;
      if (ctx == null || !ctx.mounted) return;
      final route = ModalRoute.of(ctx);
      final navigator = Navigator.of(ctx);
      if (route?.isCurrent == true) {
        navigator.pop();
      } else if (route?.isActive == true) {
        navigator.removeRoute(
          route!,
        ); // Only this original sheet, never route B.
      }
    }

    _pending.add(close);
    unawaited(request.context.cancelToken.whenCancel.then((_) => close()));
    try {
      await showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        useSafeArea: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              sheetContext = ctx;
              if (!open) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!ctx.mounted) return;
                  final route = ModalRoute.of(ctx);
                  if (route?.isCurrent == true) Navigator.of(ctx).pop();
                });
              }
              final footer = Row(
                children: [
                  Expanded(
                    child: GlazeActionButton(
                      key: const ValueKey('support_tool_confirmation_cancel'),
                      label: 'Отмена',
                      icon: Icons.close_rounded,
                      onTap: () {
                        if (!open || decided) return;
                        decided = true;
                        close();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GlazeActionButton(
                      key: const ValueKey('support_tool_confirmation_accept'),
                      label: 'Применить',
                      icon: Icons.check_rounded,
                      onTap: () {
                        if (!open ||
                            decided ||
                            !original() ||
                            !request.current) {
                          return;
                        }
                        decided = true;
                        // ONLY the actual final gesture creates this exact once lease.
                        accepted = SupportAppConfirmationLease(
                          request: request,
                          isOriginalUiCurrent: original,
                        );
                        close();
                      },
                    ),
                  ),
                ],
              );
              // The declarative short-form sheet scrolls its entire child. This
              // exact preview can be long, so constrain the kit frame instead and
              // keep the original gesture controls outside the preview scroll.
              return GlazeBottomSheetFrame(
                maxHeight: constraints.maxHeight * 0.95,
                child: SizedBox(
                  height: constraints.maxHeight * 0.8,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: Text(
                          'Изменение подключения',
                          style: Theme.of(ctx).textTheme.titleMedium,
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          key: const ValueKey(
                            'support_tool_confirmation_preview',
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'Действие: ${request.action}\nЦель: ${request.target}\n'
                            'Аргументы: ${jsonEncode(request.arguments)}\n'
                            'Последствия: ${jsonEncode(request.preview)}\n'
                            'Ключ не вводится, активное подключение не выбирается, сеть не проверяется.',
                          ),
                        ),
                      ),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: footer,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
      return original() && request.current ? accepted : null;
    } finally {
      open = false;
      decided = true;
      _pending.remove(close);
      sheetContext = null;
    }
  }

  @override
  Future<bool> open(
    SupportAppDestination destination,
    SupportAppActionContext original,
  ) async {
    if (!_current || !original.current) return false;
    final path = switch (destination) {
      SupportAppDestination.home => '/',
      SupportAppDestination.characters => '/characters',
      SupportAppDestination.tools => '/tools',
      SupportAppDestination.connections => '/tools/api',
      SupportAppDestination.personas => '/tools/personas',
      SupportAppDestination.presets => '/tools/presets',
      SupportAppDestination.regex => '/tools/regex',
      SupportAppDestination.lorebooks => '/tools/lorebooks',
      SupportAppDestination.embeddings => '/tools/embeddings',
      SupportAppDestination.settings => '/menu/settings',
      SupportAppDestination.themes => '/menu/themes',
      SupportAppDestination.about => '/menu/about',
      SupportAppDestination.glossary => '/menu/glossary',
    };
    // Retire this issuer synchronously BEFORE navigation can rebuild another UI.
    // The app adapter settles the navigation fact; the loop does not paint B.
    _alive = false;
    _revision++;
    _router.go(path);
    return true;
  }

  void dispose() {
    _alive = false;
    _router.routeInformationProvider.removeListener(_observeRoute);
    for (final close in List.of(_pending)) {
      close();
    }
    _pending.clear();
  }
}
