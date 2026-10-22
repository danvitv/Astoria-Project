import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';

// Static synthetic handles only. No App, platform startup, catalog or provider.
SupportPermissionRecipient permissionRecipient({
  String connection = 'synthetic-connection',
  String model = 'synthetic-model',
  String route = 'https://synthetic.invalid/v1/chat/completions',
  SupportRecipientProtocol protocol = SupportRecipientProtocol.openai,
  int revision = 1,
}) => SupportPermissionRecipient(
  connectionId: connection,
  modelId: model,
  protocol: protocol,
  nativeRoute: route,
  configurationRevision: revision,
);

SupportPermissionScope permissionScope({
  String game = 'synthetic-game',
  int revision = 1,
  List<String> gameMessages = const ['game-1', 'game-2'],
  List<String> supportMessages = const ['support-1', 'support-2'],
}) => SupportPermissionScope(
  selectionRevision: revision,
  gameSessionId: game,
  gameHistory: SupportMessageSelection(gameMessages),
  supportHistory: SupportMessageSelection(supportMessages),
  safeCategories: SupportSafeCategory.values,
  selectedData: {
    for (final c in SupportDataCategory.values) c: ['synthetic-${c.name}-1'],
  },
);

SupportPermissionPreferences permissionPolicy({
  Iterable<SupportPermission> grants = const [],
  int revision = 1,
  String identity = 'synthetic-policy',
  String session = 'synthetic-support',
  SupportPermissionScope? scope,
  SupportPermissionRecipient? recipient,
}) => SupportPermissionPreferences(
  supportSessionId: session,
  policyIdentity: identity,
  revision: revision,
  scope: scope ?? permissionScope(),
  recipient: recipient ?? permissionRecipient(),
  grants: grants,
);

List<SupportPermissionSource> permissionSources(
  SupportPermissionPreferences p,
) => [
  SupportPermissionSource.gameHistory(
    p.supportSessionId,
    p.scope!.gameSessionId!,
    p.scope!.gameHistory!,
  ),
  SupportPermissionSource.supportHistory(
    p.supportSessionId,
    p.scope!.supportHistory!,
  ),
  for (final c in p.scope!.safeCategories)
    SupportPermissionSource.safeProjection(p.supportSessionId, c),
  for (final e in p.scope!.selectedData.entries)
    SupportPermissionSource.selectedData(
      p.supportSessionId,
      p.scope!.gameSessionId!,
      e.key,
      e.value,
    ),
];
