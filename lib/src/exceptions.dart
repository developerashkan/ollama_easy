import 'dart:convert';

import 'models.dart' show OllamaMessage;

/// Base class for every error thrown by `ollama_easy`.
///
/// Catch this to handle all failures, or catch one of the subclasses:
///
/// | Exception                          | When                                        |
/// |------------------------------------|---------------------------------------------|
/// | [OllamaBadRequestException]        | HTTP 400, e.g. invalid options or schema    |
/// | [OllamaAuthenticationException]    | HTTP 401 / 403, missing or wrong API key    |
/// | [OllamaNotFoundException]          | HTTP 404, usually "model not found"         |
/// | [OllamaRateLimitException]         | HTTP 429, has [OllamaRateLimitException.retryAfter] |
/// | [OllamaServerException]            | HTTP 5xx                                    |
/// | [OllamaHttpException]              | any other non-2xx status (base of the above) |
/// | [OllamaStreamException]            | the server sent `{"error": ...}` mid-stream |
/// | [OllamaConnectionException]        | the server could not be reached             |
/// | [OllamaTimeoutException]           | a timeout elapsed                           |
/// | [OllamaCancelledException]         | cancelled by a token, `close()` or the listener |
/// | [OllamaResponseFormatException]    | the response was not the expected JSON      |
/// | [OllamaToolLoopException]          | the tool loop hit its iteration limit       |
class OllamaException implements Exception {
  const OllamaException(this.message, {this.statusCode, this.uri, this.body});

  /// A human readable message. For HTTP errors this is the server's own
  /// `error` text when it sent one.
  final String message;

  /// The HTTP status code, when the error came from an HTTP response.
  final int? statusCode;

  /// The request URL.
  final Uri? uri;

  /// The raw response body, when there was one.
  final String? body;

  /// The exception class name used by [toString].
  String get kind => 'OllamaException';

  @override
  String toString() {
    final code = statusCode == null ? '' : ' HTTP $statusCode.';
    final target = uri == null ? '' : ' ($uri)';
    return '$kind:$code $message$target';
  }

  /// Builds the most specific exception for a non-2xx HTTP response.
  ///
  /// [body] is parsed for Ollama's `{"error": "..."}` shape; otherwise the raw
  /// text (trimmed) becomes the message.
  static OllamaHttpException fromResponse({
    required int statusCode,
    required String body,
    Uri? uri,
    Map<String, String> headers = const {},
  }) {
    final message = errorMessageFromBody(body) ??
        'Ollama request failed with HTTP $statusCode.';
    switch (statusCode) {
      case 400:
      case 422:
        return OllamaBadRequestException(message,
            statusCode: statusCode, uri: uri, body: body);
      case 401:
      case 403:
        return OllamaAuthenticationException(message,
            statusCode: statusCode, uri: uri, body: body);
      case 404:
        return OllamaNotFoundException(message,
            statusCode: statusCode, uri: uri, body: body);
      case 429:
        return OllamaRateLimitException(message,
            statusCode: statusCode,
            uri: uri,
            body: body,
            retryAfter: parseRetryAfter(headers['retry-after']));
    }
    if (statusCode >= 500) {
      return OllamaServerException(message,
          statusCode: statusCode, uri: uri, body: body);
    }
    return OllamaHttpException(message,
        statusCode: statusCode, uri: uri, body: body);
  }

  /// Extracts Ollama's `error` text from a JSON body, or returns the trimmed
  /// body when it is not JSON. Returns `null` for an empty body.
  static String? errorMessageFromBody(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          final error = decoded['error'];
          // Native API: {"error": "..."}.
          if (error is String && error.isNotEmpty) return error;
          // OpenAI-compatible API: {"error": {"message": "..."}}.
          if (error is Map && error['message'] != null) {
            return error['message'].toString();
          }
          if (decoded['message'] is String) return decoded['message'] as String;
        }
      } on FormatException {
        // Fall through to the raw text.
      }
    }
    return trimmed.length > 500 ? '${trimmed.substring(0, 500)}…' : trimmed;
  }

  /// Parses an HTTP `Retry-After` header (seconds or an HTTP date).
  static Duration? parseRetryAfter(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final seconds = num.tryParse(value.trim());
    if (seconds != null) {
      return Duration(milliseconds: (seconds * 1000).round());
    }
    final date = _parseHttpDate(value.trim());
    if (date == null) return null;
    final delay = date.difference(DateTime.now().toUtc());
    return delay.isNegative ? Duration.zero : delay;
  }

  static DateTime? _parseHttpDate(String value) {
    // e.g. "Wed, 21 Oct 2015 07:28:00 GMT"
    final match = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})')
        .firstMatch(value);
    if (match == null) return null;
    const months = [
      'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
      'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
    ];
    final month = months.indexOf(match.group(2)!.toLowerCase()) + 1;
    if (month == 0) return null;
    return DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }
}

