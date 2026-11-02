import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/image_routmy_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/image_openrouter_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/image_novelai_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/image_naistera_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/info_blocks_repository.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/image_recovery_service.dart';
import 'package:glaze_flutter/features/chat/services/image_gen_processor.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_service.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_http.dart';
import 'package:glaze_flutter/features/image_gen/services/naistera_image_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/image_tag_markup.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_modes.dart';
import 'package:glaze_flutter/features/extensions/models/block_run_status.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extensions_settings_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/info_blocks_provider.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/block_context.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/block_image_renderer.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/block_panel_updater.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/generated_block_handler.dart';
import 'package:glaze_flutter/features/extensions/services/extension_post_gen_service.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'credentials/fake_credential_storage.dart';

class _NativeNaisteraAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '{"data_url":"data:image/png;base64,AQI="}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

// Only the final provider outcome is scripted. The processor, original native
// credential owner and ChatRepo transaction/read/write queue are real.
class _CompletedImageService extends ImageGenService {
  _CompletedImageService(this.outcome)
    : super(ImageStorageService('synthetic-unused'));
  final String outcome;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<String> processMessageImages({
    required String text,
    required ImageGenSettings settings,
    required String llmEndpoint,
    required String llmApiKey,
    required String llmModel,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
    CancelToken? cancelToken,
    void Function(String updatedText)? onUpdate,
    void Function(String error)? onError,
    void Function()? onPublicationDenied,
  }) async {
    entered.complete();
    await release.future;
    return outcome;
  }
}

class _ImageSettingsWithOutcome extends ImageGenSettingsNotifier {
  _ImageSettingsWithOutcome(
    this.service, {
    this.apiType = ImageGenApiType.routmy,
    this.enabled = true,
  });
  final ImageGenService service;
  final ImageGenApiType apiType;
  final bool enabled;
  @override
  Future<ImageGenSettings> build() async =>
      ImageGenSettings(enabled: enabled, apiType: apiType);
  @override
  Future<ImageGenService> getServiceAsync() async => service;
}

// The second native error settles while the first instruction is still pending.
// Only provider results are scripted: no model, HTTP or image file is invoked.
class _SettledNativeErrorService extends ImageGenService {
  _SettledNativeErrorService(this.owner, this.detail)
    : openRouterOwner = null,
      novelAiOwner = null,
      naisteraOwner = null,
      super(ImageStorageService('synthetic-unused'), routmyCredentials: owner);

  _SettledNativeErrorService.openRouter(this.openRouterOwner)
    : owner = null,
      novelAiOwner = null,
      naisteraOwner = null,
      detail = 'Synthetic image failure',
      super(
        ImageStorageService('synthetic-unused'),
        openrouterCredentials: openRouterOwner,
      );

  _SettledNativeErrorService.novelAi(
    this.novelAiOwner, [
    this.detail = 'Synthetic image failure',
  ]) : owner = null,
       openRouterOwner = null,
       naisteraOwner = null,
       super(
         ImageStorageService('synthetic-unused'),
         novelaiCredentials: novelAiOwner,
       );

  _SettledNativeErrorService.naistera(
    this.naisteraOwner, [
    this.detail = 'Synthetic image failure',
  ]) : owner = null,
       openRouterOwner = null,
       novelAiOwner = null,
       super(
         ImageStorageService('synthetic-unused'),
         naisteraCredentials: naisteraOwner,
       );

  final ImageRoutmyCredentialOwner? owner;
  final ImageOpenRouterCredentialOwner? openRouterOwner;
  final ImageNovelAiCredentialOwner? novelAiOwner;
  final ImageNaisteraCredentialOwner? naisteraOwner;
  final String detail;
  final secondSettled = Completer<void>();
  final releaseFirst = Completer<void>();
  int publicationDenials = 0;
  int generationCalls = 0;
  int progressCalls = 0;

  @override
  Future<String> processMessageImages({
    required String text,
    required ImageGenSettings settings,
    required String llmEndpoint,
    required String llmApiKey,
    required String llmModel,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
    CancelToken? cancelToken,
    void Function(String updatedText)? onUpdate,
    void Function(String error)? onError,
    void Function()? onPublicationDenied,
  }) => super.processMessageImages(
    text: text,
    settings: settings,
    llmEndpoint: llmEndpoint,
    llmApiKey: llmApiKey,
    llmModel: llmModel,
    character: character,
    persona: persona,
    recentImageContexts: recentImageContexts,
    cancelToken: cancelToken,
    onUpdate: (text) {
      progressCalls++;
      onUpdate?.call(text);
    },
    onError: onError,
    onPublicationDenied: () {
      publicationDenials++;
      onPublicationDenied?.call();
    },
  );

  @override
  Future<Uint8List> generateImage({
    required ImageGenSettings settings,
    required String prompt,
    required String llmEndpoint,
    required String llmApiKey,
    required String llmModel,
    String? tagStyle,
    Character? character,
    Persona? persona,
    List<String>? recentImageContexts,
    String? instructionAspectRatio,
    String? instructionImageSize,
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
  }) async {
    generationCalls++;
    if (openRouterOwner != null ||
        novelAiOwner != null ||
        naisteraOwner != null) {
      if (!secondSettled.isCompleted) secondSettled.complete();
      await releaseFirst.future;
      throw StateError(detail);
    }
    if (prompt == 'first') {
      await releaseFirst.future;
      return Uint8List(0);
    }
    try {
      return await owner!.withApiKey<Uint8List>(
        origin: 'https://api.rout.my',
        consume: (key, checkCurrent) async {
          checkCurrent();
          throw StateError('HTTP 400 $key $detail');
        },
      );
    } catch (_) {
      secondSettled.complete();
      rethrow;
    }
  }
}

// Gate the return of an actual committed repository mutation, not a fake row.
class _CommittedImageRepo extends ChatRepo {
  _CommittedImageRepo(AppDatabase db) : super(db);
  final mutationEntered = Completer<void>();
  final committed = Completer<void>();
  final release = Completer<void>();

  @override
  Future<ChatSession?> mutateMessage({
    required String sessionId,
    required String messageId,
    required ChatMessage? Function(ChatMessage) mutate,
    required int updatedAt,
  }) async {
    if (!mutationEntered.isCompleted) mutationEntered.complete();
    final durable = await super.mutateMessage(
      sessionId: sessionId,
      messageId: messageId,
      mutate: mutate,
      updatedAt: updatedAt,
    );
    committed.complete();
    await release.future;
    return durable;
  }
}

// Observe the existing native block completion, never replace its write/read.
class _ObservedImageBlockRepo extends InfoBlocksRepository {
  _ObservedImageBlockRepo(AppDatabase db, {this.holdReturn = false})
    : super(db);
  final bool holdReturn;
  int completionCalls = 0;
  final completionEntered = Completer<void>();
  final committed = Completer<void>();
  final release = Completer<void>();

  @override
  Future<InfoBlock?> completeImageRender({
    required InfoBlock target,
    required String content,
    required bool Function(String) isPublishable,
  }) async {
    completionCalls++;
    if (!completionEntered.isCompleted) completionEntered.complete();
    final durable = await super.completeImageRender(
      target: target,
      content: content,
      isPublishable: isPublishable,
    );
    if (holdReturn && durable != null) {
      committed.complete();
      await release.future;
    }
    return durable;
  }
}

class _ImageBlockChat extends ChatNotifier {
  _ImageBlockChat(this.session) : super(session.characterId);
  final ChatSession session;
  @override
  Future<ChatState> build() async => ChatState(session: session);
}

class _ImageBlockApis extends ApiListNotifier {
  @override
  Future<List<ApiConfig>> build() async => const [
    ApiConfig(
      id: 'synthetic-api',
      endpoint: 'https://unused.invalid',
      apiKey: '',
      model: 'synthetic',
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ChatSession session(String id, String content) => ChatSession(
    id: id,
    characterId: 'character',
    sessionIndex: 0,
    messages: [
      ChatMessage(id: 'assistant', role: 'assistant', content: content),
    ],
  );

  group('ImageGenProcessor owned state merging', () {
    test('merges a current image update onto live chat state', () {
      final originalSession = session('session-1', '[IMG:GEN]');
      final liveState = ChatState(
        session: originalSession.copyWith(
          messages: [
            ...originalSession.messages,
            const ChatMessage(id: 'tail', role: 'user', content: 'new tail'),
          ],
          draft: 'new draft',
          sessionVars: const {'concurrent': 'keep'},
        ),
        isGenerating: true,
        isGeneratingImage: true,
        isPostGenRunning: true,
        error: 'unrelated live state',
        visibleStartIndex: 4,
      );
      final imageUpdate = ChatState(
        session: session('session-1', '[IMG:RESULT:/images/result.png]'),
        isGeneratingImage: false,
      );

      final merged = ImageGenProcessor.mergeOwnedStateUpdate(
        liveState: liveState,
        update: imageUpdate,
        sessionId: 'session-1',
        targetMessageId: 'assistant',
        ownsOperation: true,
      );

      expect(merged, isNotNull);
      expect(merged!.messages.first.content, '[IMG:RESULT:/images/result.png]');
      expect(merged.messages.last.id, 'tail');
      expect(merged.session?.draft, 'new draft');
      expect(merged.session?.sessionVars, {'concurrent': 'keep'});
      expect(merged.isGenerating, isTrue);
      expect(merged.isPostGenRunning, isTrue);
      expect(merged.error, 'unrelated live state');
      expect(merged.visibleStartIndex, 4);
      expect(merged.isGeneratingImage, isFalse);
    });

    test('drops late callbacks after stop or replacement generation', () {
      final liveState = ChatState(
        session: session('session-1', '[IMG:GEN]'),
        isGeneratingImage: false,
      );
      final staleUpdate = ChatState(
        session: session('session-1', '[IMG:RESULT:/images/stale.png]'),
        isGeneratingImage: false,
      );

      final merged = ImageGenProcessor.mergeOwnedStateUpdate(
        liveState: liveState,
        update: staleUpdate,
        sessionId: 'session-1',
        targetMessageId: 'assistant',
        ownsOperation: false,
      );

      expect(merged, isNull);
      expect(liveState.messages.single.content, '[IMG:GEN]');
      expect(liveState.isGeneratingImage, isFalse);
    });

    test('drops an owned callback when the live session changed', () {
      final liveState = ChatState(
        session: session('new-session', 'new generation'),
        isGenerating: true,
      );
      final staleUpdate = ChatState(
        session: session('old-session', '[IMG:RESULT:/images/old.png]'),
        isGeneratingImage: false,
      );

      final merged = ImageGenProcessor.mergeOwnedStateUpdate(
        liveState: liveState,
        update: staleUpdate,
        sessionId: 'old-session',
        targetMessageId: 'assistant',
        ownsOperation: true,
      );

      expect(merged, isNull);
      expect(liveState.messages.single.content, 'new generation');
      expect(liveState.isGenerating, isTrue);
    });
  });

  for (final imageType in [
    ImageGenApiType.routmy,
    ImageGenApiType.openrouter,
    ImageGenApiType.novelai,
    ImageGenApiType.naistera,
  ]) {
    for (final outcome in [
      '[IMG:RESULT:generated/synthetic-retired.png]',
      '[IMG:ERROR:{"error":"synthetic retired error"}]',
    ]) {
      test(
        '${imageType.name} native rotation while actual message callback is queued drops $outcome and cache publication',
        () async {
          SharedPreferences.setMockInitialValues({
            'gz_imggen_settings': jsonEncode({
              'apiType': 'routmy',
              'routmyMirror': 'global',
            }),
          });
          final prefs = await TrackedSharedPreferences.getInstance();
          final storage = FakeCredentialStorage();
          final vault = CredentialVault(storage: storage, buildChannel: 'dev');
          final redaction = SecretRedactionCoordinator();
          final owner = ImageRoutmyCredentialOwner(
            vault: vault,
            redaction: redaction,
            originalPreferences: Future.value(prefs),
          );
          await owner.setApiKey('SYNTHETIC_ORIGINAL_IMAGE_KEY');
          final openRouterOwner = ImageOpenRouterCredentialOwner(
            vault: vault,
            redaction: redaction,
            originalPreferences: Future.value(prefs),
          );
          await openRouterOwner.setApiKey(
            'SYNTHETIC_ORIGINAL_OR_IMAGE_KEY',
            endpoint: '',
          );
          final novelAiOwner = ImageNovelAiCredentialOwner(
            vault: vault,
            redaction: redaction,
            originalPreferences: Future.value(prefs),
          );
          await novelAiOwner.setApiKey(
            'SYNTHETIC_ORIGINAL_NAI_IMAGE_KEY',
            endpoint: '',
            model: '',
          );
          final naisteraOwner = ImageNaisteraCredentialOwner(
            vault: vault,
            redaction: redaction,
            originalPreferences: Future.value(prefs),
          );
          await naisteraOwner.setApiKey(
            'SYNTHETIC_ORIGINAL_NAISTERA_IMAGE_KEY',
          );
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          final service = _CompletedImageService(outcome);
          const original = ChatSession(
            id: 'synthetic-image-session',
            characterId: 'synthetic-character',
            sessionIndex: 0,
            messages: [
              ChatMessage(
                id: 'assistant',
                role: 'assistant',
                content: '[IMG:GEN:{"prompt":"synthetic"}]',
              ),
            ],
          );
          final updates = <ChatState>[];
          final process = Provider<Future<void>>(
            (ref) => ImageGenProcessor(
              ref: ref,
              charId: original.characterId,
              isCurrentOperation: () => true,
              onStateUpdate: updates.add,
            ).process(const ChatState(session: original)),
          );
          final container = ProviderContainer(
            overrides: [
              appDbProvider.overrideWithValue(db),
              sharedPreferencesProvider.overrideWith((ref) async => prefs),
              credentialVaultProvider.overrideWithValue(vault),
              secretRedactionCoordinatorProvider.overrideWithValue(redaction),
              imageRoutmyCredentialOwnerProvider.overrideWithValue(owner),
              imageOpenRouterCredentialOwnerProvider.overrideWithValue(
                openRouterOwner,
              ),
              imageNovelAiCredentialOwnerProvider.overrideWithValue(
                novelAiOwner,
              ),
              imageNaisteraCredentialOwnerProvider.overrideWithValue(
                naisteraOwner,
              ),
              imageGenSettingsProvider.overrideWith(
                () => _ImageSettingsWithOutcome(service, apiType: imageType),
              ),
              activeApiConfigProvider.overrideWithValue(
                const ApiConfig(
                  id: 'synthetic-api',
                  endpoint: 'https://unused.invalid',
                  apiKey: '',
                  model: 'synthetic-model',
                ),
              ),
            ],
          );
          final transactionEntered = Completer<void>();
          final releaseTransaction = Completer<void>();
          addTearDown(() async {
            if (!service.release.isCompleted) service.release.complete();
            if (!releaseTransaction.isCompleted) releaseTransaction.complete();
            container.dispose();
            owner.dispose();
            openRouterOwner.dispose();
            novelAiOwner.dispose();
            naisteraOwner.dispose();
            redaction.dispose();
            ChatSessionService.clearCache();
            await db.close();
          });
          ChatSessionService.clearCache();
          final repo = container.read(chatRepoProvider);
          await repo.put(original);
          await container.read(imageGenSettingsProvider.future);
          final pending = container.read(process);
          await service.entered.future;
          // Park the original DB queue only after preparation has completed, so
          // the next queued transaction is the processor's final mutateMessage.
          final blocked = db.transaction(() async {
            transactionEntered.complete();
            await releaseTransaction.future;
          });
          await transactionEntered.future;
          service.release.complete();
          await Future<void>.delayed(Duration.zero);
          expect(ChatSessionService.cacheSize, 0);
          final publishedBeforeRotation = updates.length;
          if (imageType == ImageGenApiType.openrouter) {
            await openRouterOwner.setApiKey(
              'SYNTHETIC_REPLACEMENT_OR_IMAGE_KEY',
              endpoint: '',
            );
          } else if (imageType == ImageGenApiType.novelai) {
            await novelAiOwner.setApiKey(
              'SYNTHETIC_REPLACEMENT_NAI_IMAGE_KEY',
              endpoint: '',
              model: '',
            );
          } else if (imageType == ImageGenApiType.naistera) {
            await naisteraOwner.setApiKey(
              'SYNTHETIC_REPLACEMENT_NAISTERA_IMAGE_KEY',
            );
          } else {
            await owner.setApiKey('SYNTHETIC_REPLACEMENT_IMAGE_KEY');
          }
          releaseTransaction.complete();
          await blocked;
          await pending;
          expect(
            (await repo.getById(original.id))!.messages.single.content,
            original.messages.single.content,
          );
          expect(ChatSessionService.cacheSize, 0);
          expect(
            updates
                .skip(publishedBeforeRotation)
                .every(
                  (update) => update.messages.every(
                    (message) => message.content != outcome,
                  ),
                ),
            isTrue,
          );
          expect(updates.last.isGeneratingImage, isFalse);
        },
      );
    }
  }

  group('image errors use the actual downstream sink', () {
    late SharedPreferences prefs;
    late CredentialVault vault;
    late SecretRedactionCoordinator originalRedaction;
    late SecretRedactionCoordinator currentRedaction;
    late ImageRoutmyCredentialOwner owner;
    late ImageOpenRouterCredentialOwner openRouterOwner;
    late ImageNovelAiCredentialOwner novelAiOwner;
    late ImageNaisteraCredentialOwner naisteraOwner;
    const nativeKey = 'SYNTHETIC_ORIGINAL_IMAGE_KEY';
    const lateAlias = 'SYNTHETIC LATE+ALIAS/SECRET';

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'gz_imggen_settings': jsonEncode({
          'apiType': 'routmy',
          'routmyMirror': 'global',
        }),
      });
      prefs = await TrackedSharedPreferences.getInstance();
      vault = CredentialVault(
        storage: FakeCredentialStorage(),
        buildChannel: 'dev',
      );
      originalRedaction = SecretRedactionCoordinator();
      currentRedaction = SecretRedactionCoordinator();
      final previousSink = activeErrorRedactor;
      activeErrorRedactor = originalRedaction.redactor;
      owner = ImageRoutmyCredentialOwner(
        vault: vault,
        redaction: originalRedaction,
        originalPreferences: Future.value(prefs),
      );
      await owner.setApiKey(nativeKey);
      openRouterOwner = ImageOpenRouterCredentialOwner(
        vault: vault,
        redaction: originalRedaction,
        originalPreferences: Future.value(prefs),
      );
      await openRouterOwner.setApiKey(nativeKey, endpoint: '');
      novelAiOwner = ImageNovelAiCredentialOwner(
        vault: vault,
        redaction: originalRedaction,
        originalPreferences: Future.value(prefs),
      );
      await novelAiOwner.setApiKey(nativeKey, endpoint: '', model: '');
      naisteraOwner = ImageNaisteraCredentialOwner(
        vault: vault,
        redaction: originalRedaction,
        originalPreferences: Future.value(prefs),
      );
      await naisteraOwner.setApiKey(nativeKey);
      addTearDown(() {
        activeErrorRedactor = previousSink;
        owner.dispose();
        openRouterOwner.dispose();
        novelAiOwner.dispose();
        naisteraOwner.dispose();
        originalRedaction.dispose();
        currentRedaction.dispose();
        ChatSessionService.clearCache();
      });
    });

