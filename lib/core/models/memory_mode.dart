const memoryLinksMode = 'memory_links';

bool isMemoryLinksMode(String raw) => raw == memoryLinksMode;

/// Migrates the old boolean consolidation switch into the explicit mode.
String migrateMemoryModeValue(
  Object? raw, {
  required bool consolidationEnabled,
}) {
  final value = raw is String && raw.isNotEmpty ? raw : 'fast';
  if (consolidationEnabled && value != memoryLinksMode) {
    return memoryLinksMode;
  }
  return value == 'agentic' ? 'deep' : value;
}

bool memoryLinksCompatibilityFlag(String mode) => isMemoryLinksMode(mode);
