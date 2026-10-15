/// Optional diagnostic transport, separate from ordinary sync downloads.
///
/// Implementations must not refresh/persist credentials, create cloud folders,
/// or write local/cloud data. The complete body is returned: this capability
/// does not promise a transfer-byte cap or immediate cancellation.
abstract interface class CloudReadOnlyAdapter {
  Future<String> downloadReadOnly(String path);
}

enum CloudReadOnlyDownloadStatus {
  reauthenticate,
  missing,
  unreadable,
  invalidPath,
}

/// Safe diagnostic failure with no path, credentials, provider body or cause.
final class CloudReadOnlyDownloadException implements Exception {
  final CloudReadOnlyDownloadStatus status;

  const CloudReadOnlyDownloadException(this.status);

  @override
  String toString() => switch (status) {
    CloudReadOnlyDownloadStatus.reauthenticate =>
      'Cloud diagnostic requires reauthentication.',
    CloudReadOnlyDownloadStatus.missing => 'Cloud diagnostic file is missing.',
    CloudReadOnlyDownloadStatus.unreadable =>
      'Cloud diagnostic file is unreadable.',
    CloudReadOnlyDownloadStatus.invalidPath =>
      'Cloud diagnostic path is invalid.',
  };
}
