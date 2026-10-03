/// Replaces large base64 media embedded in prompt text with short placeholders.
/// Attachments travel as separate image parts and are unaffected. Use the same
/// text for request serialization and token budgeting.
String stripInlineMedia(String text) {
  if (text.length < _minPayload || !text.contains(';base64,')) return text;
  return text
      .replaceAllMapped(_imgTag, (m) => _placeholder(m[1]!))
      .replaceAllMapped(_dataUri, (m) => _placeholder(m[1]!));
}

const _minPayload = 256;

final _imgTag = RegExp(
  r'''<img\b[^>]*?\bsrc\s*=\s*["']data:([a-z]+)/[^;"']+;base64,'''
  r'''[A-Za-z0-9+/=\s]{256,}["'][^>]*>''',
  caseSensitive: false,
);

final _dataUri = RegExp(
  r'data:([a-z]+)/[a-z0-9.+-]+;base64,[A-Za-z0-9+/=]{256,}',
  caseSensitive: false,
);

String _placeholder(String kind) => switch (kind.toLowerCase()) {
  'image' => '[image]',
  'audio' => '[audio]',
  'video' => '[video]',
  _ => '[file]',
};
