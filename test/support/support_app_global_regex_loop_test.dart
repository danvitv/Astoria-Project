import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/global_regex_provider.dart';
import 'package:glaze_flutter/core/state/native_global_regex_json.dart';
import 'package:glaze_flutter/core/state/native_global_regex_port.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/native/support_native_domain_adapter.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/native/support_native_global_regex_adapter.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_native_domain_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_native_global_regex_owner.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_app_domain_loop_fixture.dart';
import 'support_app_global_regex_fixture.dart';

final class _CaptureProducerObserver extends ProviderObserver {
  int preferenceLoads = 0;

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    if (context.provider == sharedPreferencesProvider &&
        newValue is AsyncValue &&
        newValue.isLoading) {
      preferenceLoads++;
    }
  }
}

void main() {
  domainLoopTest(
    'MODEL discovers exact GLOBAL IDs then confirms disable and fresh genuine Undo',
    (tester, f) async {
      final core = f.screen.core;
      final original = await loadedGlobalRegex(tester, f);
      await configurationAction(tester, () {
        core.native.redaction.registerSecret(DomainLoopFixture.private);
      });
      final source = core.container.read(chatSourceMutationRegistryProvider);
      final checkpoint = source.sessionCheckpoint(DomainLoopFixture.session);
      final revision = original.prefs.store.owner.capture([
        NativeGlobalRegexPort.key,
      ], store: original.prefs.store).revisions[NativeGlobalRegexPort.key];
      final after = original.raw.replaceFirst(
        '"disabled":false',
        '"disabled":true',
      );
      expect(NativeGlobalRegexJson.read(original.raw)!.disabled(0), after);
      f.script(
        core.call('astoria_global_regex_scripts_list', {}, id: 'discover_regex'),
        next: (_) {
          final messages = core.wire.last['messages'] as List;
          final result = messages.cast<Map>().lastWhere(
            (m) => m['role'] == 'tool',
          );
          expect(result['tool_call_id'], 'discover_regex');
          final discovery = f.lastResult();
          expect(discovery['code'], 'completed');
          expect(discovery['effect'], 'none');
          final data = discovery['data'] as Map;
          expect(data['records'], [
            {'id': syntheticGlobalRegexId, 'disabled': false},
            {'id': 'other-global', 'disabled': true},
          ]);
          expect(data['count'], 2);
          expect(data['returnedCount'], 2);
          expect(data['omittedCount'], 0);
          expect(data['omittedNameCount'], 2);
          expect(data['unlistedCount'], 0);
          expect(data['truncated'], false);
          expect(data['bodyAccess'], 'notGranted');
          expect(
            original.prefs.getString(NativeGlobalRegexPort.key),
            original.raw,
          );
          expect(
            source.sessionCheckpoint(DomainLoopFixture.session),
            same(checkpoint),
          );
          return core.call('astoria_global_regex_disable', {
            'id': ((data['records'] as List).first as Map)['id'],
          }, id: 'disable_discovered_regex');
        },
      );
      await f.start(tester);
      expect(core.wire, hasLength(2));
      expect(
        original.prefs.store.owner.capture([
          NativeGlobalRegexPort.key,
        ], store: original.prefs.store).revisions[NativeGlobalRegexPort.key],
        revision,
      );
      expect(
        await configurationAction(
          tester,
          () => core.native.repo.getMutationsForSession(core.native.session),
        ),
        isEmpty,
      );
      final preview = find.byKey(
        const ValueKey('support_tool_confirmation_preview'),
      );
      for (final text in ['disabled', 'false', 'true', 'global']) {
        expect(
          find.descendant(
            of: preview,
            matching: find.textContaining(text, findRichText: true),
          ),
          findsWidgets,
        );
      }
      expect(
        find.descendant(
          of: preview,
          matching: find.textContaining(
            DomainLoopFixture.private,
            findRichText: true,
          ),
        ),
        findsNothing,
      );
      await f.apply(tester);
      final applied = await f.finish(tester);
      expect(original.prefs.getString(NativeGlobalRegexPort.key), after);
      expect(
        core.container.read(globalRegexProvider.notifier),
        same(original.controller),
      );
      expect(
        core.container.read(globalRegexProvider).value!.first.disabled,
        true,
      );
      expect(
        core.container.read(globalRegexProvider).value!.first.regex,
        syntheticGlobalRegex.regex,
      );
      expect(
        core.wire,
        hasLength(2),
      ); // ROOT retired; no effect-fed continuation.
      final journal = await configurationAction(
        tester,
        () => core.native.repo.getMutationsForSession(core.native.session),
      );
      expect(journal.single.domain, 'globalRegex');
      expect(journal.single.status, 'applied');
      expect(journal.single.beforeJson, contains(DomainLoopFixture.private));
      f.script(
        core.call('astoria_global_regex_receipts', {}),
        next: (_) {
          final records = f.lastData()['records'] as List;
          expect(records, hasLength(1));
          return core.call('astoria_global_regex_undo', {
            'receipt': (records.single as Map)['receipt'],
          }, id: 'fresh_regex_undo');
        },
      );
      await f.start(tester);
      await f.apply(tester);
      final undone = await f.finish(tester);
      expect(original.prefs.getString(NativeGlobalRegexPort.key), original.raw);
      expect(
        core.container.read(globalRegexProvider).value!.first.disabled,
        false,
      );
      expect(
        core.container.read(globalRegexProvider).value!.last.disabled,
        true,
      );
      expect(
        (await configurationAction(
          tester,
          () => core.native.repo.getMutationsForSession(core.native.session),
        )).single.status,
        'undone',
      );
      expect(core.wire, hasLength(4));
      f.noEgress('${applied.body}${undone.body}');
    },
  );

  domainLoopTest(
    'MODEL GLOBAL discovery is bounded, whole-field redacted and has zero effects',
    (tester, f) async {
      final core = f.screen.core;
      final original = await loadedGlobalRegex(tester, f);
      const secret = 'SYNTHETIC_REGEX_METADATA_SECRET';
      final longId = List.filled(129, 'a').join();
      final longName = '${List.filled(256, 'a').join()}$secret';
      await configurationAction(tester, () {
        core.native.redaction.registerSecret(secret);
        original.controller.state = AsyncData([
          for (var i = 0; i < 35; i++)
            syntheticGlobalRegex.copyWith(
              id: switch (i) {
                0 => 'prefix-$secret-suffix',
                1 => 'unsafe/id',
                2 => longId,
                _ => 'safe-global-$i',
              },
              name: switch (i) {
                3 => 'Whole prefix $secret suffix',
                4 => longName,
                5 => 'unsafe\nname',
                _ => 'Global script $i',
              },
              disabled: i.isOdd,
            ),
        ]);
      });
      final source = core.container.read(chatSourceMutationRegistryProvider);
      final checkpoint = source.sessionCheckpoint(DomainLoopFixture.session);
      final preferencesBefore = await configurationAction(
        tester,
        () => core.native.permissions.readForNative(core.native.session),
      );
      final savedRevision = original.prefs.store.owner.capture([
        NativeGlobalRegexPort.key,
      ], store: original.prefs.store).revisions[NativeGlobalRegexPort.key];
      // Loaded metadata intentionally differs from saved JSON. Discovery must
      // not observe raw JSON, normalize it or claim these IDs grant mutation.
      f.script(
        core.call('astoria_global_regex_scripts_list', {}, id: 'bounded_regex'),
        next: (round) {
          final result = f.lastResult();
          expect(result['code'], 'completed');
          expect(result['effect'], 'none');
          final data = result['data'] as Map;
          if (round == 3) {
            final messages = core.wire.last['messages'] as List;
            final tool = messages.cast<Map>().lastWhere(
              (m) => m['role'] == 'tool',
            );
            expect(tool['tool_call_id'], 'bounded_regex_again');
            if (core.native.settings.dcpCompressionEnabled) {
              expect(data, {'exactDuplicateOfCallId': 'bounded_regex'});
            } else {
              expect(data['returnedCount'], 29);
            }
            return core.answer('Only loaded native metadata was discovered.');
          }
          expect(data['count'], 35);
          expect(data['inspectedCount'], 32);
          expect(data['returnedCount'], 29);
          expect(data['omittedCount'], 3);
          expect(data['omittedNameCount'], 3);
          expect(data['unlistedCount'], 3);
          expect(data['truncated'], true);
          expect(data['visibility'], 'originalLoadedOwnerOnly');
          final records = (data['records'] as List).cast<Map>();
          expect(records.first, {'id': 'safe-global-3', 'disabled': true});
          expect(records.elementAt(1).containsKey('name'), false);
          expect(records.elementAt(2).containsKey('name'), false);
          expect(records.elementAt(3), {
            'id': 'safe-global-6',
            'name': 'Global script 6',
            'disabled': false,
          });
          expect(records.last['id'], 'safe-global-31');
          for (final record in records) {
            expect(
              record.keys.toSet().difference({'id', 'name', 'disabled'}),
              isEmpty,
            );
          }
          final outward = jsonEncode(data);
          for (final excluded in [
            secret,
            'prefix-',
            '-suffix',
            'Whole prefix',
            longId,
            'unsafe/id',
            'safe-global-32',
            'privateUnknown',
            'replacement',
            DomainLoopFixture.private,
          ]) {
            expect(outward, isNot(contains(excluded)));
          }
          return core.call(
            'astoria_global_regex_scripts_list',
            {},
            id: 'bounded_regex_again',
          );
        },
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(core.wire, hasLength(3));
      expect(original.prefs.getString(NativeGlobalRegexPort.key), original.raw);
      expect(
        original.prefs.store.owner.capture([
          NativeGlobalRegexPort.key,
        ], store: original.prefs.store).revisions[NativeGlobalRegexPort.key],
        savedRevision,
      );
      expect(
        source.sessionCheckpoint(DomainLoopFixture.session),
        same(checkpoint),
      );
      final preferencesAfter = await configurationAction(
        tester,
        () => core.native.permissions.readForNative(core.native.session),
      );
      expect(
        preferencesAfter.preferences!.grants,
        preferencesBefore.preferences!.grants,
      );
      expect(
        await configurationAction(
          tester,
          () => core.native.repo.getMutationsForSession(core.native.session),
        ),
        isEmpty,
      );
      f.noEgress(reply.body);
    },
  );

  for (final decision in ['cancel', 'already disabled']) {
    domainLoopTest(
      'MODEL global regex $decision writes no preference or receipt',
      (tester, f) async {
        final core = f.screen.core;
        final original = await loadedGlobalRegex(
          tester,
          f,
          disabled: decision == 'already disabled',
        );
        f.script(
          core.call('astoria_global_regex_disable', {
            'id': syntheticGlobalRegexId,
          }),
          next: (_) => core.answer('No change.'),
        );
        await f.start(tester);
        if (decision == 'cancel') {
          await f.cancel(tester);
        } else {
          await f.apply(tester);
        }
        final reply = await f.finish(tester);
        expect(
          original.prefs.getString(NativeGlobalRegexPort.key),
          original.raw,
        );
        expect(
          await configurationAction(
            tester,
            () => core.native.repo.getMutationsForSession(core.native.session),
          ),
          isEmpty,
        );
        f.noEgress(reply.body);
      },
    );
  }

  for (final retirement in ['invalidated', 'loading', 'error', 'native ROOT']) {
    domainLoopTest(
      'MODEL GLOBAL discovery refuses $retirement before metadata without load or write',
      (tester, f) async {
        final core = f.screen.core;
        final original = await loadedGlobalRegex(tester, f);
        final retained = original.controller.captureNativePort(
          original.prefs,
          () => core.native.native.isCurrent,
        )!;
        final buildRevision = retained.revision();
        final savedRevision = original.prefs.store.owner.capture([
          NativeGlobalRegexPort.key,
        ], store: original.prefs.store).revisions[NativeGlobalRegexPort.key];
        final observer = _CaptureProducerObserver();
        final producer = core.container
            .allProviders()
            .singleWhere((p) => p.provider == sharedPreferencesProvider)
            .container;
        producer.observers.add(observer);
        var retired = false;
        try {
          f.script(
            core.call(
              'astoria_global_regex_scripts_list',
              {},
              id: 'retired_regex',
            ),
            next: (_) {
              expect(f.lastResult()['code'], 'unavailable');
              expect(f.results.last['effect'], 'none');
              expect(f.results.last['data'], isEmpty);
              return core.answer('No current original native metadata.');
            },
          );
          final next = core.atFetch!;
          core.atFetch = (round) async {
            await next(round);
            if (round != 1) return;
            retired = true;
            // Retire the real owner while delivering the original first tool
            // call. No replacement graph, manufactured handle or ROOT waiver.
            if (retirement == 'native ROOT') {
              core.native.rootCurrent = false;
            } else if (retirement == 'invalidated') {
              core.container.invalidate(globalRegexProvider);
            } else {
              original.controller.state = retirement == 'loading'
                  ? const AsyncLoading()
                  : AsyncError(
                      StateError('Synthetic original metadata owner failed.'),
                      StackTrace.current,
                    );
            }
          };
          await f.start(tester, confirmation: false);
          final reply = await f.finish(tester);
          expect(retired, true);
          expect(observer.preferenceLoads, 0);
          expect(retained.revision(), buildRevision);
          expect(retained.current, false);
          expect(
            original.prefs.store.owner.capture([
              NativeGlobalRegexPort.key,
            ], store: original.prefs.store).revisions[NativeGlobalRegexPort.key],
            savedRevision,
          );
          expect(
            original.prefs.getString(NativeGlobalRegexPort.key),
            original.raw,
          );
          expect(
            await configurationAction(
              tester,
              () => core.native.repo.getMutationsForSession(core.native.session),
            ),
            isEmpty,
          );
          if (retirement == 'native ROOT') {
            // The ORIGINAL per-tool ROOT refuses before the registry can read
            // metadata. The first paid POST has already delivered this call.
            expect(core.wire, hasLength(1));
            expect(f.results, isEmpty);
          } else {
            expect(core.wire, hasLength(2));
          }
          f.noEgress(reply.body);
        } finally {
          producer.observers.remove(observer);
          retained.dispose();
        }
      },
    );
  }

  domainLoopTest(
    'NATIVE child GLOBAL override belongs only to its origin; MODEL cannot discover foreign IDs',
    (tester, f) async {
      final core = f.screen.core;
      ({ProviderContainer container, NativeGlobalRegexPort? port}) capture(
        Ref ref,
      ) => (
        container: ref.container,
        port: captureSupportNativeGlobalRegex(
          ref,
          () => ref.mounted && core.native.native.isCurrent,
        ),
      );
      final captureProbe =
          Provider<
            ({ProviderContainer container, NativeGlobalRegexPort? port})
          >(capture);
      core.isolation.extraAllowed.add(captureProbe);
      await configurationAction(tester, () {
        expect(core.container.exists(globalRegexProvider), false);
        final noOwner = core.container.read(captureProbe);
        expect(noOwner.container, same(core.container));
        expect(noOwner.port, isNull);
      });
      final children = await configurationAction(
        tester,
        () => (
          ProviderContainer(
            parent: core.container,
            overrides: [
              globalRegexProvider.overrideWith(GlobalRegexNotifier.new),
              // A non-overridden probe would build in root and test the wrong
              // caller. Localize ONLY this test seam, never the owner registry.
              captureProbe.overrideWith(capture),
            ],
          ),
          ProviderContainer(
            parent: core.container,
            overrides: [captureProbe.overrideWith(capture)],
          ),
        ),
      );
      final childA = children.$1, siblingB = children.$2;
      NativeGlobalRegexPort? originalPort;
      final observer = _CaptureProducerObserver();
      ProviderContainer? preferenceContainer;
      try {
        // Real ordinary load/register in A, still using ROOT's original fixture
        // preferences. No synthetic port/registry callback supplies authority.
        final original = await loadedGlobalRegex(tester, f, container: childA);
        final permissionsBefore = await configurationAction(
          tester,
          () => core.native.permissions.readForNative(core.native.session),
        );
        final retained = original.controller.captureNativePort(
          original.prefs,
          () => core.native.native.isCurrent,
        )!;
        originalPort = retained;
        final buildRevision = retained.revision();
        final savedRevision = original.prefs.store.owner.capture([
          NativeGlobalRegexPort.key,
        ], store: original.prefs.store).revisions[NativeGlobalRegexPort.key];
        final sources = childA.allProviders().toList();
        expect(
          sources
              .singleWhere((source) => source.provider == globalRegexProvider)
              .container,
          same(childA),
        );
        final producerContainer = sources
            .singleWhere(
              (source) => source.provider == sharedPreferencesProvider,
            )
            .container;
        expect(producerContainer, same(core.container));
        preferenceContainer = producerContainer;
        producerContainer.observers.add(observer);
        await configurationAction(tester, () {
          expect(
            childA.read(nativeGlobalRegexOwnerRegistryProvider),
            same(core.container.read(nativeGlobalRegexOwnerRegistryProvider)),
          );
          // Retire the initial no-owner PROBE cache, not any producer. Root must
          // actually execute capture again after A's genuine registration.
          core.container.invalidate(captureProbe);
          final rootCapture = core.container.read(captureProbe);
          final siblingCapture = siblingB.read(captureProbe);
          expect(rootCapture.container, same(core.container));
          expect(siblingCapture.container, same(siblingB));
          expect(rootCapture.port, isNull);
          expect(siblingCapture.port, isNull);
          final ownCapture = childA.read(captureProbe);
          expect(ownCapture.container, same(childA));
          expect(ownCapture.port, isNotNull);
          expect(ownCapture.port!.controller, same(original.controller));
          expect(ownCapture.port!.current, true);
          expect(ownCapture.port!.observe(syntheticGlobalRegexId), isNotNull);
          expect(retained.current, true);
          // Actual notifier build/publish counter and native saved-key write
          // revision, not a fake loader or a matching canonical projection.
          expect(retained.revision(), buildRevision);
          expect(ownCapture.port!.revision(), buildRevision);
          expect(
            original.prefs.store.owner.capture(
              [NativeGlobalRegexPort.key],
              store: original.prefs.store,
            ).revisions[NativeGlobalRegexPort.key],
            savedRevision,
          );
          expect(observer.preferenceLoads, 0);
          expect(core.container.exists(globalRegexProvider), false);
          expect(siblingB.exists(globalRegexProvider), false);
          expect(original.raw, contains('privateUnknown'));
          expect(original.raw, contains(DomainLoopFixture.private));
          expect(
            original.prefs.getString(NativeGlobalRegexPort.key),
            original.raw,
          );
          expect(core.wire, isEmpty);
          expect(core.active, isNull);
        });
        final permissionsAfter = await configurationAction(
          tester,
          () => core.native.permissions.readForNative(core.native.session),
        );
        expect(
          permissionsAfter.preferences!.grants,
          permissionsBefore.preferences!.grants,
        );
        expect(
          await configurationAction(
            tester,
            () => core.native.repo.getMutationsForSession(core.native.session),
          ),
          isEmpty,
        );
        expect(
          original.prefs.getString(NativeGlobalRegexPort.key),
          original.raw,
        );
        f.script(
          core.call('astoria_global_regex_scripts_list', {}, id: 'foreign_regex'),
          next: (_) {
            expect(f.lastResult()['code'], 'unavailable');
            expect(f.results.last['effect'], 'none');
            expect(f.results.last['data'], isEmpty);
            return core.answer('No original same-origin loaded owner.');
          },
        );
        await f.start(tester, confirmation: false);
        final reply = await f.finish(tester);
        expect(core.container.exists(globalRegexProvider), false);
        expect(siblingB.exists(globalRegexProvider), false);
        expect(observer.preferenceLoads, 0);
        expect(retained.revision(), buildRevision);
        expect(
          original.prefs.store.owner.capture([
            NativeGlobalRegexPort.key,
          ], store: original.prefs.store).revisions[NativeGlobalRegexPort.key],
          savedRevision,
        );
        expect(original.prefs.getString(NativeGlobalRegexPort.key), original.raw);
        expect(
          await configurationAction(
            tester,
            () => core.native.repo.getMutationsForSession(core.native.session),
          ),
          isEmpty,
        );
        f.noEgress(reply.body);
      } finally {
        preferenceContainer?.observers.remove(observer);
        originalPort?.dispose();
        siblingB.dispose();
        childA.dispose();
      }
    },
  );

  for (final refusal in [
    'invalidated',
    'loading',
    'error',
    'preferences invalidated',
  ]) {
    domainLoopTest(
      'NATIVE $refusal GLOBAL graph capture refuses before any producer rebuild or Model Send',
      (tester, f) async {
        final core = f.screen.core;
        final original = await loadedGlobalRegex(tester, f);
        final permissionsBefore = await configurationAction(
          tester,
          () => core.native.permissions.readForNative(core.native.session),
        );
        final oldPort = original.controller.captureNativePort(
          original.prefs,
          () => core.native.native.isCurrent,
        )!;
        final buildRevision = oldPort.revision();
        final savedRevision = original.prefs.store.owner.capture([
          NativeGlobalRegexPort.key,
        ], store: original.prefs.store).revisions[NativeGlobalRegexPort.key];
        final captureProbe = Provider<NativeGlobalRegexPort?>((ref) {
          return captureSupportNativeGlobalRegex(
            ref,
            () => core.native.native.isCurrent,
          );
        });
        core.isolation.extraAllowed.add(captureProbe);
        final preferenceSource = core.container.allProviders().firstWhere(
          (source) => source.provider == sharedPreferencesProvider,
        );
        final observer = _CaptureProducerObserver();
        preferenceSource.container.observers.add(observer);
        expect(oldPort.current, true);
        expect(original.raw, contains('privateUnknown'));
        expect(original.raw, contains(DomainLoopFixture.private));
        try {
          await configurationAction(tester, () {
            if (refusal == 'preferences invalidated') {
              core.container.invalidate(sharedPreferencesProvider);
              expect(core.container.exists(sharedPreferencesProvider), true);
              // Same original plugin/cache is still current. Only the ACTUAL
              // original provider's synchronous disposal can retire this port.
              expect(original.prefs.store.current, true);
            } else if (refusal == 'invalidated') {
              core.container.invalidate(globalRegexProvider);
              // This is the reviewed hole: exists is STILL true, while reading
              // value/notifier/state would flush the scheduled normalizing build.
              expect(core.container.exists(globalRegexProvider), true);
            } else {
              // Real original notifier, not a replacement authority. Its actual
              // loading/error notification must clear the retained loaded facts.
              original.controller.state = refusal == 'loading'
                  ? const AsyncLoading()
                  : AsyncError(
                      StateError('Synthetic original regex load failed.'),
                      StackTrace.current,
                    );
            }
            // No await/pump between invalidate and the production capture seam.
            // This probe only calls that seam; it supplies NO replacement owner.
            expect(core.container.read(captureProbe), isNull);
            if (refusal != 'preferences invalidated') {
              final regex = core.container
                  .read(supportAppNativeDomainAdaptersProvider)
                  .whereType<SupportNativeDomainAdapter>()
                  .map((adapter) => adapter.adapter)
                  .whereType<SupportNativeGlobalRegexAdapter>()
                  .single;
              expect(regex.port, isNull);
            }
            // Other domain siblings have their own reviewed prefs readers. The
            // source-invalidated case exercises ONLY this production capture
            // graph, without asking a sibling to rebuild the prefs producer.
            expect(
              original.controller.captureNativePort(
                original.prefs,
                () => core.native.native.isCurrent,
              ),
              isNull,
            );
            expect(oldPort.current, false);
            expect(oldPort.loaded(), isNull);
            // The original port's revision callback is a plain retained integer,
            // NOT notifier.state. Any additional actual build increments it.
            expect(oldPort.revision(), buildRevision);
            expect(observer.preferenceLoads, 0);
            expect(
              original.prefs.store.owner.capture(
                [NativeGlobalRegexPort.key],
                store: original.prefs.store,
              ).revisions[NativeGlobalRegexPort.key],
              savedRevision,
            );
            expect(
              original.prefs.getString(NativeGlobalRegexPort.key),
              original.raw,
            );
            expect(core.wire, isEmpty);
            expect(core.active, isNull);
          });
          final permissionsAfter = await configurationAction(
            tester,
            () => core.native.permissions.readForNative(core.native.session),
          );
          expect(
            permissionsAfter.preferences!.grants,
            permissionsBefore.preferences!.grants,
          );
          expect(
            await configurationAction(
              tester,
              () =>
                  core.native.repo.getMutationsForSession(core.native.session),
            ),
            isEmpty,
          );
          expect(
            original.prefs.getString(NativeGlobalRegexPort.key),
            original.raw,
          );
          f.noEgress();
        } finally {
          preferenceSource.container.observers.remove(observer);
          oldPort.dispose();
        }
      },
    );
  }

  domainLoopTest(
    'MODEL absent GLOBAL controller never boots or normalizes it',
    (tester, f) async {
      final core = f.screen.core;
      expect(core.container.exists(globalRegexProvider), false);
      f.script(
        core.call('astoria_global_regex_scripts_list', {}, id: 'absent_regex'),
        next: (round) {
          expect(f.lastResult()['code'], 'unavailable');
          expect(f.results.last['effect'], 'none');
          expect(f.results.last['data'], isEmpty);
          if (round == 2) {
            return core.call('astoria_global_regex_disable', {
              'id': syntheticGlobalRegexId,
            }, id: 'absent_regex_disable');
          }
          return core.answer('No original loaded controller.');
        },
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(core.container.exists(globalRegexProvider), false);
      expect(core.prefs.containsKey(NativeGlobalRegexPort.key), false);
      expect(
        await configurationAction(
          tester,
          () => core.native.repo.getMutationsForSession(core.native.session),
        ),
        isEmpty,
      );
      f.noEgress(reply.body);
    },
  );

  for (final refusal in ['missing ID', 'bounded encrypted evidence']) {
    domainLoopTest(
      'MODEL GLOBAL $refusal refuses without normalization or plugin effect',
      (tester, f) async {
        final core = f.screen.core;
        final original = await loadedGlobalRegex(tester, f);
        var raw = original.raw;
        if (refusal == 'bounded encrypted evidence') {
          // Keep known fields equal: enlarge ONLY an unknown private JSON value.
          raw = original.raw.replaceFirst(
            '"number":1.25',
            '"number":1.25,"largePrivateUnknown":"${List.filled(9000, 'x').join()}"',
          );
          await configurationAction(
            tester,
            () => original.prefs.setString(NativeGlobalRegexPort.key, raw),
          );
        }
        f.script(
          core.call('astoria_global_regex_disable', {
            'id': refusal == 'missing ID'
                ? 'missing-global'
                : syntheticGlobalRegexId,
          }),
          next: (_) {
            expect(f.lastResult()['code'], 'unavailable');
            return core.answer('No matching original bounded plan.');
          },
        );
        await f.start(tester, confirmation: false);
        final reply = await f.finish(tester);
        expect(original.prefs.getString(NativeGlobalRegexPort.key), raw);
        expect(
          await configurationAction(
            tester,
            () => core.native.repo.getMutationsForSession(core.native.session),
          ),
          isEmpty,
        );
        f.noEgress(reply.body);
      },
    );
  }

  for (final change in ['controller', 'source', 'raw ABA', 'stop']) {
    domainLoopTest(
      'MODEL $change retires confirmed GLOBAL regex before Apply',
      (tester, f) async {
        final core = f.screen.core;
        final original = await loadedGlobalRegex(tester, f);
        f.script(
          core.call('astoria_global_regex_disable', {
            'id': syntheticGlobalRegexId,
          }),
          next: (_) => core.answer('Nothing saved.'),
        );
        await f.start(tester);
        final button = find.byKey(
          const ValueKey('support_tool_confirmation_accept'),
        );
        final route = ModalRoute.of<void>(tester.element(button))!;
        final expiredApply = tester.widget<GlazeActionButton>(button).onTap!;
        await configurationAction(tester, () async {
          if (change == 'controller') {
            core.container.invalidate(globalRegexProvider);
          } else if (change == 'source') {
            core.container
                .read(chatSourceMutationRegistryProvider)
                .beginMutation(sessionId: DomainLoopFixture.session)();
          } else if (change == 'raw ABA') {
            await original.prefs.setString(
              NativeGlobalRegexPort.key,
              original.raw,
            );
          } else {
            tester
                .widget<IconButton>(
                  find.byKey(const ValueKey('support_composer_stop_btn')),
                )
                .onPressed!();
          }
        });
        await configurationAction(tester, expiredApply);
        await tester.pump();
        if (route.isCurrent) await f.cancel(tester);
        await tester.pump(route.reverseTransitionDuration);
        await tester.pump(const Duration(microseconds: 1));
        final reply = await f.finish(tester);
        expect(
          original.prefs.getString(NativeGlobalRegexPort.key),
          original.raw,
        );
        expect(
          await configurationAction(
            tester,
            () => core.native.repo.getMutationsForSession(core.native.session),
          ),
          isEmpty,
        );
        f.noEgress(reply.body);
      },
    );
  }

  for (final change in ['raw ABA', 'source', 'dormant inventory']) {
    domainLoopTest(
      'MODEL GLOBAL retained Undo refuses $change without importing receipt JSON',
      (tester, f) async {
        final core = f.screen.core;
        final original = await loadedGlobalRegex(tester, f);
        f.script(
          core.call('astoria_global_regex_disable', {
            'id': syntheticGlobalRegexId,
          }),
        );
        await f.start(tester);
        await f.apply(tester);
        await f.finish(tester);
        final after = original.prefs.getString(NativeGlobalRegexPort.key);
        await configurationAction(tester, () async {
          if (change == 'raw ABA') {
            await original.prefs.setString(NativeGlobalRegexPort.key, after!);
          } else if (change == 'source') {
            core.container
                .read(chatSourceMutationRegistryProvider)
                .beginMutation(sessionId: DomainLoopFixture.session)();
          } else {
            await core.container
                .read(chatRepoProvider)
                .insertIfAbsent(
                  const ChatSession(
                    id: 'domain-character_1',
                    characterId: DomainLoopFixture.character,
                    sessionIndex: 1,
                  ),
                );
          }
        });
        f.script(
          core.call('astoria_global_regex_receipts', {}),
          next: (round) {
            if (round == 2) {
              expect(f.lastData()['records'], isEmpty);
              return core.call('astoria_global_regex_undo', {
                'receipt': 'repair-00000000000000000000000000000000',
              }, id: 'forged_regex_undo');
            }
            expect(f.lastResult()['code'], 'unavailable');
            return core.answer('No current genuine Undo.');
          },
        );
        await f.start(tester, confirmation: false);
        final reply = await f.finish(tester);
        expect(original.prefs.getString(NativeGlobalRegexPort.key), after);
        expect(
          (await configurationAction(
            tester,
            () => core.native.repo.getMutationsForSession(core.native.session),
          )).single.status,
          'applied',
        );
        f.noEgress(reply.body);
      },
    );
  }

  for (final change in ['raw ABA', 'inventory insertion']) {
    domainLoopTest(
      'MODEL final inventory SELECT delivery $change prevents GLOBAL plugin CAS',
      (tester, f) async {
        final core = f.screen.core;
        final original = await loadedGlobalRegex(tester, f);
        f.script(
          core.call('astoria_global_regex_disable', {
            'id': syntheticGlobalRegexId,
          }),
        );
        await f.start(tester);
        var retired = false;
        core.native.sql.afterSelect = (statement, args) async {
          final sql = statement.toLowerCase();
          if (sql.startsWith('select') && sql.contains('chat_sessions')) {
            core.native.sql.afterSelect = null;
            retired = true;
            if (change == 'raw ABA') {
              await original.prefs.setString(
                NativeGlobalRegexPort.key,
                original.raw,
              );
            } else {
              await core.container
                  .read(chatRepoProvider)
                  .insertIfAbsent(
                    const ChatSession(
                      id: 'domain-character_1',
                      characterId: DomainLoopFixture.character,
                      sessionIndex: 1,
                    ),
                  );
            }
          }
        };
        await f.apply(tester);
        final reply = await f.finish(tester);
        expect(retired, true);
        expect(
          original.prefs.getString(NativeGlobalRegexPort.key),
          original.raw,
        );
        expect(
          (await configurationAction(
            tester,
            () => core.native.repo.getMutationsForSession(core.native.session),
          )).any((r) => r.status == 'applied'),
          false,
        );
        f.noEgress(reply.body);
      },
    );
  }

  domainLoopTest(
    'MODEL lost journal settlement preserves acknowledged GLOBAL effect without Undo',
    (tester, f) async {
      final core = f.screen.core;
      final original = await loadedGlobalRegex(tester, f);
      f.script(
        core.call('astoria_global_regex_disable', {
          'id': syntheticGlobalRegexId,
        }),
      );
      await f.start(tester);
      core.native.sql.afterWrite = (statement) async {
        final sql = statement.toLowerCase();
        if (sql.startsWith('update') &&
            sql.contains('support_mutation_journal')) {
          throw StateError(
            'Synthetic encrypted regex journal settlement lost.',
          );
        }
      };
      await f.apply(tester);
      final reply = await f.finish(tester);
      core.native.sql.afterWrite = null;
      expect(
        original.prefs.getString(NativeGlobalRegexPort.key),
        NativeGlobalRegexJson.read(original.raw)!.disabled(0),
      );
      expect(reply.body, contains('изменение сохранено'));
      expect(reply.body, isNot(contains('без изменений')));
      expect(
        (await configurationAction(
          tester,
          () => core.native.repo.getMutationsForSession(core.native.session),
        )).single.status,
        'pending',
      );
      f.noEgress(reply.body);
    },
  );
}
