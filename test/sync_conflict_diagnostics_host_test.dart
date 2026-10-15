import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_engine.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_service.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_provider.dart';
import 'package:glaze_flutter/features/cloud_sync/widgets/sync_conflict_diagnostics_panel.dart';
import 'package:glaze_flutter/features/cloud_sync/widgets/sync_sheet.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import 'sync_lifecycle_test.dart' as ports;

const _openKey = Key('sync-conflict-diagnostics-open');
const _runKey = Key('sync-diagnostics-run');
const _copyKey = Key('sync-diagnostics-copy');
const _reportKey = Key('sync-diagnostics-report');
const _includeKeysPref = 'gz_sync_include_api_keys';
const _canary = 'SYNTHETIC_PRIVATE_ID_TITLE_HASH';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(batterySaver: true);
}

SyncConflict _conflict(String suffix) {
  final entry = SyncManifestEntry(
    type: 'character',
    id: '$_canary-$suffix',
    path: '$_canary/$suffix.json',
    updatedAt: 1700000000000,
    hash: _canary,
  );
  return SyncConflict(
    key: entry.key,
    type: entry.type,
    id: entry.id,
    name: '$_canary-$suffix',
    localEntry: entry,
    cloudEntry: entry.copyWith(hash: '$_canary-cloud'),
  );
}

SyncConflictDiagnosticReport _safeReport() => SyncConflictDiagnosticReport(
  items: [
    SyncConflictDiagnosticItem(
      ordinal: 1,
      type: SyncDiagnosticType.character,
      status: SyncDiagnosticStatus.compared,
      localTimestampUnit: SyncDiagnosticTimestampUnit.millisecondsLikely,
      cloudTimestampUnit: SyncDiagnosticTimestampUnit.secondsLikely,
      paths: [
        SyncDiagnosticPath('description', SyncDiagnosticDifference.value),
      ],
    ),
  ],
);

/// Deliberately synthetic lock and read, NOT production service-lock evidence.
/// Only in-memory ports are constructed. Never call init/auth/default provider.
class _Service extends SyncService {
  _Service()
    : super(
        characterRepo: ports.FakeCharacterStore(),
        chatRepo: ports.FakeChatStore(),
        personaRepo: ports.FakePersonaStore(),
        presetRepo: ports.FakePresetStore(),
        apiRepo: ports.FakeApiConfigStore(),
        memoryBookRepo: ports.FakeMemoryBookStore(),
        lorebookRepo: ports.FakeLorebookStore(),
        embeddingRepo: ports.FakeEmbeddingStore(),
        imageStorage: ports.FakeImageStore(),
        themePresetRepo: ports.FakeThemePresetStore(),
        extensionPresetRepo: ports.FakeExtensionPresetStore(),
        extensionsSettingsStore: ports.FakeExtensionsSettingsStore(),
        infoBlockStore: ports.FakeInfoBlockStore(),
        trackerSnapshotStore: ports.FakeTrackerSnapshotStore(),
        trackerValueStore: ports.FakeTrackerValueStore(),
        studioConfigStore: ports.FakeStudioConfigStore(),
        sessionDeletionStore: ports.FakeSessionDeletionStore(
          ports.FakeChatStore(),
        ),
        characterDeletionStore: ports.FakeCharacterDeletionStore(
          ports.FakeCharacterStore(),
        ),
        saveLorebookActivations: (_) async => fail('Unexpected settings write'),
        selectAdapter: (_) => throw StateError('No cloud adapter allowed'),
        diagnosticDownload: (_) async => fail('No download allowed'),
      );

  final pending = Completer<SyncConflictDiagnosticReport>();
  List<SyncConflict>? captured;
  bool diagnosing = false;
  bool autoEnabled = true;
  int threshold = 5;
  int reads = 0;
  int settingWrites = 0;
  Completer<void>? settingsGate;