    void activateCurrent(String alias) {
      currentRedaction.registerSecret(alias);
      activeErrorRedactor = currentRedaction.redactor;
    }

    _SettledNativeErrorService settledFor(
      ImageGenApiType type, [
      String detail = 'Synthetic image failure',
    ]) => type == ImageGenApiType.naistera
        ? _SettledNativeErrorService.naistera(naisteraOwner, detail)
        : _SettledNativeErrorService.novelAi(novelAiOwner, detail);

    for (final input in [
      'raw prompt',
      'assembled prompt',
      'actual request body',
      'public control',
    ]) {
      test(
        'Naistera real generateImage retains bare sink A before collect await ($input)',
        () async {
          const quoteAlias = 'SYNTHETIC_PRIVATE"VALUE';
          const assembledAlias = '[STYLE: public style]\n\npublic cat';
          const requestBodyAlias =
              '{"prompt":"public cat","aspect_ratio":"1:1","model":"grok"}';
          final adapter = _NativeNaisteraAdapter();
          final dio = Dio()..httpClientAdapter = adapter;
          addTearDown(() => dio.close());
          var clientCalls = 0;
          final service = ImageGenService(
            ImageStorageService('synthetic-unused'),
            naisteraCredentials: naisteraOwner,
            naisteraClientFactory: (base, check, public) {
              clientCalls++;
              return NaisteraImageProvider(
                baseUrl: base,
                checkCurrent: check,
                isPublicValue: public,
                http: ImageGenHttp(dio: dio),
                assetHttp: ImageGenHttp(dio: dio),
              );
            },
          );
          final ownsNative = naisteraOwner.captureGuard();
          // The owner uses another, still-current coordinator. Only bare A knows
          // the private value; replacing the global sink must not adopt clean B.
          activeErrorRedactor = SecretRedactor(
            knownSecrets: [
              if (input == 'raw prompt') quoteAlias,
              if (input == 'assembled prompt') assembledAlias,
              if (input == 'actual request body') requestBodyAlias,
            ],
          );
          final pending = service.generateImage(
            settings: const ImageGenSettings(
              apiType: ImageGenApiType.naistera,
              naisteraModel: 'grok',
              sendCharAvatar: false,
              sendUserAvatar: false,
              imageContextEnabled: false,
            ),
            prompt: input == 'raw prompt'
                ? jsonEncode({'label': quoteAlias})
                : 'public cat',
            tagStyle: input == 'assembled prompt' ? 'public style' : null,
            llmEndpoint: '',
            llmApiKey: '',
            llmModel: '',
          );
          // Attach the observer before any await, including immediate admission
          // denial, then switch while collect's async completion is suspended.
          final observed = input == 'public control'
              ? expectLater(pending, completion(equals([1, 2])))
              : expectLater(pending, throwsA(isA<StateError>()));
          activeErrorRedactor = SecretRedactor();
          await observed;
          expect(ownsNative(), isTrue);
          expect(
            adapter.requests,
            hasLength(input == 'public control' ? 1 : 0),
          );
          expect(
            clientCalls,
            input == 'public control' || input == 'actual request body' ? 1 : 0,
          );
        },
      );
    }

    for (final originalPolicy in [true, false]) {
      test(
        'Naistera raw JSON metadata keys/leaves use ORIGINAL+CURRENT before whole encoding (original=$originalPolicy)',
        () {
          const alias = 'SYNTHETIC_PRIVATE"METADATA';
          final carried = jsonEncode({'label': alias});
          activeErrorRedactor = originalPolicy
              ? SecretRedactor(knownSecrets: const [alias])
              : SecretRedactor();
          final errors = ImageGenErrorSanitizer(
            naisteraCredentials: naisteraOwner,
            checkNaisteraResults: () => true,
          );
          activeErrorRedactor = originalPolicy
              ? SecretRedactor()
              : SecretRedactor(knownSecrets: const [alias]);
          for (final metadata in [
            {'futurePrivateMetadata': carried, 'preserveUnknown': 'keep'},
            {carried: 'public', 'preserveUnknown': 'keep'},
          ]) {
            final message = <String, dynamic>{
              'id': 'assistant',
              'role': 'assistant',
              'content': 'keep prose',
              'swipesMeta': [metadata],
            };
            final before = jsonEncode(message);
            expect(errors.storedMessageIsCurrent(message), isFalse);
            final projected = errors.displayStoredMessage(message);
            expect(jsonEncode(projected), isNot(contains('SYNTHETIC_PRIVATE')));
            expect(
              (projected['swipesMeta'] as List).single['preserveUnknown'],
              'keep',
            );
            expect(jsonEncode(message), before);
          }
          final cycle = <String, dynamic>{
            'id': 'assistant',
            'role': 'assistant',
          };
          cycle['future'] = cycle;
          expect(errors.storedMessageIsCurrent(cycle), isFalse);
          expect(errors.displayStoredMessage(cycle), {
            'id': 'assistant',
            'role': 'assistant',
            'content': '',
          });
        },
      );
    }

    for (final originalPolicy in [true, false])
      test(
        'Naistera whole stored raw JSON metadata disabled denial is ephemeral, not a DB/cache replacement (original=$originalPolicy)',
        () async {
          const alias = 'SYNTHETIC_NAISTERA_STORED_PRIVATE"METADATA';
          final carried = jsonEncode({'label': alias});
          const text = 'Keep prose. [IMG:GEN:{"prompt":"new"}]';
          final original = session('synthetic-naistera-stored-meta', text)
              .copyWith(
                messages: [
                  ChatMessage(
                    id: 'assistant',
                    role: 'assistant',
                    content: text,
                    swipes: [text],
                    agentSwipes: [AgentSwipe(content: text)],
                    triggeredLorebooks: const [
                      TriggeredEntry(
                        id: 'public-lore',
                        name: 'Keep lore',
                        pattern: '100% public',
                      ),
                    ],
                    triggeredMemories: const [
                      TriggeredEntry(id: 'public-memory', name: 'Keep memory'),
                    ],
                    swipesMeta: [
                      {
                        'futurePrivateMetadata': carried,
                        'preserveUnknown': 'keep',
                        'agentSwipes': [
                          {
                            'content': text,
                            'kind': 'final',
                            'futurePrivateMetadata': carried,
                          },
                        ],
                      },
                    ],
                  ),
                ],
              );
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          final service = settledFor(ImageGenApiType.naistera);
          final updates = <ChatState>[];
          final process = Provider<Future<void>>(
            (ref) => ImageGenProcessor(
              ref: ref,
              charId: original.characterId,
              isCurrentOperation: () => true,
              onStateUpdate: updates.add,
            ).process(ChatState(session: original)),
          );
          final container = ProviderContainer(
            overrides: [
              appDbProvider.overrideWithValue(db),
              sharedPreferencesProvider.overrideWith((ref) async => prefs),
              credentialVaultProvider.overrideWithValue(vault),
              secretRedactionCoordinatorProvider.overrideWithValue(
                originalRedaction,
              ),
              imageNaisteraCredentialOwnerProvider.overrideWithValue(
                naisteraOwner,
              ),
              imageGenSettingsProvider.overrideWith(
                () => _ImageSettingsWithOutcome(
                  service,
                  apiType: ImageGenApiType.naistera,
                  enabled: false,
                ),
              ),
            ],
          );
          addTearDown(() async {
            container.dispose();
            await db.close();
          });
          final repo = container.read(chatRepoProvider);
          await repo.put(original);
          final raw = jsonEncode((await repo.getById(original.id))!.toJson());
          await container.read(imageGenSettingsProvider.future);
          activeErrorRedactor = originalPolicy
              ? SecretRedactor(knownSecrets: const [alias])
              : SecretRedactor();
          final pending = container.read(process);
          // errors captures the ORIGINAL sink before the settings await resumes.
          activeErrorRedactor = originalPolicy
              ? SecretRedactor()
              : SecretRedactor(knownSecrets: const [alias]);
          await pending;
          expect(jsonEncode((await repo.getById(original.id))!.toJson()), raw);
          expect(ChatSessionService.cacheSize, 0);
          expect(service.generationCalls, 0);
          expect(updates, isNotEmpty);
          expect(
            updates.every(
              (update) => !jsonEncode(
                update.session!.toJson(),
              ).contains('SYNTHETIC_NAISTERA_STORED_PRIVATE'),
            ),
            isTrue,
          );
          expect(updates.last.messages.single.id, 'assistant');
          expect(updates.last.messages.single.content, contains('Keep prose.'));
          expect(
            updates.last.messages.single.agentSwipes.single.content,
            contains('Keep prose.'),
          );
          expect(
            updates.last.messages.single.triggeredLorebooks.single.name,
            'Keep lore',
          );
          expect(
            updates.last.messages.single.triggeredMemories.single.name,
            'Keep memory',
          );
          expect(
            updates.last.messages.single.swipesMeta.single['preserveUnknown'],
            'keep',
          );
          expect(updates.last.isGeneratingImage, isFalse);
        },
      );

