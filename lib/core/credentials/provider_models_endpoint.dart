/// Derive the catalog sibling without changing the saved server or API prefix.
/// This is URI construction, not credential or network authority.
Uri providerModelsEndpoint(Uri endpoint, String protocol) {
  if (!{'http', 'https'}.contains(endpoint.scheme) ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.hasQuery ||
      endpoint.hasFragment) {
    throw const FormatException('Invalid provider endpoint.');
  }
  final path = endpoint.path;
  String prefix;
  String? query;
  if (protocol == 'gemini') {
    final match = RegExp(
      r'/models/[^/]+:(?:streamGenerateContent|generateContent)$',
    ).firstMatch(path);
    if (match == null) {
      throw const FormatException('Invalid Gemini endpoint.');
    }
    prefix = path.substring(0, match.start);
    query = 'pageSize=1000';
  } else {
    final suffix = switch (protocol) {
      'anthropic' => '/messages',
      'openai_responses' => '/responses',
      'openai' ||
      'openrouter' ||
      'custom_chat_completion' => '/chat/completions',
      _ => throw const FormatException('Unsupported provider protocol.'),
    };
    if (!path.endsWith(suffix)) {
      throw const FormatException('Invalid provider endpoint.');
    }
    prefix = path.substring(0, path.length - suffix.length);
    if (protocol == 'anthropic') query = 'limit=1000';
  }
  return endpoint.replace(path: '$prefix/models', query: query);
}
