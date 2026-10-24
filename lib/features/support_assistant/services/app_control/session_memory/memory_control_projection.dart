import '../../../../../core/models/memory_book.dart';
import 'session_memory_guard.dart';

abstract final class MemoryControlProjection {
  static Map<String, Object?> settings(MemoryBookSettings s) => {
    'enabled': s.enabled,
    'maxInjectedEntries': s.maxInjectedEntries,
    'maxInjectedTokens': s.maxInjectedTokens,
    'memoryExcerptingEnabled': s.memoryExcerptingEnabled,
    'memoryPackingMode': SessionMemoryGuard.status(s.memoryPackingMode, {
      'full',
      'hybrid',
      'chunk_first',
    }),
    'injectionTarget': SessionMemoryGuard.status(s.injectionTarget, {
      'hard_block',
      'macro',
    }),
    'sourceWindowExclusion': s.sourceWindowExclusion,
    'factualContinuityGuardEnabled': s.factualContinuityGuardEnabled,
  };

  static Map<String, Object?> inspect(
    MemoryBook book,
    Map<String, Object?> arguments,
  ) {
    final offset = arguments['offset'] as int? ?? 0;
    final limit = arguments['limit'] as int? ?? 16;
    final view = arguments['view'];
    final items = view == 'entries'
        ? book.entries.map(
            (e) => <String, Object?>{
              'entryId': e.id,
              'status': SessionMemoryGuard.status(e.status, {
                'active',
                'archived',
                'inactive',
              }),
              'locked': e.locked,
              'revisionCount': e.revisions.length,
            },
          )
        : book.pendingDrafts.map(
            (d) => <String, Object?>{
              'draftId': d.id,
              'status': SessionMemoryGuard.status(d.status, {
                'pending_generation',
                'pending_approval',
                'needs_regeneration',
                'error',
              }),
              'vectorSearch': d.vectorSearch,
            },
          );
    final count = view == 'entries'
        ? book.entries.length
        : book.pendingDrafts.length;
    return {
      'bookId': book.id,
      'sessionId': book.sessionId,
      'entryCount': book.entries.length,
      'draftCount': book.pendingDrafts.length,
      if (view == 'settings') 'settings': settings(book.settings),
      if (view != 'settings') ...{
        'offset': offset,
        'items': items.skip(offset).take(limit).toList(),
        'truncated': count > offset + limit,
      },
    };
  }
}
