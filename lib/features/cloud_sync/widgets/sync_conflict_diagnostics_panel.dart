import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/sheet_view.dart';

/// Displays only the service's safe report. Never receives raw conflicts.
class SyncConflictDiagnosticsPanel extends StatefulWidget {
  const SyncConflictDiagnosticsPanel({
    super.key,
    required this.runner,
    required this.onBack,
    this.syncBusy = false,
  });

  final Future<String> Function() runner;
  final VoidCallback onBack;
  final bool syncBusy;

  @override
  State<SyncConflictDiagnosticsPanel> createState() =>
      _SyncConflictDiagnosticsPanelState();
}

class _SyncConflictDiagnosticsPanelState
    extends State<SyncConflictDiagnosticsPanel> {
  int _epoch = 0;
  bool _closed = false;
  bool _running = false;
  bool _copying = false;
  String? _report;
  String? _messageKey;

  bool _owns(int epoch) => mounted && !_closed && _epoch == epoch;

  void _close() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    widget.onBack();
  }

  Future<void> _run() async {
    if (_closed || _running || _copying || widget.syncBusy) return;
    final runner = widget.runner;
    final epoch = ++_epoch;
    setState(() {
      _running = true;
      _report = null;
      _messageKey = null;
    });
    try {
      final report = await runner();
      if (!_owns(epoch)) return;
      setState(() => _report = report);
    } catch (_) {
      if (!_owns(epoch)) return;
      setState(() => _messageKey = 'sync_diagnostics_error');
    } finally {
      if (_owns(epoch)) setState(() => _running = false);
    }
  }

  Future<void> _copy() async {
    final report = _report;
    if (_closed || _running || _copying || report == null) return;
    final epoch = _epoch;
    setState(() => _copying = true);
    try {
      await Clipboard.setData(ClipboardData(text: report));
      if (!_owns(epoch)) return;
      setState(() => _messageKey = 'sync_diagnostics_copied');
    } catch (_) {
      if (!_owns(epoch)) return;
      setState(() => _messageKey = 'sync_diagnostics_copy_error');
    } finally {
      if (_owns(epoch)) setState(() => _copying = false);
    }
  }

  @override
  void dispose() {
    _closed = true;
    _epoch++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _close();
    },
    child: SheetView(
      title: 'sync_diagnostics_title'.tr(),
      showBack: true,
      canPop: false,
      onBack: _close,
      body: Builder(
        builder: (context) => ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.paddingOf(context).top + 12,
            16,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: [
            Text('sync_diagnostics_privacy'.tr()),
            const SizedBox(height: 12),
            GlazeActionButton(
              key: const Key('sync-diagnostics-run'),
              icon: Icons.fact_check_outlined,
              label:
                  (_running
                          ? 'sync_diagnostics_running'
                          : 'sync_diagnostics_run')
                      .tr(),
              onTap: widget.syncBusy || _copying ? null : _run,
              busy: _running,
              expand: true,
            ),
            if (widget.syncBusy && !_running) ...[
              const SizedBox(height: 12),
              Text('sync_diagnostics_sync_busy'.tr()),
            ],
            if (_report != null) ...[
              const SizedBox(height: 16),
              SelectableText(
                _report!,
                key: const Key('sync-diagnostics-report'),
                style: TextStyle(color: context.cs.onSurface),
                // Export is restricted to the explicit copy action below.
                contextMenuBuilder: (_, _) => const SizedBox.shrink(),
              ),
              const SizedBox(height: 12),
              GlazeActionButton(
                key: const Key('sync-diagnostics-copy'),
                icon: Icons.copy_outlined,
                label: 'sync_diagnostics_copy'.tr(),
                onTap: _copy,
                busy: _copying,
                expand: true,
              ),
            ],
            if (_messageKey != null) ...[
              const SizedBox(height: 12),
              Text(_messageKey!.tr()),
            ],
          ],
        ),
      ),
    ),
  );
}
