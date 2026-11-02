import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/image_routmy_credential_owner.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/preferences/tracked_shared_preferences.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/image_recovery_service.dart';
import 'package:glaze_flutter/features/chat/services/image_gen_processor.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_models.dart';
import 'package:glaze_flutter/features/image_gen/image_gen_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_service.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'credentials/fake_credential_storage.dart';

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
  }) async {
    entered.complete();
    await release.future;
    return outcome;
  }
}

class _ImageSettingsWithOutcome extends ImageGenSettingsNotifier {
  _ImageSettingsWithOutcome(this.service);
  final _CompletedImageService service;
  @override
  Future<ImageGenSettings> build() async =>
      const ImageGenSettings(enabled: true, apiType: ImageGenApiType.routmy);
  @override
  Future<ImageGenService> getServiceAsync() async => service;
}

// The second native error settles while the first instruction is still pending.
// Only provider results are scripted: no model, HTTP or image file is invoked.
class _SettledNativeErrorService extends ImageGenService {
  _SettledNativeErrorService(this.owner, this.detail)
    : super(ImageStorageService('synthetic-unused'), routmyCredentials: owner);

  final ImageRoutmyCredentialOwner owner;
  final String detail;
  final secondSettled = Completer<void>();
  final releaseFirst = Completer<void>();

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
    if (prompt == 'first') {
      await releaseFirst.future;
      return Uint8List(0);
    }
    try {
      return await owner.withApiKey<Uint8List>(
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
  final committed = Completer<void>();
  final release = Completer<void>();

  @override
  Future<ChatSession?> mutateMessage({
    required String sessionId,
    required String messageId,
    required ChatMessage? Function(ChatMessage) mutate,
    required int updatedAt,
  }) async {
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

  for (final outcome in [
    '[IMG:RESULT:generated/synthetic-retired.png]',
    '[IMG:ERROR:{"error":"synthetic retired error"}]',
  ]) {
    test(
      'native rotation while actual message callback is queued drops $outcome and cache publication',
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
            imageGenSettingsProvider.overrideWith(
              () => _ImageSettingsWithOutcome(service),
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
        await owner.setApiKey('SYNTHETIC_REPLACEMENT_IMAGE_KEY');
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

  group('image errors use the actual downstream sink', () {
    late SharedPreferences prefs;
    late CredentialVault vault;
    late SecretRedactionCoordinator originalRedaction;
    late SecretRedactionCoordinator currentRedaction;
    late ImageRoutmyCredentialOwner owner;
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
      addTearDown(() {
        activeErrorRedactor = previousSink;
        owner.dispose();
        originalRedaction.dispose();
        currentRedaction.dispose();
        ChatSessionService.clearCache();
      });
    });

    void activateCurrent(String alias) {
      currentRedaction.registerSecret(alias);
      activeErrorRedactor = currentRedaction.redactor;
    }

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

    for (final afterCommit in [false, true]) {
      for (final existingError in [false, true]) {
        test(
          'policy B activates ${afterCommit ? 'after commit' : 'inside queued callback window'} before publication (existing error=$existingError)',
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
                if (afterCommit) chatRepoProvider.overrideWithValue(gatedRepo),
                sharedPreferencesProvider.overrideWith((ref) async => prefs),
                credentialVaultProvider.overrideWithValue(vault),
                secretRedactionCoordinatorProvider.overrideWithValue(
                  originalRedaction,
                ),
                imageRoutmyCredentialOwnerProvider.overrideWithValue(owner),
                imageGenSettingsProvider.overrideWith(
                  () => _ImageSettingsWithOutcome(service),
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
                isA<List>(),
              );
            }
          },
        );
      }
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
