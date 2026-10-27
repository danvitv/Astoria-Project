import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/sheet_view.dart';
import 'support_plain_markdown.dart';
import 'support_surface_layout.dart';

/// Presentation roles only; these are not transport or permission types.
enum SupportPromptPreviewRole { user, assistant, system }

@immutable
final class SupportPromptPreviewSection {
  SupportPromptPreviewSection({required this.role, required this.text}) {
    if (text.length > SupportPlainMarkdown.maxTextLength) {
      throw ArgumentError('Prompt preview section exceeds the text limit.');
    }
  }

  final SupportPromptPreviewRole role;
  final String text;
}

/// A bounded, immutable display snapshot, never an approved network intent.
///
/// The caller supplies already-sanitized public target labels and verified text.
/// This constructor rejects oversize or visually ambiguous labels, without
/// modifying them. It cannot discover secrets or verify a recipient. Never pass
/// credentials, request/configuration objects, source IDs or routing provenance.
@immutable
final class SupportPromptPreviewValues {
  SupportPromptPreviewValues({
    required this.originLabel,
    required this.operationLabel,
    required this.modelLabel,
    required this.gameMessageCount,
    required this.supportMessageCount,
    required List<SupportPromptPreviewSection> sections,
  }) : sections = _boundedSections(sections) {
    for (final label in [originLabel, operationLabel, modelLabel]) {
      if (label.isEmpty ||
          label.length > maxLabelLength ||
          label.trim() != label ||
          label.runes.any(_ambiguousLabelCodePoint)) {
        throw ArgumentError('Prompt preview requires bounded safe labels.');
      }
    }
    if (gameMessageCount < 0 ||
        gameMessageCount > maxMessageCount ||
        supportMessageCount < 0 ||
        supportMessageCount > maxMessageCount) {
      throw ArgumentError('Prompt preview message count is out of bounds.');
    }
  }

  static const int maxLabelLength = 2048;
  static const int maxSections = 514;

  /// Total display input in UTF-16 code units, not a transport-byte allowance.
  static const int maxTotalTextLength = 65536;
  static const int maxMessageCount = 512;

  final String originLabel;
  final String operationLabel;
  final String modelLabel;
  final int gameMessageCount;
  final int supportMessageCount;
  final List<SupportPromptPreviewSection> sections;

  int get textLength =>
      sections.fold(0, (sum, section) => sum + section.text.length);

  static List<SupportPromptPreviewSection> _boundedSections(
    List<SupportPromptPreviewSection> sections,
  ) {
    if (sections.length > maxSections ||
        sections.fold<int>(0, (sum, section) => sum + section.text.length) >
            maxTotalTextLength) {
      throw ArgumentError('Prompt preview exceeds the display limit.');
    }
    return List<SupportPromptPreviewSection>.unmodifiable(sections);
  }

  static bool _ambiguousLabelCodePoint(int code) =>
      code <= 0x1f ||
      (code >= 0x7f && code <= 0x9f) ||
      code == 0xad ||
      code == 0x61c ||
      (code >= 0x200b && code <= 0x200f) ||
      (code >= 0x2028 && code <= 0x202e) ||
      (code >= 0x2060 && code <= 0x206f) ||
      code == 0xfeff;
}

/// Native, passive prompt review. All callbacks and values are captured once.
///
/// [isCurrent] is the caller's pure synchronous predicate for the captured
/// lifetime/preview. [onDecision] receives at most one explicit choice; the
/// caller closes the route and independently owns native approval/consumption.
/// Dismissal/disposal emits nothing. This widget neither authorizes nor sends.
/// Replacing inputs on the same State retires the sheet; open a new sheet/key
/// for another snapshot rather than rebinding a visible confirmation button.
class SupportModelPromptPreviewSheet extends StatefulWidget {
  const SupportModelPromptPreviewSheet({
    super.key,
    required this.values,
    required this.isCurrent,
    required this.onDecision,
  });

  final SupportPromptPreviewValues values;
  final bool Function() isCurrent;
  final ValueChanged<bool> onDecision;

  @override
  State<SupportModelPromptPreviewSheet> createState() => _PromptPreviewState();
}

class _PromptPreviewState extends State<SupportModelPromptPreviewSheet> {
  late final SupportPromptPreviewValues _values;
  late final bool Function() _isCurrent;
  late final ValueChanged<bool> _onDecision;
  bool _closed = false;
  bool _checking = false;
  bool _stale = false;

  @override
  void initState() {
    super.initState();
    _values = widget.values;
    _isCurrent = widget.isCurrent;
    _onDecision = widget.onDecision;
  }

