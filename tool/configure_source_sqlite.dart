import 'dart:io';

import 'package:crypto/crypto.dart';

// Build preparation only, NOT a native build/probe and NOT an app/model tool.
// The installed sqlite3 hook owns the original asset ID. Its flat define map
// needs explicit target selection to preserve Windows exports without passing
// Windows-only declarations to Android. Never modifies package/cache/lockfiles.
const _begin = '# BEGIN ASTORIA PINNED SQLITE SOURCE HOOK';
const _end = '# END ASTORIA PINNED SQLITE SOURCE HOOK';
const _source = 'third_party/sqlite3_3530100/sqlite3.c';
const _sourceId = '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9';

Future<void> main(List<String> args) async {
  if (args.length != 1 || !const {'windows', 'android'}.contains(args.single)) {
    throw ArgumentError('Use configure_source_sqlite.dart windows|android before building/checking that target.');
  }
  final root = Platform.script.resolve('../');
  final source = File.fromUri(root.resolve(_source));
  final header = File.fromUri(root.resolve('third_party/sqlite3_3530100/sqlite3.h'));
  final sourceHash = (await source.openRead().transform(sha256).first).toString();
  final headerHash = (await header.openRead().transform(sha256).first).toString();
  final headerText = await header.readAsString();
  if (sourceHash != '9ac97192c93a6d9671d2ea667ba14e3c8fe3719a171afc5827c9d86d0278fc14' ||
      headerHash != '16d6e2f265fb13ece42329da39a865d4c540045b444d16b4bf9f7e1a7e39408f' ||
      !headerText.contains('#define SQLITE_VERSION        "3.53.1"') ||
      !headerText.contains('#define SQLITE_VERSION_NUMBER 3053001') ||
      !headerText.contains(_sourceId)) {
    throw StateError('Pinned official SQLite 3.53.1 source verification failed; no configuration changed.');
  }
  final pubspec = File.fromUri(root.resolve('pubspec.yaml'));
  final before = await pubspec.readAsString();
  final start = before.indexOf(_begin), end = before.indexOf(_end);
  if ((start < 0) != (end < 0) ||
      (start >= 0 && (end < start || before.indexOf(_begin, start + 1) >= 0 || before.indexOf(_end, end + 1) >= 0)) ||
      (start < 0 && RegExp(r'^hooks:', multiLine: true).hasMatch(before))) {
    throw StateError('Unexpected hook configuration; preserve it and request review.');
  }
  final block = configuration(args.single);
  final after = start < 0 ? '$before\n$block\n' : before.replaceRange(start, end + _end.length, block);
  if (after != before) await pubspec.writeAsString(after);
  stdout.writeln('Verified SQLite 3.53.1; configured existing sole sqlite3 source asset for ${args.single}. No native build executed.');
}

String configuration(String target) => '''$_begin
hooks:
  user_defines:
    sqlite3:
      source: source
      path: $_source
      defines:
        default_options: false
        defines:
          SQLITE_ENABLE_DBSTAT_VTAB: null
          SQLITE_ENABLE_FTS5: null
          SQLITE_ENABLE_RTREE: null
          SQLITE_ENABLE_MATH_FUNCTIONS: null
          SQLITE_DQS: '0'
          SQLITE_DEFAULT_MEMSTATUS: '0'
          SQLITE_TEMP_STORE: '2'
          SQLITE_MAX_EXPR_DEPTH: '0'
          SQLITE_STRICT_SUBTYPE: '1'
          SQLITE_OMIT_AUTHORIZATION: null
          SQLITE_OMIT_DECLTYPE: null
          SQLITE_OMIT_DEPRECATED: null
          SQLITE_OMIT_SHARED_CACHE: null
          SQLITE_OMIT_TCL_VARIABLE: null
          SQLITE_OMIT_TRACE: null
          SQLITE_USE_ALLOCA: null
          SQLITE_ENABLE_SESSION: null
          SQLITE_ENABLE_PREUPDATE_HOOK: null
          SQLITE_UNTESTABLE: null
          SQLITE_HAVE_ISNAN: null
          SQLITE_HAVE_LOCALTIME_R: null
          SQLITE_HAVE_LOCALTIME_S: null
          SQLITE_HAVE_MALLOC_USABLE_SIZE: null
          SQLITE_HAVE_STRCHRNUL: null${target == 'windows' ? "\n          SQLITE_API: '__declspec(dllexport)'" : ''}
$_end''';
