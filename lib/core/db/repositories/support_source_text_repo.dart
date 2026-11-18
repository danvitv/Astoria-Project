import 'dart:async';
import 'dart:convert';
import 'dart:math';
import '../native_history/history_message_unit.dart' as history;

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../credentials/secret_redactor.dart';
import '../../llm/diagnostics/recorded_call_failure.dart';
import '../../llm/diagnostics/recorded_generation_runtime.dart';
import '../../llm/diagnostics/recorded_runtime_source_projection.dart';
import '../../llm/diagnostics/recorded_studio_runtime.dart';
import '../../models/support_text_context.dart';
import '../../models/studio_preset_codec.dart';
import '../../models/studio_preset_diagnostics.dart';
import '../../models/studio_agent_topology_diagnostics.dart';
import '../../support/support_payload_cipher.dart';
import '../../support/source_navigation.dart' as nav;
import '../../preferences/saved_preferences_owner.dart';
import '../../preferences/saved_preferences_read_port.dart';
import '../../preferences/saved_preferences_codec.dart';
import '../app_db.dart';
import 'support_source_text/support_source_json.dart';
import 'support_text_context_repo.dart';
import 'support_repo.dart';

part 'support_source_text/source_observation.dart';
part 'support_source_text/source_metadata_reader.dart';
part 'support_source_text/source_game_reader.dart';
part 'support_source_text/source_studio_reader.dart';
part 'support_source_text/navigation_repo.dart';
part 'support_source_text/navigation_catalog.dart';
part 'support_source_text/navigation_game.dart';
part 'support_source_text/navigation_records.dart';
part 'support_source_text/navigation_presets.dart';
part 'support_source_text/navigation_studio_validation.dart';
part 'support_source_text/navigation_memory.dart';
part 'support_source_text/navigation_ledger.dart';
part 'support_source_text/navigation_reconciliation.dart';
part 'support_source_text/navigation_shape.dart';
part 'support_source_text/application_dataset_registry.dart';
part 'support_source_text/application_json_projection.dart';
part 'support_source_text/navigation_application.dart';
part 'support_source_text/navigation_astoria.dart';
part 'support_source_text/navigation_preferences.dart';

/// MODEL tools may request metadata; only the original exact native lease may
/// implement this port after confirmation of extent AND the same destination.
/// This is not a global permission, callback body grant, or persisted right.
abstract interface class SupportSourceReadAuthority {
  SupportSourceObservation get observation;
  bool get isCurrent;
}

enum SupportSourceDomain { game, studioPreset }

/// Finite local refusal categories only. No SQL, source text, error details,
/// path, identity, or digest is retained in a failure or its string form.
enum SupportSourceReadFailure {
  unavailable,
  unsupportedFormat,
  tooLarge,
  notFound,
  changed,
  locked,
}

final class SupportSourceReadException implements Exception {
  const SupportSourceReadException({
    this.failure = SupportSourceReadFailure.unavailable,
  });
  final SupportSourceReadFailure failure;
  @override
  String toString() => 'Support source unavailable.';
}

/// Read-only exact existing DB boundary. Never hydrates ChatNotifier or complete
/// game/preset models. Bodies stay private until a revalidated wire projection.
final class SupportSourceTextRepo {
  SupportSourceTextRepo({
    required AppDatabase db,
    required SupportPayloadCipher cipher,
    required SecretRedactor Function() currentRedactor,
  }) : _db = db,
       _cipher = cipher,
       _currentRedactor = currentRedactor,
       _text = SupportTextContextRepo(
         db: db,
         cipher: cipher,
         currentRedactor: currentRedactor,
       );

  static const pageSize = 16;
  static const maxToolResultBytes = 65536;
  // Studio-only LOCAL validation budgets, never native wire/metadata budgets.
  static const maxStudioStoredBytes = 2 * 1024 * 1024;
  static const studioUnpagedStoredBytes = 12000;
  static const maxStudioDefinitionBytes = 4 * 1024 * 1024;
  static const maxStudioPartCharacters = 32768;
  static const maxStudioPartDoubleJsonBytes = 40000;
  final AppDatabase _db;
  final SupportPayloadCipher _cipher;
  final SecretRedactor Function() _currentRedactor;
  final SupportTextContextRepo _text;

