part of 'support_report_builder.dart';

extension _ReportPersonalMaterial on SupportReportBuilder {
  void _gameHistory(Map<String, Object?> game) {
    final raw = game['history'];
    if (raw is! String) {
      omissions.add(
        'Selected canonical game history exceeds 131072 characters; no partial JSON or index fallback read.',
      );
      return;
    }
    try {
      final parsed = SupportReportJson.decode(raw, limit: 131072);
      if (parsed is! List || parsed.length > 512) throw const FormatException();
      final eligible = <HistoryMessageUnit>[];
      for (final object in parsed) {
        final unit = HistoryMessageUnit(jsonEncode(object));
        if (unit.eligible) eligible.add(unit);
      }
      final selected = eligible.reversed.take(8).toList().reversed;
      final messages = <Map<String, Object?>>[];
      for (final unit in selected) {
        if (unit.content.length > 8192) {
          omissions.add(
            'A selected game message exceeds 8192 characters and was omitted, not silently clipped.',
          );
        } else {
          messages.add({'role': unit.role, 'text': unit.content});
        }
      }
      add(
        'gameCommentary',
        'Selected active game history (authored prose)',
        true,
        {
          'records': messages,
          'bounded': true,
          'hasMore': eligible.length > 8,
          'diagnosticFacts': false,
          'completeLivePrompt': false,
        },
      );
    } catch (_) {
      check();
      omissions.add(
        'Selected game history has unsupported format or exceeds parsing bounds; no tolerant normalization.',
      );
    }
  }

  Future<String?> _decrypt(
    Map<String, Object?> row,
    String column,
    String table,
    String field,
    String session,
  ) async {
    check();
    final raw = row[column], id = row['id'];
    if (raw is! String || id is! String || id.length > 1024) {
      omissions.add(
        'A selected encrypted source exceeds bounds or is unavailable.',
      );
      return null;
    }
    try {
      final clear = await owner.readCipher.decrypt(
        envelopeText: raw,
        table: table,
        rowId: id,
        field: field,
        sessionId: session,
      );
      check();
      if (clear.length > 8192) {
        omissions.add(
          'A selected decrypted source exceeds 8192 characters and was omitted.',
        );
        return null;
      }
      return clear;
    } catch (_) {
      check();
      omissions.add(
        'A selected encrypted source is locked or unreadable; no raw error exported.',
      );
      return null;
    }
  }
}
