import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/db/repositories/info_blocks_repository.dart';
import '../../../../core/models/api_config.dart';
import '../../../../core/state/db_provider.dart';
import '../../../../core/utils/error_format.dart';
import '../../../image_gen/image_gen_provider.dart';
import '../../../image_gen/image_gen_models.dart';
import '../../../image_gen/services/image_gen_service.dart';
import '../../../image_gen/services/image_tag_markup.dart';
import '../../../settings/api_list_provider.dart';
import '../../models/block_run_status.dart';
import '../../models/info_block.dart';
import '../../providers/info_blocks_provider.dart';
import 'block_context.dart';
import 'block_handler.dart';

/// A denial carries no text: the image service's projection is display-only,
/// not a successful block result. The original guard travels to queued sinks.
class BlockImageRenderResult {
  const BlockImageRenderResult(this.content, this.isPublishable);
  final String? content;
  final bool Function(String) isPublishable;
}

/// Draws the pictures a block's content asks for.
///
/// This is the chat's own image pipeline, not a copy of it: the content goes
/// through [ImageGenService.processMessageImages], the same call that turns
/// `[IMG:GEN]` in a character's reply into a picture. A block therefore gets
/// what a message has always got and what the old block-only renderer never
/// did — every tag in the content rather than just the first, a retryable
/// error card in place of a tag that failed instead of the whole block going
/// red, concurrent generation when the settings ask for it, and the reference
/// images and `useSameEndpoint` wiring the shared service resolves.
///
/// Nothing here looks at the block's type. A block draws pictures because its
/// content carries image tags, exactly as a message does.
class BlockImageRenderer {
  const BlockImageRenderer({
    required this.ref,
    required this.repo,
    required this.publishStreamingBlockContent,
  });

  final Ref ref;
  final InfoBlocksRepository repo;
  final StreamingBlockPublisher publishStreamingBlockContent;

  // Native image results only, not a general block mutation/authorization API.
  // Keep custody attached through the existing InfoBlock return/callback seam.
  static final _resultPublications = Expando<bool Function(String)>();
  static void retainResultPublication(
    InfoBlock block,
    bool Function(String) guard,
  ) => _resultPublications[block] = guard;
  static void carryResultPublication(InfoBlock from, InfoBlock to) {
    final guard = _resultPublications[from];
    if (guard != null) retainResultPublication(to, guard);
  }

  static bool canPublishResult(InfoBlock block, {String? content}) =>
      _resultPublications[block]?.call(content ?? block.content) ?? true;

  bool _current(BlockContext context) =>
      ref.mounted &&
      !context.cancelToken.isCancelled &&
      context.placeholderId == context.placeholder.id &&
      context.sessionId == context.placeholder.sessionId &&
      context.messageId == context.placeholder.messageId &&
      context.blockConfig.id == context.placeholder.blockId &&
      context.swipeId == context.placeholder.swipeId &&
      context.agentSwipeId == context.placeholder.agentSwipeId &&
      identical(ref.read(infoBlocksRepoProvider), repo);

  /// Whether [content] has anything for this renderer to do.
  static bool hasWork(String content) =>
      ImageTagMarkup.hasImageGenTags(content);

