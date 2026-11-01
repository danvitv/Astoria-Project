import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_source_text_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/preferences/saved_preferences_read_port.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_transport.dart';
import 'package:glaze_flutter/core/llm/transport/native_provider_transport.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_action_registry.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support_app_backup_loop_native.dart';

/// Scripted REAL native model/service dispatch with no widgets, picker or
/// confirmation callback. File/native handle, fake vault, real AEAD, exact POST
/// capture and IO/socket tripwires are the existing audited fixture's seams.
final class AutomaticSourcesFixture {
  final io = BackupLoopIo();
  final native = BackupLoopNative();
  final wire = <Map<String, dynamic>>[];
  final requests = <RequestOptions>[];
  final activity = <SupportModelToolActivity>[];
  void Function(SupportModelToolActivity)? onActivity;
  SupportModelInputIntent? retainedInput;
  late SupportModelService service;
  late FutureOr<Map<String, Object?>> Function(int round) script;
  Object? scriptError;
  StackTrace? scriptStack;
  int serial = 0;
  bool ready = false;

  Future<void> initialize({
    bool grant = true,
    Future<List<SupportAppActionAdapter>> Function()? nativeAdapters,
    Future<SavedPreferencesReadPort> Function()? preferencesFactory,
  }) async {
    _observerZone = Zone.current;
    SharedPreferences.setMockInitialValues({});
    await native.initialize(io);
    native.wireFactory = () => _Wire(this);
    await native.permissions.initializeGlobalFromNative(
      native.session,
      isCurrent: () => native.rootCurrent,
    );
    if (grant) {
      await native.permissions.setGrantFromNative(
        native.session,
        SupportPermission.readApplicationData,
        true,
        isCurrent: () => native.rootCurrent,
      );
    }
    await native.permissions.selectRecipientFromNative(
      native.session,
      null,
      isCurrent: () => native.rootCurrent,
    );
    await native.runtime.refresh(resolve: true);
    native.runtime.recipientConfirmed = false;
    final adapters =
        await nativeAdapters?.call() ?? const <SupportAppActionAdapter>[];
    final preferences = await preferencesFactory?.call();
    service = SupportModelService(
      db: native.db,
      writeCipher: native.cipher,
      apiRepo: native.apiRepo,
      revisions: native.revisions,
      redaction: native.redaction,
      runtime: native.runtime,
      isOwnerCurrent: () => native.rootCurrent,
      admissionContract:
          SupportTextAdmissionContract.auditedRootSingleConnectionNoBusyHandler,
      writes: SupportModelWriteQueue(),
      preferences: preferences,
      adapterFactory: () => _Wire(this),
      nativeSources: native.native.sources,
      nativeMetadata: native.native.credentialReader,
      nativeDispatcher: (inner) => NativeProviderPrivateTextDispatcher(
        credentials: native.native.credentials,
        authIssuer: native.native.auth,
        mutations: native.native.mutations,
        routes: native.native.routes,
        privateTextTransport: inner,
      ),
      toolTransport: NativeToolTransport(
        credentials: native.native.credentials,
        authIssuer: native.native.auth,
        mutations: native.native.mutations,
        routes: native.native.routes,
        currentRedactor: () => native.redaction.redactor,
        adapterFactory: () => _Wire(this),
      ),
      appActionsFactory: () => SupportAppActionRegistry(
        adapters: adapters,
        metadata: _Metadata(),
        isOriginalOwnerCurrent: () => native.rootCurrent,
      ),
      sourceRepo: SupportSourceTextRepo(
        db: native.db,
        cipher: native.cipher,
        currentRedactor: () => native.redaction.redactor,
      ),
      activeStudioPresetId: () async => 'automatic-studio',
      newId: () => 'automatic-${++serial}',
      onToolActivity: (_, _, a) {
        activity.add(a);
        onActivity?.call(a);
      },
    );
    ready = true;
  }

