import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_action_button.dart';
import '../state/support_workspace_provider.dart';

/// Empty history is not a readable session or a permission grant.
class SupportSettingsStartSession extends ConsumerStatefulWidget {
  const SupportSettingsStartSession({super.key, required this.enabled});
  final bool enabled;

  @override
  ConsumerState<SupportSettingsStartSession> createState() =>
      _StartSessionState();
}

class _StartSessionState extends ConsumerState<SupportSettingsStartSession> {
  bool _busy = false, _failed = false;

  Future<void> _start() async {
    if (_busy || !widget.enabled) return;
    final original = ref.read(supportWorkspaceProvider.notifier);
    setState(() {
      _busy = true;
      _failed = false;
    });
    String? created;
    try {
      created = await original.createNewSession();
    } catch (_) {
      // Do not expose storage errors or pretend that failed reads were empty.
    }
    if (!mounted ||
        !identical(original, ref.read(supportWorkspaceProvider.notifier))) {
      return;
    }
    setState(() {
      _busy = false;
      _failed = created == null;
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Начни сессию Астории',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        const Text(
          'Профиль и разрешения общие для Астории, история — отдельная для каждого чата. '
          'Создай чат или выбери существующий, чтобы работать с историей и выбранными источниками. '
          'Создание чата само по себе не отправляет запрос модели и не даёт новых разрешений.',
        ),
        const SizedBox(height: 16),
        GlazeActionButton(
          key: const ValueKey('support_settings_start_session'),
          icon: Icons.add_comment_outlined,
          label: 'Начать сессию',
          tone: GlazeActionTone.primary,
          expand: true,
          busy: _busy,
          onTap: widget.enabled && !_busy ? _start : null,
        ),
        if (_failed) ...[
          const SizedBox(height: 12),
          const Text(
            'Не удалось создать сессию. Проверь доступ к защищённому хранилищу.',
          ),
        ],
      ],
    ),
  );
}
