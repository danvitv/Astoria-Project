import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3/unstable/ffi_bindings.dart' as nsql;

import '../../support/support_payload_cipher.dart';
import '../../services/android_snapshot_namespace.dart';
import '../app_db.dart';
import 'chat_repo.dart';
import 'support_repo.dart';

part 'database_restore/restore_state.dart';
part 'database_restore/restore_startup_owner.dart';
part 'database_restore/restore_file_port.dart';
part 'database_restore/restore_android_files.dart';
part 'database_restore/restore_windows.dart';
part 'database_restore/restore_sqlite.dart';
part 'database_restore/restore_schema.dart';
part 'database_restore/restore_digest.dart';
part 'database_restore/restore_originals.dart';
part 'database_restore/restore_owner.dart';
part 'database_restore/restore_engine.dart';
part 'database_restore/restore_unix_identity.dart';
part 'database_restore/restore_android_sqlite.dart';

/// Offline native composition only. This has NO default source, data-root
/// lookup, provider drain, model authority, startup integration or GUI consent.
/// D2 must retain this owner before any ordinary application database is opened.
final class DatabaseRestoreRepo {
  DatabaseRestoreRepo({NativeDatabaseRestoreOwner? owner}) : _owner = owner;
  final NativeDatabaseRestoreOwner? _owner;

  Future<DatabaseRestoreProposal> prepare() async {
    final owner = _owner;
    if (owner == null) {
      throw const DatabaseRestoreException(DatabaseRestoreCode.unavailable);
    }
    return owner._prepare();
  }

  /// A trusted future native button handler may call this directly. Core tests
  /// calling it establish one-use semantics, NOT a genuine GUI-consent proof.
  DatabaseRestoreConfirmation confirm(DatabaseRestoreProposal proposal) {
    final owner = _owner;
    if (owner == null) {
      throw const DatabaseRestoreException(DatabaseRestoreCode.unavailable);
    }
    return owner._confirm(proposal);
  }

  Future<DatabaseRestoreResult> restore(
    DatabaseRestoreConfirmation confirmation,
  ) async {
    final owner = _owner;
    if (owner == null) {
      return const DatabaseRestoreResult._(DatabaseRestoreCode.unavailable);
    }
    return owner._restore(confirmation);
  }

  Future<void> cancel() async {
    final owner = _owner;
    if (owner != null) await owner.cancel();
  }

  Future<void> close() async {
    final owner = _owner;
    if (owner != null) await owner.close();
  }
}
