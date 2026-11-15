const _millisecondsEpochFloor = 100000000000;

int currentTimestampSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Normalizes a persisted Unix timestamp to seconds.
///
/// Chat sessions use seconds, but legacy JavaScript backups and older cloud
/// payloads may contain milliseconds. Values above this floor cannot be
/// plausible second timestamps for the supported epoch range.
int normalizeTimestampSeconds(int value) =>
    value >= _millisecondsEpochFloor ? value ~/ 1000 : value;

/// Converts a seconds-contract timestamp to manifest milliseconds while also
/// tolerating a legacy millisecond value at the call boundary.
int timestampSecondsToMilliseconds(int value) =>
    normalizeTimestampSeconds(value) * 1000;

/// Normalizes a timestamp whose contract is milliseconds while tolerating
/// legacy values persisted in seconds. Existing millisecond precision is kept.
int normalizeTimestampMilliseconds(int value) =>
    value > 0 && value < _millisecondsEpochFloor ? value * 1000 : value;
