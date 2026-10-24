import '../../../core/llm/transport/native_tool_types.dart';

/// Native previews also need deep immutable ownership before a UI can retain
/// them. Final transport validation/redaction remains the core/registry's job.
abstract final class SupportAppActionJson {
  static Map<String, Object?> immutable(Map<String, Object?> value) {
    Object? freeze(Object? item, int depth) {
      if (depth > 4) {
        throw const FormatException('Invalid application preview.');
      }
      if (item == null || item is bool || item is num || item is String) {
        return item;
      }
      if (item is List && item.length <= 32) {
        return List<Object?>.unmodifiable(
          item.map((v) => freeze(v, depth + 1)),
        );
      }
      if (item is Map<String, Object?> && item.length <= 32) {
        return Map<String, Object?>.unmodifiable(
          item.map((key, v) => MapEntry(key, freeze(v, depth + 1))),
        );
      }
      throw const FormatException('Invalid application preview.');
    }

    return freeze(value, 0)! as Map<String, Object?>;
  }
}

enum SupportAppActionRisk {
  metadata,
  reversiblePreference,
  configuration,
  navigation,
  bodyRead,
  destructive,
  paidNetwork,
  nativeFile,
  authentication,
  publicMutation,
}

/// Fixed scalar-only field contract. No coercion, nested objects or unknown keys.
final class SupportAppActionField {
  const SupportAppActionField.boolean()
    : type = 'boolean',
      minimum = null,
      maximum = null,
      maxLength = null,
      pattern = null,
      choices = null;
  const SupportAppActionField.integer(this.minimum, this.maximum)
    : type = 'integer',
      maxLength = null,
      pattern = null,
      choices = null;
  const SupportAppActionField.number(this.minimum, this.maximum)
    : type = 'number',
      maxLength = null,
      pattern = null,
      choices = null;
  const SupportAppActionField.text(this.maxLength, {this.pattern})
    : type = 'string',
      minimum = null,
      maximum = null,
      choices = null;
  SupportAppActionField.choice(Iterable<String> values)
    : type = 'string',
      minimum = null,
      maximum = null,
      maxLength = null,
      pattern = null,
      choices = List.unmodifiable(values);

  final String type;
  final num? minimum, maximum;
  final int? maxLength;
  final String? pattern;
  final List<String>? choices;

  bool accepts(Object? value) => switch (type) {
    'boolean' => value is bool,
    'integer' => value is int && value >= minimum! && value <= maximum!,
    'number' =>
      value is num && value.isFinite && value >= minimum! && value <= maximum!,
    'string' =>
      value is String &&
          value.isNotEmpty &&
          value == value.trim() &&
          !RegExp(r'[\x00-\x1f\x7f\u200b-\u200f\ufeff]').hasMatch(value) &&
          (maxLength == null || value.length <= maxLength!) &&
          (pattern == null || RegExp(pattern!).hasMatch(value)) &&
          (choices == null || choices!.contains(value)),
    _ => false,
  };

  Map<String, Object?> get schema => {
    'type': type,
    if (minimum != null) 'minimum': minimum,
    if (maximum != null) 'maximum': maximum,
    if (type == 'string') 'minLength': 1,
    if (maxLength != null) 'maxLength': maxLength,
    if (pattern != null) 'pattern': pattern,
    if (choices != null) 'enum': choices,
  };
}

final class SupportAppActionDefinition {
  SupportAppActionDefinition({
    required this.name,
    required this.description,
    required this.risk,
    Map<String, SupportAppActionField> fields = const {},
    Set<String> requiredFields = const {},
    this.requireAnyField = false,
  }) : fields = Map.unmodifiable(fields),
       requiredFields = Set.unmodifiable(requiredFields);
  final String name, description;
  final SupportAppActionRisk risk;
  final Map<String, SupportAppActionField> fields;
  final Set<String> requiredFields;
  final bool requireAnyField;

  bool accepts(Map<String, Object?> arguments) =>
      arguments.length <= 16 &&
      (!requireAnyField || arguments.isNotEmpty) &&
      requiredFields.every(arguments.containsKey) &&
      arguments.entries.every((e) => fields[e.key]?.accepts(e.value) == true);

  NativeToolDefinition get native => NativeToolDefinition(
    name: name,
    description: description,
    parameters: {
      'type': 'object',
      'properties': {for (final e in fields.entries) e.key: e.value.schema},
      'required': requiredFields.toList(growable: false),
      'additionalProperties': false,
      if (requireAnyField) 'minProperties': 1,
    },
  );
}