  /// Resolves image tags while retaining original native publication custody.
  ///
  /// Ordinary provider failures stay retryable error cards. Publication denial
  /// is distinct and never returns its display projection as block content.
  Future<BlockImageRenderResult> render({
    required BlockContext context,
    required String sourceContent,
  }) async {
    if (!_current(context)) {
      return BlockImageRenderResult(null, (_) => false);
    }
    final routmy = ref.read(imageRoutmyCredentialOwnerProvider);
    final openrouter = ref.read(imageOpenRouterCredentialOwnerProvider);
    final ownsRoutmy = routmy.captureGuard();
    final ownsOpenRouter = openrouter.captureGuard();
    final novelai = ref.read(imageNovelAiCredentialOwnerProvider);
    final ownsNovelAi = novelai.captureGuard();
    final naistera = ref.read(imageNaisteraCredentialOwnerProvider);
    final ownsNaistera = naistera.captureGuard();
    final settings = ref.read(imageGenSettingsProvider).value;
    final errors = ImageGenErrorSanitizer(
      routmyCredentials: routmy,
      openrouterCredentials: openrouter,
      novelaiCredentials: novelai,
      naisteraCredentials: naistera,
      checkResults: () =>
          settings?.apiType == ImageGenApiType.openrouter ||
          settings?.apiType == ImageGenApiType.novelai ||
          settings?.apiType == ImageGenApiType.naistera,
      checkNaisteraResults: () => settings?.apiType == ImageGenApiType.naistera,
    );
    var denied = false;
    bool ownsPublication() =>
        !denied &&
        _current(context) &&
        (settings?.apiType != ImageGenApiType.routmy ||
            (ownsRoutmy() &&
                identical(
                  ref.read(imageRoutmyCredentialOwnerProvider),
                  routmy,
                ))) &&
        (settings?.apiType != ImageGenApiType.openrouter ||
            (ownsOpenRouter() &&
                identical(
                  ref.read(imageOpenRouterCredentialOwnerProvider),
                  openrouter,
                ))) &&
        (settings?.apiType != ImageGenApiType.novelai ||
            (ownsNovelAi() &&
                identical(
                  ref.read(imageNovelAiCredentialOwnerProvider),
                  novelai,
                ))) &&
        (settings?.apiType != ImageGenApiType.naistera ||
            (ownsNaistera() &&
                identical(
                  ref.read(imageNaisteraCredentialOwnerProvider),
                  naistera,
                )));
    bool isPublishable(String content) =>
        ownsPublication() &&
        errors.messageErrorsAreCurrent(
          errors.sanitizeMessageErrors(sourceContent),
        ) &&
        errors.messageErrorsAreCurrent(
          errors.sanitizeMessageErrors(context.placeholder.content),
        ) &&
        errors.messageErrorsAreCurrent(content);
    BlockImageRenderResult result(String content) {
      final safe = errors.sanitizeMessageErrors(content);
      return BlockImageRenderResult(
        isPublishable(safe) ? safe : null,
        isPublishable,
      );
    }

    if (settings == null || !hasWork(sourceContent))
      return result(sourceContent);

    try {
      final service = await ref
          .read(imageGenSettingsProvider.notifier)
          .getServiceAsync();
      if (!ownsPublication())
        return BlockImageRenderResult(null, isPublishable);
      final apiConfig = await _apiConfigFor(context);
      if (!ownsPublication())
        return BlockImageRenderResult(null, isPublishable);
      final recentContexts = await _recentImageContexts(context);
      if (!ownsPublication())
        return BlockImageRenderResult(null, isPublishable);
      final rendered = await service.processMessageImages(
        text: sourceContent,
        settings: settings,
        // Empty here used to disable the "use the chat's endpoint" setting for
        // blocks without saying so; the block's own connection is what that
        // setting means when an ext block is the one drawing.
        llmEndpoint: apiConfig?.endpoint ?? '',
        llmApiKey: apiConfig?.apiKey ?? '',
        llmModel: apiConfig?.model ?? '',
        character: context.character,
        persona: context.persona,
        recentImageContexts: recentContexts,
        cancelToken: context.cancelToken,
        onPublicationDenied: () => denied = true,
        onUpdate: (updated) {
          final safe = errors.sanitizeMessageErrors(updated);
          if (!isPublishable(safe)) return;
          final streamed = context.placeholder.copyWith();
          retainResultPublication(streamed, isPublishable);
          publishStreamingBlockContent(
            charId: context.charId,
            sessionId: context.sessionId,
            messageId: context.messageId,
            placeholder: streamed,
            content: safe,
            force: true,
          );
        },
      );
      return result(rendered);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e))
        return BlockImageRenderResult(null, isPublishable);
      return result(
        ImageTagMarkup.replaceTagWithError(sourceContent, 0, formatError(e)),
      );
    } catch (e) {
      return result(
        ImageTagMarkup.replaceTagWithError(sourceContent, 0, formatError(e)),
      );
    }
  }

  /// Re-draws the pictures of a block that already has some.
  ///
  /// Used by the panel's "Image" control, which repeats only the drawing and
  /// never asks the model for a new description. [blockIndex] narrows it to the
  /// one picture the reader tapped.
  Future<InfoBlock?> rerun({
    required BlockContext context,
    int? blockIndex,
  }) async {
    final existing = context.placeholder.content;
    if (existing.isEmpty) return null;

    final pending = blockIndex != null
        ? ImageTagMarkup.resetImageBlockAt(existing, blockIndex)
        : ImageTagMarkup.resetErrorTags(existing);
    // Unchanged text means the content addressed nothing that could be redrawn.
    if (pending == existing && !hasWork(existing)) return null;

    final rendered = await render(context: context, sourceContent: pending);
    final content = rendered.content;
    if (content == null || !rendered.isPublishable(content)) return null;
    final done = await repo.completeImageRender(
      target: context.placeholder,
      content: content,
      isPublishable: rendered.isPublishable,
    );
    if (done == null || !rendered.isPublishable(done.content)) return null;
    retainResultPublication(done, rendered.isPublishable);
    if (!canPublishResult(done)) return null;
    ref.read(infoBlocksProvider(context.sessionId).notifier).addOrReplace(done);
    return done;
  }

  /// The block's own connection, falling back to the chat's active one.
  Future<ApiConfig?> _apiConfigFor(BlockContext context) async {
    final configs = await ref.read(apiListProvider.future);
    if (!_current(context)) return null;
    if (configs.isEmpty) return null;
    final blockId = context.blockConfig.apiConfigId;
    if (blockId.isNotEmpty) {
      final own = configs.where((c) => c.id == blockId).firstOrNull;
      if (own != null) return own;
    }
    final activeId = ref.read(activeApiPresetIdProvider);
    return configs.where((c) => c.id == activeId).firstOrNull ?? configs.first;
  }

  /// Images this session's other blocks already produced, newest last, so a
  /// provider that takes reference images keeps the scene consistent.
  Future<List<String>?> _recentImageContexts(BlockContext context) async {
    final settings = ref.read(imageGenSettingsProvider).value;
    if (settings == null || !settings.imageContextEnabled) return null;

    final rows = await repo.getBySessionId(context.sessionId);
    final done =
        rows
            .where(
              (b) =>
                  b.status == BlockRunStatus.done &&
                  b.id != context.placeholderId,
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final paths = ImageTagMarkup.collectRecentImageResultPaths(
      done.map((b) => b.content),
      maxPaths: 3,
    );
    return paths.isEmpty ? null : paths;
  }
}
