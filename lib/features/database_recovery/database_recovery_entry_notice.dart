import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/theme/theme_preset.dart';
import '../../shared/widgets/glaze_action_button.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';

const _entryPreset = ThemePreset(
  id: 'recovery_entry',
  name: 'Recovery entry',
  uiFontMode: 'system',
  elementBlur: 0,
  noiseOpacity: 0,
  bgNoiseOpacity: 0,
);

/// A hot launcher request is a notice, never permission to close/reopen storage.
/// Context and process observations are injected; no providers or DB are opened.
final class AndroidRecoveryEntryNotice {
  AndroidRecoveryEntryNotice({
    required this.isNormalCurrent,
    required this.context,
  });
  final bool Function() isNormalCurrent;
  final BuildContext? Function() context;
  static const _channel = MethodChannel('app.astoria.flutter/recovery_entry');
  bool _pending = false;
  Future<void>? _showing;

  void install() => _channel.setMethodCallHandler((call) async {
    if (call.method != 'requiresColdStart' || call.arguments != null) {
      throw MissingPluginException('Recovery entry unavailable');
    }
    if (_showing == null) _pending = true;
    await presentPending();
  });

  Future<void> presentPending() {
    if (!_pending || _showing != null || !isNormalCurrent()) {
      return _showing ?? Future<void>.value();
    }
    final current = context();
    if (current == null || !current.mounted) return Future<void>.value();
    _pending = false;
    final original = _show(current);
    _showing = original;
    return original.whenComplete(() {
      if (identical(_showing, original)) _showing = null;
    });
  }

  Future<void> _show(BuildContext current) => showDialog<void>(
    context: current,
    builder: (dialog) => Dialog(
      backgroundColor: Colors.transparent,
      child: GlazeBottomSheetFrame(
        fixedPreset: _entryPreset,
        showHandle: false,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Восстановление требует отдельного холодного запуска'),
              const SizedBox(height: 16),
              const Text(
                'Astoria уже использует базу. Закрытие экрана или карточки в недавних приложениях не гарантирует остановку процесса. '
                'В информации о приложении Android нажми «Остановить», затем удержи значок Astoria и выбери «Восстановление БД». '
                'Файл и подтверждение выбираются заново. Сейчас ничего не закрыто и не восстановлено.',
              ),
              const SizedBox(height: 16),
              GlazeActionButton(
                icon: Icons.check,
                fixedPreset: _entryPreset,
                label: 'Понятно',
                expand: true,
                onTap: () => Navigator.of(dialog).pop(),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
