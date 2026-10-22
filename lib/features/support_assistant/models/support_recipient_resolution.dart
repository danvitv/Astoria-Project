import 'package:flutter/foundation.dart';

import 'support_permission_scope.dart';

/// Synchronous native ownership port. Epoch must advance BEFORE any selection,
/// session/lifetime change or pending settings edit, including ABA/failed edits.
@immutable
final class SupportRecipientContext {
  const SupportRecipientContext({
    required this.supportSessionId,
    required this.epoch,
  });
  final String supportSessionId;
  final int epoch;
  bool sameAs(SupportRecipientContext? other) =>
      other != null &&
      supportSessionId == other.supportSessionId &&
      epoch == other.epoch;
}

enum SupportRecipientUnavailableReason {
  staleContext('Выбор получателя изменился. Повтори подтверждение.'),
  mutationPending('Подключение изменяется. Повтори после сохранения.'),
  settingsUnavailable('Настройки выбранной сессии недоступны.'),
  selectionMissing('Явно выбери подключение и модель Астории.'),
  connectionMissing('Выбранное подключение недоступно.'),
  unsupportedConfiguration(
    'Маршрут этого подключения нельзя безопасно подтвердить.',
  );

  const SupportRecipientUnavailableReason(this.label);
  final String label;
}

/// Native consent display ONLY, never a model data projection or send lease.
/// No ApiConfig, headers, key metadata, arbitrary parameters or saved endpoint.
@immutable
sealed class SupportRecipientResolution {
  const SupportRecipientResolution();
}

final class SupportRecipientUnavailable extends SupportRecipientResolution {
  const SupportRecipientUnavailable(this.reason);
  final SupportRecipientUnavailableReason reason;
}

final class SupportResolvedRecipient extends SupportRecipientResolution {
  const SupportResolvedRecipient({
    required this.context,
    required this.recipient,
    required this.connectionLabel,
    required this.protocolLabel,
    required this.routingLabel,
    required this.originLabel,
    required this.operationLabel,
  });
  final SupportRecipientContext context;
  final SupportPermissionRecipient recipient;

  /// Validated actual scheme/host/meaningful port, not a raw endpoint URL.
  final String originLabel;

  /// Fixed operation name derived from the checked actual route/protocol.
  final String operationLabel;
  final String connectionLabel, protocolLabel, routingLabel;
}
