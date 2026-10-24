import 'dart:convert';

/// Synthetic protocol output, not a captured user/provider response.
String ledgerClockExport(List<Map<String, Object?>> ops) =>
    '<studio_ledger>Synthetic clock update</studio_ledger>\n'
    '<glaze_memory_export>${jsonEncode({'ops': ops})}</glaze_memory_export>';

Map<String, Object?> ledgerClockSet(String key, Object? value) => {
  'op': 'set',
  'key': key,
  'value': value,
  'evidence': 'Synthetic elapsed-time estimate',
  'eventState': 'completed',
};
