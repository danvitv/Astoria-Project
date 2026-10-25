part of '../database_restore_repo.dart';

String _typedRow(Iterable<Object?> cells) =>
    jsonEncode(cells.map(_typedCell).toList());
Object _typedCell(Object? value) {
  if (value == null) return ['null'];
  if (value is int) return ['integer', value.toString()];
  if (value is double) {
    final bits = ByteData(8)..setFloat64(0, value, Endian.big);
    return ['real', base64Encode(bits.buffer.asUint8List())];
  }
  if (value is String) {
    if (value.length > _RestoreLimits.maxCellBytes)
      _refuse(DatabaseRestoreCode.tooLarge);
    final bytes = utf8.encode(value);
    if (bytes.length > _RestoreLimits.maxCellBytes)
      _refuse(DatabaseRestoreCode.tooLarge);
    return ['text', base64Encode(bytes)];
  }
  if (value is Uint8List) {
    if (value.length > _RestoreLimits.maxCellBytes)
      _refuse(DatabaseRestoreCode.tooLarge);
    return ['blob', base64Encode(value)];
  }
  _refuse(DatabaseRestoreCode.unsupported);
  return ['unsupported'];
}

/// Whole typed image digest, independent of scan order, including duplicates.
/// Two domain-separated SHA-256 multiset accumulators plus exact row counts:
/// bounded memory even for a table without a key (no row map or sampling).
/// SHA equality is an integrity check, not a byte identity/power-loss claim.
final class _RestoreLogicalDigest {
  _RestoreLogicalDigest(this._digest);
  final Digest _digest;
  bool same(_RestoreLogicalDigest other) => _digest == other._digest;
  @override
  String toString() => 'RestoreLogicalDigest(private)';

