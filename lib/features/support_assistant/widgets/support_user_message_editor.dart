import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_text_field.dart';
import '../../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../../shared/widgets/sheet_view.dart';
import 'support_surface_layout.dart';

Future<String?> showSupportUserMessageEditor(
  BuildContext context, {
  required String initialText,
  required bool Function() isCurrent,
}) => isDesktopLayout(context)
    ? showDialog<String>(
        context: context,
        builder: (_) => _SupportUserMessageEditor(
          initialText: initialText,
          isCurrent: isCurrent,
        ),
      )
    : showModalBottomSheet<String>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _SupportUserMessageEditor(
          initialText: initialText,
          isCurrent: isCurrent,
          sheetHosted: true,
        ),
      );

class _SupportUserMessageEditor extends StatefulWidget {
  const _SupportUserMessageEditor({
    required this.initialText,
    required this.isCurrent,
    this.sheetHosted = false,
  });
  final String initialText;
  final bool Function() isCurrent;
  final bool sheetHosted;

  @override
  State<_SupportUserMessageEditor> createState() => _EditorState();
}

class _EditorState extends State<_SupportUserMessageEditor> {
  late final _text = TextEditingController(text: widget.initialText);

  bool get _valid =>
      widget.isCurrent() &&
      _text.text.trim().isNotEmpty &&
      _text.text.length <= 8192 &&
      _text.text != widget.initialText;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.sheetHosted
      ? SheetView(
          title: 'Изменить сообщение',
          titleWidget: SupportSheetTitle(
            title: 'Изменить сообщение',
            onBack: () => Navigator.of(context).pop(),
          ),
          body: Builder(
            builder: (context) => SupportSheetDecisionBody(
              content: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: _form(context),
              ),
              footer: _actions(context),
            ),
          ),
        )
      : Dialog(
          backgroundColor: Colors.transparent,
          child: GlazeBottomSheetFrame(
            showHandle: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Изменить сообщение',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  _form(context),
                  const SizedBox(height: 16),
                  _actions(context),
                ],
              ),
            ),
          ),
        );

  Widget _form(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      GlazeTextField(
        key: const ValueKey('support_message_edit_field'),
        controller: _text,
        maxLines: 8,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      const Text(
        'Сохранение изменит только твоё сообщение и не отправит его модели. '
        'Сообщения, на которые уже ссылается ответ модели или сжатый '
        'контекст, нельзя менять таким способом. Прежние ответы '
        'не переписываются.',
      ),
      if (_text.text.length > 8192) ...[
        const SizedBox(height: 8),
        const Text('Не больше 8192 символов.'),
      ],
    ],
  );

  Widget _actions(BuildContext context) => Row(
    children: [
      Expanded(
        child: GlazeActionButton(
          label: 'Отмена',
          maxLabelLines: null,
          icon: Icons.close_rounded,
          onTap: () => Navigator.of(context).pop(),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: GlazeActionButton(
          key: const ValueKey('support_message_edit_save'),
          label: 'Сохранить',
          maxLabelLines: null,
          icon: Icons.check_rounded,
          onTap: _valid
              ? () {
                  if (_valid) Navigator.of(context).pop(_text.text);
                }
              : null,
        ),
      ),
    ],
  );
}
