import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';

import 'support_app_domain_loop_fixture.dart';

Future<TrackedSharedPreferences> _loadSelection(
  WidgetTester tester,
  DomainLoopFixture f,
  String kind, {
  String? initial,
}) async {
  final core = f.screen.core;
  final provider = kind == 'persona'
      ? activePersonaIdProvider
      : activePresetIdProvider;
  core.isolation.extraAllowed.add(provider);
  return configurationAction(tester, () async {
    final raw = await core.container.read(sharedPreferencesProvider.future);
    expect(raw, same(core.prefs));
    SavedPreferencesOwner.process.attach(raw, trustedPlugin: true);
    final prefs =
        TrackedSharedPreferences.wrap(raw) as TrackedSharedPreferences;
    if (initial != null) await prefs.setString(_key(kind), initial);
    core.container.read(provider.notifier).state = initial;
    return prefs;
  });
}

String _key(String kind) =>
    kind == 'persona' ? 'activePersonaId' : 'activePresetId';
String _target(String kind) =>
    kind == 'persona' ? 'domain-persona' : 'domain-collision';

bool _targetRead(
  String statement,
  List<Object?> args,
  String kind,
  String id,
) =>
    statement.trimLeft().toLowerCase().startsWith('select') &&
    RegExp(
      'from\\s+"?${kind == 'persona' ? 'personas' : 'presets'}"?',
      caseSensitive: false,
    ).hasMatch(statement) &&
    args.contains(id);

Future<void> _deleteTarget(DomainLoopFixture f, String kind, String id) async {
  final c = f.screen.core.container;
  if (kind == 'persona') {
    await c.read(personaRepoProvider).delete(id);
  } else {
    await c.read(presetRepoProvider).delete(id);
  }
}

Future<void> _targetAba(DomainLoopFixture f, String kind, String id) async {
  final c = f.screen.core.container;
  if (kind == 'persona') {
    final repo = c.read(personaRepoProvider);
    final original = (await repo.getById(id))!;
    await repo.delete(id);
    await repo.put(original);
    expect(await repo.getById(id), original);
  } else {
    final repo = c.read(presetRepoProvider);
    final original = (await repo.getById(id))!;
    await repo.delete(id);
    await repo.put(original);
    expect(await repo.getById(id), original);
  }
}

ChatSession _dormant() => ChatSession(
  id: 'domain-character_1',
  characterId: DomainLoopFixture.character,
  sessionIndex: 1,
);

