import '../../../../core/llm/regex_service.dart';
import '../../../../core/models/character.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/models/persona.dart';
import '../../../../core/models/preset.dart';
import '../../../image_gen/services/image_tag_markup.dart';
import '../../models/block_config.dart';
import '../../models/block_context_item.dart';
import '../../models/block_run_status.dart';
import '../../models/info_block.dart';
import '../macro_expander.dart';

/// Ordered explicit context supersedes automatic history reconstruction.
List<Map<String, dynamic>> buildContextItemMessages({
  required BlockConfig blockConfig,
  required List<ChatMessage> messages,
  required String anchorMessageId,
  required Character? character,
  required Persona? persona,
  Map<String, String> sessionVars = const {},
  Map<String, String> globalVars = const {},
  List<PresetRegex> promptRegexes = const [],
  Map<String, List<InfoBlock>> blocksByMessageId = const {},
  int pauseCounter = 0,
}) {
  final anchor = messages.indexWhere((m) => m.id == anchorMessageId);
  if (anchor < 0) return const [];
  final history = messages.take(anchor + 1).toList();
  final visible = history
      .where(
        (m) =>
            !m.isHidden &&
            !m.isTyping &&
            !m.isError &&
            m.content.trim().isNotEmpty,
      )
      .toList();
  final macros = MacroContext(
    character: character,
    persona: persona?.name,
    personaDescription: persona?.prompt,
  );
  String expandText(String text) => expand(text, macros);
  String withoutImages(String text) =>
      ImageTagMarkup.reduceBlocksToInstructions(text);
  List<InfoBlock> blocksFor(ChatMessage m) =>
      (blocksByMessageId[m.id] ?? const <InfoBlock>[])
          .where(
            (b) =>
                b.swipeId == m.swipeId &&
                (b.agentSwipeId == -1 || b.agentSwipeId == m.agentSwipeId) &&
                b.status == BlockRunStatus.done &&
                b.content.trim().isNotEmpty,
          )
          .toList();
  String format(List<ChatMessage> slice, BlockContextItem item) {
    return slice
        .map((m) {
          final user = m.role == 'user';
          final depth =
              anchor - history.indexWhere((entry) => entry.id == m.id);
          final body = applyRegexes(
            withoutImages(m.content.trim()),
            user ? 1 : 2,
            2,
            promptRegexes,
            RegexApplyContext(
              char: character,
              persona: persona,
              sessionVars: sessionVars,
              globalVars: globalVars,
              depth: depth,
            ),
            isPrompt: true,
          );
          return '${expandText(user ? item.userPrefix : item.charPrefix)}$body'
              '${expandText(user ? item.userSuffix : item.charSuffix)}';
        })
        .join(item.messagesSeparator.text);
  }

  String contentFor(BlockContextItem item) {
    if (item.type == ContextItemType.text) return expandText(item.text);
    if (item.type == ContextItemType.previousBlock) {
      final parts = <String>[];
      for (
        var i = anchor - 1;
        i >= 0 && parts.length < item.blockCount.clamp(1, 1000);
        i--
      ) {
        if (history[i].isHidden || history[i].isTyping || history[i].isError) {
          continue;
        }
        final found = blocksFor(
          history[i],
        ).where((b) => b.blockName == item.blockName).firstOrNull;
        if (found == null) continue;
        final tag = item.blockName.trim().split(RegExp(r'\s+')).first;
        final text = withoutImages(found.content.trim());
        parts.add(tag.isEmpty ? text : '<$tag>\n$text\n</$tag>');
      }
      return parts.reversed.join('\n\n');
    }
    var working = visible
        .take(visible.length - item.messagesOffset.clamp(0, visible.length))
        .toList();
    if (working.isEmpty) return '';
    int? count = item.messagesCount;
    if (item.type == ContextItemType.lastMessagesByBlock) {
      if (item.blockName.isEmpty) return '';
      var start = 0;
      for (var i = 0; i < working.length; i++) {
        if (blocksFor(working[i]).any((b) => b.blockName == item.blockName)) {
          start = i;
        }
      }
      working = working.sublist(start);
      count = working.length;
    } else if (count == null) {
      if (item.keywordStopper.isEmpty) return '';
      var start = 0;
      final end = (working.length - pauseCounter - 1).clamp(0, working.length);
      for (var i = end - 1; i >= 0; i--) {
        if (working[i].content.contains(item.keywordStopper)) {
          start = i;
          break;
        }
      }
      working = working.sublist(start);
      count = working.length;
    }
    final slice = count > 0
        ? working
              .skip((working.length - count).clamp(0, working.length))
              .toList()
        : count < 0
        ? working.take(-count).toList()
        : <ChatMessage>[];
    return format(slice, item);
  }

  final result = <Map<String, dynamic>>[];
  for (final item in blockConfig.context) {
    if (item.disabled) continue;
    final content = contentFor(item);
    if (content.isEmpty) continue;
    if (result.isNotEmpty && result.last['role'] == item.role.name) {
      result.last['content'] = '${result.last['content']}\n$content';
    } else {
      result.add({'role': item.role.name, 'content': content});
    }
  }
  return result;
}
