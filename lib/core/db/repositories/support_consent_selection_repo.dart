import 'package:drift/drift.dart';

import '../../credentials/secret_redactor.dart';
import '../../models/support_consent_selection.dart';
import '../app_db.dart';
import 'support_repo.dart';

part 'support_consent_selection/roleplay_selection_projection.dart';
part 'support_consent_selection/roleplay_session_catalog.dart';
part 'support_consent_selection/support_selection_projection.dart';
part 'support_consent_selection/selection_projection_values.dart';
part 'support_consent_selection/session_metadata_projection.dart';

/// Owns read-only, allowlisted selector projections. No providers, startup,
/// caches, writes, whole body models, or assistant-read authorization.
final class SupportConsentSelectionRepo {
  SupportConsentSelectionRepo({
    required AppDatabase db,
    required SupportRepo supportRepo,
    required SecretRedactor Function() currentRedactor,
    bool Function()? originalOwnerCurrent,
  }) : _roleplay = _RoleplaySelectionProjection(db, currentRedactor),
       _support = _SupportSelectionProjection(db, supportRepo, currentRedactor),
       _originalOwnerCurrent = originalOwnerCurrent;

  static const maxSessionPageSize = 50;
  static const maxMessagePageSize = 100;
  static const maxSourceMessages = 2000;
  static const maxRoleplaySourceChars = 2 * 1024 * 1024;
  static const maxOffset = 10000;
  // Same bounded parent envelope as the explicit text reader. No body is read.
  static const maxSessionParentEnvelopeChars =
      512 * 256 + 4 * ((4 * 65536 + 2) ~/ 3);

  final _RoleplaySelectionProjection _roleplay;
  final _SupportSelectionProjection _support;
  final bool Function()? _originalOwnerCurrent;

  /// Native producer lifetime only. Consumers retain this exact repository;
  /// observing retirement must not resolve or instantiate a replacement graph.
  bool get isOriginalOwnerCurrent => _originalOwnerCurrent?.call() ?? true;

  /// Exact target, never a paginated-catalog search or message-body read.
  Future<SupportConsentSessionMetadata> readSessionMetadata({
    required SupportConsentSelectionSource source,
    required String? sessionId,
  }) => source == SupportConsentSelectionSource.roleplay
      ? _roleplay.sessionMetadata(sessionId)
      : _support.sessionMetadata(sessionId);

  Future<SupportConsentSessionPage> listRoleplaySessions({
    int offset = 0,
    int limit = maxSessionPageSize,
  }) => _roleplay.sessions(offset, limit);

  Future<SupportConsentMessagePage> listRoleplayMessages({
    required String? sessionId,
    int offset = 0,
    int limit = maxMessagePageSize,
  }) => _roleplay.messages(sessionId, offset, limit);

  Future<SupportConsentMessagePage> listSupportMessages({
    required String? sessionId,
    int offset = 0,
    int limit = maxMessagePageSize,
  }) => _support.messages(sessionId, offset, limit);

  @override
  String toString() => 'SupportConsentSelectionRepo';
}
