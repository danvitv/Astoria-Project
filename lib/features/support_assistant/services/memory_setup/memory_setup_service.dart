import 'dart:convert';
import 'dart:math';

import '../../../../core/application/chat_source_mutation_registry.dart';
import '../../../../core/credentials/secret_redactor.dart';
import '../../../../core/credentials/connection_revision_registry.dart';
import '../../../../core/credentials/api_connection_metadata.dart';
import '../../../../core/db/repositories/chat_repo.dart';
import '../../../../core/db/repositories/memory_book_repo.dart';
import '../../../../core/db/repositories/memory_catalog_repo.dart';
import '../../../../core/db/repositories/api_config_repo.dart';
import '../../../../core/db/repositories/support_repo.dart';
import '../../../../core/models/memory_book.dart';
import '../../../../core/models/memory_source_manifest.dart';
import '../../../../core/models/memory_entry_revisions.dart';
import '../../../../core/llm/memory_draft_planner.dart';
import '../../../../core/models/support_models.dart';
import '../../../../core/preferences/tracked_shared_preferences.dart';
import '../../../../core/preferences/saved_preferences_owner.dart';
import '../../../chat/state/chat_native_owner_registry.dart';
import '../../models/support_permission_preferences.dart';
import '../../models/support_native_view.dart';
import '../support_native_consent_controller.dart';

part 'memory_setup_plans.dart';
part 'memory_setup_session.dart';
part 'memory_setup_global.dart';
part 'memory_setup_readiness.dart';

/// Native-only five-question wizard. No model tools, transport, credential input
/// or global projection writeback. Constructor handles are the original owners.
final class MemorySetupService {
  MemorySetupService({
    required this.controller,
    required this.books,
    required this.chats,
    required this.catalog,
    required this.api,
    required this.sources,
    required this.owners,
    required this.journal,
    required this.redactor,
    required this.connections,
    required this.originalCurrent,
    required this.dbCurrent,
    required this.publishMemory,
    required this.publishPipeline,
    required this.onBookChanged,
    required this.loadConnectionMetadata,
    this.preferences,
  }) : _session = controller.runtime.sessionId,
       _lifetime = controller.runtime.lifetime,
       _writeOwner = controller.runtime.writeOwner,
       _configuration = connections.revision;

  final SupportNativeConsentController controller;
  final MemoryBookRepo books;
  final ChatRepo chats;
  final MemoryCatalogRepo catalog;
  final ApiConfigRepo api;
  final ChatSourceMutationRegistry sources;
  final ChatNativeOwnerRegistry owners;
  final SupportRepo journal;
  final SecretRedactor redactor;
  final ConnectionRevisionRegistry connections;
  final TrackedSharedPreferences? preferences;
  final bool Function() originalCurrent, dbCurrent;
  final bool Function(String, SavedPreferencesLease) publishMemory,
      publishPipeline;
  final void Function(String) onBookChanged;
  final Future<List<ApiConnectionMetadata>> Function(bool Function())
  loadConnectionMetadata;
  List<ApiConnectionMetadata> _metadata = const [];
  final String _session;
  final int _lifetime, _writeOwner, _configuration;
  bool _alive = true, _started = false, _retired = false;
  int _intent = 0;
  ChatNativeOwner? _target;
  String? _targetId;
  int? _ownerRevision;
  Object? _checkpoint;
  late final _retirement = controller.runtime.captureDataRetirement();

  bool get current {
    if (!_alive || _retired) return false;
    final runtime = controller.runtime;
    try {
      runtime.checkConfiguration();
      if (!originalCurrent() ||
          !dbCurrent() ||
          !runtime.alive ||
          runtime.sessionId != _session ||
          runtime.lifetime != _lifetime ||
          runtime.writeOwner != _writeOwner ||
          runtime.pending != 0 ||
          runtime.settingsPending != 0 ||
          !runtime.snapshot.isAvailable ||
          runtime.snapshot.preferences?.allows(
                SupportPermission.readApplicationData,
              ) !=
              true ||
          !connections.isStable ||
          connections.revision != _configuration ||
          !runtime.ownsDataRetirementExceptOwnSource(
            _retirement,
            _targetId ?? '',
          ) ||
          sources.isDisposed ||
          !owners.isCurrent ||
          (_target != null &&
              (!owners.retains(_target!, _targetId!) ||
                  owners.revision != _ownerRevision)))
        _retired = true;
    } catch (_) {
      _retired = true;
    }
    return !_retired;
  }

  /// Called once from the exact painted setup entry, after separate read consent.
  bool start(SupportNativeDisplayedIntent? displayed) {
    if (_started || !controller.isDisplayedIntentCurrent(displayed) || !current)
      return false;
    _started = true;
    return true;
  }

  List<MemorySetupTarget> get targets {
    if (!current || !_started || _target != null) return const [];
    final revision = owners.revision;
    final result = <MemorySetupTarget>[];
    for (final owner in owners.loaded) {
      final id = owner.sessionId();
      if (id == null || _safeText(id) == null || sources.isSessionPending(id)) continue;
      final checkpoint = sources.sessionCheckpoint(id);
      if (checkpoint == null || owners.revision != revision || !owners.retains(owner, id)) continue;
      result.add(MemorySetupTarget._(this, owner, id, revision, checkpoint));
    }
    return List.unmodifiable(result);
  }

