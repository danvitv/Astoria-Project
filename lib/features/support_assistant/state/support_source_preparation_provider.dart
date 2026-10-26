import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/history_source_index_repo.dart';
import '../../../core/state/db_provider.dart';

/// Native local metadata/status, not part of the tool registry or model graph.
/// A replacement DB creates a new stream; persisted 'ready' is never trusted
/// instead of the original worker's observe attestation.
final supportSourcePreparationPageProvider = StreamProvider.autoDispose
    .family<HistoryIndexLocalPage, int>((ref, afterRowid) {
      final db = ref.watch(appDbProvider);
      return db.historySourceIndex.watchLocalPage(
        afterRowid: afterRowid,
        readsFrom: {db.chatSessions, db.characters, db.historySourceGenerations, db.historyMessageUnits},
      );
    });