/// The server answered with a non-2xx HTTP status.
class OllamaHttpException extends OllamaException {
  const OllamaHttpException(super.message,
      {required int super.statusCode, super.uri, super.body});

  @override
  int get statusCode => super.statusCode!;

  @override
  String get kind => 'OllamaHttpException';
}

/// HTTP 400 (or 422): the request was invalid, e.g. a bad option or schema.
class OllamaBadRequestException extends OllamaHttpException {
  const OllamaBadRequestException(super.message,
      {required super.statusCode, super.uri, super.body});

  @override
  String get kind => 'OllamaBadRequestException';
}

/// HTTP 401 or 403: missing or invalid API key.
class OllamaAuthenticationException extends OllamaHttpException {
  const OllamaAuthenticationException(super.message,
      {required super.statusCode, super.uri, super.body});

  @override
  String get kind => 'OllamaAuthenticationException';
}

/// HTTP 404. Usually the model is not installed: pull it first, for example
/// with `ensureModel`.
class OllamaNotFoundException extends OllamaHttpException {
  const OllamaNotFoundException(super.message,
      {required super.statusCode, super.uri, super.body});

  /// Whether the server said the model was not found.
  bool get isModelNotFound => message.toLowerCase().contains('not found');

  @override
  String get kind => 'OllamaNotFoundException';
}

/// HTTP 429: too many requests (common on Ollama cloud).
class OllamaRateLimitException extends OllamaHttpException {
  const OllamaRateLimitException(super.message,
      {required super.statusCode, super.uri, super.body, this.retryAfter});

  /// The server's `Retry-After` hint, when it sent one.
  final Duration? retryAfter;

  @override
  String get kind => 'OllamaRateLimitException';
}

/// HTTP 5xx: the server failed, e.g. the model ran out of memory.
class OllamaServerException extends OllamaHttpException {
  const OllamaServerException(super.message,
      {required super.statusCode, super.uri, super.body});

  @override
  String get kind => 'OllamaServerException';
}

/// The server reported an error inside a streaming response
/// (a `{"error": "..."}` NDJSON line), or the stream ended early.
class OllamaStreamException extends OllamaException {
  const OllamaStreamException(super.message, {super.uri, super.body});

  @override
  String get kind => 'OllamaStreamException';
}

/// The server could not be reached (DNS, refused connection, reset, CORS on
/// the web, ...).
class OllamaConnectionException extends OllamaException {
  const OllamaConnectionException(super.message, {super.uri, this.cause});

  /// The underlying error, usually an `http.ClientException`.
  final Object? cause;

  @override
  String get kind => 'OllamaConnectionException';
}

/// A timeout elapsed: waiting for response headers, between streamed
/// chunks, or for the whole request.
class OllamaTimeoutException extends OllamaException {
  const OllamaTimeoutException(super.message, {super.uri, this.timeout});

  /// The timeout that elapsed.
  final Duration? timeout;

  @override
  String get kind => 'OllamaTimeoutException';
}

/// The request was cancelled with an [OllamaCancelToken], by `Ollama.close()`,
/// or because the stream listener cancelled its subscription.
class OllamaCancelledException extends OllamaException {
  const OllamaCancelledException(super.message, {super.uri, this.reason});

  /// The value passed to `OllamaCancelToken.cancel`, if any.
  final Object? reason;

  @override
  String get kind => 'OllamaCancelledException';
}

/// The response body was not the JSON the client expected, for example a
/// model ignored the requested JSON format.
class OllamaResponseFormatException extends OllamaException {
  const OllamaResponseFormatException(super.message,
      {super.statusCode, super.uri, super.body, this.cause});

  /// The underlying decode error, if any.
  final Object? cause;

  @override
  String get kind => 'OllamaResponseFormatException';
}

/// `runTools` reached `maxIterations` while the model kept calling tools.
class OllamaToolLoopException extends OllamaException {
  const OllamaToolLoopException(super.message, {this.messages = const []});

  /// The conversation so far, including every tool call and result.
  final List<OllamaMessage> messages;

  @override
  String get kind => 'OllamaToolLoopException';
}