    for (final privateMember in ['public control', 'lorebook', 'memory']) {
      test(
        'Naistera admits known typed message members without serializing arbitrary metadata ($privateMember)',
        () async {
          const alias = 'SYNTHETIC_TYPED_PRIVATE"MEMBER';
          const text = 'Keep prose. [IMG:GEN:{"prompt":"new"}]';
          final original = session('synthetic-naistera-typed', text).copyWith(
            messages: [
              ChatMessage(
                id: 'assistant',
                role: 'assistant',
                content: text,
                swipes: [text],
                agentSwipes: [const AgentSwipe(content: text)],
                triggeredLorebooks: [
                  TriggeredEntry(
                    id: 'public-lore',
                    name: privateMember == 'lorebook' ? alias : 'Keep lore',
                  ),
                ],
                triggeredMemories: [
                  TriggeredEntry(
                    id: 'public-memory',
                    name: privateMember == 'memory' ? alias : 'Keep memory',
                  ),
                ],
                swipesMeta: [
                  {
                    'preserveUnknown': 'keep',
                    'nested': {'public': 'keep'},
                  },
                ],
              ),
            ],
          );
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          final service = settledFor(ImageGenApiType.naistera);
          final updates = <ChatState>[];
          final process = Provider<Future<void>>(
            (ref) => ImageGenProcessor(
              ref: ref,
              charId: original.characterId,
              isCurrentOperation: () => true,
              onStateUpdate: updates.add,
            ).process(ChatState(session: original)),
          );
          final container = ProviderContainer(
            overrides: [
              appDbProvider.overrideWithValue(db),
              sharedPreferencesProvider.overrideWith((ref) async => prefs),
              credentialVaultProvider.overrideWithValue(vault),
              secretRedactionCoordinatorProvider.overrideWithValue(
                originalRedaction,
              ),
              imageNaisteraCredentialOwnerProvider.overrideWithValue(
                naisteraOwner,
              ),
              imageGenSettingsProvider.overrideWith(
                () => _ImageSettingsWithOutcome(
                  service,
                  apiType: ImageGenApiType.naistera,
                  enabled: false,
                ),
              ),
            ],
          );
          addTearDown(() async {
            container.dispose();
            await db.close();
          });
          final repo = container.read(chatRepoProvider);
          await repo.put(original);
          final raw = jsonEncode((await repo.getById(original.id))!.toJson());
          await container.read(imageGenSettingsProvider.future);
          activeErrorRedactor = SecretRedactor(knownSecrets: const [alias]);
          final pending = container.read(process);
          activeErrorRedactor =
              SecretRedactor(); // ORIGINAL coverage remains retained.
          await pending;
          expect(updates, isNotEmpty);
          for (final update in updates) {
            expect(update.messages.single.content, contains('Keep prose.'));
            expect(
              update.messages.single.agentSwipes.single.content,
              contains('Keep prose.'),
            );
            final metadata = update.messages.single.swipesMeta.single;
            expect(metadata['preserveUnknown'], 'keep');
            expect(metadata['nested'], {'public': 'keep'});
            if (privateMember != 'public control') {
              expect(metadata, original.messages.single.swipesMeta.single);
            } else {
              // Ordinary selected-content publication synchronizes native
              // agent-swipe metadata; this is not loss of unknown metadata.
              expect(metadata['agentSwipeId'], 0);
              expect((metadata['agentSwipes'] as List).single,
                update.messages.single.agentSwipes.single.toJson());
            }
            expect(
              jsonEncode(update.session!.toJson()),
              isNot(contains('SYNTHETIC_TYPED_PRIVATE')),
            );
          }
          final durable = (await repo.getById(original.id))!;
          if (privateMember == 'public control') {
            expect(
              durable.messages.single.content,
              contains('Image generation disabled'),
            );
            expect(
              durable.messages.single.triggeredLorebooks.single.toJson(),
              original.messages.single.triggeredLorebooks.single.toJson(),
            );
            expect(
              durable.messages.single.triggeredMemories.single.toJson(),
              original.messages.single.triggeredMemories.single.toJson(),
            );
            expect(ChatSessionService.cacheSize, 1);
          } else {
            expect(jsonEncode(durable.toJson()), raw);
            expect(ChatSessionService.cacheSize, 0);
          }
          expect(service.generationCalls, 0);
        },
      );
    }

    for (final boundary in ['progress', 'queued', 'postCommit']) {
      test(
        'Naistera CURRENT raw JSON unknown metadata denies actual $boundary publication without durable projection',
        () async {
          const alias = 'SYNTHETIC_PRIVATE"BOUNDARY_METADATA';
          final carried = jsonEncode({'label': alias});
          const text = 'Keep prose. [IMG:GEN:{"prompt":"new"}]';
          final original = session('synthetic-naistera-meta-$boundary', text)
              .copyWith(
                draft: 'keep draft',
                messages: [
                  ChatMessage(
                    id: 'assistant',
                    role: 'assistant',
                    content: text,
                    swipes: const [text],
                    agentSwipes: const [AgentSwipe(content: text)],
                    swipesMeta: [
                      {
                        'futurePrivateMetadata': carried,
                        'preserveUnknown': 'keep',
                        'agentSwipes': [
                          {
                            'content': text,
                            'kind': 'final',
                            'futurePrivateMetadata': carried,
                            'futurePublic': 'keep nested',
                          },
                        ],
                      },
                    ],
                  ),
                ],
              );
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          final gatedRepo = _CommittedImageRepo(db);
          final progressService = settledFor(ImageGenApiType.naistera);
          final completedService = _CompletedImageService(
            ImageTagMarkup.replaceTagWithResult(
              text,
              0,
              'generated/public-new.png',
            ),
          );
          final ImageGenService service = boundary == 'progress'
              ? progressService
              : completedService;
          final updates = <ChatState>[];
          final process = Provider<Future<void>>(
            (ref) => ImageGenProcessor(
              ref: ref,
              charId: original.characterId,
              isCurrentOperation: () => true,
              onStateUpdate: updates.add,
            ).process(ChatState(session: original)),
          );
          final container = ProviderContainer(
            overrides: [
              appDbProvider.overrideWithValue(db),
              if (boundary != 'progress')
                chatRepoProvider.overrideWithValue(gatedRepo),
              sharedPreferencesProvider.overrideWith((ref) async => prefs),
              credentialVaultProvider.overrideWithValue(vault),
              secretRedactionCoordinatorProvider.overrideWithValue(
                originalRedaction,
              ),
              imageNaisteraCredentialOwnerProvider.overrideWithValue(
                naisteraOwner,
              ),
              imageGenSettingsProvider.overrideWith(
                () => _ImageSettingsWithOutcome(
                  service,
                  apiType: ImageGenApiType.naistera,
                ),
              ),
              activeApiConfigProvider.overrideWithValue(
                const ApiConfig(
                  id: 'synthetic-api',
                  endpoint: 'https://unused.invalid',
                  apiKey: '',
                  model: 'synthetic',
                ),
              ),
            ],
          );
          final transactionEntered = Completer<void>(),
              releaseTransaction = Completer<void>();
          addTearDown(() async {
            if (!progressService.releaseFirst.isCompleted)
              progressService.releaseFirst.complete();
            if (!completedService.release.isCompleted)
              completedService.release.complete();
            if (!releaseTransaction.isCompleted) releaseTransaction.complete();
            if (!gatedRepo.release.isCompleted) gatedRepo.release.complete();
            container.dispose();
            await db.close();
          });
          final repo = container.read(chatRepoProvider);
          await repo.put(original);
          final before = jsonEncode(
            (await repo.getById(original.id))!.toJson(),
          );
          await container.read(imageGenSettingsProvider.future);
          final ownsNative = naisteraOwner.captureGuard();
          final pending = container.read(process);
          String? committed;
          Future<void>? blocked;
          if (boundary == 'progress') {
            await progressService.secondSettled.future;
          } else {
            await completedService.entered.future;
            if (boundary == 'queued') {
              blocked = db.transaction(() async {
                transactionEntered.complete();
                await releaseTransaction.future;
              });
              await transactionEntered.future;
            }
            completedService.release.complete();
            await gatedRepo.mutationEntered.future;
            if (boundary == 'postCommit') {
              await gatedRepo.committed.future;
              committed = jsonEncode(
                (await repo.getById(original.id))!.toJson(),
              );
            }
          }
          final countBeforePolicy = updates.length;
          activeErrorRedactor = SecretRedactor(knownSecrets: const [alias]);
          if (boundary == 'progress') {
            progressService.releaseFirst.complete();
          } else {
            releaseTransaction.complete();
            if (blocked != null) await blocked;
            gatedRepo.release.complete();
          }
          await pending;
          expect(ownsNative(), isTrue);
          expect(
            jsonEncode((await repo.getById(original.id))!.toJson()),
            committed ?? before,
          );
          expect(ChatSessionService.cacheSize, 0);
          expect(updates.skip(countBeforePolicy), isNotEmpty);
          for (final update in updates.skip(countBeforePolicy)) {
            expect(
              jsonEncode(update.session!.toJson()),
              isNot(contains('SYNTHETIC_PRIVATE')),
            );
            expect(
              update.messages.single.swipesMeta.single['preserveUnknown'],
              'keep',
            );
            expect(
              (update.messages.single.swipesMeta.single['agentSwipes'] as List)
                  .single['futurePublic'],
              'keep nested',
            );
            expect(update.session!.draft, 'keep draft');
          }
          expect(updates.last.isGeneratingImage, isFalse);
          if (boundary == 'progress') expect(progressService.progressCalls, 1);
        },
      );
    }

    String errorCard(Map<String, Object?> payload) =>
        '[IMG:ERROR:${jsonEncode(payload)}]';

    final errorInstructionCases = <String, Map<String, Object?>>{
      'no variants ORIGINAL+CURRENT': {
        'error': 'public failure',
        'instruction': jsonEncode({'prompt': '$nativeKey $lateAlias'}),
      },
      'partially percent encoded': {
        'error': 'public failure',
        'instruction': jsonEncode({
          'prompt':
              '100% public SYNTHETIC%5fORIGINAL_IMAGE_KEY '
              'SYNTHETIC%20LATE%2bALIAS/SECRET',
        }),
        'variants': 'generated/public.png;;*generated/public-other.png',
      },
      'JSON escaped instruction': {
        'error': 'public failure',
        'instruction': r'{"prompt":"SYNTHETIC\u005fORIGINAL_IMAGE_KEY"}',
        'variants': 'generated/public.png',
      },
      'repeated percent encoding': {
        'error': 'public failure',
        'instruction': jsonEncode({
          'prompt': Uri.encodeComponent(Uri.encodeComponent(lateAlias)),
        }),
      },
      'partially percent encoded variants': {
        'error': 'public failure',
        'instruction': '{"prompt":"keep public"}',
        'variants': 'generated/public.png;;*SYNTHETIC%20LATE%2bALIAS/SECRET',
      },
      'long retained instruction ORIGINAL+CURRENT': {
        'error': 'public failure',
        'instruction': jsonEncode({
          'prompt': '${List.filled(9000, 'p').join()} $nativeKey $lateAlias',
        }),
      },
      'typeless instruction': {
        'error': 'public failure',
        'instruction': {'prompt': lateAlias},
        'variants': 'generated/public.png',
      },
      'malformed variants': {
        'error': 'public failure',
        'instruction': '{"prompt":"keep public"}',
        'variants': [lateAlias, 'generated/public.png'],
      },
    };

    for (final imageType in [
      ImageGenApiType.openrouter,
      ImageGenApiType.novelai,
      ImageGenApiType.naistera,
    ]) {
      test(
        '${imageType.name} error-card fence checks whole raw and decoded retained fields before normalization',
        () {
          final errors = ImageGenErrorSanitizer(
            openrouterCredentials: imageType == ImageGenApiType.openrouter
                ? openRouterOwner
                : null,
            novelaiCredentials: imageType == ImageGenApiType.novelai
                ? novelAiOwner
                : null,
            naisteraCredentials: imageType == ImageGenApiType.naistera
                ? naisteraOwner
                : null,
          );
          activateCurrent(lateAlias);
          final denied = [
            ...errorInstructionCases.values.map(errorCard),
            errorCard({'error': 'public failure', 'instruction': lateAlias}),
            errorCard({
              'error': 'public failure',
              'instruction': null,
              'variants': 'generated/public.png',
            }),
            errorCard({
              'error': 'public failure',
              'instruction': 42,
              'variants': 'generated/public.png',
            }),
            errorCard({
              'error': 'public failure',
              'instruction': [lateAlias],
              'variants': 'generated/public.png',
            }),
            errorCard({
              'error': 'public failure',
              'instruction': '{"prompt":"keep public"}',
              'variants': {'path': lateAlias},
            }),
            errorCard({
              'error': 'public failure',
              'instruction': '{"prompt":"keep public"}',
              'variants': null,
            }),
            errorCard({
              'error': 'public failure',
              'instruction': '{"prompt":"$nativeKey"}',
            }).replaceAll('SYNTHETIC_', r'SYNTHETIC\u005f'),
          ];
          // A known alias may span the original payload, not any decoded field.
          const wholeAlias =
              '{ "error": "public failure", "instruction": "keep public", '
              '"variants": "generated/public.png" }';
          originalRedaction.registerSecret(wholeAlias);
          denied.add('[IMG:ERROR:$wholeAlias]');
          final longWholeAlias = jsonEncode({
            'error': List.filled(240, 'e').join(),
            'instruction': 'keep public',
            'variants': 'generated/public.png',
          });
          currentRedaction.registerSecret(longWholeAlias);
          activeErrorRedactor = currentRedaction.redactor;
          denied.add('[IMG:ERROR:$longWholeAlias]');
          for (final entry in denied.asMap().entries) {
            final card = entry.value;
            expect(errors.messageErrorsAreCurrent(card), isFalse, reason: card);
            final sanitized = errors.sanitizeMessageErrors(card);
            expect(
              errors.messageErrorsAreCurrent(sanitized),
              isFalse,
              reason:
                  'Sanitization must not erase denial evidence (case ${entry.key})',
            );
            final projected = errors.displayProjection('Keep prose. $card');
            expect(projected, contains('Keep prose.'));
            expect(projected, isNot(contains('generated/public')));
            expect(projected, isNot(contains(nativeKey)));
            expect(projected, isNot(contains(lateAlias)));
            expect(projected, isNot(contains('SYNTHETIC%')));
            expect(projected, isNot(contains(r'SYNTHETIC\u005f')));
            expect(errors.messageErrorsAreCurrent(projected), isTrue);
            expect(
              ImageTagMarkup.scanImageBlocks(
                projected,
              ).every((block) => block.paths.isEmpty),
              isTrue,
            );
          }
          // Neither diagnostic limits nor URL syntax apply to retained JSON.
          final publicInstruction = jsonEncode({
            'prompt': '${List.filled(9000, 'p').join()} 100% public',
            'url': 'https://public.invalid/a.png?width=1&height=2',
          });
          final publicCard = errorCard({
            'error': 'public failure',
            'instruction': publicInstruction,
            'variants': 'generated/public.png;;*generated/public-other.png',
          });
          expect(errors.messageErrorsAreCurrent(publicCard), isTrue);
          expect(errors.displayProjection(publicCard), publicCard);
          final privateDetail = errorCard({
            'error': '$nativeKey $lateAlias',
            'instruction': publicInstruction,
            'variants': 'generated/public.png',
          });
          final safeDetail = errors.sanitizeMessageErrors(privateDetail);
          expect(safeDetail, isNot(contains(nativeKey)));
          expect(safeDetail, isNot(contains(lateAlias)));
          expect(errors.messageErrorsAreCurrent(safeDetail), isTrue);
          expect(
            ImageTagMarkup.scanImageBlocks(safeDetail).single.instruction,
            publicInstruction,
          );
          expect(safeDetail, contains('generated/public.png'));
          const unrelatedProse = 'Unrelated prose $nativeKey $lateAlias.';
          expect(errors.displayProjection(unrelatedProse), unrelatedProse);
          expect(errors.messageErrorsAreCurrent(unrelatedProse), isTrue);
          final partialPrivateDetail = errors.sanitizeMessageErrors(
            errorCard({
              'error': 'SYNTHETIC%20LATE%2bALIAS/SECRET',
              'instruction': publicInstruction,
              'variants': 'generated/public.png',
            }),
          );
          expect(partialPrivateDetail, isNot(contains('SYNTHETIC%')));
          expect(partialPrivateDetail, contains('generated/public.png'));
          expect(errors.messageErrorsAreCurrent(partialPrivateDetail), isTrue);
          activeErrorRedactor = SecretRedactor(
            knownSecrets: [lateAlias],
            maxInputLength: 32,
            maxOutputLength: 32,
          );
          expect(errors.messageErrorsAreCurrent(publicCard), isTrue);
          expect(errors.displayProjection(publicCard), publicCard);
          for (final card in errorInstructionCases.values.map(errorCard)) {
            expect(errors.messageErrorsAreCurrent(card), isFalse);
          }
        },
      );
    }

