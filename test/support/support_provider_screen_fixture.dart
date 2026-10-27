import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_provider_entry.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_provider_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_provider_screen_controller.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import 'support_provider_vertical_fixture.dart';

export 'support_provider_vertical_fixture.dart';

final class ProviderScreenFixture {
  late final ProviderVerticalFixture root;
  final attempts = <String>[];
  final entryKey = GlobalKey<SupportProviderEntryState>();
  final bool permissions;
  bool _rootCreated = false;
  ProviderScreenFixture({this.permissions = true});

  Never block(String boundary) {
    attempts.add(boundary);
    throw StateError('Outside declared provider screen fixture');
  }

  Future<T> guarded<T>(Future<T> Function() body) => HttpOverrides.runZoned(
    () => IOOverrides.runZoned(
      body,
      createFile: (_) => block('file/default DB'),
      createDirectory: (_) => block('directory'),
      createLink: (_) => block('link'),
      socketConnect: (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
          block('socket'),
      socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) =>
          block('socket'),
    ),
    createHttpClient: (_) => block('HTTP/default adapter'),
  );

  Future<T> real<T>(WidgetTester tester, Future<T> Function() body) async {
    late T result;
    Object? failure;
    StackTrace? trace;
    await tester.runAsync(() async {
      try {
        result = await guarded(body);
      } catch (error, stack) {
        failure = error;
        trace = stack;
      }
    });
    // runAsync otherwise reports-and-returns-null, obscuring the original fault.
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return result;
  }