  bool usesDatabase(AppDatabase db) => identical(db, _db);

  /// Trusted native run setup only, not a tool/approval/mutation API. Prepare
  /// at most the first 16 newest session candidates before the run freezes any
  /// snapshots. Existing authenticated indexes are read-only; canonical history
  /// is never edited. Large histories remain honestly incomplete at the budget.
  Future<void> prepareAutomaticHistory({
    required bool Function() isCurrent,
  }) async {
    final native = _db.nativeDataSourceIdentity;
    bool current() =>
        isCurrent() &&
        native != null &&
        identical(native, _db.nativeDataSourceIdentity) &&
        _text.retainsNativeDataSource(native);
    if (!current()) _deny(SupportSourceReadFailure.changed);
    final clock = Stopwatch()..start();
    // Bound both mixed timestamp streams before eligibility joins, matching
    // the navigation catalog's native order without parsing authored bodies.
    final rows = await _db.customSelect('''
      SELECT s.session_id,s.updated_at,c.hidden FROM (
        SELECT * FROM (SELECT session_id,character_id,updated_at,rowid AS native_rowid
          FROM chat_sessions INDEXED BY idx_chat_sessions_updated_at
          WHERE updated_at < 100000000000 ORDER BY updated_at DESC,rowid DESC LIMIT 16)
        UNION ALL SELECT * FROM (SELECT session_id,character_id,updated_at,rowid AS native_rowid
          FROM chat_sessions INDEXED BY idx_chat_sessions_updated_at
          WHERE updated_at >= 100000000000 ORDER BY updated_at DESC,rowid DESC LIMIT 16)
      ) s JOIN characters c ON c.char_id=s.character_id
      ORDER BY CASE WHEN s.updated_at<=0 THEN 0 WHEN s.updated_at<100000000000
        THEN s.updated_at*1000 ELSE s.updated_at END DESC,s.updated_at DESC,s.native_rowid DESC LIMIT 16
    ''').get();
    if (!current()) _deny(SupportSourceReadFailure.changed);
    for (final row in rows) {
      if (!current()) _deny(SupportSourceReadFailure.changed);
      if (clock.elapsed >= const Duration(seconds: 3)) break;
      final id = row.data['session_id'];
      if (row.data['hidden'] != 0 || !SupportSourceJson.identity(id)) continue;
      final status = await _db.historySourceIndex.observe(id as String);
      if (!current()) _deny(SupportSourceReadFailure.changed);
      if (status['status'] == 'ready' || status['status'] == 'unsupported') {
        continue;
      }
      await _db.historySourceIndex.maintain(
        sessionId: id,
        isCurrent: current,
        maxSteps: 16,
        deadline: const Duration(milliseconds: 250),
      );
      if (!current()) _deny(SupportSourceReadFailure.changed);
    }
  }

  Future<SupportSourceCatalogPage> catalog({
    required SupportSourceDomain domain,
    int offset = 0,
    String? activeStudioPresetId,
    required bool Function() isCurrent,
  }) => _catalog(domain, offset, isCurrent, activeStudioPresetId);

  /// Exact trailing active page, in native ascending order. Offset counts back
  /// from the newest ACTIVE messages, not from hidden variants or attachments.
  /// Studio uses studioPage instead: metadata only until consent, then full
  /// local source validation/redaction and disclosure of exactly that part.
  Future<SupportSourceObservation> observe({
    required SupportSourceCatalogEntry entry,
    int activeMessageOffset = 0,
    int studioPage = 0,
    required bool Function() isCurrent,
  }) => _observe(entry, activeMessageOffset, studioPage, isCurrent);

  Future<SupportSourceSnapshot> read({
    required SupportSourceObservation observation,
    required SupportSourceReadAuthority authority,
  }) async {
    try {
      _authority(observation, authority);
      final snapshot = await _db.transaction(() async {
        _authority(observation, authority);
        final stamp = await _stamp(() => _authority(observation, authority));
        if (stamp != observation._stamp) {
          _deny(SupportSourceReadFailure.changed);
        }
        final value = await _materialize(observation, authority);
        _authority(observation, authority);
        final after = await _stamp(() => _authority(observation, authority));
        if (after != stamp) _deny(SupportSourceReadFailure.changed);
        return value;
      });
      _authority(observation, authority);
      return snapshot;
    } on SupportSourceReadException {
      rethrow;
    } on FormatException {
      _deny(SupportSourceReadFailure.unsupportedFormat);
    } catch (_) {
      _deny();
    }
  }