  @override
  SyncStatus get status => SyncStatus.conflict;
  @override
  bool isConnected() => true;
  @override
  bool get isDiagnosingConflicts => diagnosing;
  @override
  bool get autoSyncEnabled => autoEnabled;
  @override
  int get autoSyncMessageCount => threshold;

  @override
  Future<SyncConflictDiagnosticReport> diagnoseConflicts(
    List<SyncConflict> snapshot,
  ) async {
    if (diagnosing) fail('Duplicate diagnosis');
    reads++;
    captured = snapshot;
    diagnosing = true;
    try {
      return await pending.future;
    } finally {
      diagnosing = false;
    }
  }

  @override
  Future<void> setAutoSync(bool enabled, {int messageCount = 5}) async {
    settingWrites++;
    if (diagnosing) fail('Settings reached service during diagnosis');
    if (settingsGate != null) await settingsGate!.future;
    autoEnabled = enabled;
    threshold = messageCount;
  }

  @override
  Future<void> fullPush({
    void Function(SyncProgress)? onProgress,
    bool? includeApiKeys,
  }) async => fail('Unexpected push');
  @override
  Future<void> fullPull({void Function(SyncProgress)? onProgress}) async =>
      fail('Unexpected pull');
  @override
  Future<void> disconnect() async => fail('Unexpected disconnect');
  @override
  Future<void> wipeCloudData({void Function(SyncProgress)? onProgress}) async =>
      fail('Unexpected wipe');
  @override
  Future<void> resolveConflict(SyncConflict conflict, String choice) async =>
      fail('Unexpected choice');
  @override
  Future<void> resolveAllConflictsAndApply(
    String choice, {
    required void Function(SyncProgress) onProgress,
  }) async => fail('Unexpected all-conflict choice');
}

class _Host {
  _Host(this.container, this.navigator, this.prefs);
  final ProviderContainer container;
  final GlobalKey<NavigatorState> navigator;
  final SharedPreferences prefs;

