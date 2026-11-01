import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/preferences/saved_preferences_owner.dart';
import 'package:glaze_flutter/core/preferences/saved_preferences_read_port.dart';
import 'package:glaze_flutter/core/preferences/tracked_shared_preferences.dart';
import 'package:glaze_flutter/core/services/backup/js_backup_importer.dart';
import 'package:glaze_flutter/core/services/backup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backup/import_fence_fixture.dart' show ImportFenceImages;
import 'helpers/support_source_text_native_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real FILE backup entry intent precedes detection/first await, and rejected input finally settles',
    () async {
      final f = SupportSourceTextNativeFixture();
      try {
        await f.initialize();
        SharedPreferences.setMockInitialValues({'memorySettings': '{}'});
        final prefs = await TrackedSharedPreferences.getInstance();
        final port = SavedPreferencesReadPort(
          original: Future.value(prefs),
          loaded: prefs,
          producerCurrent: () => true,
        );
        final old = port.capture('savedMemoryPreferences');
        var began = false;
        final service = BackupService(
          f.db,
          ImportFenceImages(f.directory.path),
          onImportStarted: () {
            began = true;
            expect(port.isCurrent(old), false);
            expect(port.capture('savedMemoryPreferences').current, false);
            return () {};
          },
        );
        final write = service.importBackupFromFile(
          '${f.directory.path}/missing-prefs.glz',
        );
        expect(began, true);
        expect(port.isCurrent(old), false);
        await expectLater(write, throwsA(isA<FileSystemException>()));
        expect(port.capture('savedMemoryPreferences').current, true);
        expect(port.isCurrent(old), false);
      } finally {
        await f.close();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'actual FILE generic backup replays all five families under one earlier bulk intent',
    () async {
      final f = SupportSourceTextNativeFixture();
      try {
        await f.initialize();
        SharedPreferences.setMockInitialValues({});
        final prefs = await TrackedSharedPreferences.getInstance();
        final port = SavedPreferencesReadPort(
          original: Future.value(prefs),
          loaded: prefs,
          producerCurrent: () => true,
        );
        final old = {
          for (final family in SavedPreferencesKeys.families.keys)
            family: port.capture(family),
        };
        final expected = <String, Object>{
          'memorySettings': '{"enabled":false}',
          'pipelineSettings': '{}',
          'gz_global_regex_scripts': '[]',
          'gz_studio_regex_scripts': '[]',
          'activePresetId': 'synthetic-restored-id',
          'feature_studio_enabled': false,
          'globalVars': '{"authored":"restored"}',
          'glaze.global_variables': '{"v":3}',
        };
        final archive = Archive()
          ..addFile(
            ArchiveFile.bytes(
              'manifest.json',
              utf8.encode('{"schemaVersion":13}'),
            ),
          )
          ..addFile(
            ArchiveFile.bytes(
              'preferences.json',
              utf8.encode(jsonEncode(expected)),
            ),
          );
        final file = File('${f.directory.path}/preferences.glz');
        await file.writeAsBytes(ZipEncoder().encode(archive));
        final service = BackupService(
          f.db,
          ImportFenceImages(f.directory.path),
        );
        final write = service.importBackupFromFile(
          file.path,
          onProgress: (_) {
            for (final family in old.keys)
              expect(port.capture(family).current, false);
          },
        );
        for (final lease in old.values) expect(port.isCurrent(lease), false);
        await write;
        for (final e in expected.entries) expect(prefs.get(e.key), e.value);
        for (final family in old.keys) {
          expect(port.isCurrent(old[family]!), false);
          expect(port.capture(family).current, true);
        }
      } finally {
        await f.close();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'actual JS import claims Memory/regex/bindings/vars BEFORE its first DB await, not pipeline/unrelated keys',
    () async {
      final f = SupportSourceTextNativeFixture();
      try {
        await f.initialize();
        SharedPreferences.setMockInitialValues({});
        final prefs = await TrackedSharedPreferences.getInstance();
        final port = SavedPreferencesReadPort(
          original: Future.value(prefs),
          loaded: prefs,
          producerCurrent: () => true,
        );
        final old = {
          for (final family in SavedPreferencesKeys.families.keys)
            family: port.capture(family),
        };
        final importer = JsBackupImporter(
          f.db,
          ImportFenceImages(f.directory.path),
        );
        final write = importer.import({
          'localStorage': {
            'gz_memory_settings': '{"enabled":false}',
            'gz_global_vars': '{"authored":"imported"}',
            'silly_cradle_current_preset_id': 'synthetic-js-selection',
          },
        });
        for (final family in old.keys) {
          expect(
            port.isCurrent(old[family]!),
            family == 'savedPipelinePreferences',
          );
        }
        await write;
        expect(prefs.getString('memorySettings'), '{"enabled":false}');
        expect(prefs.getString('globalVars'), '{"authored":"imported"}');
        expect(prefs.getString('activePresetId'), 'synthetic-js-selection');
        for (final family in old.keys)
          expect(port.capture(family).current, true);
      } finally {
        await f.close();
      }
    },
    skip: !Platform.isWindows,
  );
}
