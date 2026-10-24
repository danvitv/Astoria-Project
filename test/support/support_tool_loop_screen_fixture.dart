import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_message_display_projection.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_message_list.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_plain_markdown.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';

import 'helpers/support_model_provider_fixture_isolation.dart';
import 'support_tool_loop_fixture.dart';

void toolLoopWidgetTest(
  String name,
  Future<void> Function(WidgetTester, ToolLoopScreenFixture) body,
) {
  testWidgets(name, (tester) async {
    final isolation = ModelProviderIsolation();
    final messenger = tester.binding.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    // Mock locale readiness before opening the strictly declared UI graph.
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(EasyLocalization.ensureInitialized);
    messenger.allMessagesHandler = (channel, handler, message) async {
      if (message == null) return isolation.block('empty native channel');
      if (channel == SystemChannels.textInput.name &&
          tester.testTextInput.isRegistered &&
          handler != null) {
        return handler(
          message,
        ); // Only Flutter's explicitly installed test input.
      }
      if (channel == SystemChannels.platform.name) {
        final call = const JSONMethodCodec().decodeMethodCall(message);
        final result = switch (call.method) {
          'HapticFeedback.vibrate' ||
          'SystemSound.play' ||
          'SystemChrome.setSystemUIOverlayStyle' ||
          'SystemChrome.setApplicationSwitcherDescription' => null,
          'LiveText.isLiveTextInputAvailable' => false,
          'Clipboard.hasStrings' => {'value': false},
          _ => isolation.block('platform ${call.method}'),
        };
        return const JSONMethodCodec().encodeSuccessEnvelope(result);
      }
      if (channel == SystemChannels.processText.name) {
        final call = SystemChannels.processText.codec.decodeMethodCall(message);
        if (call.method == 'ProcessText.queryTextActions' &&
            call.arguments == null) {
          return SystemChannels.processText.codec.encodeSuccessEnvelope(
            <String, Object?>{},
          );
        }
        return isolation.block('process text');
      }
      if (channel == SystemChannels.accessibility.name) {
        final event = SystemChannels.accessibility.codec.decodeMessage(message);
        if (event case {
          'type': 'tap',
          'data': final Map<Object?, Object?> data,
          'nodeId': final int id,
        }) {
          if (data.isEmpty && id >= 0) {
            return SystemChannels.accessibility.codec.encodeMessage(null);
          }
        }
        return isolation.block('accessibility');
      }
      if (channel == SystemChannels.navigation.name) {
        final call = SystemChannels.navigation.codec.decodeMethodCall(message);
        final args = call.arguments;
        final accepted = switch (call.method) {
          'selectMultiEntryHistory' ||
          'selectSingleEntryHistory' => args == null,
          'routeInformationUpdated' =>
            args is Map<Object?, Object?> &&
                args.length == 3 &&
                args.containsKey('state') &&
                {
                  '/',
                  '/support',
                  '/characters',
                  '/tools/api',
                  '/menu/themes',
                  '/menu/settings',
                }.contains(args['uri']) &&
                args['replace'] is bool,
          _ => false,
        };
        if (accepted) {
          return SystemChannels.navigation.codec.encodeSuccessEnvelope(null);
        }
        return isolation.block('navigation metadata');
      }
      return isolation.block('native $channel');
    };
    ToolLoopScreenFixture? fixture;
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            try {
              final core = await _real(
                tester,
                () => ToolLoopFixture.create(isolation, screen: true),
              );
              fixture = ToolLoopScreenFixture(core);
              await tester.pumpWidget(fixture!.host());
              await tester.pumpAndSettle();
              await body(tester, fixture!);
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pump();
              final original = fixture;
              if (original != null) {
                await _real(tester, original.core.close);
                original.router.dispose();
              }
            }
          },
          createFile: (_) => isolation.block('file/default database'),
          createDirectory: (_) => isolation.block('directory'),
          createLink: (_) => isolation.block('link'),
          socketConnect:
              (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
                  isolation.block('socket.connect'),
          socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) =>
              isolation.block('socket.startConnect'),
        ),
        createHttpClient: (_) => isolation.block('HTTP/socket'),
      );
    } finally {
      await messenger.platformMessagesFinished;
      messenger.allMessagesHandler = previous;
      expect(isolation.attempts, isEmpty);
      expect(tester.takeException(), isNull);
    }
  });
}

Future<T> _real<T>(WidgetTester tester, Future<T> Function() action) async {
  late T value;
  Object? failure;
  StackTrace? stack;
  await tester.runAsync(() async {
    try {
      value = await action();
    } catch (error, trace) {
      failure = error;
      stack = trace;
    }
  });
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
  return value;
}