  Future<void> reopen(WidgetTester tester) async {
    unawaited(
      navigator.currentState!.push<void>(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => const SyncSheet(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Future<_Host> _pumpHost(
  WidgetTester tester,
  _Service service, {
  Size size = const Size(800, 1000),
  Locale locale = const Locale('en'),
  List<SyncConflict>? conflicts,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      syncServiceProvider.overrideWith((_) async => service),
      sharedPreferencesProvider.overrideWith((_) async => prefs),
      appSettingsProvider.overrideWith(_Settings.new),
      themeProvider.overrideWith(
        (_) => ThemeNotifier(storage: ThemePresetStorage(prefs)),
      ),
      syncConnectedProvider.overrideWith((_) => true),
      syncStatusProvider.overrideWith((_) => service.status),
      syncAutoEnabledProvider.overrideWith((_) => service.autoEnabled),
      syncConflictsProvider.overrideWith(
        (_) => conflicts ?? [_conflict('one'), _conflict('two')],
      ),
    ],
  );
  addTearDown(container.dispose);
  // Preload only the override, never SyncConfig, .env or runtime DB providers.
  await container.read(syncServiceProvider.future);
  await container.read(sharedPreferencesProvider.future);
  final navigator = GlobalKey<NavigatorState>();
  await tester.runAsync(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: EasyLocalization(
          supportedLocales: const [Locale('en'), Locale('ru')],
          path: 'assets/translations',
          startLocale: locale,
          fallbackLocale: const Locale('en'),
          child: Builder(
            builder: (context) => MaterialApp(
              navigatorKey: navigator,
              theme: ThemeData.dark(),
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  });
  await tester.pumpAndSettle();
  final host = _Host(container, navigator, prefs);
  await host.reopen(tester);
  return host;
}

Future<void> _press(WidgetTester tester, Key key) async {
  if (find.byKey(key).evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      find.byKey(key),
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await Scrollable.ensureVisible(
    tester.element(find.byKey(key)),
    alignment: 0.5,
  );
  await tester.pump();
  await tester.tap(find.byKey(key));
  await tester.pump();
}

Future<void> _back(WidgetTester tester) async {
  tester.widget<SheetView>(find.byType(SheetView)).onBack!();
  await tester.pump();
}

List<VoidCallback> _idleActions(WidgetTester tester) => [
  ...tester.widgetList<InkWell>(_bodyInkWells).map((w) => w.onTap),
  ...tester
      .widgetList<TextButton>(find.byType(TextButton))
      .map((w) => w.onPressed),
].whereType<VoidCallback>().toList();

Finder get _bodyInkWells => find.descendant(
  of: find.byType(SingleChildScrollView),
  matching: find.byType(InkWell),
);

void _expectLocked(WidgetTester tester) {
  expect(tester.widget<GlazeActionButton>(find.byKey(_openKey)).onTap, isNull);
  for (final row in tester.widgetList<SyncConflictRow>(
    find.byType(SyncConflictRow),
  )) {
    expect(row.enabled, isFalse);
  }
  for (final button in tester.widgetList<TextButton>(find.byType(TextButton))) {
    expect(button.onPressed, isNull);
  }
  for (final button in tester.widgetList<InkWell>(_bodyInkWells)) {
    expect(button.onTap, isNull);
  }
  for (final toggle in tester.widgetList<Switch>(find.byType(Switch))) {
    expect(toggle.onChanged, isNull);
  }
}

void main() {
  final clipboardWrites = <String>[];
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({_includeKeysPref: false});
    clipboardWrites.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardWrites.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('actual host freezes opening list and copies only safe report', (
    tester,
  ) async {
    final original = [_conflict('one'), _conflict('two')];
    final expected = List.of(original);
    final service = _Service();
    final host = await _pumpHost(tester, service, conflicts: original);
    await _press(tester, _openKey);
    expect(find.byType(SyncConflictDiagnosticsPanel), findsOneWidget);
    expect(service.reads, 0);
    expect(find.textContaining(_canary), findsNothing);
    original.clear();
    host.container.read(syncConflictsProvider.notifier).state = [
      _conflict('new'),
    ];
    await _press(tester, _runKey);
    expect(service.captured, orderedEquals(expected));
    expect(() => service.captured!.clear(), throwsUnsupportedError);
    expect(service.reads, 1);
    service.pending.complete(_safeReport());
    await tester.pumpAndSettle();
    expect(find.text(_safeReport().toSafeText()), findsOneWidget);
    expect(find.textContaining(_canary), findsNothing);
    expect(clipboardWrites, isEmpty);
    await _press(tester, _copyKey);
    await tester.pumpAndSettle();
    expect(clipboardWrites, [_safeReport().toSafeText()]);
    expect(tester.takeException(), isNull);
  });

  for (final failRead in [false, true]) {
    testWidgets(
      'back retains locks and drops late ${failRead ? 'error' : 'success'}',
      (tester) async {
        final service = _Service();
        final host = await _pumpHost(tester, service);
        final actions = _idleActions(tester);
        final switches = tester
            .widgetList<Switch>(find.byType(Switch))
            .toList();
        final settingRows = [
          tester
              .widget<GestureDetector>(
                find.byKey(const Key('sync-auto-setting')),
              )
              .onTap!,
          tester
              .widget<GestureDetector>(
                find.byKey(const Key('sync-include-keys-setting')),
              )
              .onTap!,
        ];
        expect(switches, hasLength(2));
        expect(settingRows, hasLength(2));
        final conflicts = List.of(host.container.read(syncConflictsProvider));
        await _press(tester, _openKey);
        await _press(tester, _runKey);
        await _back(tester);
        _expectLocked(tester);
        // The current host's own lock survives panel back independently too.
        service.diagnosing = false;
        // Stale callbacks also recheck the lock before any controller mutation.
        for (final action in [...actions, ...settingRows]) {
          action();
        }
        for (final toggle in switches) {
          toggle.onChanged!(!toggle.value);
        }
        await tester.pump();
        expect(service.settingWrites, 0);
        service.diagnosing = true;
        expect(host.prefs.getBool(_includeKeysPref), isFalse);
        expect(
          host.container.read(syncConflictsProvider),
          orderedEquals(conflicts),
        );
        expect(service.reads, 1);
        if (failRead) {
          service.pending.completeError(StateError(_canary));
        } else {
          service.pending.complete(_safeReport());
        }
        await tester.pumpAndSettle();
        expect(find.byKey(_reportKey), findsNothing);
        expect(find.byKey(_copyKey), findsNothing);
        expect(
          tester.widget<GlazeActionButton>(find.byKey(_openKey)).onTap,
          isNotNull,
        );
        await _press(tester, _openKey);
        expect(find.byKey(_reportKey), findsNothing);
        expect(clipboardWrites, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final failRead in [false, true]) {
    testWidgets(
      'new host respects captured service lock after pending host closes: $failRead',
      (tester) async {
        final service = _Service();
        final host = await _pumpHost(tester, service);
        await _press(tester, _openKey);
        await _press(tester, _runKey);
        await _back(tester);
        await _back(tester);
        await tester.pumpAndSettle();
        expect(find.byType(SyncSheet), findsNothing);
        expect(service.isDiagnosingConflicts, isTrue);
        await host.reopen(tester);
        _expectLocked(tester);
        if (failRead) {
          service.pending.completeError(StateError(_canary));
        } else {
          service.pending.complete(_safeReport());
        }
        await tester.pumpAndSettle();
        // The synthetic service flag is not reactive. A real host rebuild reads it.
        host.container.read(syncConflictsProvider.notifier).state = [
          _conflict('new'),
        ];
        await tester.pumpAndSettle();
        expect(find.byKey(_reportKey), findsNothing);
        await _press(tester, _openKey);
        expect(find.byType(SyncConflictDiagnosticsPanel), findsOneWidget);
        expect(find.byKey(_reportKey), findsNothing);
        expect(service.reads, 1);
        expect(clipboardWrites, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'idle settings still persist and late auto setting uses no disposed WidgetRef',
    (tester) async {
      final service = _Service();
      final host = await _pumpHost(tester, service);
      var switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
      switches.last.onChanged!(true);
      await tester.pumpAndSettle();
      expect(host.prefs.getBool(_includeKeysPref), isTrue);
      final add = tester.widget<InkWell>(
        find
            .ancestor(
              of: find.byIcon(Icons.add),
              matching: find.byType(InkWell),
            )
            .first,
      );
      add.onTap!();
      await tester.pumpAndSettle();
      expect(service.threshold, 6);
      switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
      switches.first.onChanged!(false);
      await tester.pumpAndSettle();
      expect(service.autoEnabled, isFalse);
      expect(host.container.read(syncAutoEnabledProvider), isFalse);
      service.settingsGate = Completer<void>();
      tester.widgetList<Switch>(find.byType(Switch)).first.onChanged!(true);
      await _back(tester);
      await tester.pumpAndSettle();
      service.settingsGate!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [360.0, 1200.0]) {
    testWidgets(
      'actual conflict/privacy/run/copy controls reachable at $width',
      (tester) async {
        final service = _Service();
        await _pumpHost(
          tester,
          service,
          size: Size(width, 800),
          locale: const Locale('ru'),
        );
        await _press(tester, _openKey);
        final privacyContext = tester.element(find.byKey(_runKey));
        final privacy = find.text(
          'sync_diagnostics_privacy'.tr(context: privacyContext),
        );
        expect(privacy, findsOneWidget);
        await tester.ensureVisible(privacy);
        expect(
          tester.getRect(privacy).overlaps(Offset.zero & Size(width, 800)),
          isTrue,
        );
        expect(service.reads, 0);
        await _press(tester, _runKey);
        service.pending.complete(_safeReport());
        await tester.pumpAndSettle();
        await _press(tester, _copyKey);
        await tester.pumpAndSettle();
        expect(clipboardWrites, [_safeReport().toSafeText()]);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