  Future<SupportModelSubmission> start({
    SupportModelToolUiPorts? toolUi,
  }) async {
    final visible = await native.repo.getMessagesForSession(native.session);
    final emitted = await service.emitInput(
      controller: Object(),
      uiLifetime: Object(),
      draftRevision: 1,
      text:
          'Read the newest named Marina session, another session and current Studio.',
      isEmitterCurrent: () => true,
      isDraftCurrent: () => true,
      visibleConversation: [
        for (final message in visible)
          if (const ['user', 'assistant'].contains(message.role))
            SupportModelConversationMessage(
              id: message.id,
              role: message.role,
              text: message.body,
            ),
      ],
      // Match production support_model_ui_submission, not the legacy preview
      // admission lane which independently requires a reviewed recipient.
      directConversation: true,
      toolUi: toolUi,
    );
    expect(emitted.intent, isNotNull, reason: emitted.reason.name);
    retainedInput = emitted.intent;
    return service.beginSend(emitted.intent!);
  }

  Map<String, dynamic> result(String id) {
    final messages = wire.last['messages'] as List;
    final tool = messages.lastWhere(
      (m) => m['role'] == 'tool' && m['tool_call_id'] == id,
    );
    return jsonDecode(tool['content'] as String) as Map<String, dynamic>;
  }

  // Existing support_model_source_loop_fixture pattern: the actual POST remains
  // in its original ROOT. Synthetic post-handoff DB observers must not retain
  // Drift's closed transaction zone. Keep the fixture's IO/socket guards intact.
  late final Zone _observerZone;

  Map<String, dynamic> body(String id) =>
      jsonDecode((result(id)['data'] as Map)['sourceText'] as String)
          as Map<String, dynamic>;

  Future<void> close() async {
    if (ready) service.dispose();
    await native.close();
    expect(io.attempts, isEmpty);
    if (scriptError != null)
      Error.throwWithStackTrace(scriptError!, scriptStack!);
  }

  static Map<String, Object?> calls(
    List<(String, String, Map<String, Object?>)> calls,
  ) => {
    'choices': [
      {
        'index': 0,
        'message': {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            for (final (id, name, args) in calls)
              {
                'id': id,
                'type': 'function',
                'function': {'name': name, 'arguments': jsonEncode(args)},
              },
          ],
        },
        'finish_reason': 'tool_calls',
      },
    ],
  };
  static Map<String, Object?> answer() => {
    'choices': [
      {
        'index': 0,
        'message': {
          'role': 'assistant',
          'content':
              'Read the requested saved evidence; it is not an assembled historical prompt.',
        },
        'finish_reason': 'stop',
      },
    ],
  };
}

final class _Metadata implements SupportAppMetadataPolicy {
  @override
  String? exactText(String value, {required int maxLength}) =>
      value.length <= maxLength ? value : null;
}

final class _Wire implements HttpClientAdapter {
  _Wire(this.f);
  final AutomaticSourcesFixture f;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (stream != null) {
      await for (final part in stream) {
        bytes.addAll(part);
      }
    }
    f.requests.add(options);
    f.wire.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    try {
      final response = await f._observerZone.run(() => f.script(f.wire.length));
      return ResponseBody.fromString(
        jsonEncode(response),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    } catch (error, stack) {
      f.scriptError = error;
      f.scriptStack = stack;
      rethrow;
    }
  }

  @override
  void close({bool force = false}) {}
}

Future<void> automaticSourcesTest(
  Future<void> Function(AutomaticSourcesFixture) body, {
  bool grant = true,
}) async {
  final f = AutomaticSourcesFixture();
  await HttpOverrides.runZoned(
    () => IOOverrides.runWithIOOverrides(() async {
      try {
        await f.initialize(grant: grant);
        await body(f);
      } finally {
        await f.close();
      }
    }, f.io),
    createHttpClient: (_) => f.io.block('HTTP/socket'),
  );
}
