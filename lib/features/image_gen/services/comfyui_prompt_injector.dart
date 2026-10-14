/// Prompt injection for API graphs exported without SillyTavern placeholders.
void injectComfyUiPrompts(
  Map<String, dynamic> workflow, {
  required String prompt,
  required String negativePrompt,
}) {
  Map<String, dynamic>? inputs(Object? node) {
    if (node is! Map || node['inputs'] is! Map) return null;
    return (node['inputs'] as Map).cast<String, dynamic>();
  }

  final positive = <String>{};
  final negative = <String>{};
  for (final node in workflow.values) {
    final fields = inputs(node);
    for (final (role, targets) in [
      ('positive', positive),
      ('negative', negative),
    ]) {
      final link = fields?[role];
      if (link is List && link.isNotEmpty) targets.add('${link.first}');
    }
  }

  void write(String id, bool negativeSide, Set<String> visited) {
    if (!visited.add(id)) return;
    final fields = inputs(workflow[id]);
    if (fields == null) return;
    final names = negativeSide
        ? ['negative_prompt', 'text']
        : ['prompt', 'text'];
    for (final name in names) {
      if (fields[name] is String) {
        fields[name] = negativeSide ? negativePrompt : prompt;
        return;
      }
    }
    // Conditioning wrappers can sit between the sampler and text encoder.
    for (final entry in fields.entries) {
      if (!entry.key.contains('conditioning')) continue;
      final link = entry.value;
      if (link is List && link.isNotEmpty) {
        write('${link.first}', negativeSide, visited);
      }
    }
  }

  if (positive.isEmpty && negative.isEmpty) {
    for (final node in workflow.values) {
      final fields = inputs(node);
      if (fields == null) continue;
      if (fields['prompt'] is String || fields['text'] is String) {
        fields[fields['prompt'] is String ? 'prompt' : 'text'] = prompt;
        if (fields['negative_prompt'] is String) {
          fields['negative_prompt'] = negativePrompt;
        }
        break;
      }
    }
  } else {
    for (final id in positive) {
      write(id, false, {});
    }
    for (final id in negative) {
      write(id, true, {});
    }
  }
}
