import '../../../models/support_app_action.dart';
import 'support_content_mutation.dart';

/// A grouped text scalar is body-capable only for its selected body field.
/// Names and labels retain the original metadata contract; neither kind is
/// permission to expose existing text in previews or results.
abstract final class SupportContentTextArguments {
  static const name = SupportAppActionField.text(256);
  static const body = SupportAppActionField.bodyText(32768);

  static String selected(
    Map<String, Object?> arguments, {
    bool isBody = true,
    bool allowClear = true,
  }) {
    final text = SupportContentArguments.text(arguments);
    if ((!allowClear && text.isEmpty) ||
        (!isBody && arguments.containsKey('text') && !name.accepts(text))) {
      throw const SupportAppActionRefused(
        SupportAppActionCode.invalidArguments,
      );
    }
    // Shared registry body admission/redaction already applies to body scalars.
    // Do not trim, truncate, append, mask or estimate admission using tokens.
    return text;
  }
}
