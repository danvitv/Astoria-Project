import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/repositories/database_restore_repo.dart';
import '../../shared/theme/theme_preset.dart';
import '../../shared/widgets/glaze_action_button.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_error_block.dart';
import '../../shared/widgets/glaze_spinner.dart';
import 'database_recovery_controller.dart';

const _recoveryPreset = ThemePreset(
  id: 'offline_recovery',
  name: 'Offline recovery',
  uiFontMode: 'system',
  elementBlur: 0,
  noiseOpacity: 0,
  bgNoiseOpacity: 0,
);

/// Deliberately not GlazeApp/GoRouter/EasyLocalization: this scope contains only
/// recovery state. Fixed text/theme requires no preferences, DB or font loader.
class DatabaseRecoveryApp extends StatelessWidget {
  const DatabaseRecoveryApp({
    super.key,
    required this.controller,
    this.targetPath,
  });
  final DatabaseRecoveryController controller;
  final String? targetPath;

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      databaseRecoveryControllerProvider.overrideWith(() => controller),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Astoria offline recovery',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFF5C400),
      ),
      home: DatabaseRecoveryScreen(targetPath: targetPath),
    ),
  );
}

class DatabaseRecoveryScreen extends ConsumerStatefulWidget {
  const DatabaseRecoveryScreen({super.key, this.targetPath});
  final String? targetPath;

  @override
  ConsumerState<DatabaseRecoveryScreen> createState() =>
      _DatabaseRecoveryScreenState();
}

