import 'dart:math' as math;

import 'exceptions.dart';

/// Controls automatic retries of failed requests.
///
/// A request is retried only *before* any response data was handed to you,
/// so a stream never repeats tokens. By default the client retries up to two
/// times on connection errors and on HTTP 408, 429, 502, 503 and 504, with
/// exponential backoff and jitter, honouring `Retry-After`.
///
/// ```dart
/// Ollama(retryPolicy: const OllamaRetryPolicy(maxRetries: 5));
/// Ollama(retryPolicy: OllamaRetryPolicy.none);
/// ```
class OllamaRetryPolicy {
  const OllamaRetryPolicy({
    this.maxRetries = 2,
    this.initialDelay = const Duration(milliseconds: 400),
    this.maxDelay = const Duration(seconds: 10),
    this.multiplier = 2,
    this.jitter = 0.2,
    this.retryStatusCodes = const {408, 429, 502, 503, 504},
    this.retryConnectionErrors = true,
    this.retryTimeouts = false,
    this.shouldRetry,
  });

  /// Never retries.
  static const OllamaRetryPolicy none = OllamaRetryPolicy(maxRetries: 0);

  /// Retries after the first attempt. `0` disables retries.
  final int maxRetries;

  /// Delay before the first retry.
  final Duration initialDelay;

  /// Upper bound for any single delay (including `Retry-After`).
  final Duration maxDelay;

  /// Backoff growth factor.
  final double multiplier;

  /// Random +/- fraction applied to each delay (0 disables jitter).
  final double jitter;

  /// HTTP status codes that are retried.
  final Set<int> retryStatusCodes;

  /// Whether [OllamaConnectionException]s are retried.
  final bool retryConnectionErrors;

  /// Whether [OllamaTimeoutException]s are retried. Off by default: a slow
  /// first response usually means the model is still loading.
  final bool retryTimeouts;

  /// Overrides the built-in decision. Return `true` to retry.
  final bool Function(OllamaException error, int attempt)? shouldRetry;

  /// Whether [error] should be retried after [attempt] (1-based) attempts.
  bool canRetry(OllamaException error, int attempt) {
    if (attempt > maxRetries) return false;
    if (error is OllamaCancelledException) return false;
    final custom = shouldRetry;
    if (custom != null) return custom(error, attempt);
    if (error is OllamaConnectionException) return retryConnectionErrors;
    if (error is OllamaTimeoutException) return retryTimeouts;
    if (error is OllamaHttpException) {
      return retryStatusCodes.contains(error.statusCode);
    }
    return false;
  }

  /// The delay before retry number [attempt] (1-based).
  Duration delayFor(int attempt, OllamaException error, [math.Random? random]) {
    if (error is OllamaRateLimitException && error.retryAfter != null) {
      return _clamp(error.retryAfter!);
    }
    final base = initialDelay.inMicroseconds *
        math.pow(multiplier, math.max(0, attempt - 1));
    final spread = jitter <= 0
        ? 1.0
        : 1 + ((random ?? _random).nextDouble() * 2 - 1) * jitter;
    return _clamp(Duration(microseconds: (base * spread).round()));
  }

  Duration _clamp(Duration value) {
    if (value > maxDelay) return maxDelay;
    if (value.isNegative) return Duration.zero;
    return value;
  }

  static final math.Random _random = math.Random();
}