    for (final imageType in [
      ImageGenApiType.novelai,
      ImageGenApiType.naistera,
    ]) {
      for (final enabled in [false, true]) {
        test(
          '${imageType.name} real service denies retained error instruction/types with no progress (enabled=$enabled)',
          () async {
            activateCurrent(lateAlias);
            for (final entry in errorInstructionCases.entries) {
              final service = settledFor(imageType);
              service.releaseFirst.complete();
              final text =
                  'Keep prose. [IMG:GEN:{"prompt":"new"}] '
                  '${errorCard(entry.value)}';
              final updates = <String>[];
              final result = await service.processMessageImages(
                text: text,
                settings: ImageGenSettings(
                  enabled: enabled,
                  apiType: imageType,
                ),
                llmEndpoint: '',
                llmApiKey: '',
                llmModel: '',
                onUpdate: updates.add,
              );
              expect(service.publicationDenials, 1, reason: entry.key);
              expect(service.generationCalls, enabled ? 1 : 0);
              expect(service.progressCalls, 0);
              expect(updates, isEmpty);
              expect(
                result,
                contains('Keep prose. [IMG:GEN:{"prompt":"new"}]'),
              );
              expect(result, isNot(contains(nativeKey)));
              expect(result, isNot(contains(lateAlias)));
              expect(result, isNot(contains('SYNTHETIC%')));
              expect(result, isNot(contains('generated/public.png')));
              expect(
                ImageGenErrorSanitizer(
                  novelaiCredentials: imageType == ImageGenApiType.novelai
                      ? novelAiOwner
                      : null,
                  naisteraCredentials: imageType == ImageGenApiType.naistera
                      ? naisteraOwner
                      : null,
                ).messageErrorsAreCurrent(result),
                isTrue,
              );
            }
          },
        );

        for (final location in ['selected', 'swipe', 'agent', 'stored']) {
          test(
            '${imageType.name} real processor error instruction denial covers $location and preserves canonical DB/cache (enabled=$enabled)',
            () async {
              final payload = switch (location) {
                'selected' =>
                  errorInstructionCases['no variants ORIGINAL+CURRENT']!,
                'swipe' => {
                  'error': 'public failure',
                  'instruction':
                      '{"prompt":"100% public '
                      'SYNTHETIC%20LATE%2bALIAS/SECRET"}',
                  'variants': 'generated/public.png',
                },
                'agent' => errorInstructionCases['typeless instruction']!,
                _ => errorInstructionCases['malformed variants']!,
              };
              final denied = errorCard(payload);
              const pendingText = 'Keep prose. [IMG:GEN:{"prompt":"new"}]';
              final selected = location == 'selected'
                  ? '$pendingText $denied'
                  : pendingText;
              final original =
                  session('synthetic-nai-error-instruction', selected).copyWith(
                    draft: 'keep draft',
                    sessionVars: {'concurrent': 'keep'},
                    messages: [
                      ChatMessage(
                        id: 'assistant',
                        role: 'assistant',
                        content: selected,
                        reasoning: 'keep reasoning',
                        swipes: [
                          selected,
                          location == 'swipe' ? denied : 'keep swipe',
                        ],
                        agentSwipes: [
                          AgentSwipe(content: selected),
                          AgentSwipe(
                            content: location == 'agent'
                                ? denied
                                : 'keep agent',
                          ),
                        ],
                        swipesMeta: [
                          {
                            'preserveUnknown': 'keep',
                            'agentSwipes': [
                              {'content': selected, 'kind': 'final'},
                            ],
                          },
                          {
                            'preserveUnknown': 'keep archived',
                            'agentSwipes': [
                              {
                                'content': location == 'stored'
                                    ? denied
                                    : 'keep stored',
                                'future': 'keep',
                              },
                            ],
                          },
                        ],
                      ),
                    ],
                  );
              final db = AppDatabase.forTesting(NativeDatabase.memory());
              final service = settledFor(imageType);
              final updates = <ChatState>[];
              final process = Provider<Future<void>>(
                (ref) => ImageGenProcessor(
                  ref: ref,
                  charId: original.characterId,
                  isCurrentOperation: () => true,
                  onStateUpdate: updates.add,
                ).process(ChatState(session: original)),
              );
              final container = ProviderContainer(
                overrides: [
                  appDbProvider.overrideWithValue(db),
                  sharedPreferencesProvider.overrideWith((ref) async => prefs),
                  credentialVaultProvider.overrideWithValue(vault),
                  secretRedactionCoordinatorProvider.overrideWithValue(
                    originalRedaction,
                  ),
                  imageRoutmyCredentialOwnerProvider.overrideWithValue(owner),
                  imageOpenRouterCredentialOwnerProvider.overrideWithValue(
                    openRouterOwner,
                  ),
                  imageNovelAiCredentialOwnerProvider.overrideWithValue(
                    novelAiOwner,
                  ),
                  imageNaisteraCredentialOwnerProvider.overrideWithValue(
                    naisteraOwner,
                  ),
                  imageGenSettingsProvider.overrideWith(
                    () => _ImageSettingsWithOutcome(
                      service,
                      apiType: imageType,
                      enabled: enabled,
                    ),
                  ),
                  activeApiConfigProvider.overrideWithValue(
                    const ApiConfig(
                      id: 'synthetic-api',
                      endpoint: 'https://unused.invalid',
                      apiKey: '',
                      model: 'synthetic',
                    ),
                  ),
                ],
              );
              addTearDown(() async {
                if (!service.releaseFirst.isCompleted)
                  service.releaseFirst.complete();
                container.dispose();
                await db.close();
              });
              final repo = container.read(chatRepoProvider);
              await repo.put(original);
              final before = jsonEncode(
                (await repo.getById(original.id))!.toJson(),
              );
              await container.read(imageGenSettingsProvider.future);
              if (!enabled) activateCurrent(lateAlias);
              final processing = container.read(process);
              var publishedBeforePolicy = 0;
              if (enabled) {
                await service.secondSettled.future;
                publishedBeforePolicy = updates.length;
                activateCurrent(lateAlias);
                service.releaseFirst.complete();
              }
              await processing;
              expect(updates, isNotEmpty);
              for (final update in updates.skip(publishedBeforePolicy)) {
                final serialized = jsonEncode(update.session!.toJson());
                expect(serialized, isNot(contains(nativeKey)));
                expect(serialized, isNot(contains(lateAlias)));
                expect(serialized, isNot(contains('SYNTHETIC%')));
                expect(serialized, isNot(contains('generated/public.png')));
                expect(update.messages.single.content, contains(pendingText));
                expect(update.messages.single.reasoning, 'keep reasoning');
                expect(update.session!.draft, original.draft);
                expect(update.session!.sessionVars, original.sessionVars);
                expect(
                  update.messages.single.swipesMeta.last['preserveUnknown'],
                  'keep archived',
                );
                expect(
                  (update.messages.single.swipesMeta.last['agentSwipes']
                          as List)
                      .single['future'],
                  'keep',
                );
              }
              expect(updates.last.isGeneratingImage, isFalse);
              expect(service.generationCalls, enabled ? 1 : 0);
              expect(
                service.progressCalls,
                enabled && location != 'selected' ? 1 : 0,
              );
              expect(
                jsonEncode((await repo.getById(original.id))!.toJson()),
                before,
              );
              expect(ChatSessionService.cacheSize, 0);
            },
          );
        }
      }
    }
    for (final imageType in [ImageGenApiType.novelai, ImageGenApiType.naistera])
      test(
        '${imageType.name} actual block renderer returns typed denial for retained error instruction without completion',
        () async {
          final text =
              'Keep prose. [IMG:GEN:{"prompt":"new"}] '
              '${errorCard(errorInstructionCases['typeless instruction']!)}';
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          final repo = _ObservedImageBlockRepo(db);
          final service = settledFor(imageType);
          const config = BlockConfig(
            id: 'synthetic-error-instruction-block',
            name: 'Image',
            source: BlockSource.carried,
          );
          final original = session(
            'synthetic-error-instruction-block',
            'prose',
          );
          final placeholder = InfoBlock(
            id: 'synthetic-error-instruction-row',
            sessionId: original.id,
            messageId: 'assistant',
            blockId: config.id,
            blockName: 'Image',
            blockType: 'generated',
            content: '',
            status: BlockRunStatus.running,
            createdAt: 1,
          );
          final process = Provider<Future<BlockImageRenderResult>>(
            (ref) =>
                BlockImageRenderer(
                  ref: ref,
                  repo: repo,
                  publishStreamingBlockContent: BlockPanelUpdater(
                    ref,
                  ).publishStreamingContent,
                ).render(
                  context: BlockContext(
                    charId: original.characterId,
                    sessionId: original.id,
                    messageId: 'assistant',
                    swipeId: 0,
                    messages: original.messages,
                    blockConfig: config,
                    preset: null,
                    character: const Character(
                      id: 'character',
                      name: 'Synthetic',
                    ),
                    persona: null,
                    previousOutput: null,
                    cancelToken: CancelToken(),
                    placeholderId: placeholder.id,
                    placeholder: placeholder,
                  ),
                  sourceContent: text,
                ),
          );
          final container = ProviderContainer(
            overrides: [
              appDbProvider.overrideWithValue(db),
              infoBlocksRepoProvider.overrideWithValue(repo),
              sharedPreferencesProvider.overrideWith((ref) async => prefs),
              credentialVaultProvider.overrideWithValue(vault),
              secretRedactionCoordinatorProvider.overrideWithValue(
                originalRedaction,
              ),
              imageRoutmyCredentialOwnerProvider.overrideWithValue(owner),
              imageOpenRouterCredentialOwnerProvider.overrideWithValue(
                openRouterOwner,
              ),
              imageNovelAiCredentialOwnerProvider.overrideWithValue(
                novelAiOwner,
              ),
              imageNaisteraCredentialOwnerProvider.overrideWithValue(
                naisteraOwner,
              ),
              imageGenSettingsProvider.overrideWith(
                () => _ImageSettingsWithOutcome(
                  service,
                  apiType: imageType,
                  enabled: false,
                ),
              ),
              apiListProvider.overrideWith(_ImageBlockApis.new),
            ],
          );
          addTearDown(() async {
            container.dispose();
            await db.close();
          });
          await repo.insert(placeholder);
          await container.read(imageGenSettingsProvider.future);
          await container
              .read(infoBlocksProvider(original.id).notifier)
              .refresh();
          final before = jsonEncode(
            (await repo.getBySessionId(original.id)).single.toJson(),
          );
          final updates = <List<InfoBlock>>[];
          final subscription = container.listen(
            infoBlocksProvider(original.id),
            (_, next) => updates.add(next),
          );
          addTearDown(subscription.close);
          activateCurrent(lateAlias);
          final result = await container.read(process);
          expect(result, isA<BlockImageRenderResult>());
          expect(result.content, isNull);
          expect(result.isPublishable('public replacement'), isFalse);
          expect(service.publicationDenials, 1);
          expect(service.generationCalls, 0);
          expect(service.progressCalls, 0);
          expect(repo.completionCalls, 0);
          expect(updates, isEmpty);
          expect(
            jsonEncode(
              (await repo.getBySessionId(original.id)).single.toJson(),
            ),
            before,
          );
        },
      );

