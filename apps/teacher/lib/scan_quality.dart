/// Plain-language reasons why a scan's faces were rejected, from `quality_json.reject_reasons`.
///
/// Read-only: it explains numbers the worker already recorded and changes no recognition result.
/// The wording matches the session report's GATE_ADVICE so the app and the report agree.
library;

const _advice = <String, String>{
  'brightness': 'the picture was too dark or too bright (turn the lights on and keep windows out of the background)',
  'small': 'faces were too small in the frame (move the phone closer or record the back rows separately)',
  'blur': 'faces were blurred (hold the phone steady and let faces rest still)',
  'edge': 'faces were cut off at the edge of the picture (keep everyone inside the frame)',
  'landmarks': 'faces were turned away or covered so the eyes and mouth were not found (ask students to look toward the camera)',
};

/// A short sentence naming the main cause(s) of rejected faces, or null when the capture has no
/// usable breakdown (older captures, empty or malformed data).
String? rejectCause(Object? quality) {
  if (quality is! Map) return null;
  final raw = quality['reject_reasons'];
  if (raw is! Map) return null;
  final counts = <String, int>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is String &&
        _advice.containsKey(key) &&
        value is num &&
        value > 0) {
      counts[key] = value.toInt();
    }
  }
  final total = counts.values.fold<int>(0, (a, b) => a + b);
  if (total == 0) return null;
  final ranked = counts.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  final main = ranked.first;
  final parts = <String>['${_advice[main.key]}'];
  if (ranked.length > 1 && ranked[1].value * 4 >= total) {
    parts.add('${_advice[ranked[1].key]}');
  }
  final lead = main.value * 2 >= total ? 'Mostly' : 'Mainly';
  return '$lead: ${parts.join('; also ')}.';
}
