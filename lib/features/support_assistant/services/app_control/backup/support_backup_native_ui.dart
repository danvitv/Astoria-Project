import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../../shared/widgets/glaze_action_button.dart';
import '../../../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../models/support_app_action.dart';
import 'support_backup_file_host.dart';

/// Framework file-dialog boundary. Never receives body bytes or model paths.
abstract interface class SupportBackupFileDialog {
  Future<String?> saveLocalDatabase();
}

final class SupportBackupPlatformFileDialog implements SupportBackupFileDialog {
  const SupportBackupPlatformFileDialog();
  @override
  Future<String?> saveLocalDatabase() => FilePicker.saveFile(
    dialogTitle: 'Сохранить локальный снимок базы Astoria',
    fileName: 'astoria-backup.db',
    type: FileType.custom,
    allowedExtensions: const ['db'],
    // No bytes: the dialog chooses only. Snapshot core owns CREATE_NEW/publish.
  );
}

/// Actual ORIGINAL screen + SaveFile picker + final local-file consent.
/// The selected private path is visible to its native UI only, never the model.
final class SupportBackupNativeUi implements SupportBackupFileUi {
  SupportBackupNativeUi({
    required this.context,
    required this.isOriginalUiCurrent,
    this.fileDialog = const SupportBackupPlatformFileDialog(),
  }) : _router = GoRouter.of(context) {
    _location = _router.routeInformationProvider.value.uri;
    _router.routeInformationProvider.addListener(_observeRoute);
  }
  final BuildContext context;
  final bool Function() isOriginalUiCurrent;
  final SupportBackupFileDialog fileDialog;
  final GoRouter _router;
  late Uri _location;
  final _pending = <void Function()>{};
  bool _alive = true, _pickerBusy = false;

  @override
  bool get isCurrent =>
      (Platform.isWindows || Platform.isAndroid) &&
      _alive &&
      context.mounted &&
      isOriginalUiCurrent();

  void _observeRoute() {
    final next = _router.routeInformationProvider.value.uri;
    if (next == _location) return;
    _location = next;
    // Latch A→B→A too. A replacement UI cannot revive this original issuer.
    _alive = false;
    for (final close in _pending.toList()) {
      close();
    }
  }

  @override
  Future<String?> chooseLocalFile(SupportAppActionContext original) async {
    if (!isCurrent || !original.current || _pickerBusy) return null;
    if (Platform.isAndroid) {
      final root = original.domainRoot;
      if (root is! SupportBackupAppPrivateDatabaseRoot) return null;
      final proposal = root.proposeAppPrivateSnapshotDestination(original);
      return isCurrent && original.current ? proposal : null;
    }
    _pickerBusy = true;
    final preparation = Completer<String?>();
    void abandon() {
      if (!preparation.isCompleted) preparation.complete(null);
    }

    _pending.add(abandon);
    unawaited(original.cancelToken.whenCancel.then((_) => abandon()));
    // The plugin need not support dismissing an OS dialog. Only its unadmitted
    // preparation wait is cancellable. Keep observing the original plugin future
    // (including late errors), keep the OS-dialog busy latch, and drop late paths.
    Future<void> observePicker() async {
      try {
        if (!isCurrent || !original.current) {
          abandon();
          return;
        }
        final selected = await fileDialog.saveLocalDatabase();
        if (!isCurrent || !original.current) {
          abandon();
        } else if (!preparation.isCompleted) {
          preparation.complete(selected);
        }
      } catch (error, stack) {
        if (!isCurrent || !original.current) {
          abandon();
        } else if (!preparation.isCompleted) {
          preparation.completeError(error, stack);
        }
      } finally {
        _pickerBusy = false;
      }
    }

    try {
      unawaited(observePicker());
      final selected = await preparation.future;
      if (!isCurrent || !original.current) return null;
      return selected;
    } finally {
      _pending.remove(abandon);
    }
  }

  @override
  Future<SupportAppConfirmationLease?> confirmLocalFile(
    SupportAppConfirmationRequest request,
    String privateDestination,
    String disclosure,
  ) async {
    if (!isCurrent ||
        !request.current ||
        request.action != SupportBackupNativeFileHost.action ||
        disclosure != SupportBackupNativeFileHost.disclosure) {
      return null;
    }
    final location = _location;
    bool original() => isCurrent && _location == location;
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
        navigator.removeRoute(route!); // THIS original sheet only.
      }
    }

    _pending.add(close);
    unawaited(request.context.cancelToken.whenCancel.then((_) => close()));
    try {
      if (!original() || !request.current) return null;
      await showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        useSafeArea: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => LayoutBuilder(
          builder: (ctx, constraints) {
            sheetContext = ctx;
            if (!open) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (ctx.mounted && ModalRoute.of(ctx)?.isCurrent == true) {
                  Navigator.of(ctx).pop();
                }
              });
            }
            return GlazeBottomSheetFrame(
              maxHeight: constraints.maxHeight * 0.95,
              child: SizedBox(
                height: constraints.maxHeight * 0.8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Локальный снимок всей базы Astoria',
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        key: const ValueKey(
                          'support_backup_confirmation_preview',
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          '$disclosure\n\n'
                          '${Platform.isAndroid ? 'Хранилище: приватная папка Astoria на этом устройстве, '
                                    'исключённая из системного backup. Файл не отправляется '
                                    'в галерею, облако или системный диалог. Очистка данных '
                                    'или удаление Astoria может удалить и эту копию. '
                                    'Это не переносимый архив и не восстановление без ключей.\n\n' : 'Синхронизация выбранной папки другим ПО не проверяется. '
                                    'Выбери локальную несинхронизируемую папку.\n\n'}'
                          'Выбранный файл: $privateDestination\n'
                          'Действие: ${request.action}\n'
                          'Исходный запрос: ${request.callId}\n'
                          'Сеанс: ${request.context.sessionId}\n'
                          'Запуск: ${request.context.runId}',
                        ),
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Expanded(
                              child: GlazeActionButton(
                                key: const ValueKey(
                                  'support_backup_confirmation_cancel',
                                ),
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
                                key: const ValueKey(
                                  'support_backup_confirmation_accept',
                                ),
                                label: 'Сохранить локально',
                                icon: Icons.save_rounded,
                                onTap: () {
                                  if (!open ||
                                      decided ||
                                      !original() ||
                                      !request.current) {
                                    return;
                                  }
                                  decided = true;
                                  accepted = SupportAppConfirmationLease(
                                    request: request,
                                    isOriginalUiCurrent: original,
                                  );
                                  close();
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
      if (!original() || !request.current) return null;
      return accepted;
    } finally {
      open = false;
      decided = true;
      _pending.remove(close);
      sheetContext = null;
    }
  }

  void dispose() {
    _alive = false;
    _router.routeInformationProvider.removeListener(_observeRoute);
    for (final close in _pending.toList()) {
      close();
    }
    _pending.clear();
  }
}