final class ToolLoopScreenFixture {
  ToolLoopScreenFixture(this.core) {
    router = GoRouter(
      initialLocation: '/support',
      routes: [
        GoRoute(
          path: '/support',
          builder: (context, state) => const SupportAssistantScreen(
            welcomeAvatar: Icon(Icons.support_agent_rounded),
          ),
        ),
        for (final path in [
          '/characters',
          '/tools/api',
          '/menu/themes',
          '/menu/settings',
        ])
          GoRoute(path: path, builder: (_, _) => const SizedBox.shrink()),
      ],
    );
  }
  final ToolLoopFixture core;
  late final GoRouter router;

  Widget host() => UncontrolledProviderScope(
    container: core.container,
    child: EasyLocalization(
      supportedLocales: const [Locale('ru')],
      startLocale: const Locale('ru'),
      saveLocale: false,
      path: 'synthetic-no-assets',
      assetLoader: const _ToolLoopTranslations(),
      child: Builder(
        builder: (context) => MaterialApp.router(
          routerConfig: router,
          locale: context.locale,
          supportedLocales: context.supportedLocales,
          localizationsDelegates: context.localizationDelegates,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff506080),
            ),
          ),
          builder: (context, child) => FlatBackdrop(
            color: Theme.of(context).colorScheme.surface,
            child: child!,
          ),
        ),
      ),
    ),
  );

  /// Bounded join of ORIGINAL signals. The fake clock never fabricates an answer.
  Future<T> join<T>(WidgetTester tester, Future<T> original) async {
    var done = false;
    late T value;
    Object? failure;
    StackTrace? stack;
    unawaited(
      original.then<void>(
        (v) {
          value = v;
          done = true;
        },
        onError: (Object error, StackTrace trace) {
          failure = error;
          stack = trace;
          done = true;
        },
      ),
    );
    for (var turn = 0; turn < 1024 && !done; turn++) {
      await tester.pump();
      await _real(tester, () => Future<void>.delayed(Duration.zero));
    }
    if (!done) {
      throw StateError(
        'Original model/UI signal exceeded fixture turn budget.',
      );
    }
    if (failure != null) Error.throwWithStackTrace(failure!, stack!);
    return value;
  }

  Future<void> terminal(WidgetTester tester) {
    final signal = Completer<void>();
    void observe() {
      if (!core.bridge.view.busy &&
          core.bridge.view.saved &&
          !signal.isCompleted) {
        signal.complete();
      }
    }

    final stop = core.bridge.listen(observe);
    observe();
    return join(tester, signal.future).whenComplete(stop);
  }

  /// Reveal the original lazy feed row, then inspect its ACTUAL selectable span.
  /// No replacement text widget or pure-codec-only display assertion.
  Future<void> revealReply(WidgetTester tester, String expected) async {
    final projected = SupportMessageDisplayProjection(
      redactor: core.native.redaction.redactor,
    ).project(expected);
    final feed = find.byType(SupportMessageList);
    final markdown = find.descendant(
      of: feed,
      matching: find.byWidgetPredicate(
        (widget) => widget is SupportPlainMarkdown && widget.text == projected,
      ),
    );
    await tester.scrollUntilVisible(
      markdown,
      200,
      scrollable: find
          .descendant(of: feed, matching: find.byType(Scrollable))
          .first,
      maxScrolls: 12,
    );
    await tester.pumpAndSettle();
    expect(markdown, findsOneWidget);
    final selectable = find.descendant(
      of: markdown,
      matching: find.byType(SelectableText),
    );
    expect(selectable, findsOneWidget);
    expect(
      tester.widget<SelectableText>(selectable).textSpan?.toPlainText(),
      projected,
    );
    expect(selectable.hitTestable(), findsOneWidget);
    expect(tester.getRect(selectable).overlaps(tester.getRect(feed)), isTrue);
  }

  /// Finish the original entrance animation before checking/tapping its footer.
  /// Keep the real 800x600 viewport; missed gestures are not suppressed.
  Future<void> confirmationReady(WidgetTester tester) async {
    await tester.pumpAndSettle();
    final viewport =
        Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
    for (final name in ['cancel', 'accept']) {
      final button = find.byKey(ValueKey('support_tool_confirmation_$name'));
      expect(button, findsOneWidget);
      expect(button.hitTestable(), findsOneWidget);
      final bounds = tester.getRect(button);
      expect(viewport.contains(bounds.topLeft), isTrue);
      expect(viewport.contains(bounds.bottomRight), isTrue);
    }
    final preview = find.byKey(
      const ValueKey('support_tool_confirmation_preview'),
    );
    expect(preview, findsOneWidget);
    expect(
      find.descendant(
        of: preview,
        matching: find.byKey(
          const ValueKey('support_tool_confirmation_accept'),
        ),
      ),
      findsNothing,
    );
  }
}

final class _ToolLoopTranslations extends AssetLoader {
  const _ToolLoopTranslations();
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      const {};
}