void main() {
  for (final kind in ['persona', 'preset']) {
    for (final fault in ['target ABA', 'final SELECT delivery delete']) {
      domainLoopTest('MODEL $kind selection $fault starts no preference write', (
        tester,
        f,
      ) async {
        final core = f.screen.core;
        final prefs = await _loadSelection(tester, f, kind);
        f.script(
          core.call('astoria_active_${kind}_set', {
            'operation': 'select',
            'id': _target(kind),
          }),
          next: (_) => core.answer('Nothing saved.'),
        );
        await f.start(tester);
        var finalReadRetired = false;
        if (fault == 'target ABA') {
          final button = find.byKey(
            const ValueKey('support_tool_confirmation_accept'),
          );
          final route = ModalRoute.of<void>(tester.element(button))!;
          final expiredApply = tester.widget<GlazeActionButton>(button).onTap!;
          await configurationAction(
            tester,
            () => _targetAba(f, kind, _target(kind)),
          );
          await configurationAction(tester, expiredApply);
          await tester.pump();
          if (route.isCurrent) await f.cancel(tester);
          await tester.pump(route.reverseTransitionDuration);
          await tester.pump(const Duration(microseconds: 1));
          expect(route.isCurrent, false);
        } else {
          var reads = 0;
          core.native.sql.afterSelect = (statement, args) async {
            if (_targetRead(statement, args, kind, _target(kind)) &&
                ++reads == 2) {
              // NativeInputSql has already captured the successful final SELECT.
              // Remove the ORIGINAL target before its awaited result is delivered.
              core.native.sql.afterSelect = null;
              finalReadRetired = true;
              await _deleteTarget(f, kind, _target(kind));
            }
          };
          await f.apply(tester);
        }
        final reply = await f.finish(tester);
        core.native.sql.afterSelect = null;
        if (fault != 'target ABA') expect(finalReadRetired, true);
        expect(prefs.containsKey(_key(kind)), false);
        expect(
          core.container.read(
            kind == 'persona'
                ? activePersonaIdProvider
                : activePresetIdProvider,
          ),
          isNull,
        );
        final journal = await configurationAction(
          tester,
          () => core.native.repo.getMutationsForSession(core.native.session),
        );
        expect(journal.any((r) => r.status == 'applied'), false);
        // This synthetic producer has no compensation path: a plugin set would
        // leave this key present. No saved or ambiguous plugin effect is claimed.
        expect(reply.body, isNot(contains('изменение сохранено')));
        f.noEgress(reply.body);
      });

      domainLoopTest(
        'MODEL $kind selection Undo $fault starts no preference write',
        (tester, f) async {
          final core = f.screen.core;
          final before = _target(kind);
          final prefs = await _loadSelection(tester, f, kind, initial: before);
          await configurationAction(tester, () async {
            if (kind == 'persona') {
              await core.container
                  .read(personaRepoProvider)
                  .put(
                    const Persona(
                      id: 'selection-next',
                      name: 'Synthetic next persona',
                    ),
                  );
            } else {
              await core.container
                  .read(presetRepoProvider)
                  .put(
                    const Preset(
                      id: 'selection-next',
                      name: 'Synthetic next preset',
                    ),
                  );
            }
          });
          f.script(
            core.call('astoria_active_${kind}_set', {
              'operation': 'select',
              'id': 'selection-next',
            }),
          );
          await f.start(tester);
          await f.apply(tester);
          await f.finish(tester);
          expect(prefs.getString(_key(kind)), 'selection-next');
          f.script(
            core.call('astoria_active_selection_receipts', {}),
            next: (_) {
              final records = f.lastData()['records'] as List;
              expect(records, hasLength(1));
              return core.call('astoria_active_selection_undo', {
                'receipt': (records.single as Map)['receipt'],
              }, id: 'fresh_selection_undo');
            },
          );
          await f.start(tester);
          var finalReadRetired = false;
          if (fault == 'target ABA') {
            final button = find.byKey(
              const ValueKey('support_tool_confirmation_accept'),
            );
            final route = ModalRoute.of<void>(tester.element(button))!;
            final expiredApply = tester
                .widget<GlazeActionButton>(button)
                .onTap!;
            await configurationAction(
              tester,
              () => _targetAba(f, kind, before),
            );
            await configurationAction(tester, expiredApply);
            await tester.pump();
            if (route.isCurrent) await f.cancel(tester);
            await tester.pump(route.reverseTransitionDuration);
            await tester.pump(const Duration(microseconds: 1));
            expect(route.isCurrent, false);
          } else {
            var reads = 0;
            core.native.sql.afterSelect = (statement, args) async {
              if (_targetRead(statement, args, kind, before) && ++reads == 2) {
                core.native.sql.afterSelect = null;
                finalReadRetired = true;
                await _deleteTarget(f, kind, before);
              }
            };
            await f.apply(tester);
          }
          final reply = await f.finish(tester);
          core.native.sql.afterSelect = null;
          if (fault != 'target ABA') expect(finalReadRetired, true);
          expect(prefs.getString(_key(kind)), 'selection-next');
          final journal = await configurationAction(
            tester,
            () => core.native.repo.getMutationsForSession(core.native.session),
          );
          expect(journal.any((r) => r.status == 'undone'), false);
          expect(reply.body, isNot(contains('изменение сохранено')));
          f.noEgress(reply.body);
        },
      );
    }
  }

  for (final gap in [
    'prepare target read',
    'execute target read',
    'journal await',
  ]) {
    domainLoopTest(
      'MODEL dormant inventory insertion during $gap refuses selection',
      (tester, f) async {
        final core = f.screen.core;
        final prefs = await _loadSelection(tester, f, 'persona');
        final chats = core.container.read(chatRepoProvider);
        final owners = core.container.read(chatNativeOwnerRegistryProvider);
        final ownerRevision = owners.revision;
        var inserted = false;
        f.script(
          core.call('astoria_active_persona_set', {
            'operation': 'select',
            'id': 'domain-persona',
          }),
          next: (_) => core.answer('Nothing saved.'),
        );
        if (gap == 'prepare target read') {
          core.native.sql.afterSelect = (statement, args) async {
            if (_targetRead(statement, args, 'persona', 'domain-persona')) {
              core.native.sql.afterSelect = null;
              inserted = await chats.insertIfAbsent(_dormant());
            }
          };
        }
        await f.start(tester, confirmation: gap != 'prepare target read');
        if (gap == 'execute target read') {
          core.native.sql.afterSelect = (statement, args) async {
            if (_targetRead(statement, args, 'persona', 'domain-persona')) {
              core.native.sql.afterSelect = null;
              inserted = await chats.insertIfAbsent(_dormant());
            }
          };
        }
        if (gap == 'journal await') {
          final gates = await configurationAction(
            tester,
            () => (f.release(), f.release()),
          );
          final entered = gates.$1, release = gates.$2;
          core.native.sql.afterWrite = (statement) async {
            if (statement.trimLeft().toLowerCase().startsWith('insert') &&
                statement.contains('support_mutation_journal')) {
              core.native.sql.afterWrite = null;
              entered.complete();
              await release.future;
            }
          };
          await f.apply(tester);
          await f.screen.join(tester, entered.future);
          // Start on the ORIGINAL caller outside the journal transaction. Its SQL
          // waits, but synchronous insertion intent retires collateral immediately.
          final pending = await configurationAction(
            tester,
            () => (future: chats.insertIfAbsent(_dormant())),
          );
          await configurationAction(tester, release.complete);
          inserted = await f.screen.join(tester, pending.future);
        } else if (gap != 'prepare target read') {
          await f.apply(tester);
        }
        final reply = await f.finish(tester);
        expect(inserted, true);
        expect(owners.revision, ownerRevision); // No active-owner registration.
        expect(owners.existing(_dormant().id), isNull);
        expect(prefs.containsKey('activePersonaId'), false);
        expect(reply.body, isNot(contains('изменение сохранено')));
        if (gap == 'prepare target read') {
          expect(
            find.byKey(const ValueKey('support_tool_confirmation_accept')),
            findsNothing,
          );
        }
        f.noEgress(reply.body);
      },
    );
  }

  domainLoopTest(
    'MODEL retained selection inventory retires new dormant insertion',
    (tester, f) async {
      final core = f.screen.core;
      final prefs = await _loadSelection(tester, f, 'persona');
      f.script(
        core.call('astoria_active_persona_set', {
          'operation': 'select',
          'id': 'domain-persona',
        }),
      );
      await f.start(tester);
      final preview = tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(
                const ValueKey('support_tool_confirmation_preview'),
              ),
              matching: find.byType(Text),
            ),
          )
          .data!;
      expect(preview, contains('"sourceSessionsFenced":1'));
      await f.apply(tester);
      await f.finish(tester);
      final owners = core.container.read(chatNativeOwnerRegistryProvider);
      final revision = owners.revision;
      await configurationAction(
        tester,
        () => core.container.read(chatRepoProvider).insertIfAbsent(_dormant()),
      );
      expect(owners.revision, revision);
      f.script(
        core.call('astoria_active_selection_receipts', {}),
        next: (_) {
          expect(f.lastData()['records'], isEmpty);
          return core.answer('No original retained collateral.');
        },
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(prefs.getString('activePersonaId'), 'domain-persona');
      f.noEgress(reply.body);
    },
  );

  for (final target in ['previous', 'selected']) {
    domainLoopTest(
      'MODEL retained selection $target target ABA cannot renew Undo',
      (tester, f) async {
        final core = f.screen.core;
        final prefs = await _loadSelection(
          tester,
          f,
          'persona',
          initial: 'domain-persona',
        );
        await configurationAction(
          tester,
          () => core.container
              .read(personaRepoProvider)
              .put(
                const Persona(
                  id: 'selection-next',
                  name: 'Synthetic next persona',
                ),
              ),
        );
        f.script(
          core.call('astoria_active_persona_set', {
            'operation': 'select',
            'id': 'selection-next',
          }),
        );
        await f.start(tester);
        await f.apply(tester);
        await f.finish(tester);
        await configurationAction(
          tester,
          () => _targetAba(
            f,
            'persona',
            target == 'previous' ? 'domain-persona' : 'selection-next',
          ),
        );
        f.script(
          core.call('astoria_active_selection_receipts', {}),
          next: (_) {
            expect(f.lastData()['records'], isEmpty);
            return core.answer('No original retained target.');
          },
        );
        await f.start(tester, confirmation: false);
        final reply = await f.finish(tester);
        expect(prefs.getString('activePersonaId'), 'selection-next');
        f.noEgress(reply.body);
      },
    );
  }

  domainLoopTest(
    'MODEL selection Undo final target read dormant insertion refuses collateral',
    (tester, f) async {
      final core = f.screen.core;
      final prefs = await _loadSelection(
        tester,
        f,
        'persona',
        initial: 'domain-persona',
      );
      await configurationAction(
        tester,
        () => core.container
            .read(personaRepoProvider)
            .put(
              const Persona(
                id: 'selection-next',
                name: 'Synthetic next persona',
              ),
            ),
      );
      f.script(
        core.call('astoria_active_persona_set', {
          'operation': 'select',
          'id': 'selection-next',
        }),
      );
      await f.start(tester);
      await f.apply(tester);
      await f.finish(tester);
      f.script(
        core.call('astoria_active_selection_receipts', {}),
        next: (_) {
          final records = f.lastData()['records'] as List;
          expect(records, hasLength(1));
          return core.call('astoria_active_selection_undo', {
            'receipt': (records.single as Map)['receipt'],
          }, id: 'inventory_selection_undo');
        },
      );
      await f.start(tester);
      var reads = 0, inserted = false;
      core.native.sql.afterSelect = (statement, args) async {
        if (_targetRead(statement, args, 'persona', 'domain-persona') &&
            ++reads == 2) {
          core.native.sql.afterSelect = null;
          inserted = await core.container
              .read(chatRepoProvider)
              .insertIfAbsent(_dormant());
        }
      };
      await f.apply(tester);
      final reply = await f.finish(tester);
      expect(inserted, true);
      expect(prefs.getString('activePersonaId'), 'selection-next');
      final journal = await configurationAction(
        tester,
        () => core.native.repo.getMutationsForSession(core.native.session),
      );
      expect(journal.any((r) => r.status == 'undone'), false);
      expect(reply.body, isNot(contains('изменение сохранено')));
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'original selection inventory same-ID native replacement retires identity custody',
    (tester, f) async {
      final core = f.screen.core;
      final chats = core.container.read(chatRepoProvider);
      await configurationAction(tester, () => chats.insertIfAbsent(_dormant()));
      final observed = await configurationAction(
        tester,
        () => chats.observeNativeSelectionInventory(
          () => core.native.native.isCurrent,
        ),
      );
      expect(observed, isNotNull);
      expect(observed!.current, true);
      final ownerRevision = core.container
          .read(chatNativeOwnerRegistryProvider)
          .revision;
      // Same ORIGINAL database but a second native repo instance, without an
      // active owner or a mutation-registry callback for this dormant session.
      await configurationAction(
        tester,
        () =>
            ChatRepo(core.native.db).put(_dormant().copyWith(sessionIndex: 2)),
      );
      expect(observed.current, false);
      expect(
        core.container.read(chatNativeOwnerRegistryProvider).revision,
        ownerRevision,
      );
      final latest = await configurationAction(
        tester,
        () => chats.getById(_dormant().id),
      );
      expect(latest!.sessionIndex, 2);
      expect(observed.sessions, contains(_dormant().id));
    },
  );
}