class _DatabaseRecoveryScreenState
    extends ConsumerState<DatabaseRecoveryScreen> {
  late DatabaseRecoveryController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(databaseRecoveryControllerProvider.notifier);
  }

  @override
  void dispose() {
    _controller.retireView(); // No DB/raw/process-guard disposal.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(databaseRecoveryControllerProvider);
    final blocked = state.phase == DatabaseRecoveryPhase.blocked;
    final proposal = state.proposal;
    final operation = state.operation;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_controller.cancel());
      },
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: GlazeBottomSheetFrame(
                fixedPreset: _recoveryPreset,
                showHandle: false,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Astoria offline recovery',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        Platform.isAndroid
                            ? 'This cold-start recovery surface opened from the Android launcher shortcut. '
                                  'Choose a self-contained .db backup, review the destination, then approve replacement. '
                                  'The launcher action itself grants no file or restore approval.'
                            : 'The normal application is not open. Nothing is restored by a command-line flag. '
                                  'Choose a local .db backup, review the fixed destination, then use the destructive button below.',
                      ),
                      if (Platform.isAndroid) ...[
                        const SizedBox(height: 12),
                        const Text(
                          'Android’s picker makes a private cache copy; that copy is checked, not the external original. '
                          'Use an exported main-only backup. Missing sidecars in the copy do not prove that the original had no WAL. '
                          'Only the verified logical original is retained; no raw four-file archive is promised.',
                        ),
                      ],
                      const SizedBox(height: 16),
                      if (widget.targetPath case final target?) ...[
                        const Text('This installation’s exact destination:'),
                        SelectableText(target),
                        const SizedBox(height: 12),
                      ],
                      if (state.selectedPath case final source?) ...[
                        const Text(
                          'Selected backup (private to this recovery screen):',
                        ),
                        SelectableText(source),
                        const SizedBox(height: 12),
                      ],
                      const Text(
                        'After fresh approval, opening SQLite for writing can recover or change native journals '
                        'and sidecars before copying begins. Astoria retains a logical original made by native SQLite backup '
                        'after that bootstrap; this is not a byte-identical four-file guarantee or power-loss repair. '
                        'Unreadable database headers and missing installation vault keys cannot be reconstructed. '
                        'Originals remain retained by default.',
                      ),
                      const SizedBox(height: 20),
                      if (state.code != null || state.keyFailure != null) ...[
                        GlazeErrorBlock(
                          label: blocked
                              ? 'STARTUP BLOCKED'
                              : 'RECOVERY UNAVAILABLE',
                          message: state.keyFailure != null
                              ? 'The existing installation key is missing, invalid, or unavailable. No key was created or replaced.'
                              : _message(state.code!),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (state.busy) ...[
                        const Center(child: GlazeSpinner()),
                        const SizedBox(height: 8),
                        Text(
                          state.phase == DatabaseRecoveryPhase.cancelling
                              ? 'Waiting for the original operation to settle. Late picker results will be ignored.'
                              : state.phase == DatabaseRecoveryPhase.restoring
                              ? 'Waiting for SQLite’s actual restore or reverse settlement.'
                              : 'Waiting for the original operation. No second selection can start.',
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (proposal != null && operation != null)
                        GlazeActionButton(
                          key: const ValueKey('recovery-confirm'),
                          fixedPreset: _recoveryPreset,
                          icon: Icons.warning_amber_rounded,
                          label: 'Replace this installation database',
                          tone: GlazeActionTone.destructive,
                          expand: true,
                          // Capture EXACT opaque proposal/operation. A stale old button
                          // cannot admit a later selection or confirm twice.
                          onTap: () {
                            unawaited(_controller.confirm(operation, proposal));
                          },
                        ),
                      if (!blocked && proposal == null)
                        GlazeActionButton(
                          key: const ValueKey('recovery-pick'),
                          fixedPreset: _recoveryPreset,
                          icon: Icons.folder_open,
                          label: 'Choose local .db backup',
                          expand: true,
                          onTap: !state.busy && _controller.recoveryAvailable
                              ? () {
                                  unawaited(_controller.chooseFile());
                                }
                              : null,
                        ),
                      if (!blocked) ...[
                        const SizedBox(height: 12),
                        GlazeActionButton(
                          key: const ValueKey('recovery-cancel'),
                          fixedPreset: _recoveryPreset,
                          icon: Icons.close,
                          label: 'Cancel selection / go back',
                          expand: true,
                          onTap: proposal != null || state.busy
                              ? () {
                                  unawaited(_controller.cancel());
                                }
                              : null,
                        ),
                        const SizedBox(height: 12),
                        GlazeActionButton(
                          key: const ValueKey('recovery-continue'),
                          fixedPreset: _recoveryPreset,
                          icon: Icons.arrow_forward,
                          label: 'Continue normal startup without restore',
                          expand: true,
                          onTap: !state.busy && proposal == null
                              ? () {
                                  unawaited(_controller.continueNormally());
                                }
                              : null,
                        ),
                      ],
                      if (blocked)
                        const Text(
                          'Close this process. Normal startup remains blocked; '
                          'no automatic retry, marker replay, or fallback database will be opened.',
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _message(DatabaseRestoreCode code) => switch (code) {
  DatabaseRestoreCode.busy =>
    Platform.isAndroid
        ? 'Astoria still owns startup. Removing its Activity or recent-task card is not a process stop. '
              'Use Android App info → Force stop, then the launcher’s Database recovery shortcut. No database was opened here.'
        : 'Another process owns startup. No migration or normal database open was attempted.',
  DatabaseRestoreCode.interruptedRequiresFreshConfirmation =>
    'An interrupted-restore marker blocks startup. It will not be cleared or replayed.',
  DatabaseRestoreCode.unsupported =>
    Platform.isAndroid
        ? 'The native Android storage or SQLite identity mechanism is unsupported. No replacement was authorized.'
        : 'This recovery mode requires an existing canonical local Windows installation and supported storage.',
  DatabaseRestoreCode.originalRestored =>
    'SQLite reported the logical original restored. Normal fallback is deliberately not automatic.',
  DatabaseRestoreCode.unavailable =>
    'Recovery is unavailable. An absent installation may continue through guarded normal first-run startup.',
  DatabaseRestoreCode.invalidCandidate =>
    'The selected backup or its encrypted data could not be validated. No new restore approval remains.',
  _ =>
    'The operation did not authorize normal startup. The process guard remains held; close the process before trying again.',
};