    for (final imageType in [
      ImageGenApiType.novelai,
      ImageGenApiType.naistera,
    ]) {
      for (final enabled in [false, true]) {
        for (final latePolicy in [false, true]) {
          test(
            '${imageType.name} actual service and processor initial/busy denial is display-only (enabled=$enabled current=$latePolicy)',
            () async {
              const alias = 'generated/SYNTHETIC_NAI_INITIAL_PRIVATE.png';
              const text =
                  'Keep prose. [IMG:GEN:{"prompt":"new"}] [IMG:RESULT:$alias;;*generated/public.png|{"prompt":"keep"}]';
              final original = session('synthetic-nai-denial-session', text)
                  .copyWith(
                    messages: [
                      ChatMessage(
                        id: 'assistant',
                        role: 'assistant',
                        content: text,
                        swipes: [text, 'Archive $text'],
                        agentSwipes: [AgentSwipe(content: text)],
                        swipesMeta: [
                          {
                            'agentSwipes': [
                              {'content': text, 'kind': 'final'},
                            ],
                          },
                          {
                            'agentSwipes': [
                              {'content': 'Archive $text', 'kind': 'cleaned'},
                            ],
                          },
                        ],
                      ),
                    ],
                  );
              if (latePolicy) {
                activateCurrent(alias);
              } else {
                originalRedaction.registerSecret(alias);
              }
              final service = settledFor(imageType);
              service.releaseFirst.complete();
              final db = AppDatabase.forTesting(NativeDatabase.memory());
              final updates = <ChatState>[];
              final process = Provider<Future<void>>(
                (ref) => ImageGenProcessor(
                  ref: ref,
                  charId: original.characterId,
                  isCurrentOperation: () => true,
                  onStateUpdate: updates.add,
                ).process(ChatState(session: original)),
              );
              final container = ProviderContainer(
                overrides: [
                  appDbProvider.overrideWithValue(db),
                  sharedPreferencesProvider.overrideWith((ref) async => prefs),
                  credentialVaultProvider.overrideWithValue(vault),
                  secretRedactionCoordinatorProvider.overrideWithValue(
                    originalRedaction,
                  ),
                  imageNovelAiCredentialOwnerProvider.overrideWithValue(
                    novelAiOwner,
                  ),
                  imageNaisteraCredentialOwnerProvider.overrideWithValue(
                    naisteraOwner,
                  ),
                  imageGenSettingsProvider.overrideWith(
                    () => _ImageSettingsWithOutcome(
                      service,
                      apiType: imageType,
                      enabled: enabled,
                    ),
                  ),
                  activeApiConfigProvider.overrideWithValue(
                    const ApiConfig(
                      id: 'synthetic-api',
                      endpoint: 'https://unused.invalid',
                      apiKey: '',
                      model: 'synthetic',
                    ),
                  ),
                ],
              );
              addTearDown(() async {
                container.dispose();
                await db.close();
              });
              final repo = container.read(chatRepoProvider);
              await repo.put(original);
              final stored = jsonEncode(
                (await repo.getById(original.id))!.toJson(),
              );
              await container.read(imageGenSettingsProvider.future);
              await container.read(process);
              expect(
                jsonEncode((await repo.getById(original.id))!.toJson()),
                stored,
              );
              expect(ChatSessionService.cacheSize, 0);
              expect(updates, isNotEmpty);
              for (final update in updates) {
                expect(
                  jsonEncode(update.session!.toJson()),
                  isNot(contains(alias)),
                );
                expect(
                  jsonEncode(update.session!.toJson()),
                  isNot(contains('generated/public.png')),
                );
                expect(update.messages.single.content, contains('Keep prose.'));
              }
              expect(updates.last.isGeneratingImage, isFalse);
              expect(service.generationCalls, enabled ? 1 : 0);
            },
          );
        }
      }
      for (final encoded in [false, true]) {
        test(
          '${imageType.name} actual service error callbacks/final result consult ORIGINAL and CURRENT aliases (encoded=$encoded)',
          () async {
            final detail =
                '$nativeKey ${encoded ? Uri.encodeComponent(lateAlias) : lateAlias}';
            final service = settledFor(imageType, detail);
            final updates = <String>[], errors = <String>[];
            final pending = service.processMessageImages(
              text: '[IMG:GEN:{"prompt":"new"}]',
              settings: ImageGenSettings(enabled: true, apiType: imageType),
              llmEndpoint: '',
              llmApiKey: '',
              llmModel: '',
              onUpdate: updates.add,
              onError: errors.add,
            );
            await service.secondSettled.future;
            activateCurrent(lateAlias);
            service.releaseFirst.complete();
            final result = await pending;
            expect(errors, isNotEmpty);
            for (final value in [result, ...updates, ...errors]) {
              expect(value, isNot(contains(nativeKey)));
              expect(value, isNot(contains(lateAlias)));
              expect(value, isNot(contains(Uri.encodeComponent(lateAlias))));
            }
            expect(result, contains('[IMG:ERROR:'));
          },
        );
      }
    }
    for (final latePolicy in [false, true]) {
      test(
        'disabled native service refuses carried ${latePolicy ? 'CURRENT' : 'original'} private results before callbacks',
        () async {
          const alias = 'generated/SYNTHETIC_DISABLED_PRIVATE.png';
          final instruction = const ImageBlockPayload(
            paths: [alias, 'generated/public.png'],
            instruction: '{"prompt":"keep"}',
          ).encodePending();
          final text = 'Keep prose. [IMG:GEN:$instruction]';
          final originalGuard = openRouterOwner.captureGuard();
          if (latePolicy)
            activateCurrent(alias);
          else
            originalRedaction.registerSecret(alias);
          final service = _SettledNativeErrorService.openRouter(
            openRouterOwner,
          );
          final updates = <String>[];
          var denied = 0;
          final result = await service.processMessageImages(
            text: text,
            settings: const ImageGenSettings(
              enabled: false,
              apiType: ImageGenApiType.openrouter,
            ),
            llmEndpoint: '',
            llmApiKey: '',
            llmModel: '',
            onUpdate: updates.add,
            onPublicationDenied: () => denied++,
          );
          expect(originalGuard(), isTrue);
          expect(service.generationCalls, 0);
          expect(denied, 1);
          expect(updates, isEmpty);
          expect(result, isNot(contains(alias)));
          expect(result, isNot(contains('generated/public.png')));
          expect(result, contains(r'\"prompt\":\"keep\"'));
          expect(result, contains('Keep prose.'));
          expect(
            ImageGenErrorSanitizer(
              openrouterCredentials: openRouterOwner,
            ).messageErrorsAreCurrent(result),
            isTrue,
          );
        },
      );

      test(
        'disabled native processor projects carried ${latePolicy ? 'CURRENT' : 'original'} private results without DB or cache writes',
        () async {
          const alias = 'generated/SYNTHETIC_DISABLED_PROCESSOR.png';
          final pending = const ImageBlockPayload(
            paths: [alias, 'generated/public.png'],
            instruction: '{"prompt":"keep"}',
          ).encodePending();
          final text = 'Keep prose. [IMG:GEN:$pending]';
          final original = session('synthetic-disabled-session', text).copyWith(
            draft: 'keep draft',
            sessionVars: {'concurrent': 'keep'},
            messages: [
              ChatMessage(
                id: 'assistant',
                role: 'assistant',
                content: text,
                swipes: [text],
                agentSwipes: [AgentSwipe(content: text)],
                swipesMeta: [
                  {
                    'preserveUnknown': 'keep',
                    'agentSwipes': [
                      {'content': text, 'future': 'keep'},
                    ],
                  },
                ],
              ),
            ],
          );
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          final service = _SettledNativeErrorService.openRouter(
            openRouterOwner,
          );
          final updates = <ChatState>[];
          final process = Provider<Future<void>>(
            (ref) => ImageGenProcessor(
              ref: ref,
              charId: original.characterId,
              isCurrentOperation: () => true,
              onStateUpdate: updates.add,
            ).process(ChatState(session: original)),
          );
          final container = ProviderContainer(
            overrides: [
              appDbProvider.overrideWithValue(db),
              sharedPreferencesProvider.overrideWith((ref) async => prefs),
              credentialVaultProvider.overrideWithValue(vault),
              secretRedactionCoordinatorProvider.overrideWithValue(
                originalRedaction,
              ),
              imageRoutmyCredentialOwnerProvider.overrideWithValue(owner),
              imageOpenRouterCredentialOwnerProvider.overrideWithValue(
                openRouterOwner,
              ),
              imageGenSettingsProvider.overrideWith(
                () => _ImageSettingsWithOutcome(
                  service,
                  apiType: ImageGenApiType.openrouter,
                  enabled: false,
                ),
              ),
            ],
          );
          addTearDown(() async {
            container.dispose();
            await db.close();
          });
          final repo = container.read(chatRepoProvider);
          await repo.put(original);
          final before = jsonEncode(
            (await repo.getById(original.id))!.toJson(),
          );
          await container.read(imageGenSettingsProvider.future);
          if (latePolicy)
            activateCurrent(alias);
          else
            originalRedaction.registerSecret(alias);
          await container.read(process);
          expect(updates, isNotEmpty);
          for (final update in updates) {
            final serialized = jsonEncode(update.session!.toJson());
            expect(serialized, isNot(contains(alias)));
            expect(serialized, isNot(contains(Uri.encodeComponent(alias))));
            expect(serialized, isNot(contains('generated/public.png')));
            expect(update.messages.single.content, contains('Keep prose.'));
            expect(update.session!.draft, original.draft);
            expect(update.session!.sessionVars, original.sessionVars);
            expect(
              update.messages.single.swipesMeta.single['preserveUnknown'],
              'keep',
            );
          }
          expect(
            jsonEncode((await repo.getById(original.id))!.toJson()),
            before,
          );
          expect(ChatSessionService.cacheSize, 0);
          expect(service.generationCalls, 0);
        },
      );
    }

    for (final latePolicy in [false, true]) {
      for (final archivedKind in ['swipe', 'agent', 'stored']) {
        test(
          'enabled native progress refuses ${latePolicy ? 'CURRENT' : 'original'} private unselected $archivedKind without persistence',
          () async {
            const alias = 'generated/SYNTHETIC_PRIVATE_ARCHIVED_PROGRESS.png';
            const selected = 'Keep prose. [IMG:GEN:{"prompt":"keep"}]';
            final archived = ImageTagMarkup.encodeResultElement(
              const ImageBlockPayload(
                paths: [alias, 'generated/public-archived.png'],
                instruction: '{"prompt":"archive keep"}',
              ),
            );
            final original = session('synthetic-progress-session', selected)
                .copyWith(
                  draft: 'keep draft',
                  sessionVars: {'concurrent': 'keep'},
                  messages: [
                    ChatMessage(
                      id: 'assistant',
                      role: 'assistant',
                      content: selected,
                      swipes: [
                        selected,
                        archivedKind == 'swipe' ? archived : 'keep swipe',
                      ],
                      agentSwipes: [
                        const AgentSwipe(content: selected),
                        AgentSwipe(
                          content: archivedKind == 'agent'
                              ? archived
                              : 'keep agent',
                        ),
                      ],
                      swipesMeta: [
                        {'preserveUnknown': 'keep'},
                        {
                          'preserveUnknown': 'keep archived',
                          'agentSwipes': [
                            {
                              'content': archivedKind == 'stored'
                                  ? archived
                                  : 'keep stored',
                              'future': 'keep',
                            },
                          ],
                        },
                      ],
                    ),
                  ],
                );
            final db = AppDatabase.forTesting(NativeDatabase.memory());
            final service = _SettledNativeErrorService.openRouter(
              openRouterOwner,
            );
            final updates = <ChatState>[];
            final originalGuard = openRouterOwner.captureGuard();
            final process = Provider<Future<void>>(
              (ref) => ImageGenProcessor(
                ref: ref,
                charId: original.characterId,
                isCurrentOperation: () => true,
                onStateUpdate: updates.add,
              ).process(ChatState(session: original)),
            );
            final container = ProviderContainer(
              overrides: [
                appDbProvider.overrideWithValue(db),
                sharedPreferencesProvider.overrideWith((ref) async => prefs),
                credentialVaultProvider.overrideWithValue(vault),
                secretRedactionCoordinatorProvider.overrideWithValue(
                  originalRedaction,
                ),
                imageRoutmyCredentialOwnerProvider.overrideWithValue(owner),
                imageOpenRouterCredentialOwnerProvider.overrideWithValue(
                  openRouterOwner,
                ),
                apiListProvider.overrideWith(_ImageBlockApis.new),
                imageGenSettingsProvider.overrideWith(
                  () => _ImageSettingsWithOutcome(
                    service,
                    apiType: ImageGenApiType.openrouter,
                  ),
                ),
              ],
            );
            addTearDown(() async {
              if (!service.releaseFirst.isCompleted)
                service.releaseFirst.complete();
              container.dispose();
              await db.close();
            });
            final repo = container.read(chatRepoProvider);
            await repo.put(original);
            final before = jsonEncode(
              (await repo.getById(original.id))!.toJson(),
            );
            await container.read(imageGenSettingsProvider.future);
            if (!latePolicy) originalRedaction.registerSecret(alias);
            final pending = container.read(process);
            await service.secondSettled.future;
            final publishedBeforePolicy = updates.length;
            // Register CURRENT while real generation is pending. The original
            // owner remains current, and the real service will invoke onUpdate.
            if (latePolicy) {
              activateCurrent(alias);
            }
            expect(originalGuard(), isTrue);
            service.releaseFirst.complete();
            await pending;
            expect(service.progressCalls, 1);
            expect(service.generationCalls, 1);
            expect(originalGuard(), isTrue);
            expect(updates, isNotEmpty);
            for (final update in updates.skip(
              latePolicy ? publishedBeforePolicy : 0,
            )) {
              final serialized = jsonEncode(update.session!.toJson());
              expect(serialized, isNot(contains(alias)));
              expect(serialized, isNot(contains(Uri.encodeComponent(alias))));
              expect(
                serialized,
                isNot(contains('generated/public-archived.png')),
              );
              expect(update.messages.single.content, contains('Keep prose.'));
              expect(update.session!.draft, original.draft);
              expect(update.session!.sessionVars, original.sessionVars);
              expect(
                update.messages.single.swipesMeta.last['preserveUnknown'],
                'keep archived',
              );
            }
            expect(updates.last.isGeneratingImage, isFalse);
            expect(
              jsonEncode((await repo.getById(original.id))!.toJson()),
              before,
            );
            expect(ChatSessionService.cacheSize, 0);
          },
        );
      }
    }

    test(
      'OpenRouter checks whole original HTML then actual decoded src and variants without changing public HTML',
      () {
        const alias = 'SYNTHETIC_A&B';
        final errors = ImageGenErrorSanitizer(
          openrouterCredentials: openRouterOwner,
        );
        final originalGuard = openRouterOwner.capturePublicTextGuard(url: true);
        final privateSrc = ImageTagMarkup.encodeResultElement(
          const ImageBlockPayload(
            paths: ['generated/SYNTHETIC_A&B.png'],
            instruction: '{"prompt":"keep"}',
          ),
        );
        final privateVariant = ImageTagMarkup.encodeResultElement(
          const ImageBlockPayload(
            paths: ['generated/public.png', 'generated/SYNTHETIC_A&B.png'],
            instruction: '{"prompt":"keep"}',
          ),
        );
        final publicHtml = ImageTagMarkup.encodeResultElement(
          const ImageBlockPayload(
            paths: ['https://public.invalid/a.png?width=1&height=2'],
            instruction: '{"prompt":"keep & public"}',
          ),
        );
        expect(
          ImageTagMarkup.scanResultElements(
            privateSrc,
          ).single.payload.activePath,
          'generated/$alias.png',
        );
        originalRedaction.registerSecret(alias);
        // The raw original is clean: only the real HTML attribute decoder exposes
        // the alias. The guard must inspect both representations, in that order.
        expect(privateSrc, contains('SYNTHETIC_A&amp;B'));
        expect(originalGuard(privateSrc), isTrue);
        expect(errors.messageErrorsAreCurrent(privateSrc), isFalse);
        expect(errors.messageErrorsAreCurrent(privateVariant), isFalse);
        expect(errors.messageErrorsAreCurrent(publicHtml), isTrue);
        expect(errors.displayProjection(publicHtml), publicHtml);
        expect(
          originalGuard('generated/public.png|{"prompt":"100% public"}'),
          isTrue,
        );
        originalRedaction.registerSecret('SYNTHETIC_IMAGE_NATIVE');
        expect(originalGuard('100% public SYNTHETIC%5fIMAGE_NATIVE'), isFalse);
        for (final denied in [privateSrc, privateVariant]) {
          final projected = errors.displayProjection(denied);
          expect(projected, isNot(contains('SYNTHETIC_A')));
          expect(projected, isNot(contains('generated/public.png')));
          expect(projected, contains(r'\"prompt\":\"keep\"'));
          expect(errors.messageErrorsAreCurrent(projected), isTrue);
        }
      },
    );

