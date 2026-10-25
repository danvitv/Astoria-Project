part of 'sqlite_restore_port_fixture.dart';

/// Internal complete native logical image. It never leaves a fixture, gets
/// logged, or substitutes for the independent full SQLite original backup.
final class _LogicalImage {
  _LogicalImage(
    this.schema,
    this.tables,
    this.applicationId,
    this.userVersion,
    this.schemaCookie,
    this.pageSize,
    this.pageCount,
  );
  final String schema;
  final Map<String, String> tables;
  final int applicationId;
  final int userVersion;
  final int schemaCookie;
  final int pageSize;
  final int pageCount;

  static int scalar(Database db, String query) =>
      db.select(query).single.values.single as int;
  static String quote(String name) => '"${name.replaceAll('"', '""')}"';

  static _LogicalImage capture(Database db) {
    final integrity = db.select('PRAGMA main.integrity_check(4)');
    expect(
      integrity.length == 1 && integrity.single.values.single == 'ok',
      true,
      reason: 'Complete native integrity check',
    );
    final schemaRows = db.select(
      'SELECT type,name,tbl_name,rootpage,sql '
      'FROM main.sqlite_schema ORDER BY type,name',
    );
    expect(schemaRows.length <= 512, true, reason: 'Bounded full schema');
    final entities = db.select(
      'SELECT name,type FROM pragma_table_list '
      "WHERE schema='main' ORDER BY name",
    );
    expect(entities.length <= 128, true, reason: 'Bounded full table list');
    expect(
      entities.every((r) => r['type'] != 'virtual' && r['type'] != 'shadow'),
      true,
      reason: 'Ordinary compiled fixture tables only',
    );
    final contents = <String, String>{};
    var totalRows = 0;
    for (final entity in entities) {
      if (entity['type'] != 'table') continue;
      final name = entity['name'] as String;
      final columns = db.select('PRAGMA main.table_xinfo(${quote(name)})');
      final rows = db.select('SELECT * FROM main.${quote(name)}');
      totalRows += rows.length;
      expect(totalRows <= 512, true, reason: 'Bounded every-row verification');
      final canonicalRows = rows.map((r) => typedRow(r.values)).toList()
        ..sort();
      contents[name] = jsonEncode([
        columns.map((r) => typedRow(r.values)).toList(),
        canonicalRows,
      ]);
    }
    return _LogicalImage(
      jsonEncode(schemaRows.map((r) => typedRow(r.values)).toList()),
      contents,
      scalar(db, 'PRAGMA main.application_id'),
      scalar(db, 'PRAGMA main.user_version'),
      scalar(db, 'PRAGMA main.schema_version'),
      scalar(db, 'PRAGMA main.page_size'),
      scalar(db, 'PRAGMA main.page_count'),
    );
  }

  static String typedRow(Iterable<Object?> row) =>
      jsonEncode(row.map(typedCell).toList());
  static Object typedCell(Object? value) {
    if (value == null) return ['null'];
    if (value is int) return ['integer', value.toString()];
    if (value is double) {
      final bytes = ByteData(8)..setFloat64(0, value, Endian.big);
      return ['real', base64Encode(bytes.buffer.asUint8List())];
    }
    if (value is String) {
      expect(
        utf8.encode(value).length <= 256 * 1024,
        true,
        reason: 'Bounded text cell',
      );
      return ['text', base64Encode(utf8.encode(value))];
    }
    if (value is Uint8List) {
      expect(value.length <= 256 * 1024, true, reason: 'Bounded blob cell');
      return ['blob', base64Encode(value)];
    }
    throw StateError('Unexpected native SQLite cell type');
  }

  void requireRegistration(Set<String> registered) {
    expect(userVersion, 137, reason: 'Current native user_version');
    expect(
      registered.every(tables.containsKey),
      true,
      reason: 'Every actual registered table present',
    );
  }

  bool equals(_LogicalImage other) =>
      schema == other.schema &&
      applicationId == other.applicationId &&
      userVersion == other.userVersion &&
      pageSize == other.pageSize &&
      pageCount == other.pageCount &&
      tables.length == other.tables.length &&
      tables.entries.every((e) => other.tables[e.key] == e.value);

  void requireEqual(_LogicalImage other, String boundary) {
    // Canonical schema includes exact rootpage; it is NOT silently excluded.
    // Schema cookie alone deliberately changes on SQLite backup destinations.
    expect(equals(other), true, reason: 'Whole typed native image: $boundary');
  }
}

final class _BundleObservation {
  _BundleObservation(this._bytes);
  final List<Uint8List?> _bytes;
  static _BundleObservation capture(String mainPath) {
    final values = <Uint8List?>[];
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final file = File('$mainPath$suffix');
      if (!file.existsSync()) {
        values.add(null);
      } else {
        expect(
          file.lengthSync() <= 16 * 1024 * 1024,
          true,
          reason: 'Bounded owned raw observation',
        );
        values.add(file.readAsBytesSync());
      }
    }
    return _BundleObservation(values);
  }

  bool get mainExists => _bytes.first != null;
  Map<String, bool> flagsAgainst(_BundleObservation before) {
    final result = <String, bool>{};
    const labels = ['main', 'wal', 'shm', 'journal'];
    for (var i = 0; i < labels.length; i++) {
      final current = _bytes[i];
      final previous = before._bytes[i];
      result['${labels[i]}Exists'] = current != null;
      result['${labels[i]}BytesAndExistenceSame'] = current == null
          ? previous == null
          : previous != null && _sameBytes(current, previous);
    }
    return result;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