  @override
  void didUpdateWidget(covariant SupportModelPromptPreviewSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.values, _values) ||
        !identical(widget.isCurrent, _isCurrent) ||
        !identical(widget.onDecision, _onDecision)) {
      _stale = true;
    }
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }

  bool _current() {
    if (_closed || _stale || _checking || !mounted) return false;
    _checking = true;
    try {
      return _isCurrent();
    } catch (_) {
      // A failed lifetime check is never permission, nor user-visible error data.
      return false;
    } finally {
      _checking = false;
    }
  }

  void _finish(bool confirmed) {
    if (_closed || _checking || !mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    if (confirmed && !_current()) {
      if (mounted && !_closed) setState(() => _stale = true);
      return;
    }
    // The predicate is synchronous. No await/provider/native binding is inserted
    // between its final check and this once-only decision for the captured view.
    if (_closed ||
        (confirmed && _stale) ||
        !mounted ||
        (route != null && !route.isCurrent)) {
      return;
    }
    setState(() => _closed = true);
    _onDecision(confirmed);
  }

  @override
  Widget build(BuildContext context) {
    final current = _current();
    return PopScope<bool>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _closed = true;
      },
      child: SheetView(
        titleWidget: SupportSheetTitle(
          title: 'Prompt preview',
          titleKey: const ValueKey('support_prompt_preview_header'),
          onBack: () => _finish(false),
        ),
        showBack: false,
        onBack: () => _finish(false),
        canPop: true,
        collapsedFraction: 0.85,
        body: Builder(
          builder: (bodyContext) => SupportSheetDecisionBody(
            footer: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GlazeActionButton(
                  key: const ValueKey('support_prompt_preview_confirm'),
                  icon: Icons.check,
                  label: 'Confirm',
                  expand: true,
                  tone: GlazeActionTone.primary,
                  onTap: current ? () => _finish(true) : null,
                ),
                const SizedBox(height: 8),
                GlazeActionButton(
                  key: const ValueKey('support_prompt_preview_cancel'),
                  icon: Icons.close,
                  label: 'Cancel',
                  expand: true,
                  onTap: _closed ? null : () => _finish(false),
                ),
              ],
            ),
            content: ListView(
              key: const ValueKey('support_prompt_preview_scroll'),
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                MediaQuery.paddingOf(bodyContext).bottom + 24,
              ),
              children: [
                if (!current)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'This preview is no longer current. Go back or cancel.',
                    ),
                  ),
                _TargetLabel('Origin', _values.originLabel),
                _TargetLabel('Operation', _values.operationLabel),
                _TargetLabel('Model', _values.modelLabel),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'Selected game messages: ${_values.gameMessageCount}\n'
                    'Selected assistant-chat messages: ${_values.supportMessageCount}\n'
                    'Text sections: ${_values.sections.length}\n'
                    'Text length (UTF-16 code units): ${_values.textLength}',
                  ),
                ),
                const Text(
                  'Only text generation. Tools, actions, undo and reports are not '
                  'performed. This preview does not authorize or transmit anything. '
                  'Text selection does not automatically copy, export or open '
                  'links or images. Target labels do not verify downstream routing.',
                ),
                for (var index = 0; index < _values.sections.length; index++)
                  _TextSection(section: _values.sections[index], index: index),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TargetLabel extends StatelessWidget {
  const _TargetLabel(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        // Plain text: never a URL/link. No maxLines, ellipsis or value rewriting.
        Text(value, softWrap: true),
      ],
    ),
  );
}

class _TextSection extends StatelessWidget {
  const _TextSection({required this.section, required this.index});
  final SupportPromptPreviewSection section;
  final int index;

  @override
  Widget build(BuildContext context) {
    final renderer = SupportPlainMarkdown(
      key: ValueKey('support_prompt_preview_section_$index'),
      text: section.text,
      style: Theme.of(context).textTheme.bodyMedium,
    );
    // PassiveR consumes paired emphasis markers. Preserve exact source as well
    // when that changes visible text; never present formatted output as exact.
    final needsExactSource =
        renderer.toTextSpan().toPlainText() != section.text;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${index + 1} · ${section.role.name}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          renderer,
          if (needsExactSource) ...[
            const SizedBox(height: 12),
            const Text('Exact text (including emphasis markers)'),
            SelectableText(
              section.text,
              key: ValueKey('support_prompt_preview_exact_$index'),
              contextMenuBuilder: null,
              showCursor: false,
            ),
          ],
        ],
      ),
    );
  }
}