    for (final existingError in [false, true]) {
      test(
        'real OpenRouter service fallback projects an original ${existingError ? 'error variant' : 'result'} that becomes CURRENT-secret',
        () async {
          const alias = 'generated/SYNTHETIC_SERVICE_OLD.png';
          const pending = '[IMG:GEN:{"prompt":"new"}]';
          final existing = existingError
              ? '[IMG:ERROR:${jsonEncode({'error': 'public failure', 'instruction': '{"prompt":"keep"}', 'variants': '$alias;;generated/public.png'})}]'
              : '[IMG:RESULT:$alias;;generated/public.png|{"prompt":"keep"}]';
          final text = 'Keep prose. $pending $existing';
          final service = _SettledNativeErrorService.openRouter(
            openRouterOwner,
          );
          final updates = <String>[];
          var denials = 0;
          addTearDown(() {
            if (!service.releaseFirst.isCompleted)
              service.releaseFirst.complete();
          });
          final result = service.processMessageImages(
            text: text,
            settings: const ImageGenSettings(
              enabled: true,
              apiType: ImageGenApiType.openrouter,
            ),
            llmEndpoint: 'https://unused.invalid',
            llmApiKey: '',
            llmModel: 'synthetic',
            onUpdate: updates.add,
            onPublicationDenied: () => denials++,
          );
          await service.secondSettled.future;
          activateCurrent(alias);
          service.releaseFirst.complete();
          final projected = await result;
          expect(denials, 1);
          expect(updates, isEmpty);
          expect(projected, contains('Keep prose. $pending'));
          expect(projected, isNot(contains(alias)));
          expect(projected, isNot(contains('generated/public.png')));
          expect(projected, contains(r'\"prompt\":\"keep\"'));
          expect(text, contains(alias));
        },
      );
    }

    for (final imageType in [
      ImageGenApiType.openrouter,
      ImageGenApiType.novelai,
      ImageGenApiType.naistera,
    ]) {
      for (final caller in ['generated handler', 'extension image rerun']) {
        for (final outcomeKind in ['denied', 'provider error', 'success']) {
          test(
            '${imageType.name} real block caller $caller consumes $outcomeKind without treating projection as output',
            () async {
              const alias = 'generated/SYNTHETIC_BLOCK_SERVICE_OLD.png';
              const pendingText = '[IMG:GEN:{"prompt":"new"}]';
              const oldResult =
                  '[IMG:RESULT:$alias;;generated/public.png|{"prompt":"keep"}]';
              const text = 'Keep prose. $pendingText $oldResult';
              final blockConfig = BlockConfig(
                id: 'synthetic-image-block',
                name: 'Image',
                source: BlockSource.carried,
                staticContent: text,
              );
              final preset = ExtensionPreset(
                id: 'synthetic-image-preset',
                name: 'Images',
                blocks: [blockConfig],
              );
              final original = session(
                'synthetic-block-session',
                'assistant prose',
              );
              final placeholder = InfoBlock(
                id: 'synthetic-block-row',
                sessionId: original.id,
                messageId: 'assistant',
                blockId: blockConfig.id,
                blockName: blockConfig.name,
                blockType: 'generated',
                content: caller == 'generated handler' ? '' : text,
                createdAt: DateTime.now().millisecondsSinceEpoch,
                status: caller == 'generated handler'
                    ? BlockRunStatus.running
                    : BlockRunStatus.done,
              );
              final db = AppDatabase.forTesting(NativeDatabase.memory());
              final repo = _ObservedImageBlockRepo(db);
              final nativeService = imageType == ImageGenApiType.openrouter
                  ? _SettledNativeErrorService.openRouter(openRouterOwner)
                  : settledFor(imageType);
              final successText = ImageTagMarkup.replaceTagWithResult(
                text,
                0,
                'generated/new-public.png',
              );
              final successfulService = _CompletedImageService(successText);
              final ImageGenService service = outcomeKind == 'success'
                  ? successfulService
                  : nativeService;
              var refreshes = 0;
              final process = Provider<Future<InfoBlock?>>((ref) {
                if (caller == 'extension image rerun') {
                  return ref
                      .read(extensionPostGenServiceProvider)
                      .rerunImageOnly(
                        blockId: blockConfig.id,
                        messageId: 'assistant',
                        swipeId: 0,
                        agentSwipeId: -1,
                        sessionId: original.id,
                        charId: original.characterId,
                        character: const Character(
                          id: 'character',
                          name: 'Synthetic',
                        ),
                        persona: null,
                      )
                      .then((_) => null);
                }
                return GeneratedBlockHandler(
                  ref: ref,
                  repo: repo,
                  markBlockError:
                      ({required context, required errorMessage}) async =>
                          throw StateError(
                            'Unexpected block error: $errorMessage',
                          ),
                  refreshPanelForMessage: (_, _, _, _, _) => refreshes++,
                  makeStreamHandler:
                      ({
                        required blockConfig,
                        required charId,
                        required sessionId,
                        required messageId,
                        required placeholder,
                      }) => null,
                  publishStreamingBlockContent: BlockPanelUpdater(
                    ref,
                  ).publishStreamingContent,
                ).handle(
                  BlockContext(
                    charId: original.characterId,
                    sessionId: original.id,
                    messageId: 'assistant',
                    swipeId: 0,
                    messages: original.messages,
                    blockConfig: blockConfig,
                    preset: preset,
                    character: const Character(
                      id: 'character',
                      name: 'Synthetic',
                    ),
                    persona: null,
                    previousOutput: null,
                    cancelToken: CancelToken(),
                    placeholderId: placeholder.id,
                    placeholder: placeholder,
                  ),
                );
              });
              final container = ProviderContainer(
                overrides: [
                  appDbProvider.overrideWithValue(db),
                  infoBlocksRepoProvider.overrideWithValue(repo),
                  sharedPreferencesProvider.overrideWith((ref) async => prefs),
                  credentialVaultProvider.overrideWithValue(vault),
                  secretRedactionCoordinatorProvider.overrideWithValue(
                    originalRedaction,
                  ),
                  imageRoutmyCredentialOwnerProvider.overrideWithValue(owner),
                  imageOpenRouterCredentialOwnerProvider.overrideWithValue(
                    openRouterOwner,
                  ),
                  imageNovelAiCredentialOwnerProvider.overrideWithValue(
                    novelAiOwner,
                  ),
                  imageNaisteraCredentialOwnerProvider.overrideWithValue(
                    naisteraOwner,
                  ),
                  imageGenSettingsProvider.overrideWith(
                    () =>
                        _ImageSettingsWithOutcome(service, apiType: imageType),
                  ),
                  chatProvider(
                    original.characterId,
                  ).overrideWith(() => _ImageBlockChat(original)),
                  apiListProvider.overrideWith(_ImageBlockApis.new),
                ],
              );
              addTearDown(() async {
                if (!nativeService.releaseFirst.isCompleted)
                  nativeService.releaseFirst.complete();
                if (!successfulService.release.isCompleted)
                  successfulService.release.complete();
                container.dispose();
                await db.close();
              });
              await repo.insert(placeholder);
              await container.read(extensionPresetsRepoProvider).insert(preset);
              await container.read(extensionPresetsProvider.notifier).refresh();
              await container
                  .read(extensionsSettingsProvider.notifier)
                  .setActivePresetId(preset.id);
              await container.read(chatProvider(original.characterId).future);
              await container.read(imageGenSettingsProvider.future);
              await container
                  .read(infoBlocksProvider(original.id).notifier)
                  .refresh();
              final initialJson = jsonEncode(
                (await repo.getBySessionId(original.id)).single.toJson(),
              );
              final updates = <List<InfoBlock>>[];
              final subscription = container.listen(
                infoBlocksProvider(original.id),
                (_, next) => updates.add(next),
              );
              addTearDown(subscription.close);
              final pending = container.read(process);
              if (outcomeKind == 'success') {
                await successfulService.entered.future;
                successfulService.release.complete();
              } else {
                await nativeService.secondSettled.future;
                if (outcomeKind == 'denied') activateCurrent(alias);
                nativeService.releaseFirst.complete();
              }
              final result = await pending;
              final durable = (await repo.getBySessionId(original.id)).single;
              if (outcomeKind == 'denied') {
                expect(nativeService.publicationDenials, 1);
                expect(repo.completionCalls, 0);
                expect(jsonEncode(durable.toJson()), initialJson);
                expect(updates, isEmpty);
                expect(refreshes, 0);
                expect(result, isNull);
              } else {
                expect(nativeService.publicationDenials, 0);
                expect(repo.completionCalls, 1);
                expect(durable.status, BlockRunStatus.done);
                expect(
                  durable.content,
                  outcomeKind == 'success'
                      ? successText
                      : contains('[IMG:ERROR:'),
                );
                if (outcomeKind == 'provider error' &&
                    caller == 'extension image rerun') {
                  // Rerun deliberately rearms BOTH pending and finished images.
                  // The scripted provider must fail both calls, retaining variants.
                  final firstError = ImageTagMarkup.replaceTagWithError(
                    ImageTagMarkup.resetErrorTags(text),
                    0,
                    'Bad state: Synthetic image failure',
                  );
                  expect(
                    durable.content,
                    ImageTagMarkup.replaceTagWithError(
                      firstError,
                      0,
                      'Bad state: Synthetic image failure',
                    ),
                  );
                  expect(nativeService.generationCalls, 2);
                  expect(
                    durable.content,
                    isNot(contains('Future already completed')),
                  );
                } else {
                  expect(durable.content, contains(oldResult));
                }
                expect(updates.last.single.content, durable.content);
                if (caller == 'generated handler')
                  expect(result!.content, durable.content);
              }
            },
          );
        }
      }
    }
    for (final imageType in [
      ImageGenApiType.openrouter,
      ImageGenApiType.novelai,
      ImageGenApiType.naistera,
    ]) {
      for (final afterCommit in [false, true]) {
        test(
          '${imageType.name} native block completion rechecks custody ${afterCommit ? 'after commit without rollback' : 'after the actual repository queue'}',
          () async {
            const alias = 'generated/SYNTHETIC_BLOCK_QUEUED.png';
            const text =
                '[IMG:GEN:{"prompt":"new"}] [IMG:RESULT:$alias|{"prompt":"keep"}]';
            final outcome = ImageTagMarkup.replaceTagWithResult(
              text,
              0,
              'generated/new-public.png',
            );
            final service = _CompletedImageService(outcome);
            final db = AppDatabase.forTesting(NativeDatabase.memory());
            final repo = _ObservedImageBlockRepo(db, holdReturn: afterCommit);
            final original = session(
              'synthetic-block-queue-session',
              'assistant prose',
            );
            const config = BlockConfig(
              id: 'synthetic-block',
              name: 'Image',
              source: BlockSource.carried,
              staticContent: text,
            );
            final placeholder = InfoBlock(
              id: 'synthetic-block-row',
              sessionId: original.id,
              messageId: 'assistant',
              blockId: config.id,
              blockName: 'Image',
              blockType: 'generated',
              content: '',
              status: BlockRunStatus.running,
              createdAt: DateTime.now().millisecondsSinceEpoch,
            );
            final process = Provider<Future<InfoBlock?>>(
              (ref) =>
                  GeneratedBlockHandler(
                    ref: ref,
                    repo: repo,
                    markBlockError:
                        ({required context, required errorMessage}) async =>
                            throw StateError(
                              'Unexpected block error: $errorMessage',
                            ),
                    refreshPanelForMessage: (_, _, _, _, _) {},
                    makeStreamHandler:
                        ({
                          required blockConfig,
                          required charId,
                          required sessionId,
                          required messageId,
                          required placeholder,
                        }) => null,
                    publishStreamingBlockContent: BlockPanelUpdater(
                      ref,
                    ).publishStreamingContent,
                  ).handle(
                    BlockContext(
                      charId: original.characterId,
                      sessionId: original.id,
                      messageId: 'assistant',
                      swipeId: 0,
                      messages: original.messages,
                      blockConfig: config,
                      preset: null,
                      character: const Character(
                        id: 'character',
                        name: 'Synthetic',
                      ),
                      persona: null,
                      previousOutput: null,
                      cancelToken: CancelToken(),
                      placeholderId: placeholder.id,
                      placeholder: placeholder,
                    ),
                  ),
            );
            final container = ProviderContainer(
              overrides: [
                appDbProvider.overrideWithValue(db),
                infoBlocksRepoProvider.overrideWithValue(repo),
                sharedPreferencesProvider.overrideWith((ref) async => prefs),
                credentialVaultProvider.overrideWithValue(vault),
                secretRedactionCoordinatorProvider.overrideWithValue(
                  originalRedaction,
                ),
                imageRoutmyCredentialOwnerProvider.overrideWithValue(owner),
                imageOpenRouterCredentialOwnerProvider.overrideWithValue(
                  openRouterOwner,
                ),
                imageNovelAiCredentialOwnerProvider.overrideWithValue(
                  novelAiOwner,
                ),
                imageNaisteraCredentialOwnerProvider.overrideWithValue(
                  naisteraOwner,
                ),
                imageGenSettingsProvider.overrideWith(
                  () => _ImageSettingsWithOutcome(service, apiType: imageType),
                ),
                chatProvider(
                  original.characterId,
                ).overrideWith(() => _ImageBlockChat(original)),
                apiListProvider.overrideWith(_ImageBlockApis.new),
              ],
            );
            final entered = Completer<void>(), release = Completer<void>();
            addTearDown(() async {
              if (!service.release.isCompleted) service.release.complete();
              if (!release.isCompleted) release.complete();
              if (!repo.release.isCompleted) repo.release.complete();
              container.dispose();
              await db.close();
            });
            await repo.insert(placeholder);
            await container.read(chatProvider(original.characterId).future);
            await container.read(imageGenSettingsProvider.future);
            await container
                .read(infoBlocksProvider(original.id).notifier)
                .refresh();
            final initialJson = jsonEncode(
              (await repo.getBySessionId(original.id)).single.toJson(),
            );
            final updates = <List<InfoBlock>>[];
            final subscription = container.listen(
              infoBlocksProvider(original.id),
              (_, next) => updates.add(next),
            );
            addTearDown(subscription.close);
            final pending = container.read(process);
            await service.entered.future;
            final blocked = db.transaction(() async {
              entered.complete();
              await release.future;
            });
            await entered.future;
            service.release.complete();
            await repo.completionEntered.future;
            String? committedJson;
            if (afterCommit) {
              release.complete();
              await blocked;
              await repo.committed.future;
              committedJson = jsonEncode(
                (await repo.getBySessionId(original.id)).single.toJson(),
              );
            }
            activateCurrent(alias);
            if (afterCommit)
              repo.release.complete();
            else {
              release.complete();
              await blocked;
            }
            expect(await pending, isNull);
            final durable = (await repo.getBySessionId(original.id)).single;
            expect(
              jsonEncode(durable.toJson()),
              afterCommit ? committedJson : initialJson,
            );
            if (afterCommit) {
              expect(durable.content, outcome);
              expect(durable.status, BlockRunStatus.done);
            } else {
              expect(durable.content, isEmpty);
              expect(durable.status, BlockRunStatus.running);
            }
            expect(updates, isEmpty);
          },
        );
      }
    }
    test(
      'real OpenRouter service denial projection cannot become a durable processor replacement',
      () async {
        const alias = 'generated/SYNTHETIC_REAL_SERVICE_OLD.png';
        final text =
            '[IMG:GEN:{"prompt":"new"}] [IMG:ERROR:${jsonEncode({'error': 'public error', 'instruction': '{"prompt":"existing"}', 'variants': '$alias;;generated/public.png'})}]';
        final original = session(
          'synthetic-real-service-session',
          text,
        ).copyWith(draft: 'keep draft', sessionVars: {'concurrent': 'keep'});
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final service = _SettledNativeErrorService.openRouter(openRouterOwner);
        final updates = <ChatState>[];
        final process = Provider<Future<void>>(
          (ref) => ImageGenProcessor(
            ref: ref,
            charId: original.characterId,
            isCurrentOperation: () => true,
            onStateUpdate: updates.add,
          ).process(ChatState(session: original)),
        );
        final container = ProviderContainer(
          overrides: [
            appDbProvider.overrideWithValue(db),
            sharedPreferencesProvider.overrideWith((ref) async => prefs),
            credentialVaultProvider.overrideWithValue(vault),
            secretRedactionCoordinatorProvider.overrideWithValue(
              originalRedaction,
            ),
            imageRoutmyCredentialOwnerProvider.overrideWithValue(owner),
            imageOpenRouterCredentialOwnerProvider.overrideWithValue(
              openRouterOwner,
            ),
            imageGenSettingsProvider.overrideWith(
              () => _ImageSettingsWithOutcome(
                service,
                apiType: ImageGenApiType.openrouter,
              ),
            ),
            activeApiConfigProvider.overrideWithValue(
              const ApiConfig(
                id: 'synthetic-api',
                endpoint: 'https://unused.invalid',
                apiKey: '',
                model: 'synthetic',
              ),
            ),
          ],
        );
        addTearDown(() async {
          if (!service.releaseFirst.isCompleted)
            service.releaseFirst.complete();
          container.dispose();
          await db.close();
        });
        ChatSessionService.clearCache();
        final repo = container.read(chatRepoProvider);
        await repo.put(original);
        final originalStored = jsonEncode(
          (await repo.getById(original.id))!.toJson(),
        );
        await container.read(imageGenSettingsProvider.future);
        final pending = container.read(process);
        await service.secondSettled.future;
        activateCurrent(alias);
        service.releaseFirst.complete();
        await pending;
        expect(
          jsonEncode((await repo.getById(original.id))!.toJson()),
          originalStored,
        );
        expect(ChatSessionService.cacheSize, 0);
        expect(updates.last.isGeneratingImage, isFalse);
        expect(updates.last.messages.single.content, isNot(contains(alias)));
        expect(
          updates.last.messages.single.content,
          isNot(contains('generated/public.png')),
        );
        expect(updates.last.messages.single.content, contains('existing'));
        expect(updates.last.session!.draft, 'keep draft');
      },
    );

