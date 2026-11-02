import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/block_config.dart';
import '../../models/block_run_status.dart';
import '../../models/info_block.dart';
import '../../../../core/state/character_provider.dart';
import '../../providers/info_blocks_provider.dart';
import '../../../chat/chat_provider.dart';
import '../ext_blocks_panel_builder.dart';
import '../macro_expander.dart';
import '../../../../features/chat/bridge/chat_bridge_registry.dart';
import '../../../../core/llm/regex_service.dart';
import '../../../../core/state/active_selection_provider.dart';
import 'block_image_renderer.dart';

const _panelJsTimeout = Duration(seconds: 2);

class BlockPanelUpdater {
  BlockPanelUpdater(this._ref);

  final Ref _ref;

  Future<void>? _panelJsChain;
  DateTime? _lastStreamPanelAt;

  void _enqueuePanelJs(Future<void> Function() work) {
    _panelJsChain = (_panelJsChain ?? Future.value()).then((_) async {
      try {
        await work().timeout(_panelJsTimeout);
      } on TimeoutException {
        debugPrint('[ExtPostGen] panel JS update timed out');
      } catch (e, st) {
        debugPrint('[ExtPostGen] panel JS update failed: $e\n$st');
      }
    });
  }

  void refreshForMessage(
    String charId,
    String sessionId,
    String messageId,
    int swipeId,
    int agentSwipeId,
  ) {
    _enqueuePanelJs(() async {
      if (!_ref.mounted ||
          _ref.read(chatProvider(charId)).value?.session?.id != sessionId) {
        return;
      }
      final bridge = _ref.read(chatBridgeRegistryProvider(charId));
      if (bridge == null) return;
      // Panels render only under assistant/character messages. afterUser
      // blocks are stored under the user message id (for prompt injection)
      // but must never paint a visible panel there — hide defensively so a
      // stale panel from a prior run can't linger under a user message.
      if (!_isAssistantMessage(charId, messageId)) {
        await bridge.hideExtBlocksPanel(messageId);
        return;
      }
      final blocks = ExtBlocksPanelBuilder.build(
        _ref,
        sessionId: sessionId,
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
      );
      if (blocks.isEmpty) {
        await bridge.hideExtBlocksPanel(messageId);
        return;
      }
      final publicBlocks = _expandBlockPayloads(blocks, charId, sessionId);
      // Do not fall back to an old private result when queued image custody was
      // denied. Omission is not a fabricated replacement or a completion claim.
      if (publicBlocks.isEmpty) return;
      await bridge.showExtBlocksPanel(
        messageId,
        publicBlocks,
        canRunAll: ExtBlocksPanelBuilder.canRunAll(publicBlocks),
      );
    });
  }

  Future<void> patchOrRefresh({
    required String charId,
    required String sessionId,
    required String messageId,
    required String blockId,
    required int swipeId,
    required int agentSwipeId,
    required String content,
    required String status,
    InfoBlock? imagePublication,
  }) async {
    if (!_ref.mounted ||
        _ref.read(chatProvider(charId)).value?.session?.id != sessionId ||
        (imagePublication != null &&
            !BlockImageRenderer.canPublishResult(
              imagePublication,
              content: content,
            ))) {
      return;
    }
    final bridge = _ref.read(chatBridgeRegistryProvider(charId));
    if (bridge == null) return;
    final patched = await bridge.patchExtBlockContent(
      messageId: messageId,
      blockId: blockId,
      content: content,
      status: status,
    );
    if (imagePublication != null &&
        !BlockImageRenderer.canPublishResult(
          imagePublication,
          content: content,
        ))
      return;
    if (!_ref.mounted ||
        _ref.read(chatProvider(charId)).value?.session?.id != sessionId)
      return;
    if (patched) return;
    refreshForMessage(charId, sessionId, messageId, swipeId, agentSwipeId);
  }