  bool selectTarget(MemorySetupTarget choice) {
    if (!current || !_started || _target != null) return false;
    final id = choice.sessionId, target = choice._owner;
    if (!identical(choice._service, this) || owners.revision != choice._revision ||
        !identical(choice._checkpoint, sources.sessionCheckpoint(id)) ||
        !owners.retains(target, id) ||
        sources.isSessionPending(id) ||
        _safeText(id) == null)
      return false;
    _target = target;
    _targetId = id;
    _ownerRevision = choice._revision;
    _checkpoint = choice._checkpoint;
    return _checkpoint != null;
  }

  bool _sourceCurrent(Object? checkpoint, {bool admitted = false}) =>
      current &&
      _target != null &&
      checkpoint != null &&
      identical(checkpoint, sources.sessionCheckpoint(_targetId!)) &&
      (admitted || !sources.isSessionPending(_targetId!));

  String? _safeText(String text) =>
      text.length <= 128 &&
          !text.contains(SecretRedactor.removed) &&
          !text.contains(SecretRedactor.limited) &&
          !text.contains(RegExp(r'[\r\n]')) &&
          redactor.redactText(text) == text
      ? text
      : null;

  String? _evidence(Map<String, Object?> value) {
    final encoded = jsonEncode(value);
    // Only these native budget labels are not credential slots. Relabel them
    // ONLY at the owned session schema level; nested raw JSON keeps every
    // secret-field rule. Retain the exact painted document for the journal.
    const budgetLabels = {
      'maxInjectedTokens': 'nativeInjectionCeiling',
      'memoryExcerptTokensPerChunk': 'nativeExcerptChunkCeiling',
    };
    final checkedDocument = <String, Object?>{...value};
    for (final container in ['settings', 'creationSettings']) {
      final fields = value[container];
      if (fields is! Map) continue;
      for (final label in budgetLabels.keys) {
        if (fields.containsKey(label) && redactor.redactText(label) != label)
          return null;
      }
      checkedDocument[container] = {
        for (final entry in fields.entries)
          budgetLabels[entry.key] ?? entry.key: entry.value,
      };
    }
    final checked = jsonEncode(checkedDocument);
    if (redactor.redactText(checked) != checked) return null;
    try {
      return SupportMutationEvidence.encode(encoded);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _fresh() async {
    if (!current) return false;
    final policy = controller.runtime.snapshot.preferences;
    try {
      final result = await controller.runtime.permissions.readForNative(
        _session,
      );
      return current &&
          result.isAvailable &&
          result.preferences?.allows(SupportPermission.readApplicationData) ==
              true &&
          result.preferences?.policyIdentity == policy?.policyIdentity &&
          result.preferences?.revision == policy?.revision;
    } catch (_) {
      return false;
    }
  }

  void answersChanged() {
    _intent++;
  }

  void retire() {
    _alive = false;
    _intent++;
  }

  Future<MemorySetupReview?> prepare(
    MemorySetupAnswers answers,
    MemorySetupScope scope,
  ) => scope == MemorySetupScope.session
      ? _prepareSession(answers)
      : _prepareGlobal(answers, scope);

  Future<List<MemorySetupConnection>> savedConnections() => _savedConnections();

  /// Approval is the exact native review identity, never a plan/card JSON. It is
  /// consumed before the first async reservation or source subscriber callback.
  Future<MemorySetupResult> apply(MemorySetupReview review) {
    if (!identical(review._service, this) ||
        review._used ||
        review._intent != _intent ||
        !current)
      return Future.value(MemorySetupResult.refused);
    review._used = true;
    _intent++;
    return review.scope == MemorySetupScope.session
        ? _applySession(review, _intent)
        : _applyGlobal(review, _intent);
  }

  Future<MemorySetupReview?> prepareUndo(MemorySetupReceipt receipt) async {
    final intent = ++_intent;
    final bookTicket = receipt._session?.ticket;
    if (receipt.scope == MemorySetupScope.session && bookTicket?.current != true) return null;
    if (!identical(receipt._service, this) ||
        receipt._used ||
        !current ||
        !_sourceCurrent(receipt._checkpoint) ||
        !await _fresh() ||
        intent != _intent)
      return null;
    if (receipt.scope == MemorySetupScope.session) {
      final observed = await books.observeForControl(_targetId!);
      if (!_sourceCurrent(receipt._checkpoint) ||
          bookTicket?.current != true ||
          observed == null ||
          intent != _intent ||
          jsonEncode(
                books.setupFieldSnapshot(
                  observed,
                  receipt._session!.after.keys,
                ),
              ) !=
              jsonEncode(receipt._session.after))
        return null;
      return MemorySetupReview._(
        this,
        intent,
        receipt.scope,
        receipt.after,
        receipt.before,
        receipt._checkpoint,
        observed: observed,
        undo: receipt,
        bookTicket: bookTicket,
      );
    }
    final global = receipt._global!;
    final prefs = preferences;
    if (prefs == null ||
        !global.lease.current ||
        prefs.getString(global.key) != global.raw)
      return null;
    return MemorySetupReview._(
      this,
      intent,
      receipt.scope,
      receipt.after,
      receipt.before,
      receipt._checkpoint,
      global: global,
      undo: receipt,
    );
  }
}
