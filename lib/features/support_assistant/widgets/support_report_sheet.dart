import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/support_consent_selection.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../services/report/support_report_coordinator.dart';
import '../models/support_permission_preferences.dart';
import '../state/support_native_provider.dart';
import '../state/support_report_provider.dart';
import 'support_application_data_consent.dart';
import 'support_surface_layout.dart';

part 'support_report_preview_body.dart';

/// Always starts a NEW native flow. Report IDs/model flags are deliberately not
/// accepted: a model card cannot attest creation of an encrypted OS file.
Future<void> showSupportReportSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 900),
      builder: (_) => const SupportReportSheet(),
    );

class SupportReportSheet extends ConsumerStatefulWidget {
  const SupportReportSheet({super.key});
  @override
  ConsumerState<SupportReportSheet> createState() => _SupportReportSheetState();
}

class _SupportReportSheetState extends ConsumerState<SupportReportSheet> {
  final _launch = Object();
  late SupportReportNotifier _flow;
  bool _closed = false, _selecting = false, _includeCurrent = false;
  SupportConsentSessionOption? _game;
  String? _selectionMessage;

  @override
  void initState() {
    super.initState();
    _flow = ref.read(supportReportProvider(_launch).notifier);
    scheduleMicrotask(() {
      if (mounted && !_closed) {
        _flow.prepare(const SupportReportPrepareRequest());
      }
    });
  }

  @override
  void dispose() {
    _flow.cancel();
    super.dispose();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _flow.cancel(); // Retires ciphertext admission BEFORE dismissing the sheet.
    Navigator.of(context).pop();
  }

  Future<void> _include({required bool game}) async {
    if (_closed || _selecting) return;
    if (!ref.exists(supportNativeRuntimeProvider)) {
      setState(
        () => _selectionMessage =
            'Оригинальная сессия недоступна. Открой ассистента заново.',
      );
      return;
    }
    final controller = ref.read(supportNativeConsentControllerProvider);
    final runtime = controller.runtime;
    final issuer = controller.view.displayedIntent;
    // Capture both producers synchronously. Their producer-owned retirement
    // hooks/issuer generation are observed directly after awaits; no live
    // provider lookup (including a comparison) may create a replacement graph.
    final selectors = game
        ? ref.read(supportConsentSelectionRepoProvider)
        : null;
    final session = runtime.sessionId, lifetime = runtime.lifetime;
    final configuration = runtime.configurationRevision();
    int? contentEpoch, contentRevocation;
    bool current() =>
        mounted &&
        !_closed &&
        runtime.alive &&
        controller.ownsDisplayedIssuer(issuer) &&
        (selectors?.isOriginalOwnerCurrent ?? true) &&
        runtime.sessionId == session &&
        runtime.lifetime == lifetime &&
        runtime.configurationRevision() == configuration &&
        runtime.configurationStable() &&
        (contentEpoch == null || runtime.epoch == contentEpoch) &&
        (contentRevocation == null ||
            (runtime.permissions.applicationDataRevocationRevision ==
                    contentRevocation &&
                !runtime.permissions.applicationDataReadDenied));
    _flow.discardPreview();
    setState(() {
      _selecting = true;
      _selectionMessage = null;
    });
    try {
      if (runtime.permissions.applicationDataReadDenied ||
          runtime.snapshot.preferences?.allows(
                SupportPermission.readApplicationData,
              ) !=
              true ||
          runtime.snapshot.preferences?.isGlobal != true) {
        final accepted = await requestSupportApplicationDataConsent(
          context: context,
          controller: controller,
          displayedIntent: issuer,
          isCurrent: current,
        );
        if (!current()) return;
        if (accepted != true) {
          _selectionMessage =
              'Личные данные не добавлены. Подготовь безопасную диагностику заново.';
          return;
        }
      }
      if (!current()) return;
      contentEpoch = runtime.epoch;
      contentRevocation = runtime.permissions.applicationDataRevocationRevision;
      if (game) {
        // Typed, bounded LOCAL report-content selection. This does not mutate
        // read permission scope or invoke the source consent dialogs.
        final page = await selectors!.listRoleplaySessions();
        if (!mounted || !current()) {
          return;
        }
        final picked = await GlazeBottomSheet.show<SupportConsentSessionOption>(
          context,
          title: 'Одна игровая сессия для репорта',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Выбор содержимого репорта, не разрешение ассистенту. '
                  'Будут включены название и доступная ограниченная история. '
                  'Показана только первая страница, не все сессии.',
                ),
              ),
              if (page.items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Доступных сессий нет.'),
                ),
              for (final option in page.items)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: GlazeActionButton(
                    label: option.label,
                    icon: Icons.chat_outlined,
                    maxLabelLines: null,
                    expand: true,
                    onTap:
                        option.status ==
                                SupportConsentSelectionStatus.available &&
                            current()
                        ? () => Navigator.of(
                            context,
                            rootNavigator: true,
                          ).pop(option)
                        : null,
                  ),
                ),
            ],
          ),
        );
        if (!current()) return;
        if (picked == null) {
          _selectionMessage = 'Выбор отменён. Личные данные не добавлены.';
          return;
        }
        _game = picked;
      } else {
        _includeCurrent = true;
      }
      // Grant changes the native epoch/revocation revision. This is a NEW
      // capture/preview, never a rebinding or widening of the old preview.
      await _flow.prepare(
        SupportReportPrepareRequest(
          supportSessionId: _includeCurrent ? session : null,
          gameSessionId: _game?.sessionId,
          includeTitles: true,
          includeProse: true,
        ),
      );
    } catch (_) {
      if (current()) {
        _selectionMessage = 'Источник недоступен. Личные данные не добавлены.';
      }
    } finally {
      if (mounted && !_closed) setState(() => _selecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(supportReportProvider(_launch));
    final preview = state.preview;
    if (preview != null && !state.displayed && !state.busy) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_closed) _flow.markDisplayed(preview);
      });
    }
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _flow.cancel();
      },
      child: SheetView(
        title: 'Зашифрованный репорт',
        showBack: false,
        onBack: _close,
        titleWidget: SupportSheetTitle(
          title: 'Зашифрованный репорт',
          onBack: _close,
        ),
        body: Builder(
          builder: (context) => SupportSheetDecisionBody(
            content: _SupportReportPreviewBody(
              state: state,
              selectionMessage: _selectionMessage,
              onExclude: _selecting ? null : _flow.exclude,
              onIncludeCurrent: state.busy || _selecting || state.finished
                  ? null
                  : () => _include(game: false),
              onIncludeGame: state.busy || _selecting || state.finished
                  ? null
                  : () => _include(game: true),
              onSafe: state.busy || _selecting
                  ? null
                  : () {
                      setState(() {
                        _includeCurrent = false;
                        _game = null;
                        _selectionMessage = null;
                      });
                      _flow.prepare(const SupportReportPrepareRequest());
                    },
            ),
            footer: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GlazeActionButton(
                  key: const ValueKey('support_report_save'),
                  expand: true,
                  label: 'Сохранить зашифрованный репорт',
                  maxLabelLines: null,
                  icon: Icons.save_outlined,
                  busy: state.busy,
                  onTap: state.canSave && !_selecting ? _flow.save : null,
                ),
                const SizedBox(height: 8),
                GlazeActionButton(
                  key: const ValueKey('support_report_cancel'),
                  expand: true,
                  label: 'Закрыть',
                  icon: Icons.close,
                  onTap: _close,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