    for (final longDetail in [false, true]) {
      test(
        'settled native outcome rechecks policy B before markup/onError (long=$longDetail)',
        () async {
          final alias = longDetail
              ? 'SYNTHETIC_BOUNDARY_${List.filled(240, 'x').join()}'
              : lateAlias;
          final service = _SettledNativeErrorService(owner, alias);
          final nativeCurrent = owner.captureGuard();
          final updates = <String>[];
          final errors = <String>[];
          addTearDown(() {
            if (!service.releaseFirst.isCompleted)
              service.releaseFirst.complete();
          });
          final pending = service.processMessageImages(
            text: '[IMG:GEN:{"prompt":"first"}] [IMG:GEN:{"prompt":"second"}]',
            settings: const ImageGenSettings(
              enabled: true,
              apiType: ImageGenApiType.routmy,
              concurrentGeneration: true,
            ),
            llmEndpoint: 'https://unused.invalid',
            llmApiKey: '',
            llmModel: 'synthetic',
            onUpdate: updates.add,
            onError: errors.add,
          );
          await service.secondSettled.future;
          // Let _runOne settle the second outcome; instruction order still parks
          // its actual publication behind the first provider's explicit gate.
          await Future<void>.delayed(Duration.zero);
          expect(updates, isEmpty);
          activateCurrent(alias);
          service.releaseFirst.complete();
          final result = await pending;
          expect(nativeCurrent(), isTrue);
          for (final value in [result, ...updates, ...errors]) {
            expect(value, isNot(contains(nativeKey)));
            expect(value, isNot(contains(alias)));
            expect(
              value,
              isNot(contains(alias.substring(0, longDetail ? 160 : 15))),
            );
          }
          expect(errors, hasLength(2));
          expect(result, contains('[IMG:ERROR:'));
          expect(result, contains(r'\u005d'));
        },
      );
    }

    test(
      'captured UI sanitizer retains A and consults B/new injected aliases before limits',
      () {
        final errors = ImageGenErrorSanitizer(routmyCredentials: owner);
        activateCurrent(lateAlias);
        const laterOriginalAlias = 'SYNTHETIC_LATE_ORIGINAL_ALIAS';
        originalRedaction.registerSecret(laterOriginalAlias);
        final safe = errors.sanitize(
          '$nativeKey $laterOriginalAlias $lateAlias',
        );
        expect(safe, isNot(contains(nativeKey)));
        expect(safe, isNot(contains(laterOriginalAlias)));
        expect(safe, isNot(contains(lateAlias)));
        expect(
          errors.sanitize(List.filled(300, 'x').join()),
          SecretRedactor.limited,
        );
        activeErrorRedactor = SecretRedactor(maxInputLength: 32);
        expect(
          errors.sanitize(List.filled(40, 'x').join()),
          SecretRedactor.limited,
        );
      },
    );

    for (final imageType in [
      ImageGenApiType.routmy,
      ImageGenApiType.openrouter,
    ]) {
      for (final afterCommit in [false, true]) {
        for (final existingError in [false, true]) {
          test(
            '${imageType.name} policy B activates ${afterCommit ? 'after commit' : 'inside queued callback window'} before publication (existing error=$existingError)',
            () async {
              final db = AppDatabase.forTesting(NativeDatabase.memory());
              final gatedRepo = _CommittedImageRepo(db);
              final error =
                  'HTTP 400 $lateAlias ${Uri.encodeComponent(lateAlias)}';
              final outcome =
                  '[IMG:ERROR:${jsonEncode({'error': error, 'instruction': '{"prompt":"synthetic"}', 'variants': 'generated/synthetic-kept.png'})}]';
              final service = _CompletedImageService(outcome);
              final pendingText = '[IMG:GEN:{"prompt":"synthetic"}]';
              final originalText = existingError
                  ? '$pendingText [IMG:ERROR:${jsonEncode({'error': lateAlias, 'instruction': '{"prompt":"existing"}', 'variants': 'generated/existing-kept.png'})}]'
                  : pendingText;
              final original = ChatSession(
                id: 'synthetic-image-session',
                characterId: 'synthetic-character',
                sessionIndex: 0,
                draft: 'keep draft',
                sessionVars: {'concurrent': 'keep'},
                messages: [
                  ChatMessage(
                    id: 'assistant',
                    role: 'assistant',
                    content: originalText,
                    swipes: [originalText],
                    agentSwipes: [AgentSwipe(content: originalText)],
                    swipesMeta: [
                      {
                        'preserveUnknown': 'keep',
                        'agentSwipes': [
                          {'content': originalText, 'kind': 'final'},
                        ],
                      },
                    ],
                  ),
                ],
              );
              final updates = <ChatState>[];
              final nativeCurrent = owner.captureGuard();
              final process = Provider<Future<void>>(
                (ref) => ImageGenProcessor(
                  ref: ref,
                  charId: original.characterId,
                  isCurrentOperation: () => true,
                  onStateUpdate: updates.add,
                ).process(ChatState(session: original)),
              );
              final container = ProviderContainer(
                overrides: [
                  appDbProvider.overrideWithValue(db),
                  if (afterCommit)
                    chatRepoProvider.overrideWithValue(gatedRepo),
                  sharedPreferencesProvider.overrideWith((ref) async => prefs),
                  credentialVaultProvider.overrideWithValue(vault),
                  secretRedactionCoordinatorProvider.overrideWithValue(
                    originalRedaction,
                  ),
                  imageRoutmyCredentialOwnerProvider.overrideWithValue(owner),
                  imageOpenRouterCredentialOwnerProvider.overrideWithValue(
                    openRouterOwner,
                  ),
                  imageGenSettingsProvider.overrideWith(
                    () =>
                        _ImageSettingsWithOutcome(service, apiType: imageType),
                  ),
                  activeApiConfigProvider.overrideWithValue(
                    const ApiConfig(
                      id: 'synthetic-api',
                      endpoint: 'https://unused.invalid',
                      apiKey: '',
                      model: 'synthetic',
                    ),
                  ),
                ],
              );
              final transactionEntered = Completer<void>();
              final releaseTransaction = Completer<void>();
              addTearDown(() async {
                if (!service.release.isCompleted) service.release.complete();
                if (!releaseTransaction.isCompleted)
                  releaseTransaction.complete();
                if (!gatedRepo.release.isCompleted)
                  gatedRepo.release.complete();
                container.dispose();
                await db.close();
              });
              ChatSessionService.clearCache();
              final repo = container.read(chatRepoProvider);
              await repo.put(original);
              await container.read(imageGenSettingsProvider.future);
              final pending = container.read(process);
              await service.entered.future;
              final blocked = db.transaction(() async {
                transactionEntered.complete();
                await releaseTransaction.future;
              });
              await transactionEntered.future;
              service.release.complete();
              await Future<void>.delayed(Duration.zero);
              expect(ChatSessionService.cacheSize, 0);
              ChatSession? committedBeforePolicy;
              if (afterCommit) {
                releaseTransaction.complete();
                await blocked;
                await gatedRepo.committed.future;
                committedBeforePolicy = await repo.getById(original.id);
              }
              final publishedBeforePolicyChange = updates.length;
              activateCurrent(lateAlias);
              if (afterCommit) {
                gatedRepo.release.complete();
              } else {
                releaseTransaction.complete();
                await blocked;
              }
              await pending;
              expect(nativeCurrent(), isTrue);
              final durable = (await repo.getById(original.id))!;
              expect(durable.draft, original.draft);
              expect(durable.sessionVars, original.sessionVars);
              expect(
                durable.messages.single.content,
                contains('generated/synthetic-kept.png'),
              );
              expect(
                durable.messages.single.content,
                contains(r'\"prompt\":\"synthetic\"'),
              );
              if (afterCommit) {
                // Already committed facts are not speculatively rewritten for cache.
                expect(durable.messages.single.content, contains(lateAlias));
                expect(
                  jsonEncode(durable.toJson()),
                  jsonEncode(committedBeforePolicy!.toJson()),
                );
                expect(ChatSessionService.cacheSize, 0);
              } else {
                expect(
                  durable.messages.single.content,
                  isNot(contains(lateAlias)),
                );
                expect(
                  durable.messages.single.content,
                  isNot(contains(Uri.encodeComponent(lateAlias))),
                );
                expect(
                  durable.messages.single.swipes.single,
                  durable.messages.single.content,
                );
                expect(
                  durable.messages.single.agentSwipes.single.content,
                  durable.messages.single.content,
                );
                expect(ChatSessionService.cacheSize, 1);
              }
              for (final update in updates.skip(publishedBeforePolicyChange)) {
                expect(
                  jsonEncode(update.session!.toJson()),
                  isNot(contains(lateAlias)),
                );
                expect(
                  jsonEncode(update.session!.toJson()),
                  isNot(contains(Uri.encodeComponent(lateAlias))),
                );
              }
              expect(updates.last.isGeneratingImage, isFalse);
              if (existingError && afterCommit) {
                // The flag-clearing fallback is a passive error projection, not an
                // invented durable overwrite, and keeps all original variant metadata.
                expect(
                  updates.last.messages.single.content,
                  contains(pendingText),
                );
                expect(
                  updates.last.messages.single.content,
                  contains('generated/existing-kept.png'),
                );
                expect(
                  updates
                      .last
                      .messages
                      .single
                      .swipesMeta
                      .single['preserveUnknown'],
                  'keep',
                );
                expect(
                  updates.last.messages.single.swipesMeta.single['agentSwipes'],
                  isA<List<Object?>>(),
                );
              }
            },
          );
        }
      }
    }

