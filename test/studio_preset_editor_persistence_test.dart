import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/models/ledger_preset_instruction_upgrade.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/features/presets/studio_preset_save_controller.dart';

const _original = StudioPreset(
  id: 'editor-persistence',
  name: 'Editor persistence',
  blocks: [
    StudioPresetBlock(
      id: 'ledger_system',
      content: 'Before editing',
      section: '',
      injectionPoint: 'ledger',
    ),
  ],
);

StudioPreset _withText(String text) => _original.copyWith(
  blocks: [_original.blocks.single.copyWith(content: text)],
);

void main() {
  test(
    'edit -> timer expiry -> leave inline -> consolidate preserves latest text',
    () async {
      // This exercises the exact controller wired into the editor and the real
      // upgrade repository, using only an isolated in-memory test database.
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = StudioPresetRepo(db);
      await repo.upsert(_original);

      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      var writes = 0;
      final saves = StudioPresetSaveController(
        debounce: Duration.zero,
        write: (preset) async {
          writes++;
          writeStarted.complete();
          await releaseWrite.future;
          await repo.upsert(preset);
        },
      );
      addTearDown(saves.dispose);

      saves.schedule(_withText('Latest authored instructions'));
      // The one-shot timer has expired, but the full-row write is in flight.
      await writeStarted.future;
      expect(saves.hasDirtySnapshot, isTrue);
      final leavingInline = saves.flushAndWait();
      var previewStarted = false;
      final consolidating = () async {
        await saves.flushAndWait();
        previewStarted = true;
        final plan = await repo.previewLedgerInstructionUpgrade(_original.id);
        expect(
          plan.original.blocks
              .firstWhere((block) => block.id == 'ledger_system')
              .content,
          'Latest authored instructions',
        );
        await repo.applyLedgerInstructionUpgrade(
          presetId: _original.id,
          expectedFingerprint: plan.expectedFingerprint,
        );
      }();
      expect(previewStarted, isFalse);
      expect(writes, 1, reason: 'Closing inline must not enqueue a duplicate.');

      releaseWrite.complete();
      await leavingInline;
      await consolidating;
      final durable = await repo.getById(_original.id);
      expect(writes, 1);
      expect(saves.hasDirtySnapshot, isFalse);
      expect(
        durable!.runtime.ledgerInstructionRevision,
        ledgerInstructionRevision,
      );
      expect(
        durable.blocks
            .firstWhere((block) => block.id == 'ledger_system')
            .content,
        'Latest authored instructions',
      );
    },
  );

  test(
    'overlapping full-row editor saves commit serially in edit order',
    () async {
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final started = <StudioPreset>[];
      StudioPreset? durable;
      final saves = StudioPresetSaveController(
        write: (preset) async {
          started.add(preset);
          if (started.length == 1) {
            firstStarted.complete();
            await releaseFirst.future;
          }
          durable = preset;
        },
      );
      addTearDown(saves.dispose);

      final first = saves.writeImmediately(_withText('First edit'));
      await firstStarted.future;
      final latest = _withText('Latest edit').copyWith(name: 'Latest rename');
      final second = saves.writeImmediately(latest);
      final flushed = saves.flushAndWait();
      expect(started, [_withText('First edit')]);

      releaseFirst.complete();
      await Future.wait([first, second, flushed]);
      expect(started, [_withText('First edit'), latest]);
      expect(durable, latest);
      expect(saves.hasDirtySnapshot, isFalse);
    },
  );

  test('an immediate edit supersedes an unqueued debounce snapshot', () async {
    final written = <StudioPreset>[];
    final saves = StudioPresetSaveController(
      write: (preset) async => written.add(preset),
    );
    addTearDown(saves.dispose);

    saves.schedule(_withText('Typed edit'));
    final latest = _withText('Typed edit').copyWith(name: 'Renamed');
    await saves.writeImmediately(latest);
    await saves.flushAndWait();
    expect(written, [latest]);
    expect(saves.hasDirtySnapshot, isFalse);
  });

  test(
    'failed save aborts preview and retains latest dirty edit for retry',
    () async {
      final failure = StateError('Controlled write failure');
      var failWrites = true;
      StudioPreset? durable;
      final saves = StudioPresetSaveController(
        write: (preset) async {
          if (failWrites) throw failure;
          durable = preset;
        },
      );
      addTearDown(saves.dispose);
      final latest = _withText('Do not replace this with a durable reload');
      saves.schedule(latest);

      var previewStarted = false;
      final consolidating = () async {
        await saves.flushAndWait();
        previewStarted = true;
      }();
      await expectLater(consolidating, throwsA(same(failure)));
      expect(previewStarted, isFalse);
      expect(saves.hasDirtySnapshot, isTrue);
      expect(durable, isNull);

      failWrites = false;
      await saves.flushAndWait();
      expect(durable, latest);
      expect(saves.hasDirtySnapshot, isFalse);
    },
  );

  test('an older completion cannot clear a newer debounced edit', () async {
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final written = <StudioPreset>[];
    final saves = StudioPresetSaveController(
      write: (preset) async {
        if (written.isEmpty) {
          firstStarted.complete();
          await releaseFirst.future;
        }
        written.add(preset);
      },
    );
    addTearDown(saves.dispose);

    final first = saves.writeImmediately(_withText('First edit'));
    await firstStarted.future;
    final latest = _withText('New edit while the first is saving');
    saves.schedule(latest);
    releaseFirst.complete();
    await first;
    expect(saves.hasDirtySnapshot, isTrue);

    await saves.flushAndWait();
    expect(written, [_withText('First edit'), latest]);
    expect(saves.hasDirtySnapshot, isFalse);
  });
}