  Future<void> mount(
    WidgetTester tester, {
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    await real(tester, () async {
      root = ProviderVerticalFixture();
      _rootCreated = true;
      await root.initialize(permissions: permissions);
      await EasyLocalization.ensureInitialized();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: root.container,
        child: EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'declared-memory-only',
          assetLoader: const ProviderMemoryLoader(),
          startLocale: const Locale('en'),
          saveLocale: false,
          child: Builder(
            builder: (context) => MaterialApp(
              theme: ThemeData(brightness: brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              locale: context.locale,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              home: Scaffold(
                appBar: AppBar(actions: [SupportProviderEntry(key: entryKey)]),
                body: const SizedBox(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('support_provider_open')), findsOneWidget);
  }

  SupportProviderScreenController? controller(WidgetTester tester) => tester
      .widget<SupportProviderSheet>(find.byType(SupportProviderSheet))
      .controller;
  Future<void> until(
    WidgetTester tester,
    bool Function() reached, {
    required String label,
  }) async {
    // Post-frame observation and shared SQL/vault tails may belong to the fake
    // zone even when the final gesture belongs to runAsync. Drive BOTH queues.
    for (var turn = 0; turn < 100; turn++) {
      if (reached()) return;
      await tester.pump(const Duration(milliseconds: 16));
      await real(tester, () => Future<void>.delayed(Duration.zero));
    }
    await tester.pump();
    expect(reached(), isTrue, reason: 'Original provider UI: $label');
  }

  Future<void> idle(WidgetTester tester, SupportProviderScreenController c) =>
      until(tester, () => !c.busy, label: 'owned controller job');

  Future<T> join<T>(
    WidgetTester tester,
    Future<T> Function() original, {
    required String label,
  }) async {
    // Box BEFORE returning from runAsync: never flatten an original future that
    // needs another fake frame. Observation cannot complete or replace its job.
    final observed = await real(
      tester,
      () async => _ProviderScreenJob<T>(original()),
    );
    await until(tester, () => observed.done, label: label);
    return observed.result();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    expect(finder, findsOneWidget);
    final list = find.ancestor(of: finder, matching: find.byType(ListView));
    if (list.evaluate().isNotEmpty) {
      expect(list, findsOneWidget);
      expect(
        tester.element(list),
        same(
          tester.element(find.byKey(const ValueKey('support_provider_scroll'))),
        ),
      );
      // Default ensureVisible top-aligns even an already visible control, under
      // SheetView's interactive header. Preserve visible controls; otherwise
      // reveal centrally, with zero-duration scrolling in the fake zone.
      final bounds = _providerControlBounds(tester, finder, list);
      if (!bounds.visible.contains(bounds.control.topLeft) ||
          bounds.control.bottom > bounds.visible.bottom) {
        await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
        await tester.pump();
        await tester.pump();
      }
      final revealed = _providerControlBounds(tester, finder, list);
      expect(revealed.control.top, greaterThanOrEqualTo(revealed.visible.top));
      expect(
        revealed.control.bottom,
        lessThanOrEqualTo(revealed.visible.bottom),
      );
      expect(
        revealed.control.left,
        greaterThanOrEqualTo(revealed.visible.left),
      );
      expect(revealed.control.right, lessThanOrEqualTo(revealed.visible.right));
    } else if (find
        .ancestor(of: finder, matching: find.byType(SheetView))
        .evaluate()
        .isNotEmpty) {
      final sheet = tester.getRect(find.byType(SheetView));
      final rect = tester.getRect(finder);
      expect(rect.top, greaterThanOrEqualTo(sheet.top));
      expect(
        rect.bottom,
        lessThanOrEqualTo(
          sheet.bottom -
              tester.view.viewInsets.bottom / tester.view.devicePixelRatio,
        ),
      );
      expect(rect.left, greaterThanOrEqualTo(sheet.left));
      expect(rect.right, lessThanOrEqualTo(sheet.right));
    }
    expect(finder.hitTestable(), findsOneWidget);
  }

  Future<void> tap(WidgetTester tester, String key, {bool waits = true}) async {
    final finder = find.byKey(ValueKey(key));
    if (finder.evaluate().isEmpty && key == 'support_provider_cancel') {
      // The original index-zero close control can be recycled after scrolling
      // a long form. Materialize it in its OWN list before exact hit testing.
      await tester.scrollUntilVisible(
        finder,
        -200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('support_provider_scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
    }
    await reveal(tester, finder);
    await real(tester, () async {
      await tester.tap(finder);
    });
    if (!waits) return; // Allows immediate-clear proof before another frame.
    await tester.pump();
    if (key == 'support_provider_open') {
      final route = ModalRoute.of(
        tester.element(find.byType(SupportProviderSheet)),
      )!;
      // The first frame establishes the original ticker epoch. Cross its OWN
      // endpoint, then publish the post-frame measured header before hit testing.
      await tester.pump(
        route.transitionDuration + const Duration(microseconds: 1),
      );
      expect(route.animation!.status, AnimationStatus.completed);
      expect(route.isCurrent, isTrue);
    }
    await until(tester, () {
      if (find.byType(SupportProviderSheet).evaluate().isEmpty) return true;
      return controller(tester)?.busy != true;
    }, label: '$key controller job');
    // Only the required layout frames; cursor/ripple activity is not job truth.
    await tester.pump();
    await tester.pump();
    expect(find.byType(ErrorWidget), findsNothing);
  }

  Future<void> text(WidgetTester tester, String key, String value) async {
    final keyed = find.byKey(ValueKey(key));
    final field = tester.widget(keyed) is TextField
        ? keyed
        : find.descendant(of: keyed, matching: find.byType(TextField));
    await reveal(tester, field);
    await tester.enterText(field, value);
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    if (_rootCreated) {
      await join(tester, root.close, label: 'owned memory DB close');
    }
    expect(attempts, isEmpty);
    expect(tester.takeException(), isNull);
  }
}

/// Read-only observation of the actual job, including its original failure.
final class _ProviderScreenJob<T> {
  _ProviderScreenJob(Future<T> original) {
    original.then(
      (value) {
        _value = value;
        done = true;
      },
      onError: (Object error, StackTrace trace) {
        _error = error;
        _trace = trace;
        done = true;
      },
    );
  }
  bool done = false;
  late T _value;
  Object? _error;
  StackTrace? _trace;
  T result() {
    if (_error != null) Error.throwWithStackTrace(_error!, _trace!);
    return _value;
  }
}

({Rect control, Rect visible}) _providerControlBounds(
  WidgetTester tester,
  Finder control,
  Finder list,
) {
  final sheet = find.ancestor(of: list, matching: find.byType(SheetView));
  expect(sheet, findsOneWidget);
  final title = find.descendant(
    of: sheet,
    matching: find.text(tester.widget<SheetView>(sheet).title!),
  );
  expect(title, findsOneWidget);
  final header = find.descendant(
    of: sheet,
    matching: find.ancestor(
      of: title,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Positioned &&
            widget.top == 0 &&
            widget.left == 0 &&
            widget.right == 0 &&
            widget.bottom == null,
      ),
    ),
  );
  expect(header, findsOneWidget);
  final original = Scrollable.of(tester.element(control));
  final scrollable = find.descendant(
    of: list,
    matching: find.byElementPredicate(
      (element) => identical(element, original.context),
    ),
  );
  expect(scrollable, findsOneWidget);
  expect(original.position.hasContentDimensions, isTrue);
  final viewport = tester
      .getRect(scrollable)
      .intersect(
        Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio),
      );
  final headerRect = tester.getRect(header);
  expect(headerRect.height, greaterThan(0));
  final visible = Rect.fromLTRB(
    viewport.left,
    headerRect.bottom > viewport.top ? headerRect.bottom : viewport.top,
    viewport.right,
    viewport.bottom,
  );
  expect(visible.height, greaterThan(0));
  return (control: tester.getRect(control), visible: visible);
}

final class ProviderMemoryLoader extends AssetLoader {
  const ProviderMemoryLoader();
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => {
    for (final key in [
      'title',
      'name',
      'model',
      'endpoint',
      'max_tokens',
      'context_size',
      'temperature',
      'purpose',
      'protocol',
      'new',
      'existing',
      'review',
      'confirm',
      'cancel',
      'close',
      'before',
      'after',
      'key_title',
      'key_submit',
      'key_cancel',
      'key_notice',
      'key_destinations',
      'key_destination_notice',
      'key_not_saved',
      'key_saved',
      'unverified',
      'scope_notice',
      'purpose_notice',
      'offline',
      'route',
      'permissions',
      'prepared',
      'empty',
      'list_notice',
      'refresh',
      'no_assignment',
      'applied',
      'key_saved_notice',
      'custom_confirm',
      'back_list',
      'custom_endpoint',
      'custom_endpoint_notice',
      'purpose_roleplay',
      'purpose_studio',
      'purpose_memoryBooks',
      'purpose_astoria',
      'protocol_openai',
      'protocol_openai_responses',
      'protocol_anthropic',
      'protocol_gemini',
      'protocol_openrouter',
      'protocol_custom_chat_completion',
      'profile',
      'model_manual',
      'max_tokens_bounds',
      'context_bounds',
      'temperature_bounds',
      'destination_bounds',
      'model_for_endpoint',
      'exact_review',
      'confirm_apply',
      'confirm_undo',
      'review_cancel',
      'review_undo',
      'no_profile',
      'custom_review',
      'custom_confirmed',
      'update_immutable',
      'edit',
      'key_metadata_unavailable',
      'key_custom_confirm',
      'key_unavailable',
      'key_invalid',
      'key_uncertain',
      'key_busy',
      'permissions_open',
      'busy',
      'unavailable',
      'read_only',
      'invalid',
      'refused',
      'storageUncertain',
      'undone',
      'undoConflict',
    ])
      'support_provider_$key': key.replaceAll('_', ' '),
    'support_provider_key_saved': 'Key saved ({})',
  };
}

void providerScreenTest(
  String name,
  Future<void> Function(WidgetTester, ProviderScreenFixture) body, {
  bool permissions = true,
}) {
  testWidgets(name, (tester) async {
    final f = ProviderScreenFixture(permissions: permissions);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, data) async {
      if (data == null) return f.block('empty native channel');
      // ONLY Flutter's already installed TEST text-input adapter may receive the
      // explicitly synthetic form/key values. No OS/clipboard/vault delegation.
      if (channel == SystemChannels.textInput.name &&
          tester.testTextInput.isRegistered &&
          handler != null) {
        return handler(data);
      }
      if (channel == SystemChannels.platform.name) {
        final call = SystemChannels.platform.codec.decodeMethodCall(data);
        final Object? reply = switch (call.method) {
          'Clipboard.hasStrings' => {'value': false},
          'LiveText.isLiveTextInputAvailable' => false,
          'HapticFeedback.vibrate' ||
          'SystemSound.play' ||
          'SystemChrome.setSystemUIOverlayStyle' ||
          'SystemChrome.setApplicationSwitcherDescription' => null,
          _ => f.block('platform ${call.method}'),
        };
        return SystemChannels.platform.codec.encodeSuccessEnvelope(reply);
      }
      if (channel == SystemChannels.processText.name) {
        final call = SystemChannels.processText.codec.decodeMethodCall(data);
        if (call.method != 'ProcessText.queryTextActions' ||
            call.arguments != null) {
          return f.block('process text');
        }
        return SystemChannels.processText.codec.encodeSuccessEnvelope(
          <String, Object?>{},
        );
      }
      if (channel == SystemChannels.accessibility.name) {
        final call = SystemChannels.accessibility.codec.decodeMessage(data);
        if (call case {
          'type': 'tap',
          'data': final Map<Object?, Object?> values,
          'nodeId': final int id,
        }) {
          if (values.isEmpty && id >= 0) {
            return SystemChannels.accessibility.codec.encodeMessage(null);
          }
        }
        return f.block('accessibility');
      }
      if (channel == SystemChannels.navigation.name) {
        final call = SystemChannels.navigation.codec.decodeMethodCall(data);
        if ((call.method == 'selectMultiEntryHistory' ||
                call.method == 'selectSingleEntryHistory') &&
            call.arguments == null) {
          return SystemChannels.navigation.codec.encodeSuccessEnvelope(null);
        }
        if (call.method == 'routeInformationUpdated') {
          final args = call.arguments;
          if (args is Map<Object?, Object?> &&
              args.length == 3 &&
              args['uri'] == '/' &&
              args.containsKey('state') &&
              args['replace'] is bool) {
            return SystemChannels.navigation.codec.encodeSuccessEnvelope(null);
          }
        }
        return f.block('navigation');
      }
      return f.block('native $channel');
    };
    Object? failure;
    StackTrace? trace;
    Future<void> capture(Future<void> Function() work) async {
      try {
        await work();
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }

    try {
      // Fake-zone builds/post-frame work inherit the SAME strict I/O guard as
      // the declared real SQLite jobs. No unguarded queue during teardown.
      await f.guarded(() async {
        await capture(() => body(tester, f));
        await capture(() => f.close(tester));
        if (messenger.pendingMessageCount != 0) {
          await capture(
            () => f.join(
              tester,
              () => messenger.platformMessagesFinished,
              label: 'framework metadata cleanup',
            ),
          );
        }
        await capture(() async => expect(f.attempts, isEmpty));
        await capture(() async => expect(tester.takeException(), isNull));
      });
    } finally {
      messenger.allMessagesHandler = previous;
    }
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  });
}
