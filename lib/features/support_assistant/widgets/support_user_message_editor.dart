import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_text_field.dart';

Future<String?> showSupportUserMessageEditor(
  BuildContext context, {
  required String initialText,
  required bool Function() isCurrent,
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      _SupportUserMessageEditor(initialText: initialText, isCurrent: isCurrent),
);

class _SupportUserMessageEditor extends StatefulWidget {
  const _SupportUserMessageEditor({
    required this.initialText,
    required this.isCurrent,
  });
  final String initialText;
  final bool Function() isCurrent;

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
  Widget build(BuildContext context) => Dialog(
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
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: GlazeActionButton(
                    label: 'Отмена',
                    icon: Icons.close_rounded,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GlazeActionButton(
                    key: const ValueKey('support_message_edit_save'),
                    label: 'Сохранить',
                    icon: Icons.check_rounded,
                    onTap: _valid
                        ? () {
                            if (_valid) Navigator.of(context).pop(_text.text);
                          }
                        : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
