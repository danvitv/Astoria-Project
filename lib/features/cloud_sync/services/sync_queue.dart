import 'dart:math';

import 'package:dio/dio.dart';

class SyncQueue {
  static const _maxRetries = 3;
  static const _baseDelayMs = 1000;
  static const _maxDelayMs = 30000;

  int _pendingCount = 0;
  bool _isPaused = false;
  bool _isAborted = false;
  int _generation = 0;

  int get pendingCount => _pendingCount;

  /// Multipart work must stop after Abort/Reset even when a newer sync has
  /// already cleared the aborted flag. This guard owns one queue generation.
  void Function() captureActiveGuard() {
    final generation = _generation;
    return () {
      if (_isAborted || generation != _generation) {
        throw StateError('Sync queue aborted');
      }
    };
  }

  Future<T> enqueue<T>(Future<T> Function() operation, {String? label}) async {
    final generation = _generation;
    final checkActive = captureActiveGuard();
    while (_isPaused) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      checkActive();
    }
    checkActive();

    _pendingCount++;
    try {
      return await _retryWithBackoff(operation, label, checkActive);
    } finally {
      if (generation == _generation) _pendingCount--;
    }
  }

  Future<({List<T> results, List<Object> errors})> enqueueAll<T>(
    List<Future<T> Function()> tasks, {
    int concurrency = 3,
    int delayMs = 300,
  }) async {
    final results = <int, T>{};
    final errors = <Object>[];
    final checkActive = captureActiveGuard();
    var index = 0;

    Future<void> worker() async {
      while (index < tasks.length) {
        checkActive();
        while (_isPaused) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          checkActive();
        }
        final i = index++;
        if (i >= tasks.length) break;
        try {
          final result = await enqueue(tasks[i]);
          results[i] = result;
        } catch (e) {
          errors.add(e);
        }
        checkActive();
        if (delayMs > 0 && index < tasks.length) {
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
      }
    }

    final workers = List.generate(
      tasks.length.clamp(0, concurrency),
      (_) => worker(),
    );
    await Future.wait(workers);

    final sortedKeys = results.keys.toList()..sort();
    final sortedResults = sortedKeys.map((k) => results[k] as T).toList();
    return (results: sortedResults, errors: errors);
  }

  Future<T> _retryWithBackoff<T>(
    Future<T> Function() operation,
    String? label,
    void Function() checkActive,
  ) async {
    var attempt = 0;
    while (true) {
      try {
        checkActive();
        final result = await operation();
        checkActive();
        return result;
      } catch (e) {
        attempt++;
        if (attempt >= _maxRetries || !isRetryableError(e)) {
          rethrow;
        }
        checkActive();
        final delay = _calculateDelay(attempt);
        await Future<void>.delayed(Duration(milliseconds: delay));
        checkActive();
      }
    }
  }

  int _calculateDelay(int attempt) {
    final exponential = _baseDelayMs * (1 << (attempt - 1));
    final capped = exponential.clamp(0, _maxDelayMs);
    final jitter = Random().nextInt(1000) - 500;
    return (capped + jitter).clamp(0, _maxDelayMs);
  }

  static bool isRetryableError(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.connectionError => true,
        DioExceptionType.badResponse =>
          status == 429 || (status != null && status >= 500 && status < 600),
        DioExceptionType.cancel || DioExceptionType.badCertificate => false,
        _ => false,
      };
    }

    final msg = error.toString();
    if (msg.contains('429')) return true;
    if (msg.contains('5') && RegExp(r'5\d\d').hasMatch(msg)) return true;
    if (msg.contains('SocketException') || msg.contains('TimeoutException')) {
      return true;
    }
    if (msg.contains('HttpException') || msg.contains('Connection closed')) {
      return true;
    }
    if (msg.contains('Sync queue aborted')) return false;
    if (msg.contains('4') && RegExp(r'4\d\d').hasMatch(msg)) return false;
    return false;
  }

  void pause() => _isPaused = true;
  void resume() => _isPaused = false;
  void abort() {
    _isAborted = true;
    _generation++;
    _pendingCount = 0;
  }

  void reset() {
    _generation++;
    _isPaused = false;
    _isAborted = false;
    _pendingCount = 0;
  }
}

class SyncQueueAggregateError implements Exception {
  final List<Object> errors;
  SyncQueueAggregateError(this.errors);

  @override
  String toString() {
    final first = errors.first.toString();
    if (errors.length == 1) return first;
    return '$first (+${errors.length - 1} more errors)';
  }
}