  void publishStreamingContent({
    required String charId,
    required String sessionId,
    required String messageId,
    required InfoBlock placeholder,
    required String content,
    bool force = false,
  }) {
    if (!_ref.mounted ||
        _ref.read(chatProvider(charId)).value?.session?.id != sessionId ||
        !BlockImageRenderer.canPublishResult(placeholder, content: content)) {
      return;
    }
    final now = DateTime.now();
    if (!force &&
        _lastStreamPanelAt != null &&
        now.difference(_lastStreamPanelAt!) <
            const Duration(milliseconds: 80)) {
      return;
    }
    _lastStreamPanelAt = now;
    final updated = placeholder.copyWith(
      content: content,
      status: BlockRunStatus.running,
    );
    BlockImageRenderer.carryResultPublication(placeholder, updated);
    _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(updated);
    // afterUser blocks target a user message: keep the streamed InfoBlock
    // state (used for prompt injection) but never render a panel under it.
    if (!_isAssistantMessage(charId, messageId)) return;
    _enqueuePanelJs(() async {
      if (!_ref.mounted ||
          _ref.read(chatProvider(charId)).value?.session?.id != sessionId ||
          !BlockImageRenderer.canPublishResult(updated))
        return;
      final expanded = _expandContent(content, charId, sessionId);
      if (!BlockImageRenderer.canPublishResult(updated, content: expanded))
        return;
      await patchOrRefresh(
        charId: charId,
        sessionId: sessionId,
        messageId: messageId,
        blockId: placeholder.blockId,
        swipeId: placeholder.swipeId,
        agentSwipeId: placeholder.agentSwipeId,
        content: expanded,
        status: BlockRunStatus.running.name,
        imagePublication: updated,
      );
    });
  }

  List<Map<String, dynamic>> _expandBlockPayloads(
    List<Map<String, dynamic>> blocks,
    String charId,
    String sessionId,
  ) {
    return [
      for (final block in blocks)
        if (_imagePayloadIsCurrent(block, charId, sessionId))
          {
            ...block,
            if (block['content'] is String)
              'content': _expandContent(
                block['content'] as String,
                charId,
                sessionId,
              ),
          },
    ];
  }

  bool _imagePayloadIsCurrent(
    Map<String, dynamic> payload,
    String charId,
    String sessionId,
  ) {
    final original = _ref
        .read(infoBlocksProvider(sessionId))
        .where((block) => block.id == payload['id'])
        .firstOrNull;
    final content = payload['content'];
    return original == null ||
        content is! String ||
        BlockImageRenderer.canPublishResult(
          original,
          content: _expandContent(content, charId, sessionId),
        );
  }

  String _expandContent(String content, String charId, String sessionId) {
    final character = _ref.read(characterByIdProvider(charId));
    final persona = _ref.read(
      effectivePersonaForChatProvider((charId: charId, sessionId: sessionId)),
    );
    final expanded = expand(
      content,
      MacroContext(
        character: character,
        persona: persona?.name,
        personaDescription: persona?.prompt,
      ),
    );
    return applyRegexes(
      expanded,
      2,
      2,
      _ref.read(activeRegexesProvider).value ?? const [],
      RegexApplyContext(
        char: character,
        persona: persona,
        sessionVars:
            _ref.read(chatProvider(charId)).value?.session?.sessionVars ??
            const {},
        globalVars: _ref.read(globalVarsProvider),
        depth: 0,
      ),
      isMarkdown: true,
    );
  }

  /// Whether [messageId] belongs to an assistant/character message in the
  /// currently active chat session. Resolved per-call from `chatProvider` so
  /// overlapping afterUser / afterAssistant chains (which target different
  /// message ids) are gated independently without shared mutable state. If the
  /// message isn't found (e.g. the user switched sessions mid-run) the panel is
  /// suppressed — the WebView DOM won't contain that message's section anyway.
  bool _isAssistantMessage(String charId, String messageId) {
    final messages =
        _ref.read(chatProvider(charId)).value?.messages ?? const [];
    for (final m in messages) {
      if (m.id == messageId) {
        return m.role == 'assistant' || m.role == 'character';
      }
    }
    return false;
  }

  void Function(String)? makeStreamHandler({
    required BlockConfig blockConfig,
    required String charId,
    required String sessionId,
    required String messageId,
    required InfoBlock placeholder,
  }) {
    if (!blockConfig.streamToPanel) return null;
    return (partial) => publishStreamingContent(
      charId: charId,
      sessionId: sessionId,
      messageId: messageId,
      placeholder: placeholder,
      content: partial,
    );
  }
}