    for (final imageType in [
      ImageGenApiType.openrouter,
      ImageGenApiType.novelai,
      ImageGenApiType.naistera,
    ]) {
      for (final oldBlockKind in [
        'legacy result',
        'HTML src',
        'HTML variant',
        'error variant',
      ]) {
        for (final afterCommit in [false, true]) {
          test(
            '${imageType.name} denied original $oldBlockKind across all message variants ${afterCommit ? 'after commit' : 'while queued'} is display-only',
            () async {
              const alias = 'generated/SYNTHETIC_OLD_VARIANT.png';
              const pendingText = '[IMG:GEN:{"prompt":"new"}]';
              const instruction = '{"prompt":"existing"}';
              final oldBlock = switch (oldBlockKind) {
                'HTML src' => ImageTagMarkup.encodeResultElement(
                  const ImageBlockPayload(
                    paths: [alias],
                    instruction: instruction,
                  ),
                ),
                'HTML variant' => ImageTagMarkup.encodeResultElement(
                  const ImageBlockPayload(
                    paths: ['generated/public.png', alias],
                    instruction: instruction,
                  ),
                ),
                'error variant' =>
                  '[IMG:ERROR:${jsonEncode({'error': 'public error', 'instruction': instruction, 'variants': '$alias;;*generated/public.png'})}]',
                _ => '[IMG:RESULT:$alias;;*generated/public.png|$instruction]',
              };
              final originalText = 'Keep prose. $pendingText $oldBlock';
              final archived = 'Keep archived prose. $oldBlock';
              final original = ChatSession(
                id: 'synthetic-or-old-result-session',
                characterId: 'synthetic-character',
                sessionIndex: 0,
                draft: 'keep draft',
                sessionVars: {'concurrent': 'keep'},
                messages: [
                  ChatMessage(
                    id: 'assistant',
                    role: 'assistant',
                    content: originalText,
                    reasoning: 'keep reasoning',
                    swipes: [originalText, archived],
                    agentSwipes: [
                      AgentSwipe(content: originalText),
                      AgentSwipe(content: archived),
                    ],
                    swipesMeta: [
                      {
                        'preserveUnknown': 'keep',
                        'agentSwipes': [
                          {'content': originalText, 'kind': 'final'},
                          {'content': archived, 'kind': 'cleaned'},
                        ],
                      },
                      {
                        'preserveUnknown': 'keep archived',
                        'agentSwipes': [
                          {'content': archived, 'kind': 'final'},
                        ],
                      },
                    ],
                  ),
                ],
              );
              final originalJson = jsonEncode(original.toJson());
              final outcome = ImageTagMarkup.replaceTagWithResult(
                originalText,
                0,
                'generated/new.png',
              );
              final db = AppDatabase.forTesting(NativeDatabase.memory());
              final gatedRepo = _CommittedImageRepo(db);
              final service = _CompletedImageService(outcome);
              final updates = <ChatState>[];
              final process = Provider<Future<void>>(
                (ref) => ImageGenProcessor(
                  ref: ref,
                  charId: original.characterId,
                  isCurrentOperation: () => true,
                  onStateUpdate: updates.add,
                ).process(ChatState(session: original)),
              );
              final container = ProviderContainer(
                overrides: [
                  appDbProvider.overrideWithValue(db),
                  if (afterCommit)
                    chatRepoProvider.overrideWithValue(gatedRepo),
                  sharedPreferencesProvider.overrideWith((ref) async => prefs),
                  credentialVaultProvider.overrideWithValue(vault),
                  secretRedactionCoordinatorProvider.overrideWithValue(
                    originalRedaction,
                  ),
                  imageRoutmyCredentialOwnerProvider.overrideWithValue(owner),
                  imageOpenRouterCredentialOwnerProvider.overrideWithValue(
                    openRouterOwner,
                  ),
                  imageNovelAiCredentialOwnerProvider.overrideWithValue(
                    novelAiOwner,
                  ),
                  imageNaisteraCredentialOwnerProvider.overrideWithValue(
                    naisteraOwner,
                  ),
                  imageGenSettingsProvider.overrideWith(
                    () =>
                        _ImageSettingsWithOutcome(service, apiType: imageType),
                  ),
                  activeApiConfigProvider.overrideWithValue(
                    const ApiConfig(
                      id: 'synthetic-api',
                      endpoint: 'https://unused.invalid',
                      apiKey: '',
                      model: 'synthetic',
                    ),
                  ),
                ],
              );
              final transactionEntered = Completer<void>(),
                  releaseTransaction = Completer<void>();
              addTearDown(() async {
                if (!service.release.isCompleted) service.release.complete();
                if (!releaseTransaction.isCompleted)
                  releaseTransaction.complete();
                if (!gatedRepo.release.isCompleted)
                  gatedRepo.release.complete();
                container.dispose();
                await db.close();
              });
              ChatSessionService.clearCache();
              final repo = container.read(chatRepoProvider);
              await repo.put(original);
              final storedOriginal = jsonEncode(
                (await repo.getById(original.id))!.toJson(),
              );
              await container.read(imageGenSettingsProvider.future);
              final pending = container.read(process);
              await service.entered.future;
              final blocked = db.transaction(() async {
                transactionEntered.complete();
                await releaseTransaction.future;
              });
              await transactionEntered.future;
              service.release.complete();
              await Future<void>.delayed(Duration.zero);
              String? committedBeforePolicy;
              if (afterCommit) {
                releaseTransaction.complete();
                await blocked;
                await gatedRepo.committed.future;
                committedBeforePolicy = jsonEncode(
                  (await repo.getById(original.id))!.toJson(),
                );
              }
              final countBeforePolicy = updates.length;
              activateCurrent(alias);
              if (afterCommit) {
                gatedRepo.release.complete();
              } else {
                releaseTransaction.complete();
                await blocked;
              }
              await pending;
              final durable = (await repo.getById(original.id))!;
              expect(
                jsonEncode(durable.toJson()),
                afterCommit ? committedBeforePolicy : storedOriginal,
              );
              expect(jsonEncode(original.toJson()), originalJson);
              expect(ChatSessionService.cacheSize, 0);
              for (final update in updates.skip(countBeforePolicy)) {
                expect(
                  jsonEncode(update.session!.toJson()),
                  isNot(contains(alias)),
                );
                final message = update.messages.single;
                final contents = [
                  message.content,
                  ...message.swipes,
                  ...message.agentSwipes.map((swipe) => swipe.content),
                  for (final meta in message.swipesMeta)
                    for (final swipe
                        in (meta['agentSwipes'] as List)
                            .cast<Map<Object?, Object?>>())
                      swipe['content'] as String,
                ];
                for (final content in contents) {
                  expect(content, contains('existing'));
                  expect(content, isNot(contains('generated/public.png')));
                  expect(
                    ImageTagMarkup.scanImageBlocks(
                      content,
                    ).every((block) => block.paths.isEmpty),
                    isTrue,
                  );
                }
                expect(message.content, contains('Keep prose. $pendingText'));
                expect(message.reasoning, 'keep reasoning');
                expect(message.swipesMeta.first['preserveUnknown'], 'keep');
                expect(
                  message.swipesMeta.last['preserveUnknown'],
                  'keep archived',
                );
                expect(update.session!.draft, original.draft);
                expect(update.session!.sessionVars, original.sessionVars);
              }
              expect(updates.last.isGeneratingImage, isFalse);
            },
          );
        }
      }
    }
    for (final afterCommit in [false, true]) {
      test(
        'OpenRouter whole result alias ${afterCommit ? 'after committed callback' : 'inside queued callback'} cannot publish/cache',
        () async {
          const path = 'generated/SYNTHETIC_PUBLIC_RESULT.png';
          const pendingText = '[IMG:GEN:{"prompt":"synthetic"}]';
          const outcome = '[IMG:RESULT:$path]';
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          final gatedRepo = _CommittedImageRepo(db);
          final service = _CompletedImageService(outcome);
          final original = session('synthetic-or-result-session', pendingText);
          final updates = <ChatState>[];
          final process = Provider<Future<void>>(
            (ref) => ImageGenProcessor(
              ref: ref,
              charId: original.characterId,
              isCurrentOperation: () => true,
              onStateUpdate: updates.add,
            ).process(ChatState(session: original)),
          );
          final container = ProviderContainer(
            overrides: [
              appDbProvider.overrideWithValue(db),
              if (afterCommit) chatRepoProvider.overrideWithValue(gatedRepo),
              sharedPreferencesProvider.overrideWith((ref) async => prefs),
              credentialVaultProvider.overrideWithValue(vault),
              secretRedactionCoordinatorProvider.overrideWithValue(
                originalRedaction,
              ),
              imageRoutmyCredentialOwnerProvider.overrideWithValue(owner),
              imageOpenRouterCredentialOwnerProvider.overrideWithValue(
                openRouterOwner,
              ),
              imageGenSettingsProvider.overrideWith(
                () => _ImageSettingsWithOutcome(
                  service,
                  apiType: ImageGenApiType.openrouter,
                ),
              ),
              activeApiConfigProvider.overrideWithValue(
                const ApiConfig(
                  id: 'synthetic-api',
                  endpoint: 'https://unused.invalid',
                  apiKey: '',
                  model: 'synthetic',
                ),
              ),
            ],
          );
          final transactionEntered = Completer<void>(),
              releaseTransaction = Completer<void>();
          addTearDown(() async {
            if (!service.release.isCompleted) service.release.complete();
            if (!releaseTransaction.isCompleted) releaseTransaction.complete();
            if (!gatedRepo.release.isCompleted) gatedRepo.release.complete();
            container.dispose();
            await db.close();
          });
          ChatSessionService.clearCache();
          final repo = container.read(chatRepoProvider);
          await repo.put(original);
          await container.read(imageGenSettingsProvider.future);
          final pending = container.read(process);
          await service.entered.future;
          final blocked = db.transaction(() async {
            transactionEntered.complete();
            await releaseTransaction.future;
          });
          await transactionEntered.future;
          service.release.complete();
          await Future<void>.delayed(Duration.zero);
          if (afterCommit) {
            releaseTransaction.complete();
            await blocked;
            await gatedRepo.committed.future;
          }
          final countBeforePolicy = updates.length;
          activateCurrent(path);
          if (afterCommit) {
            gatedRepo.release.complete();
          } else {
            releaseTransaction.complete();
            await blocked;
          }
          await pending;
          final durable = (await repo.getById(original.id))!;
          expect(
            durable.messages.single.content,
            afterCommit ? outcome : pendingText,
          );
          expect(ChatSessionService.cacheSize, 0);
          expect(
            updates
                .skip(countBeforePolicy)
                .every(
                  (update) => update.messages.every(
                    (message) => !message.content.contains(path),
                  ),
                ),
            isTrue,
          );
          expect(updates.last.isGeneratingImage, isFalse);
        },
      );
    }
  });

  group('Imagen green swipes', () {
    test('regeneration rewrites the active swipe instead of adding one', () {
      final message = ChatMessage(
        id: 'assistant',
        role: 'assistant',
        content: 'She smiles. [IMG:RESULT:/old.png|{"prompt":"scene"}]',
        isError: true,
        swipes: const ['She smiles. [IMG:RESULT:/old.png|{"prompt":"scene"}]'],
        swipesMeta: [
          <String, dynamic>{
            'isError': true,
            'agentSwipes': [
              const AgentSwipe(
                content: 'She smiles. [IMG:RESULT:/old.png|{"prompt":"scene"}]',
              ).toJson(),
            ],
            'agentSwipeId': 0,
          },
        ],
        agentSwipes: const [
          AgentSwipe(
            content: 'She smiles. [IMG:RESULT:/old.png|{"prompt":"scene"}]',
          ),
        ],
      );

      final result = ImageGenProcessor.resetImageContentInPlace(
        message,
        'She smiles. [IMG:GEN:{"prompt":"scene"}]',
      );

      expect(result.swipes, ['She smiles. [IMG:GEN:{"prompt":"scene"}]']);
      expect(result.swipeId, 0);
      expect(result.content, 'She smiles. [IMG:GEN:{"prompt":"scene"}]');
      expect(result.agentSwipes.single.content, contains('[IMG:GEN:'));
      expect(result.isError, isFalse);
      expect(result.swipesMeta.single.containsKey('isError'), isFalse);
      expect(
        AgentSwipe.fromJson(
          Map<String, dynamic>.from(
            (result.swipesMeta[0]['agentSwipes'] as List).single as Map,
          ),
        ).content,
        contains('[IMG:GEN:'),
      );
    });

    test('image completion keeps green, blue and metadata content aligned', () {
      final candidate = ChatMessage(
        id: 'assistant',
        role: 'assistant',
        content: '[IMG:GEN]',
        swipes: const ['old', '[IMG:GEN]'],
        swipeId: 1,
        swipesMeta: [
          <String, dynamic>{},
          <String, dynamic>{
            'agentSwipes': [const AgentSwipe(content: '[IMG:GEN]').toJson()],
          },
        ],
        agentSwipes: const [AgentSwipe(content: '[IMG:GEN]')],
      );

      final result = ImageGenProcessor.replaceActiveImageContent(
        candidate,
        '[IMG:RESULT:/new.png]',
      );

      expect(result.content, '[IMG:RESULT:/new.png]');
      expect(result.swipes, ['old', '[IMG:RESULT:/new.png]']);
      expect(result.agentSwipes.single.content, '[IMG:RESULT:/new.png]');
      final stored = AgentSwipe.fromJson(
        Map<String, dynamic>.from(
          (result.swipesMeta[1]['agentSwipes'] as List).single as Map,
        ),
      );
      expect(stored.content, '[IMG:RESULT:/new.png]');
    });
  });

  group('regenerating a failed block', () {
    const text =
        '[IMG:RESULT:/kept.png|{"prompt":"kept"}] '
        '[IMG:ERROR:{"error":"HTTP 502","instruction":"{\\"prompt\\":\\"lost\\"}"}]';

    test('resets only the failed block and keeps the finished image', () {
      final result = ImageRecoveryService.resetImgErrorTagsToGen(text);

      expect(result, contains('[IMG:RESULT:/kept.png|{"prompt":"kept"}]'));
      expect(result, contains('[IMG:GEN:{"prompt":"lost"}]'));
      expect(result, isNot(contains('[IMG:ERROR:')));
    });

    test('a full retry still resets every block', () {
      final result = ImageRecoveryService.resetImgTagsToGen(text);

      expect(result, isNot(contains('[IMG:RESULT:')));
      // The finished image rides along in the pending tag, so the retry adds a
      // variant to that block instead of replacing its only picture.
      expect(result, contains('[IMG:GEN:@/kept.png|{"prompt":"kept"}]'));
      expect(result, contains('[IMG:GEN:{"prompt":"lost"}]'));
    });
  });
}
