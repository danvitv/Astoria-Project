// Public named injection arguments deliberately initialize private dependencies.
// ignore_for_file: prefer_initializing_formals

import '../../../core/credentials/connection_revision_registry.dart';
import '../../../core/credentials/secret_redactor.dart';
import '../../../core/db/repositories/api_config_repo.dart';
import '../models/support_recipient_resolution.dart';
import '../models/support_workspace_models.dart';
import 'support_recipient_projection.dart';

/// Read ONLY the exact durable support session's settings; null for a missing,
/// locked or unavailable session. Never workspace.load(), active roleplay or
/// metadata FutureProvider. The parent adapter must verify session existence.
typedef SupportRecipientSettingsReader =
    Future<SupportAssistantSettings?> Function(String sessionId);

/// Identification for native consent, NOT authorization, readiness or a send.
/// Call again at each gate. New registry lifetimes require explicit reconfirmation.
final class SupportRecipientResolver {
  SupportRecipientResolver({
    required ApiConfigRepo apiRepo,
    required SupportRecipientSettingsReader readSettings,
    required SupportRecipientContext? Function() currentContext,
    required ConnectionRevisionRegistry revisions,
    required SecretRedactor Function() redactor,
  }) : _apiRepo = apiRepo,
       _readSettings = readSettings,
       _currentContext = currentContext,
       _revisions = revisions,
       _redactor = redactor;

  final ApiConfigRepo _apiRepo;
  final SupportRecipientSettingsReader _readSettings;
  final SupportRecipientContext? Function() _currentContext;
  final ConnectionRevisionRegistry _revisions;
  final SecretRedactor Function() _redactor;
  static const _projection = SupportRecipientProjection();

  Future<SupportRecipientResolution> resolve(String supportSessionId) async {
    final SupportRecipientContext? context;
    try {
      context = _currentContext();
    } catch (_) {
      return const SupportRecipientUnavailable(
        SupportRecipientUnavailableReason.settingsUnavailable,
      );
    }
    if (context == null ||
        context.supportSessionId != supportSessionId ||
        context.epoch < 1) {
      return const SupportRecipientUnavailable(
        SupportRecipientUnavailableReason.staleContext,
      );
    }
    final revision = _revisions.revision;
    SupportRecipientUnavailable? checkpoint() {
      final SupportRecipientContext? current;
      try {
        current = _currentContext();
      } catch (_) {
        return const SupportRecipientUnavailable(
          SupportRecipientUnavailableReason.settingsUnavailable,
        );
      }
      if (context?.sameAs(current) != true || revision != _revisions.revision) {
        return const SupportRecipientUnavailable(
          SupportRecipientUnavailableReason.staleContext,
        );
      }
      if (!_revisions.isStable) {
        return const SupportRecipientUnavailable(
          SupportRecipientUnavailableReason.mutationPending,
        );
      }
      return null;
    }

    final initial = checkpoint();
    if (initial != null) return initial;
    try {
      final selected = await _readSettings(supportSessionId);
      final afterSettings = checkpoint();
      if (afterSettings != null) return afterSettings;
      if (selected == null) {
        return const SupportRecipientUnavailable(
          SupportRecipientUnavailableReason.settingsUnavailable,
        );
      }
      final apiId = selected.apiConfigId;
      final modelId = selected.modelId;
      if (apiId == null ||
          apiId.isEmpty ||
          modelId == null ||
          modelId.isEmpty) {
        return const SupportRecipientUnavailable(
          SupportRecipientUnavailableReason.selectionMissing,
        );
      }
      final config = await _apiRepo.getById(apiId);
      final afterConfig = checkpoint();
      if (afterConfig != null) return afterConfig;
      if (config == null) {
        return const SupportRecipientUnavailable(
          SupportRecipientUnavailableReason.connectionMissing,
        );
      }
      // Explicit reread catches late durable selection, even if a caller missed
      // a context bump. Unobserved raw-write ABA still needs a wider write fence.
      final latest = await _readSettings(supportSessionId);
      final afterLatest = checkpoint();
      if (afterLatest != null) return afterLatest;
      if (latest == null ||
          latest.apiConfigId != apiId ||
          latest.modelId != modelId) {
        return const SupportRecipientUnavailable(
          SupportRecipientUnavailableReason.staleContext,
        );
      }
      final result = _projection.project(
        context: context,
        config: config,
        modelId: modelId,
        revision: revision,
        redactor: _redactor(),
      );
      return checkpoint() ??
          result ??
          const SupportRecipientUnavailable(
            SupportRecipientUnavailableReason.unsupportedConfiguration,
          );
    } catch (_) {
      // No raw exception/config formatting, even for malformed database rows.
      return checkpoint() ??
          const SupportRecipientUnavailable(
            SupportRecipientUnavailableReason.settingsUnavailable,
          );
    }
  }
}