  /// Re-reads the originally approved extent in a real transaction (including
  /// full local validation of Studio's source for the same disclosed part). No
  /// fallback, silent clipping, private digest in JSON, or alternative source.
  /// Unrelated support provenance writes do not invalidate unchanged source text.
  Future<bool> revalidate({
    required SupportSourceSnapshot snapshot,
    required SupportSourceReadAuthority authority,
  }) async {
    if (!identical(snapshot._owner, this) || snapshot._revoked) return false;
    try {
      _authority(snapshot._observation, authority);
      final next = await _db.transaction(() async {
        final before = await _stamp(
          () => _authority(snapshot._observation, authority),
        );
        final result = await _materialize(snapshot._observation, authority);
        _authority(snapshot._observation, authority);
        final after = await _stamp(
          () => _authority(snapshot._observation, authority),
        );
        if (before != after) _deny(SupportSourceReadFailure.changed);
        return result;
      });
      _authority(snapshot._observation, authority);
      if (next._digest != snapshot._digest || next._json != snapshot._json) {
        _deny(SupportSourceReadFailure.changed);
      }
      return true;
    } on SupportSourceReadException catch (error) {
      snapshot._refusal = error.failure;
      snapshot._revoked = true;
      return false;
    } on FormatException {
      snapshot._refusal = SupportSourceReadFailure.unsupportedFormat;
      snapshot._revoked = true;
      return false;
    } catch (_) {
      snapshot._refusal = SupportSourceReadFailure.unavailable;
      snapshot._revoked = true;
      return false;
    }
  }

  Future<String> toolResult({
    required SupportSourceSnapshot snapshot,
    required SupportSourceReadAuthority authority,
  }) async {
    if (!await revalidate(snapshot: snapshot, authority: authority)) {
      _deny(snapshot._refusal ?? SupportSourceReadFailure.unavailable);
    }
    _authority(snapshot._observation, authority);
    return snapshot._json;
  }

  Future<SupportSourceSnapshot> _materialize(
    SupportSourceObservation observation,
    SupportSourceReadAuthority authority,
  ) async {
    void guard() => _authority(observation, authority);
    guard();
    final header = await _header(
      observation.domain,
      observation.sourceId,
      guard,
    );
    guard();
    if (!_equal(header, observation._header)) {
      _deny(SupportSourceReadFailure.changed);
    }
    return observation.domain == SupportSourceDomain.game
        ? _game(observation, guard)
        : _studio(observation, guard);
  }

  SupportSourceSnapshot _snapshot(
    SupportSourceObservation observation,
    Object privateMaterial,
    Map<String, Object?> result,
  ) {
    final json = jsonEncode(result);
    if (utf8.encode(json).length > maxToolResultBytes) {
      _deny(SupportSourceReadFailure.tooLarge);
    }
    final digest = sha256
        .convert(utf8.encode(jsonEncode(privateMaterial)))
        .toString();
    return SupportSourceSnapshot._(this, observation, json, digest);
  }

  void _authority(
    SupportSourceObservation observation,
    SupportSourceReadAuthority authority,
  ) {
    final source = _db.nativeDataSourceIdentity;
    if (!identical(observation._owner, this) ||
        !identical(authority.observation, observation) ||
        !authority.isCurrent ||
        source == null ||
        !_text.retainsNativeDataSource(source)) {
      _deny();
    }
  }

  Future<(int, int)> _stamp(void Function() guard) async {
    guard();
    final row = await _db
        .customSelect(
          'SELECT total_changes() AS changes, data_version AS version FROM pragma_data_version',
        )
        .getSingle();
    guard();
    return (row.read<int>('changes'), row.read<int>('version'));
  }

  bool _equal(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
  bool _identity(Object? value) =>
      SupportSourceJson.identity(value) &&
      _currentRedactor().redactText(value as String) == value;
  Never _deny([
    SupportSourceReadFailure failure = SupportSourceReadFailure.unavailable,
  ]) => throw SupportSourceReadException(failure: failure);
  @override
  String toString() => 'SupportSourceTextRepo';
}