  static Future<_RestoreLogicalDigest> capture(
    Database db,
    void Function() check, {
    bool validateStoredTypes = false,
  }) async {
    check();
    _requireBounds(db);
    final objects = _schemaObjects(db);
    final output = _RestoreDigestSink();
    final sink = sha256.startChunkedConversion(output);
    var totalRows = 0;
    var totalBytes = 0;
    try {
      // Schema cookie changes on a backup destination; rootpage/SQL and actual
      // schema, page layout, application ID and user version do not get omitted.
      sink.add(
        utf8.encode(
          _typedRow([
            _scalar(db, 'PRAGMA main.application_id'),
            _scalar(db, 'PRAGMA main.user_version'),
            _scalar(db, 'PRAGMA main.page_size'),
            _scalar(db, 'PRAGMA main.page_count'),
          ]),
        ),
      );
      for (final row in objects.values) {
        sink.add(utf8.encode(_typedRow(row)));
      }
      final modulus = BigInt.one << 256;
      for (final name in _ordinaryTables(db)) {
        check();
        final columns = _metadata(db, 'table_xinfo', name);
        if (columns.any((c) => c[6] != 0))
          _refuse(DatabaseRestoreCode.unsupported);
        sink.add(utf8.encode(_typedRow([name, ...columns.map(_typedRow)])));
        // Bound cell allocations BEFORE fetching any row. Native SQLite length
        // and typeof operate on storage, not application payload decoding.
        final predicate = columns
            .map(
              (c) =>
                  'length(CAST(${_quote(c[1] as String)} AS BLOB)) > ${_RestoreLimits.maxCellBytes}',
            )
            .join(' OR ');
        if (predicate.isNotEmpty &&
            _scalar(
                  db,
                  'SELECT count(*) FROM main.${_quote(name)} WHERE $predicate',
                ) !=
                0)
          _refuse(DatabaseRestoreCode.tooLarge);
        final rowBytes = columns
            .map(
              (c) =>
                  'coalesce(length(CAST(${_quote(c[1] as String)} AS BLOB)),0)',
            )
            .join(' + ');
        if (rowBytes.isNotEmpty &&
            _scalar(
                  db,
                  'SELECT count(*) FROM main.${_quote(name)} WHERE $rowBytes > ${_RestoreLimits.maxCellBytes * 2}',
                ) !=
                0)
          _refuse(DatabaseRestoreCode.tooLarge);
        final withoutRowId =
            db
                .select(
                  "SELECT wr FROM pragma_table_list WHERE schema='main' AND name=?",
                  [name],
                )
                .single
                .values
                .single ==
            1;
        final names = columns.map((c) => c[1] as String).toList();
        String? rowId;
        if (!withoutRowId) {
          for (final alias in ['_rowid_', 'rowid', 'oid']) {
            if (!names.any((n) => n.toLowerCase() == alias)) {
              rowId = alias;
              break;
            }
          }
          if (rowId == null) _refuse(DatabaseRestoreCode.unsupported);
        }
        final expressions = names
            .map((n) {
              final q = _quote(n);
              // Preserve native UTF-8 bytes including NUL/invalid byte sequences,
              // rather than silently hashing Dart's UTF-8 replacement decoding.
              return "typeof($q),CASE WHEN typeof($q)='text' THEN CAST($q AS BLOB) ELSE $q END";
            })
            .join(',');
        final statement = db.prepare(
          'SELECT ${rowId == null ? '' : '$rowId,'}$expressions FROM main.${_quote(name)}',
        );
        var n = 0;
        var a = BigInt.zero;
        var b = BigInt.zero;
        try {
          final cursor = statement.iterateWith(
            const StatementParameters.empty(),
          );
          while (cursor.moveNext()) {
            check();
            if (++totalRows > _RestoreLimits.maxRows)
              _refuse(DatabaseRestoreCode.tooLarge);
            final values = cursor.current.values.toList();
            final offset = rowId == null ? 0 : 1;
            final cells = <Object>[];
            if (rowId != null) cells.add(_typedCell(values.first));
            for (var i = 0; i < columns.length; i++) {
              final tag = values[offset + i * 2] as String;
              final value = values[offset + i * 2 + 1];
              if (validateStoredTypes)
                _requireStoredType(tag, value, columns[i]);
              cells.add(
                tag == 'text'
                    ? ['text', base64Encode(value as Uint8List)]
                    : _typedCell(value),
              );
            }
            final encoded = utf8.encode(jsonEncode(cells));
            totalBytes += encoded.length;
            if (totalBytes > _RestoreLimits.maxBytes * 2)
              _refuse(DatabaseRestoreCode.tooLarge);
            a =
                (a +
                    BigInt.parse(
                      sha256.convert([0, ...encoded]).toString(),
                      radix: 16,
                    )) %
                modulus;
            b =
                (b +
                    BigInt.parse(
                      sha256.convert([1, ...encoded]).toString(),
                      radix: 16,
                    )) %
                modulus;
            if (++n % 128 == 0) {
              await Future<void>.delayed(Duration.zero);
              check();
            }
          }
        } finally {
          statement.close();
        }
        sink.add(
          utf8.encode(_typedRow([n, a.toRadixString(16), b.toRadixString(16)])),
        );
        await Future<void>.delayed(Duration.zero);
        check();
      }
    } finally {
      sink.close();
    }
    return _RestoreLogicalDigest(output.value!);
  }
}

void _requireStoredType(String tag, Object? value, List<Object?> column) {
  if (value == null) {
    if (column[3] == 1) _refuse(DatabaseRestoreCode.invalidCandidate);
    return;
  }
  final type = (column[2] as String).toUpperCase();
  final valid = switch (type) {
    'INTEGER' ||
    'INT' ||
    'BOOLEAN' ||
    'BOOL' => tag == 'integer' && value is int,
    'REAL' || 'DOUBLE' || 'FLOAT' =>
      (tag == 'real' && value is double) || (tag == 'integer' && value is int),
    'TEXT' || 'VARCHAR' => tag == 'text' && value is Uint8List,
    'BLOB' || '' => tag == 'blob' && value is Uint8List || type.isEmpty,
    _ => false,
  };
  if (!valid) _refuse(DatabaseRestoreCode.invalidCandidate);
}
